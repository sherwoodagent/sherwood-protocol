## RENAMED Requirements

- FROM: `### Requirement: WOOD pricing is feed-first with governance fallback`
- TO: `### Requirement: WOOD is priced by the feed, capped by governance, with no fallback`
- FROM: `### Requirement: Governance WOOD price is rate-limited upward only`
- TO: `### Requirement: The WOOD price cap has no on-chain rate limit`
- FROM: `### Requirement: WOOD haircut is bounded and rate-limited`
- TO: `### Requirement: WOOD haircut is bounded`
- FROM: `### Requirement: Approval recording reserves full coverage per approver`
- TO: `### Requirement: Approval recording books a declared WOOD lock`
- FROM: `### Requirement: Booking failures never fail the approve vote`
- TO: `### Requirement: Approval recording reverts rather than seat an unbacked approver`

## MODIFIED Requirements

### Requirement: WOOD is priced by the feed, capped by governance, with no fallback
`woodPriceX8()` SHALL return `haircut(min(feedX8, woodUsdPriceX8))`, floored at 1, where `feedX8` is the wired WOOD/USD feed's answer normalised to 8 decimals. `woodUsdPriceX8` SHALL be an upper cap only and SHALL never be served as a price. `woodPriceX8()` SHALL revert `NoWoodPrice` when the cap is zero or when the feed is unset, codeless, reverts, answers `<= 0`, or is older than its configured `maxDelay`. There is no fallback price and no detail view.

#### Scenario: Healthy feed below the cap
- **WHEN** a WOOD feed is wired, fresh, positive, and below `woodUsdPriceX8`
- **THEN** `woodPriceX8()` returns the feed answer normalised to 8 decimals times `woodHaircutBps / 10_000`

#### Scenario: Cap below the feed
- **WHEN** `woodUsdPriceX8` is below the feed's answer
- **THEN** `woodPriceX8()` returns the cap times `woodHaircutBps / 10_000`, so every bond is valued at the cap

#### Scenario: Stale, non-positive, or reverting feed
- **WHEN** the wired feed is stale beyond `maxDelay`, answers `<= 0`, or reverts
- **THEN** `woodPriceX8()` reverts `NoWoodPrice`

#### Scenario: Feed unwired
- **WHEN** `setWoodFeed(address(0), 0)` is called by the owner
- **THEN** the feed is cleared and every price read reverts `NoWoodPrice`; a clear with `maxDelay != 0`, or a non-zero feed with `maxDelay == 0`, reverts `InvalidParameter`

### Requirement: The WOOD price cap has no on-chain rate limit
`setWoodUsdPrice` SHALL be owner-only and SHALL accept any value at any time, with no interval and no size ceiling; rate limiting is enforced off-chain by a Zodiac module on the owner Safe (see the deployment-docs capability). Zero SHALL remain settable as a hard stop: with a zero cap every price read reverts `NoWoodPrice`. Each update SHALL emit `WoodUsdPriceSet`.

#### Scenario: Large raise in one call
- **WHEN** the owner raises the cap tenfold in one call
- **THEN** the call succeeds

#### Scenario: Crash response
- **WHEN** the owner cuts the cap tenfold in one call
- **THEN** the update is accepted at once, so bonds are not left over-valued during a crash

### Requirement: WOOD haircut is bounded
`setWoodHaircutBps` SHALL be owner-only and SHALL accept only values in `[5_000, 10_000]` bps, with no interval between updates. The haircut default SHALL be `10_000` (no haircut).

#### Scenario: Haircut below the floor
- **WHEN** the owner sets a haircut below 5_000 bps or above 10_000 bps
- **THEN** the call reverts `InvalidParameter`

### Requirement: Approval recording books a declared WOOD lock
`recordApproval(governor, proposalId, guardian, lockWood)` SHALL be callable only by the wired guardian registry and SHALL be idempotent per (proposal, guardian). It SHALL lock `min(lockWood, free budget)` WOOD, where free budget is `kNumerator × guardianStake(guardian) − openExposure(guardian)`, all in WOOD. The lock SHALL be booked into the epoch bucket containing `executeBy + strategyDuration` (floored at the current epoch), recorded per guardian as the single figure that is at once the guardian's booking, pledge and slash base, appended to the ledger's own approver list, and announced via `ExposureRecorded`. There SHALL be no cohort cap: a proposal's locks MAY sum to more than its requirement.

