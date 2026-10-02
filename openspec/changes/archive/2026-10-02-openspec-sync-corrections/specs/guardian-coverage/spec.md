## MODIFIED Requirements

### Requirement: Capped-duration coverage horizon
The ledger SHALL refuse to book coverage whose settlement (`executeBy + strategyDuration`) lands more than `MAX_COVERAGE_HORIZON = 60 days` past the current time. `requireWithinCoverageHorizon(executeBy, strategyDuration)` SHALL revert `CoverageHorizonExceeded` beyond the horizon and SHALL be called at propose so the error lands on the proposer; at vote time `recordApproval` SHALL revert `CoverageHorizonExceeded` for a proposal beyond the horizon, taking the approve vote with it. The horizon is expressed in TIME, not epochs, so narrowing the bucket width cannot silently shrink it.

#### Scenario: Over-horizon proposal at propose
- **WHEN** a proposal's `executeBy + strategyDuration` exceeds `block.timestamp + 60 days` and the governor calls `requireWithinCoverageHorizon`
- **THEN** the call reverts `CoverageHorizonExceeded` and the proposal cannot be opened

#### Scenario: Over-horizon at vote
- **WHEN** an approve vote reaches `recordApproval` for a proposal whose settlement is beyond the horizon
- **THEN** `recordApproval` reverts `CoverageHorizonExceeded` and the approve vote reverts with it

### Requirement: Bounded bucket scan
The bucket walk in `openExposure` SHALL be bounded by `MAX_SCAN_BUCKETS = 16`: the constructor and `setChallengeWindow` SHALL reject any `(challengeWindow, epochLength)` combination where `(challengeWindow + 60 days) / epochLength + 2 > 16`. This bound replaces the former `challengeWindow <= epochLength` rule, freeing bucket width to be tuned for release precision.

#### Scenario: Scan-busting parameters rejected
- **WHEN** a challenge window is proposed that would push the bucket walk past 16 buckets at the current epoch length
- **THEN** the setter reverts `InvalidParameter`

### Requirement: Approval release
`releaseApproval(governor, proposalId, guardian)` SHALL be registry-only, SHALL release exactly the recorded WOOD lock from the epoch bucket the lock currently occupies, SHALL be a no-op when nothing is recorded, and SHALL swap-and-pop the guardian out of the approver list in O(1). It SHALL revert `CoverageFrozen` while the proposal's coverage is frozen — a guardian under live challenge may not release and recycle the accused budget.

#### Scenario: Vote change Approve to Block
- **WHEN** the registry releases a recorded approval on an unfrozen proposal
- **THEN** the recorded WOOD lock is subtracted from the bucket it occupies, the lock record is deleted, the guardian is removed from the approver list, and `ExposureReleased` is emitted

#### Scenario: Release under freeze
- **WHEN** `releaseApproval` is called while the proposal's coverage is frozen
- **THEN** the call reverts `CoverageFrozen`

### Requirement: Challenge window bounds
`setChallengeWindow` SHALL reject zero, SHALL enforce the scan bound, and — when a registry is wired and answers `reviewPeriod()` — SHALL enforce the floor `challengeWindow >= registry.reviewPeriod() + 7 days` (the maximum governor execution window), so a bucket always outlives the approve-to-execute gap and one bond cannot cover two live drains. A decrease SHALL additionally be refused below the wired coverage freezer's own `challengeWindow` (`CoverageFreezerUnreadable` when a non-zero freezer cannot answer). `setGuardianRegistry` SHALL re-check the same floor against the incoming registry (tolerantly, when the registry answers `reviewPeriod()`), closing the wiring-order bypass. The window applies retroactively to already-booked buckets: shrinking it frees coverage early, growing it re-counts expired buckets.

#### Scenario: Window below the approve-execute gap
- **WHEN** the owner sets a challenge window below `reviewPeriod + 7 days` while a registry is wired
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Wiring a registry that breaks the floor
- **WHEN** the owner points the ledger at a registry whose `reviewPeriod` makes the current window sit below the floor
- **THEN** `setGuardianRegistry` reverts `InvalidParameter`

### Requirement: Risk-scaled proposer bond
`proposerBondWood(asset, requiredCoverage)` SHALL return the WOOD amount of the proposer bond: the coverage's USD value times `proposerBondBps` (default 100 = 1%), converted at `woodPriceX8()`. It SHALL return zero, without reading the WOOD price, when the bps slice floors to zero USD, and otherwise SHALL revert (fail closed) when WOOD cannot be priced (`NoWoodPrice`). `setProposerBondBps` SHALL accept only values up to 10_000.

#### Scenario: Bond with unset WOOD price
- **WHEN** `proposerBondWood` is called with a non-zero USD slice while no source can price WOOD
- **THEN** the call reverts `NoWoodPrice`

### Requirement: Covered-TVL cap
`requireWithinCoveredTvlCap(asset, requiredCoverage)` SHALL revert `CoveredTvlCapExceeded` when the USD value of the required coverage exceeds `coveredTvlCapUsd`. The cap SHALL default to zero, which fails closed: nothing with non-zero priced coverage can be proposed through a governor wired to the ledger until governance seeds the cap (a zero-coverage proposal passes). The governor SHALL invoke this check at propose whenever a ledger is wired.

#### Scenario: Unseeded cap
- **WHEN** `coveredTvlCapUsd` is zero and a coverage-consuming proposal is opened
- **THEN** the propose call reverts `CoveredTvlCapExceeded`

### Requirement: Freezer rotation refused while anything is frozen
`setCoverageFreezer` SHALL revert `CoverageFrozen` while `frozenCoverageCount() != 0`, so rotating the role can never orphan a live freeze (whose only clearer is the freezer). It SHALL also refuse a non-zero freezer whose own `challengeWindow` exceeds the ledger's (`InvalidParameter`; `CoverageFreezerUnreadable` when it cannot answer). Zero SHALL be a legal freezer value — the unwire switch — but only reachable once every live challenge has drained. `frozenCoverageCount` SHALL expose the global count governance sequences a rotation against.

#### Scenario: Rotation during a live challenge
- **WHEN** the owner attempts to change `coverageFreezer` while any proposal's coverage is frozen
- **THEN** the call reverts `CoverageFrozen`; the rotation is deferred, not forbidden
