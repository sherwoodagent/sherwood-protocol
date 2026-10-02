## MODIFIED Requirements

### Requirement: Age-weighted vote weight

`getPastVotes` SHALL be the age-weighted read: a guardian's raw votable own-stake checkpoint discounted by a linear age factor that ramps from `ageFloorBps` (bps of raw stake) at age 0 to par (10,000 bps) at `maturationPeriod`, then plateaus at par. Its only on-chain consumer is `TokenCourt.vote`. Guardian review votes and emergency block votes do NOT use it: they weigh the raw `getPastStake` (see "Distinct vote-read bases"). Age is measured from the `stakedAt` anchor AS OF THE READ TIMESTAMP: sWOOD SHALL checkpoint the anchor (timestamp-keyed trace, pushed in the same transaction as every anchor write — first stake, top-up re-anchor, unstake request) and `getPastVotes(guardian, ts)` SHALL return `rawOwnCheckpoint(ts) * ageFactorBps(anchorCheckpoint(ts), ts) / 10_000`. Historical reads are therefore exact: a later top-up or re-anchor can neither inflate nor deflate an already-past read. A read at a timestamp before the guardian's first anchor checkpoint sees an empty trace (anchor 0) and a zero raw checkpoint, and returns 0. `getVotes(account)` SHALL return the live equivalent (`getPastVotes` at the current timestamp): at the current timestamp the checkpointed anchor IS the live anchor. Weight MUST never exceed raw stake at the same timestamp. A guardian with a pending unstake request has a zero votable checkpoint and therefore zero weight. The age factor's `ageFloorBps` / `maturationPeriod` parameters are read live at evaluation time, for historical reads as for current ones.

#### Scenario: Fresh stake votes at the floor

- **WHEN** a guardian's stake was anchored at the read timestamp (age 0)
- **THEN** its `getPastVotes` weight is `ageFloorBps` of its raw checkpointed stake

#### Scenario: Matured stake votes at par

- **WHEN** the stake's age at the read timestamp is at least `maturationPeriod`
- **THEN** its `getPastVotes` weight equals its raw checkpointed stake

#### Scenario: A later top-up does not deflate an earlier read

- **WHEN** a guardian stakes, a snapshot timestamp `ts` passes, the guardian tops up (re-anchoring the live `stakedAt` forward past what it was at `ts`), and `getPastVotes(g, ts)` is then evaluated
- **THEN** the result uses the anchor as it stood at `ts` — the same value the read would have returned before the top-up

#### Scenario: Unstake-requested guardian has zero weight

- **WHEN** `getPastVotes` is evaluated at a timestamp after the guardian's unstake request
- **THEN** the result is 0 (the request pushed a zero votable checkpoint)

#### Scenario: Read before the first stake

- **WHEN** `getPastVotes(g, ts)` is evaluated at a timestamp before the guardian's first anchor checkpoint
- **THEN** the result is 0 — the raw trace is empty there, and the empty anchor trace cannot manufacture weight

### Requirement: Distinct vote-read bases — aged, raw, and total
sWOOD SHALL expose three deliberately distinct historical reads. `getPastVotes` is the AGE-WEIGHTED per-guardian weight; `TokenCourt.vote` is its only on-chain consumer. `getPastStake(guardian, ts)` is the RAW votable own-stake checkpoint — the same basis `getPastTotalVotes` sums, so the two are comparable and subtractable; it reads the checkpoint directly with no live, re-anchorable factor. `GuardianRegistry` weighs every guardian review vote and every emergency block vote with `getPastStake` at the proposal's propose-time snapshot (`snapshotAt = propose − 1 s`), against `getPastTotalVotes` at the same instant, so stake placed one block before `propose` votes at full weight. `TokenCourt._participationFloor` also subtracts the accused cohort with `getPastStake`, denying an accused approver the lever of requesting unstake to shrink its own contribution. `getPastTotalVotes(ts)` (and its alias `getPastTotalSupply(ts)`) SHALL return the raw total-active-stake checkpoint; the aged per-account weights sum to at most the total. `getPastVotes` is NOT a term of `getPastTotalVotes`; consumers subtracting from the total MUST use `getPastStake`. sWOOD SHALL NOT implement the full OZ `IVotes` interface (no `delegate`/`delegates`/`delegateBySig`); the read surface exists for Snapshot's `erc20-votes` strategy and on-chain consumers.

#### Scenario: Raw and aged reads diverge on young stake
- **WHEN** a guardian's stake is younger than `maturationPeriod` at timestamp `ts`
- **THEN** `getPastStake(g, ts)` returns the full raw checkpoint while `getPastVotes(g, ts)` returns the age-discounted fraction

#### Scenario: Review ballots are raw
- **WHEN** a guardian staked 30,000 WOOD one block before `propose` and votes Block in that proposal's review or emergency round
- **THEN** its ballot weighs 30,000, not the age-discounted `getPastVotes` figure

#### Scenario: Conservative quorum denominator
- **WHEN** any set of guardians' aged weights (`getPastVotes`) at `ts` are summed
- **THEN** the sum never exceeds `getPastTotalVotes(ts)`

#### Scenario: Unstake request cannot shrink the raw basis retroactively
- **WHEN** a guardian requests unstake after timestamp `ts`
- **THEN** `getPastStake(g, ts)` still returns the pre-request checkpointed amount