#### Scenario: Successful lock
- **WHEN** the registry records an approval carrying a WOOD amount for a guardian with free budget on a priceable, in-horizon proposal, and the lock clears the slot floor
- **THEN** `min(lockWood, free)` is added to the settlement bucket and recorded for the guardian, and the guardian joins the approver list with `ExposureRecorded` emitted

#### Scenario: Unauthorized caller
- **WHEN** any address other than the wired guardian registry calls `recordApproval` or `releaseApproval`
- **THEN** the call reverts `NotGuardianRegistry`

#### Scenario: Repeat recording is a no-op
- **WHEN** `recordApproval` is called again for a (proposal, guardian) that already holds a non-zero lock
- **THEN** nothing changes (vote-change round trips cannot double-lock)

### Requirement: Approval recording reverts rather than seat an unbacked approver
`recordApproval` SHALL revert, taking the approve vote with it, when: the coverage inputs cannot be read (`CoverageInputsUnreadable`); the need cannot be priced (`coverageUsd` reverts `FeedNotConfigured` or `StalePrice`); WOOD cannot be priced (`woodPriceX8()` reverts `NoWoodPrice`); the lock is zero, the guardian's whole-budget valuation is zero, or the lock is worth less than the slot floor (`ApproveLockBelowFloor`); or settlement lies beyond the coverage horizon (`CoverageHorizonExceeded`). The slot floor is `ceil(needUsd / APPROVER_SLOTS)`, or the guardian's whole-budget valuation when that is no larger and fewer than `APPROVER_SLOTS / 2` approvers are booked. So an approve vote reverts during a WOOD-price or vault-asset-feed outage; a block vote makes no ledger call and still lands.

#### Scenario: Guardian with exhausted budget
- **WHEN** a guardian whose open exposure already meets or exceeds `kNumerator × guardianStake` casts an approve vote
- **THEN** the vote reverts `ApproveLockBelowFloor`

#### Scenario: Unpriceable asset at vote time
- **WHEN** the vault asset's feed is unconfigured or stale during an approve vote
- **THEN** the vote reverts with the feed's error

#### Scenario: Unpriceable WOOD at vote time
- **WHEN** the WOOD feed is unwired or stale, or the cap is zero, during an approve vote
- **THEN** the vote reverts `NoWoodPrice`, while a block vote on the same review lands

### Requirement: Execute-time approve quorum
`requireApproveQuorum(governor, proposalId, asset, requiredCoverage)` SHALL measure coverage and return `(coverageRaisedUsd, requiredCoverageUsd)`, where `requiredCoverageUsd = coverageUsd(asset, requiredCoverage)` and `coverageRaisedUsd` is the covering approvers' aggregate `Σ min(lock_i, recoverable stake_i) × woodPriceX8()`. The approver set SHALL come from the ledger's own list, never the registry's. It SHALL revert `InsufficientApproveCoverage` only when the approver set is empty or the aggregate is zero; a partial aggregate is returned. `NoWoodPrice` SHALL propagate. The governor SHALL invoke this check at execute for every proposal with a wired ledger and non-zero `requiredCoverage`, at every tier, and SHALL scale `effectiveMaxCapital` and every per-call cap by `coverageRaisedUsd / requiredCoverageUsd` when the aggregate falls short; zero-`requiredCoverage` proposals skip it.

#### Scenario: Aggregate coverage across a cohort
- **WHEN** two guardians each lock WOOD worth $600k at execute on a $1M-coverage proposal
- **THEN** the aggregate meets the requirement and the proposal executes at full capital

#### Scenario: Partial coverage scales the proposal
- **WHEN** the covering approvers' aggregate is 80% of `requiredCoverageUsd`
- **THEN** the call returns it without reverting and the governor executes at 80% of `maxCapital`

#### Scenario: Bond shrank since the vote
- **WHEN** an approver's stake (unstake, or a WOOD price fall) is now worth less than its lock
- **THEN** it counts at the shrunken value

#### Scenario: No covering approver
- **WHEN** a proposal with non-zero required coverage reaches execute with no approver, or with a zero aggregate
- **THEN** execution reverts `InsufficientApproveCoverage` and the proposal expires at `executeBy` unless covering approvals arrive

## REMOVED Requirements

### Requirement: Quorum tier threshold defaults to every tier
**Reason**: The ledger has no `quorumTierThreshold`. The governor runs the coverage measurement for every proposal with a wired ledger and non-zero required coverage, at every tier.
**Migration**: None. Operators have no threshold to configure.
