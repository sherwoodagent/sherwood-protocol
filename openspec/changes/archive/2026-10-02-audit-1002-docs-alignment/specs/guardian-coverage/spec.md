## RENAMED Requirements

- FROM: `### Requirement: WOOD haircut is bounded and rate-limited`
- TO: `### Requirement: WOOD haircut is bounded`
- FROM: `### Requirement: Booking failures never fail the approve vote`
- TO: `### Requirement: Approval recording reverts rather than seat an unbacked approver`

## ADDED Requirements

### Requirement: WOOD is priced by the feed, capped by governance, with no fallback
`woodPriceX8()` SHALL return `haircut(min(feedX8, woodUsdPriceX8))`, floored at 1, where `feedX8` is the wired WOOD/USD feed's answer normalised to 8 decimals. `woodUsdPriceX8` SHALL be an upper cap only and SHALL never be served as a price. `woodPriceX8()` SHALL revert `NoWoodPrice` when the cap is zero or when the feed is unset, codeless, reverts, returns malformed data, answers `<= 0`, normalises to zero, or is older than its configured `maxDelay`. There is no fallback price and no detail view.

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

## MODIFIED Requirements

### Requirement: WOOD haircut is bounded
`setWoodHaircutBps` SHALL be owner-only and SHALL accept only values in `[5_000, 10_000]` bps, with no interval between updates. The haircut default SHALL be `10_000` (no haircut).

#### Scenario: Haircut below the floor
- **WHEN** the owner sets a haircut below 5_000 bps or above 10_000 bps
- **THEN** the call reverts `InvalidParameter`

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
`requireApproveQuorum(governor, proposalId, asset, requiredCoverage)` SHALL measure coverage and return `(coverageRaisedUsd, requiredCoverageUsd)`, where `requiredCoverageUsd = coverageUsd(asset, requiredCoverage)` and `coverageRaisedUsd` is the covering approvers' running aggregate of `min(lock_i, slashableStakeAt(g_i, now)) × woodPriceX8()`, one price read for the cohort; it MAY stop summing once the aggregate reaches `requiredCoverageUsd`, so a fully covered proposal may report a partial sum. The approver set SHALL come from the ledger's own list, never the registry's. Zero committed approvers SHALL always revert `InsufficientApproveCoverage`, even at zero priced coverage; with approvers listed it SHALL revert `InsufficientApproveCoverage` only when the aggregate is zero and short of the requirement, and otherwise return the aggregate. `NoWoodPrice` and the asset feed's `FeedNotConfigured` / `StalePrice` SHALL propagate. The governor SHALL invoke this check at execute for every proposal with a wired ledger and non-zero `requiredCoverage`, at every tier, and SHALL scale `effectiveMaxCapital` and every per-call cap by `coverageRaisedUsd / requiredCoverageUsd` when the aggregate falls short; zero-`requiredCoverage` proposals skip it.

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
- **THEN** execution reverts `InsufficientApproveCoverage`; no vote is possible after `reviewEnd`, so the proposal stays Approved until it expires at `executeBy`

## REMOVED Requirements

### Requirement: WOOD pricing is feed-first with governance fallback
**Reason**: There is no fallback. `woodPriceX8()` is the feed capped by `woodUsdPriceX8` and reverts `NoWoodPrice` without a fresh feed.
**Migration**: Replaced by "WOOD is priced by the feed, capped by governance, with no fallback".

### Requirement: Governance WOOD price is rate-limited upward only
**Reason**: `setWoodUsdPrice` has no interval and no size ceiling; rate limiting is off-chain.
**Migration**: Replaced by "The WOOD price cap has no on-chain rate limit".

### Requirement: Approval recording reserves full coverage per approver
**Reason**: The ledger books the guardian's declared WOOD lock, not a USD reservation.
**Migration**: Replaced by "Approval recording books a guardian-declared WOOD lock".

### Requirement: Quorum tier threshold defaults to every tier
**Reason**: The ledger has no `quorumTierThreshold`. The governor runs the coverage measurement for every proposal with a wired ledger and non-zero required coverage, at every tier.
**Migration**: None. Operators have no threshold to configure.
