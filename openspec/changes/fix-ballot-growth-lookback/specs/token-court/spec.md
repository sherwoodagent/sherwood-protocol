# token-court delta — fix-ballot-growth-lookback

## MODIFIED Requirements

### Requirement: Voting

`vote(caseId, guilty)` SHALL accept a ballot only when all of the following hold, reverting otherwise:

- the case is in phase `Voting` (else `WrongPhase`);
- `block.timestamp < referredAt + voteWindowAtReferral` (else `WindowClosed`);
- the caller has not already voted on this case (else `AlreadyVoted`) — one vote per address, no vote changes;
- the caller is not in the case's accused set (else `AccusedCannotVote`);
- the caller's lookback-clamped ballot weight (defined below) is non-zero (else `NoVotingPower`);
- the caller's present voting power `getVotes(caller)` is non-zero (else `NoPresentHoldings`) — the present-holdings gate.

The ballot's weight SHALL be the MINIMUM of two finished aged weights: `weightNow = getPastVotes(caller, snapshotTs)` and `weightThen = getPastVotes(caller, lookbackTs)`, where `lookbackTs = snapshotTs - FLOOR_LOOKBACK` (clamped at 0). Each side SHALL be evaluated on its OWN instant's state: `weightNow` applies the age factor as of `snapshotTs` to the raw checkpoint at `snapshotTs`, and `weightThen` applies the age factor as of `lookbackTs` — computed from the `stakedAt` anchor AS IT STOOD at `lookbackTs`, not the live anchor — to the raw checkpoint at `lookbackTs`. The weight is therefore never more than what the caller's position was worth at either instant: stake or age acquired inside the window cannot raise it, and events after `lookbackTs` (top-ups, re-anchors) cannot lower the historical side.

The min SHALL NOT apply when no electorate existed at the lookback instant (`getPastTotalVotes(lookbackTs) == 0`, including the clamped-to-zero instant when `snapshotTs <= FLOOR_LOOKBACK`): during the protocol's bootstrap window the weight is the unclamped `weightNow`, mirroring the participation floor's own `earlier == 0` fallback and for the same reason — a clamp against an empty history would make every case in the first `FLOOR_LOOKBACK` of staking history unvotable, a guaranteed `Inconclusive`. The fallback SHALL key on the TOTAL electorate, never on the individual caller's `weightThen` — a per-caller fallback would re-admit exactly the fresh-whale ballot this requirement removes.

The clamped weight is accumulated into `guiltyVotes` or `notGuiltyVotes`, with `VoteCast(caseId, voter, guilty, weight)` emitting the clamped value. Voting SHALL be open: ballots and running tallies are public on-chain the instant they land; there is no commit-reveal.

The lookback distance SHALL be the same `FLOOR_LOOKBACK` constant the participation floor uses, so the ballot numerator and the floor denominator are measured against the same pair of instants; it SHALL remain a constant, not an owner parameter, for the reason already documented on `FLOOR_LOOKBACK` — a settable lookback is a lever to shrink it to zero before a drain.

#### Scenario: Valid vote inside the window

- **WHEN** an unaccused address with non-zero clamped weight and non-zero present holdings votes during the open window
- **THEN** its clamped weight is added to the chosen tally, its ruling is recorded, and `VoteCast` is emitted with that weight

#### Scenario: Mature steady staker keeps full weight

- **WHEN** a guardian whose position was already at par age a `FLOOR_LOOKBACK` before the snapshot and whose raw stake did not change votes, with a non-zero electorate at the lookback instant
- **THEN** the recorded weight equals `getPastVotes(caller, snapshotTs)` exactly — both sides of the min are equal and the clamp is a no-op

#### Scenario: Young steady staker votes at its month-ago worth

- **WHEN** a guardian whose single stake is older than `FLOOR_LOOKBACK` but younger than `maturationPeriod + FLOOR_LOOKBACK` at the snapshot votes, with a non-zero electorate at the lookback instant
- **THEN** the recorded weight is `weightThen` — the position's aged worth at the lookback instant, smaller than today's unclamped read; the discount heals linearly and vanishes once the stake is at par a full lookback before the snapshot

#### Scenario: A top-up never drags the pre-existing position below its month-ago worth

- **WHEN** a guardian with a base staked before `lookbackTs` tops up inside the window and votes
- **THEN** the recorded weight equals the base's aged worth at `lookbackTs` exactly — the top-up neither adds ballot (the raw increment is absent from `weightThen`) nor subtracts it (the historical side is computed from the anchor as of `lookbackTs`, which the top-up's forward re-anchor cannot reach; and the enlarged raw always keeps `weightNow` at or above the pre-top-up weight)

#### Scenario: A reduced position is not rewarded with its historical figure

- **WHEN** a guardian whose position shrank between `lookbackTs` and `snapshotTs` votes, so `weightThen > weightNow`
- **THEN** the recorded weight is `weightNow` — the min can only lower a ballot relative to today's single read, never raise it

#### Scenario: Fresh pre-drain stake carries no ballot

- **WHEN** an address whose first stake landed inside the `FLOOR_LOOKBACK` window before `snapshotTs` calls `vote`, with a non-zero electorate at the lookback instant
- **THEN** the call reverts `NoVotingPower` — its raw checkpoint at `lookbackTs` is zero, so `weightThen` is zero regardless of any age-floor multiplier, closing the fresh-whale ballot (25% of raw under the deployed age floor) that the bare snapshot read admitted

#### Scenario: Bootstrap fallback leaves the ballot unclamped

- **WHEN** a guardian votes on a case whose lookback instant predates the first guardian stake ever (`getPastTotalVotes(lookbackTs) == 0`)
- **THEN** the recorded weight is the unclamped `getPastVotes(caller, snapshotTs)` — the min declines to apply against an empty history rather than silencing the whole bootstrap electorate

#### Scenario: Accused address barred

- **WHEN** an address in the case's accused set calls `vote`
- **THEN** the call reverts `AccusedCannotVote`

#### Scenario: Second vote refused

- **WHEN** an address that already voted on the case calls `vote` again, with either value
- **THEN** the call reverts `AlreadyVoted` — there is no path to change a cast vote

#### Scenario: Vote after the window closes

- **WHEN** `vote` is called at or after `referredAt + voteWindowAtReferral`
- **THEN** the call reverts `WindowClosed`
