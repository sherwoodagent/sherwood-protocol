# token-court delta — fix-ballot-growth-lookback

## MODIFIED Requirements

### Requirement: Voting

`vote(caseId, guilty)` SHALL accept a ballot only when all of the following hold, reverting otherwise:

- the case is in phase `Voting` (else `WrongPhase`);
- `block.timestamp < referredAt + voteWindowAtReferral` (else `WindowClosed`);
- the caller has not already voted on this case (else `AlreadyVoted`) — one vote per address, no vote changes;
- the caller is not in the case's accused set (else `AccusedCannotVote`);
- the caller's growth-clamped ballot weight (defined below) is non-zero (else `NoVotingPower`);
- the caller's present voting power `getVotes(caller)` is non-zero (else `NoPresentHoldings`) — the present-holdings gate.

The ballot's weight SHALL be the aged `getPastVotes` amount at `snapshotTs`, with its RAW basis clamped to the smaller of the caller's raw own stake at `snapshotTs` and at `snapshotTs - FLOOR_LOOKBACK`. Equivalently, with `rawNow` and `rawThen` the raw own-stake checkpoints at those two instants and the age factor evaluated once at `snapshotTs`:

- when `rawNow <= rawThen` (a position that held steady or shrank over the lookback window), the weight SHALL equal `getPastVotes(caller, snapshotTs)` exactly — unchanged from a court without the clamp;
- when `rawNow > rawThen` (a position that grew inside the window), the weight SHALL be scaled by `rawThen / rawNow`, rounding down — only the pre-growth raw level carries a ballot, and the age factor applied to it remains the one at `snapshotTs`.

The clamp SHALL NOT apply when no electorate existed at the lookback instant (`getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) == 0`, including the clamped-to-zero instant when `snapshotTs <= FLOOR_LOOKBACK`): during the protocol's bootstrap window the weight is the unclamped `getPastVotes(caller, snapshotTs)`, mirroring the participation floor's own `earlier == 0` fallback and for the same reason — a clamp against an empty history would make every case in the first `FLOOR_LOOKBACK` of staking history unvotable, a guaranteed `Inconclusive`. The fallback SHALL key on the TOTAL electorate, never on the individual caller's `rawThen` — a per-caller fallback would re-admit exactly the fresh-whale ballot this requirement removes.

The clamped weight is accumulated into `guiltyVotes` or `notGuiltyVotes`, with `VoteCast(caseId, voter, guilty, weight)` emitting the clamped value. Voting SHALL be open: ballots and running tallies are public on-chain the instant they land; there is no commit-reveal.

The lookback distance SHALL be the same `FLOOR_LOOKBACK` constant the participation floor uses, so the ballot numerator and the floor denominator are measured against the same pair of instants; it SHALL remain a constant, not an owner parameter, for the reason already documented on `FLOOR_LOOKBACK` — a settable lookback is a lever to shrink it to zero before a drain.

#### Scenario: Valid vote inside the window

- **WHEN** an unaccused address with non-zero clamped snapshot weight and non-zero present holdings votes during the open window
- **THEN** its clamped weight is added to the chosen tally, its ruling is recorded, and `VoteCast` is emitted with that weight

#### Scenario: Steady staker keeps full weight

- **WHEN** a guardian whose raw own stake is identical at `snapshotTs` and at `snapshotTs - FLOOR_LOOKBACK` votes, with a non-zero electorate at the lookback instant
- **THEN** the recorded weight equals `getPastVotes(caller, snapshotTs)` exactly — the clamp is a no-op for a position that did not grow

#### Scenario: Stake added near the drain is discounted to its prior level

- **WHEN** a guardian whose raw own stake grew between `snapshotTs - FLOOR_LOOKBACK` and `snapshotTs` votes
- **THEN** the recorded weight is `getPastVotes(caller, snapshotTs)` scaled by `rawThen / rawNow` (rounded down) — the increment acquired inside the window carries no ballot, while the pre-existing position still votes at the snapshot's age factor

#### Scenario: A reduced position is not rewarded with its historical figure

- **WHEN** a guardian whose raw own stake shrank between `snapshotTs - FLOOR_LOOKBACK` and `snapshotTs` votes
- **THEN** the recorded weight is the unclamped `getPastVotes(caller, snapshotTs)` — the weight of the SMALLER current position, never the larger historical one

#### Scenario: Fresh pre-drain stake carries no ballot

- **WHEN** an address whose first stake landed inside the `FLOOR_LOOKBACK` window before `snapshotTs` calls `vote`, with a non-zero electorate at the lookback instant
- **THEN** the call reverts `NoVotingPower` — `rawThen` is zero, so the clamped weight is zero, closing the fresh-whale ballot (25% of raw under the deployed age floor) that the bare snapshot read admitted

#### Scenario: Bootstrap fallback leaves the ballot unclamped

- **WHEN** a guardian votes on a case whose lookback instant predates the first guardian stake ever (`getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK) == 0`)
- **THEN** the recorded weight is the unclamped `getPastVotes(caller, snapshotTs)` — the clamp declines to apply against an empty history rather than silencing the whole bootstrap electorate

#### Scenario: Accused address barred

- **WHEN** an address in the case's accused set calls `vote`
- **THEN** the call reverts `AccusedCannotVote`

#### Scenario: Second vote refused

- **WHEN** an address that already voted on the case calls `vote` again, with either value
- **THEN** the call reverts `AlreadyVoted` — there is no path to change a cast vote

#### Scenario: Vote after the window closes

- **WHEN** `vote` is called at or after `referredAt + voteWindowAtReferral`
- **THEN** the call reverts `WindowClosed`
