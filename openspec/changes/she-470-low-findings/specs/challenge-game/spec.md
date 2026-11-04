# challenge-game (delta)

## MODIFIED Requirements

### Requirement: An acquittal spends the window only at the quorum; below it the failure is silence and re-arms
`file` SHALL raise `challengeableUntil[reviewKey]` to the baseline deadline `executedAt + strategyDuration + challengeWindow` when the stored value is lower. On the fail path the game SHALL re-arm the proposal's challenge window — raising `challengeableUntil[reviewKey]` to `block.timestamp + challengeWindow` and pinning the ledger's coverage to the same deadline — if and only if `acquitWeight * 10_000 < quorumBpsAtFiling * totalStakeAtFiling`, the proposal is not already convicted, that proposal's window has not been re-armed before, and `block.timestamp + challengeWindow` exceeds the stored `challengeableUntil[reviewKey]`. An extension that does not exceed the deadline already in force SHALL NOT spend the re-arm. An acquittal adjudicates only once it clears the same bar a conviction must: below it the cohort did not decide, and one dust ballot MUST NOT spend the proposal's one re-arm. The re-arm latch SHALL be one-shot per proposal, so repeated silent failures let the window lapse rather than letting a filer cycling addresses pin an honest cohort's coverage indefinitely. `challengeableUntil` SHALL be raise-only on every write.

#### Scenario: Acquittal at the quorum does not re-arm
- **WHEN** a challenge fails with `acquitWeight` at or above `quorumBpsAtFiling` of `totalStakeAtFiling`
- **THEN** `challengeableUntil[reviewKey]` stays at the baseline seeded by `file` and the proposal's ordinary window runs out on its original schedule

#### Scenario: A sub-quorum acquittal does not foreclose the re-arm
- **WHEN** a challenge fails with acquit weight below that bar — one wei, or a substantial 25% of the total against 20% convict at a 3,000 bps quorum
- **THEN** the failure counts as silence in both cases: `challengeableUntil[reviewKey]` is raised and the ledger's coverage is pinned to the same deadline

#### Scenario: Silence re-arms exactly once
- **WHEN** a second challenge against the same proposal also fails in silence
- **THEN** no further re-arm occurs — the first silent failure spent the proposal's one re-arm

#### Scenario: An early silent failure does not spend the re-arm
- **WHEN** on a 30-day strategy a filing fails in silence on day 1, whose extension falls before the baseline deadline, and a later filing near the baseline also fails in silence
- **THEN** the first failure leaves the baseline unchanged and the latch unspent, and the later failure re-arms the window past the baseline
