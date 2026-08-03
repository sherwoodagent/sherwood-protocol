# token-court delta — fix-ballot-growth-lookback

## MODIFIED Requirements

### Requirement: Voting

`vote(caseId, guilty)` SHALL accept a ballot only when all of the following hold, reverting otherwise:

- the case is in phase `Voting` (else `WrongPhase`);
- `block.timestamp < referredAt + voteWindowAtReferral` (else `WindowClosed`);
- the caller has not already voted on this case (else `AlreadyVoted`) — one vote per address, no vote changes;
- the caller is not in the case's accused set (else `AccusedCannotVote`);
- the caller's ballot weight (defined below) is non-zero (else `NoVotingPower`);
- the caller's present voting power `getVotes(caller)` is non-zero (else `NoPresentHoldings`) — the present-holdings gate.

The ballot's weight SHALL be growth-gated: with `lookbackTs = snapshotTs - FLOOR_LOOKBACK` (clamped at 0), `rawNow = getPastStake(caller, snapshotTs)` and `rawThen = getPastStake(caller, lookbackTs)` — the same raw votable-stake trace the aged weights are computed from —

- when `rawNow > rawThen` (strict) AND an electorate existed at the lookback instant (`getPastTotalVotes(lookbackTs) != 0`), the weight SHALL be the MINIMUM of two finished aged weights: `weightNow = getPastVotes(caller, snapshotTs)` and `weightThen = getPastVotes(caller, lookbackTs)`;
- otherwise the weight SHALL be `weightNow` alone — bit-identical to the single snapshot read performed today, with neither `weightThen` nor the clamp evaluated.

Each side of the min SHALL be evaluated on its OWN instant's state: `weightNow` applies the age factor as of `snapshotTs` to the raw checkpoint at `snapshotTs`, and `weightThen` applies the age factor as of `lookbackTs` — computed from the `stakedAt` anchor AS IT STOOD at `lookbackTs`, not the live anchor — to the raw checkpoint at `lookbackTs`. Stake acquired inside the window therefore cannot raise the weight (it is absent from `weightThen`, and the gate its arrival triggers caps the ballot at the month-ago worth), while events after `lookbackTs` (top-ups, re-anchors) cannot lower the historical side.

The gate SHALL compare RAW stake, not weight: raw growth is the attack vector (capital arriving inside the window), while weight growth without raw growth is pure aging — legitimate by construction, since age cannot be acquired inside the window without capital that was already present a full lookback before the snapshot. The comparison SHALL be strict (`>`): a position that shrank or held over the window never has the clamp evaluate, and in particular a shrunken position is never handed the higher historical figure.

The bootstrap fallback SHALL key on the TOTAL electorate, never on the individual caller's `rawThen` or `weightThen` (a per-caller fallback would re-admit exactly the fresh-whale ballot this requirement removes — a zero lookback position is the attack's signature, not an excuse): when `getPastTotalVotes(lookbackTs) == 0` (including the clamped-to-zero instant when `snapshotTs <= FLOOR_LOOKBACK`), the weight is the unclamped `weightNow`, mirroring the participation floor's own `earlier == 0` fallback and for the same reason — a clamp against an empty history would make every case in the first `FLOOR_LOOKBACK` of staking history unvotable, a guaranteed `Inconclusive`.

The recorded weight is accumulated into `guiltyVotes` or `notGuiltyVotes`, with `VoteCast(caseId, voter, guilty, weight)` emitting the recorded value. Voting SHALL be open: ballots and running tallies are public on-chain the instant they land; there is no commit-reveal.

The lookback distance SHALL be the same `FLOOR_LOOKBACK` constant the participation floor uses, so the ballot numerator and the floor denominator are measured against the same pair of instants; it SHALL remain a constant, not an owner parameter, for the reason already documented on `FLOOR_LOOKBACK` — a settable lookback is a lever to shrink it to zero before a drain.

#### Scenario: Valid vote inside the window

- **WHEN** an unaccused address with non-zero ballot weight and non-zero present holdings votes during the open window
- **THEN** its weight is added to the chosen tally, its ruling is recorded, and `VoteCast` is emitted with that weight

#### Scenario: Steady staker is bit-identical to today at every age

- **WHEN** a guardian whose raw stake at the lookback instant is greater than or equal to its raw stake at the snapshot votes, with any electorate history
- **THEN** the recorded weight equals `getPastVotes(caller, snapshotTs)` exactly — the gate is false, the clamp never evaluates, and the ballot matches today's single-read behaviour whether the position is 31 days old, 45 days old, or years old

#### Scenario: Fresh pre-drain stake carries no ballot

- **WHEN** an address whose first stake landed inside the `FLOOR_LOOKBACK` window before `snapshotTs` calls `vote`, with a non-zero electorate at the lookback instant
- **THEN** the call reverts `NoVotingPower` — its raw checkpoint at `lookbackTs` is zero, so the gate is unavoidably true and `weightThen` is zero regardless of any age-floor multiplier, closing the fresh-whale ballot (25% of raw under the deployed age floor) that the bare snapshot read admitted

#### Scenario: A drain-time top-up on a pre-existing position buys nothing

- **WHEN** an address that held raw stake `P` at the lookback instant tops up by any amount inside the window and votes, with a non-zero electorate at the lookback instant
- **THEN** the recorded weight is at most the pre-existing position's aged worth at the lookback instant — the increment is absent from `weightThen`, the gate its arrival triggers pins the ballot to the min, and the recorded weight is unmoved by the increment's size

#### Scenario: A top-up never drags the pre-existing position below its month-ago worth

- **WHEN** a guardian with a base staked at or before `lookbackTs` tops up inside the window and votes
- **THEN** the recorded weight equals the base's aged worth at `lookbackTs` exactly — never a wei below it: the historical side is computed from the anchor and raw checkpoint as of `lookbackTs`, which the top-up's forward re-anchor cannot reach, and the enlarged raw keeps `weightNow` at or above the base's snapshot worth, so the min lands on `weightThen`

#### Scenario: The min pays no more than current worth even on the growth path

- **WHEN** a guardian whose raw stake grew over the window but whose aged snapshot weight fell below its lookback weight (a re-anchoring sequence) votes, with a non-zero electorate at the lookback instant
- **THEN** the recorded weight is `weightNow`, the smaller side — the clamp is a `min`, so a gated voter never collects the larger historical figure either

#### Scenario: A reduced position is not rewarded with its historical figure

- **WHEN** a guardian whose raw stake shrank between `lookbackTs` and `snapshotTs` votes
- **THEN** the recorded weight is `weightNow` — the strict gate is false, and the (larger) historical weight is never consulted

#### Scenario: Bootstrap fallback leaves the ballot unclamped

- **WHEN** a guardian whose raw stake grew over the window votes on a case whose lookback instant predates the first guardian stake ever (`getPastTotalVotes(lookbackTs) == 0`)
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
