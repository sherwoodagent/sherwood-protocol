# guardian-staking delta — fix-ballot-growth-lookback

## MODIFIED Requirements

### Requirement: Age-weighted vote weight

A guardian's vote weight SHALL be its raw votable own-stake checkpoint discounted by a linear age factor: the factor ramps from `ageFloorBps` (bps of raw stake) at age 0 to par (10,000 bps) at `maturationPeriod`, then plateaus at par. Age is measured from the `stakedAt` anchor AS OF THE READ TIMESTAMP: sWOOD SHALL checkpoint the anchor (timestamp-keyed trace, pushed in the same transaction as every anchor write — first stake, top-up re-anchor, unstake request) and `getPastVotes(guardian, ts)` SHALL return `rawOwnCheckpoint(ts) * ageFactorBps(anchorCheckpoint(ts), ts) / 10_000`. Historical reads are therefore exact: a later top-up or re-anchor can neither inflate nor deflate an already-past read (the former live-anchor saturation, "deflation-only drift", is removed). A read at a timestamp before the guardian's first anchor checkpoint sees an empty trace (anchor 0) and a zero raw checkpoint, and returns 0. `getVotes(account)` SHALL return the live equivalent (`getPastVotes` at the current timestamp), which is unchanged: at the current timestamp the checkpointed anchor IS the live anchor. Weight MUST never exceed raw stake at the same timestamp. A guardian with a pending unstake request has a zero votable checkpoint and therefore zero weight. The age factor's `ageFloorBps` / `maturationPeriod` parameters are read live at evaluation time, for historical reads as for current ones — parameter changes re-price history identically to today; the anchor trace does not change that.

#### Scenario: Fresh stake votes at the floor

- **WHEN** a guardian's stake was anchored at the read timestamp (age 0)
- **THEN** its vote weight is `ageFloorBps` of its raw checkpointed stake

#### Scenario: Matured stake votes at par

- **WHEN** the stake's age at the read timestamp is at least `maturationPeriod`
- **THEN** its vote weight equals its raw checkpointed stake

#### Scenario: A later top-up does not deflate an earlier read

- **WHEN** a guardian stakes, a snapshot timestamp `ts` passes, the guardian tops up (re-anchoring the live `stakedAt` forward past what it was at `ts`), and `getPastVotes(g, ts)` is then evaluated
- **THEN** the result uses the anchor as it stood at `ts` — the same value the read would have returned before the top-up — not the re-anchored live value that previously saturated the age toward the floor

#### Scenario: Unstake-requested guardian has zero weight

- **WHEN** `getPastVotes` is evaluated at a timestamp after the guardian's unstake request
- **THEN** the result is 0 (the request pushed a zero votable checkpoint)

#### Scenario: Read before the first stake

- **WHEN** `getPastVotes(g, ts)` is evaluated at a timestamp before the guardian's first anchor checkpoint
- **THEN** the result is 0 — the raw trace is empty there, and the empty anchor trace cannot manufacture weight
