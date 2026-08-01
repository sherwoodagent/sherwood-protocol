# Guardian Coverage Specification

## Purpose

Dollar-denominated coverage accounting for the guardian economic-security model: guardians who approve a coverage-consuming proposal book USD exposure against their slashable WOOD bond, execution requires the covering approvers' aggregate bond to meet the proposal's required coverage, and a live challenge freezes the committed coverage so accused collateral cannot exit. Implemented by `src/ExposureLedger.sol` (interface `src/interfaces/IExposureLedger.sol`), consumed by `GuardianRegistry` (recording at approve-vote time), `SyndicateGovernor` (covered-TVL check at propose, approve quorum at execute, guardian fee at settlement), `ChallengeGame` (freeze), and `StakedWood` (exit gate).

## Requirements

### Requirement: Slashable bond valuation
The ledger SHALL value a guardian's slashable bond in USD (8-decimal price) as `ownStake(g) × woodPriceX8() / 1e8`, where `ownStake` is read from sWOOD's `guardianStake`. Only the guardian's own stake counts — there is no delegated-inbound term (delegation is out of scope for v1).

#### Scenario: Bond priced from own stake
- **WHEN** `slashableBondUsd(guardian)` is called for a guardian with staked WOOD
- **THEN** it returns the guardian's own stake multiplied by the current haircut WOOD/USD price, with no delegated component

### Requirement: WOOD pricing is feed-first with governance fallback
`woodPriceX8()` SHALL return the Chainlink WOOD/USD feed price normalised to 8 decimals when a feed is wired and healthy, and SHALL fall back to the owner-set `woodUsdPriceX8` — without reverting — when the feed is unset, returns a non-positive answer, is older than its configured `maxDelay`, or reverts. The haircut `woodHaircutBps` SHALL be applied to BOTH the feed price and the fallback price. `woodPriceDetail()` SHALL expose whether the returned price came from the fallback, so monitoring can observe the degraded path.

#### Scenario: Healthy feed
- **WHEN** a WOOD feed is wired, fresh, and returns a positive answer
- **THEN** `woodPriceX8()` returns the feed answer normalised to 8 decimals times `woodHaircutBps / 10_000`, and `woodPriceDetail()` reports `usingFallback == false`

#### Scenario: Stale, non-positive, or reverting feed
- **WHEN** the wired feed is stale beyond `maxDelay`, answers `<= 0`, or reverts
- **THEN** `woodPriceX8()` returns `woodUsdPriceX8 × woodHaircutBps / 10_000` without reverting, and `woodPriceDetail()` reports `usingFallback == true`

#### Scenario: Feed unwired
- **WHEN** `setWoodFeed(address(0), 0)` is called by the owner
- **THEN** the feed is cleared and pricing returns to the governance fallback; a clear with `maxDelay != 0`, or a non-zero feed with `maxDelay == 0`, reverts `InvalidParameter`

### Requirement: Governance WOOD price is rate-limited upward only
`setWoodUsdPrice` SHALL be owner-only, SHALL reject any update within `1 day` of the previous update (first-ever update exempt), and SHALL reject any upward move above `2×` the current price (recovery from a current price of zero exempt). Downward moves SHALL NOT be bounded — the price exists to absorb a WOOD crash. Zero SHALL remain settable as the emergency stop. Each accepted update SHALL emit `WoodUsdPriceSet`.

#### Scenario: Upward move beyond 2x
- **WHEN** the owner sets a new price greater than twice the current non-zero price
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Update inside the interval
- **WHEN** the owner sets a price less than 1 day after the previous set (and a previous set exists)
- **THEN** the call reverts `InvalidParameter`, so a zero-then-restore round trip costs at least a day

#### Scenario: Crash response
- **WHEN** the owner cuts the price by 10x in one update
- **THEN** the update is accepted (subject only to the interval), so bonds are not left over-valued during a crash

### Requirement: WOOD haircut is bounded and rate-limited
`setWoodHaircutBps` SHALL be owner-only and SHALL accept only values in `[5_000, 10_000]` bps, rejecting updates within `1 day` of the previous haircut update (first exempt). The haircut default SHALL be `10_000` (no haircut), so wiring a feed alone does not change valuations.

#### Scenario: Haircut below the floor
- **WHEN** the owner sets a haircut below 5_000 bps or above 10_000 bps
- **THEN** the call reverts `InvalidParameter`

### Requirement: Asset coverage pricing fails closed
`coverageUsd(asset, amount)` SHALL return the USD-18 value of `amount` of `asset` using the registered Chainlink feed, flooring on conversion, and SHALL revert `FeedNotConfigured` when the asset has no registered feed and `StalePrice` when the feed answer is non-positive or older than its `maxDelay`. A proposal in an unpriceable asset cannot be coverage-checked and therefore cannot proceed through any path that requires pricing.

#### Scenario: Unregistered asset
- **WHEN** `coverageUsd` is called for an asset with no feed configured
- **THEN** the call reverts `FeedNotConfigured`

#### Scenario: Stale asset feed
- **WHEN** the asset's feed answer is older than the registered `maxDelay`
- **THEN** the call reverts `StalePrice`

### Requirement: Epoch-bucketed exposure accounting
Exposure SHALL be booked into epoch buckets of immutable width `epochLength` anchored at `epochGenesis` (deploy time). `openExposureUsd(guardian)` SHALL sum every bucket whose challenge window has not elapsed — from bucket `(elapsed − challengeWindow) / epochLength` (0 when `elapsed <= challengeWindow`) forward through `(elapsed + 60 days) / epochLength` — so forward-dated settlement bookings are counted and a bucket expires exactly at `bucketEnd + challengeWindow`. `epochLength` SHALL be immutable because changing it would shift every existing bucket index.

#### Scenario: Bucket expiry recycles budget
- **WHEN** a bucket's end plus the challenge window has elapsed
- **THEN** that bucket no longer counts toward `openExposureUsd` and the guardian's budget recycles

#### Scenario: Forward-dated bookings are visible
- **WHEN** a commitment was booked into a future settlement bucket
- **THEN** `openExposureUsd` includes it immediately, so the batching cap sees pledged budget as consumed

### Requirement: Capped-duration coverage horizon
The ledger SHALL refuse to book coverage whose settlement (`executeBy + strategyDuration`) lands more than `MAX_COVERAGE_HORIZON = 60 days` past the current time. `requireWithinCoverageHorizon(executeBy, strategyDuration)` SHALL revert `CoverageHorizonExceeded` beyond the horizon and SHALL be called at propose so the error lands on the proposer; at vote time `recordApproval` SHALL book nothing (not revert) for a proposal beyond the horizon. The horizon is expressed in TIME, not epochs, so narrowing the bucket width cannot silently shrink it.

#### Scenario: Over-horizon proposal at propose
- **WHEN** a proposal's `executeBy + strategyDuration` exceeds `block.timestamp + 60 days` and the governor calls `requireWithinCoverageHorizon`
- **THEN** the call reverts `CoverageHorizonExceeded` and the proposal cannot be opened

#### Scenario: Over-horizon at vote
- **WHEN** an approve vote reaches `recordApproval` for a proposal whose settlement is beyond the horizon
- **THEN** the ledger books nothing and returns, leaving the vote itself to succeed

### Requirement: Bounded bucket scan
The bucket walk in `openExposureUsd` SHALL be bounded by `MAX_SCAN_BUCKETS = 16`: the constructor and `setChallengeWindow` SHALL reject any `(challengeWindow, epochLength)` combination where `(challengeWindow + 60 days) / epochLength + 2 > 16`. This bound replaces the former `challengeWindow <= epochLength` rule, freeing bucket width to be tuned for release precision.

#### Scenario: Scan-busting parameters rejected
- **WHEN** a challenge window is proposed that would push the bucket walk past 16 buckets at the current epoch length
- **THEN** the setter reverts `InvalidParameter`

### Requirement: Approval recording reserves full coverage per approver
`recordApproval(governor, proposalId, guardian)` SHALL be callable only by the wired guardian registry and SHALL be idempotent per (proposal, guardian). It SHALL book a RESERVATION of `min(free budget, the proposal's full USD coverage)` — never merely the still-uncovered remainder — where free budget is `kNumerator × slashableBondUsd(guardian) − openExposureUsd(guardian)`. The reservation SHALL be booked into the epoch bucket containing `executeBy + strategyDuration` (floored at the current epoch), added to the proposal's committed total, recorded per-guardian, appended to the ledger's own approver list, and announced via `ExposureRecorded`.

#### Scenario: Successful booking
- **WHEN** the registry records an approval for a guardian with free budget on a priceable, in-horizon proposal with non-zero coverage
- **THEN** the guardian's reservation of `min(free, needUsd)` is added to the settlement bucket and the committed total, and the guardian joins the approver list with `ExposureRecorded` emitted

#### Scenario: Unauthorized caller
- **WHEN** any address other than the wired guardian registry calls `recordApproval` or `releaseApproval`
- **THEN** the call reverts `NotGuardianRegistry`

#### Scenario: Repeat recording is a no-op
- **WHEN** `recordApproval` is called again for a (proposal, guardian) that already holds a non-zero recorded exposure
- **THEN** nothing changes (vote-change round trips cannot double-book)

### Requirement: Booking failures never fail the approve vote
`recordApproval` SHALL book nothing and return — never revert — when the asset price is unreadable (unconfigured or stale feed), when the proposal's required coverage prices to zero, when the guardian has no free budget (`open >= cap`), or when settlement lies beyond the coverage horizon. The exposure cap is enforced by committing zero and letting the execute-time quorum fail, not by reverting the vote; `ExposureCapExceeded` is retained in the ABI but never thrown.

#### Scenario: Guardian with exhausted budget
- **WHEN** a guardian whose open exposure already meets or exceeds `kNumerator × slashableBondUsd` casts an approve vote
- **THEN** the vote succeeds, the ledger books nothing, and the proposal can only execute if other approvers cover it

#### Scenario: Unpriceable asset at vote time
- **WHEN** the vault asset's feed is unconfigured or stale during an approve vote
- **THEN** the vote succeeds with nothing booked, so the review is never forced block-only

### Requirement: Approval release
`releaseApproval(governor, proposalId, guardian)` SHALL be registry-only, SHALL release exactly the recorded amount from exactly the bucket it was booked into, SHALL be a no-op when nothing is recorded, and SHALL swap-and-pop the guardian out of the approver list in O(1). It SHALL revert `CoverageFrozen` while the proposal's coverage is frozen — a guardian under live challenge may not release and recycle the accused budget.

#### Scenario: Vote change Approve to Block
- **WHEN** the registry releases a recorded approval on an unfrozen proposal
- **THEN** the recorded USD is subtracted from the original bucket and the committed total, the guardian is removed from the approver list, and `ExposureReleased` is emitted

#### Scenario: Release under freeze
- **WHEN** `releaseApproval` is called while the proposal's coverage is frozen
- **THEN** the call reverts `CoverageFrozen`

### Requirement: Execute-time approve quorum
`requireApproveQuorum(governor, proposalId, asset, requiredCoverage)` SHALL revert `InsufficientApproveCoverage` unless the covering approvers' aggregate `Σ min(reservation_i, live slashableBondUsd_i)` meets `coverageUsd(asset, requiredCoverage)`. The approver set SHALL come from the ledger's own list, never the registry's. Zero committed approvers SHALL always revert, even at zero priced coverage. The governor SHALL invoke this check at execute for every proposal with a wired ledger, non-zero `requiredCoverage`, and `envelopeTier >= quorumTierThreshold`; zero-`requiredCoverage` proposals keep optimistic passage.

#### Scenario: Aggregate coverage across a cohort
- **WHEN** two guardians each hold a live bond worth $600k and both reserved on a $1M-coverage proposal
- **THEN** the quorum passes on the aggregate — no single approver must cover the proposal alone

#### Scenario: Bond shrank since the vote
- **WHEN** an approver's live bond (unstake, or a WOOD price fall) is now worth less than its reservation
- **THEN** it counts at the shrunken live value, so coverage must still hold in dollars at execution

#### Scenario: No covering approver
- **WHEN** a coverage-consuming proposal at or above the tier threshold reaches execute with no live committed approver
- **THEN** execution reverts `InsufficientApproveCoverage` and the proposal expires at `executeBy` unless covering approvals arrive

### Requirement: Quorum tier threshold defaults to every tier
`quorumTierThreshold` SHALL default to `0`, making the approve quorum fail-closed for EVERY envelope tier (ROE validation resolved: the gate passes at tier 0/1 and fails at tier 2, and enforcement below tier 2 is a correctness fix). The owner setter SHALL accept only values `0..3`, where `3` disables the quorum for all tiers. Tier-2 exposure remains admissible on-chain — the proposed on-chain tier ceiling was dropped in favour of off-chain incentives.

#### Scenario: Threshold out of range
- **WHEN** the owner sets a threshold greater than 3
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Launch default
- **WHEN** the ledger is deployed
- **THEN** `quorumTierThreshold` is 0 without any setter call, so a deployment that forgets configuration still enforces the quorum at every tier

### Requirement: Covered-TVL cap
`requireWithinCoveredTvlCap(asset, requiredCoverage)` SHALL revert `CoveredTvlCapExceeded` when the USD value of the required coverage exceeds `coveredTvlCapUsd`. The cap SHALL default to zero, which fails closed: nothing can be proposed through a wired governor until governance seeds the cap. The governor SHALL invoke this check at propose.

#### Scenario: Unseeded cap
- **WHEN** `coveredTvlCapUsd` is zero and a coverage-consuming proposal is opened
- **THEN** the propose call reverts `CoveredTvlCapExceeded`

### Requirement: Allocation is pro-rata over the effective total
`allocatedUsd(governor, proposalId, guardian)` SHALL return the guardian's actual carried share: its `min(reservation, live bond)` scaled by `needUsd / effectiveTotal` when the proposal is over-subscribed (`effectiveTotal > needUsd`, rounding down), and the full `min(reservation, live bond)` otherwise — never scaled up to cover a shortfall. The effective total SHALL be `Σ min(reservation_i, live bond_i)` so a guardian whose bond has gone cannot dilute the survivors' shares. Allocations SHALL be computed lazily at read time, so a departing approver's share transfers to the remaining approvers on the next read and no settlement keeper is load-bearing. `allocatedUsd` SHALL revert on an unpriceable asset (deliberate asymmetry with `recordApproval`: sizing a slash off an unvouched price is the unsafe direction). `liabilityUsd` SHALL return `min(needUsd, effectiveTotal)` — the cohort's single-number actual liability, never the sum of reservations.

#### Scenario: Over-subscribed split
- **WHEN** two approvers each reserved the full coverage of a proposal whose need is $8,000
- **THEN** each is allocated $4,000, not the $8,000 reserved

#### Scenario: Challenger bond sizing
- **WHEN** an external caller (e.g. the challenge game) needs what a conviction can actually take
- **THEN** `liabilityUsd` returns `min(needUsd, effectiveTotal)` so bonds are sized off allocations, not reservations

### Requirement: Coverage settlement returns over-reservations
`settleCoverage(governor, proposalId)` SHALL be permissionless and safe to skip. It SHALL revert `ReviewNotClosed` unless `executeBy` is set and `block.timestamp > executeBy` (strictly after — no overlap with the last executable instant), so no third party can collapse the quorum's reservation cushion while the proposal is still executable. It SHALL be idempotent via a settled flag. When the reserved total exceeds the priced need, it SHALL collapse each reservation to its pro-rata allocation, release the excess from each guardian's bucket, and assign the rounding residue to the first live holder ONLY in the over-subscribed branch (an under-covered cohort must not have phantom exposure invented for it). When the coverage is unpriceable it SHALL return without settling (retry later); when under-subscribed or empty it SHALL mark settled with no changes. Settlement SHALL emit `CoverageSettled(reviewKey, reservedTotal, allocatedTotal)`.

#### Scenario: Settling before the execution window closes
- **WHEN** `settleCoverage` is called at or before `executeBy`, or before `executeBy` is set
- **THEN** the call reverts `ReviewNotClosed`

#### Scenario: Over-subscribed settlement
- **WHEN** settlement runs on a proposal whose reservations exceed its need and whose effective total exceeds its need
- **THEN** each approver's booking shrinks to its allocation, freed budget returns to the guardians' buckets immediately, the truncation residue lands on the first holder so the aggregate equals the need, and `CoverageSettled` is emitted

#### Scenario: Shrunken cohort settlement
- **WHEN** bonds have shrunk so the effective total is below the need, though raw reservations exceeded it
- **THEN** no residue is credited to anyone — the under-covered proposal stays under-covered

#### Scenario: Double settlement
- **WHEN** `settleCoverage` is called on an already-settled proposal
- **THEN** it returns without re-dividing the settled numbers

### Requirement: Per-approver slash rates
`slashBpsFor(governor, proposalId)` SHALL return, positionally aligned with the ledger's approver list, each approver's slash rate in bps of their own live slashable stake: their ALLOCATION (never their reservation) divided by their live bond, rounding UP so the cohort's recovered sum never falls below the loss by truncation. A rate SHALL saturate at 10_000 bps when the owed amount meets or exceeds the live bond or the live bond is zero. A guardian with a zero commitment (released, or an approval that booked nothing) SHALL owe 0 bps. The view inherits pricing reverts: a stale asset feed makes a conviction unpriceable and the call reverts.

#### Scenario: Rate priced on allocation
- **WHEN** two approvers each reserved $5,000 on an $8,000-need proposal and carry $4,000 allocations
- **THEN** each rate is derived from $4,000 owed, not from the $5,000 reservation

#### Scenario: Bond gone
- **WHEN** an approver's live bond is zero or below its owed allocation
- **THEN** the rate is pinned at 10_000 bps and recovery is bounded by the live stake — the shortfall is the residual after the execute-time quorum, not a gate hole

### Requirement: Coverage freeze pins release and exit
`freezeCoverage` and `unfreezeCoverage` SHALL be callable only by the owner-set `coverageFreezer` (the challenge game). A freeze SHALL pin exactly one proposal's committed coverage — never the guardians' whole stake or other approvals — blocking `releaseApproval` for that proposal and incrementing a per-guardian frozen-commitment COUNT for every listed approver with a live booking. `hasFrozenCoverage(guardian)` SHALL report whether any frozen proposal names the guardian, and sWOOD gates the unstake claim on it, so bucket expiry (pure wall-clock) cannot let accused collateral walk out mid-challenge. Freeze and unfreeze SHALL be idempotent (counters move only when the flag flips), and unfreeze SHALL clear exactly the per-guardian marks its freeze set.

#### Scenario: Freeze by non-freezer
- **WHEN** any address other than `coverageFreezer` calls `freezeCoverage` or `unfreezeCoverage`
- **THEN** the call reverts `NotCoverageFreezer`

#### Scenario: Accused guardian cannot exit
- **WHEN** a proposal naming a guardian is frozen and the guardian's epoch buckets have aged out
- **THEN** `hasFrozenCoverage(guardian)` is true and the sWOOD unstake claim is refused until the challenge resolves and unfreezes

#### Scenario: Repeated freeze
- **WHEN** `freezeCoverage` is called twice for the same proposal
- **THEN** the per-guardian counters do not drift; the second call only re-emits the event

### Requirement: Freezer rotation refused while anything is frozen
`setCoverageFreezer` SHALL revert `CoverageFrozen` while `frozenCoverageCount() != 0`, so rotating the role can never orphan a live freeze (whose only clearer is the freezer). Zero SHALL be a legal freezer value — the unwire switch — but only reachable once every live challenge has drained. `frozenCoverageCount` SHALL expose the global count governance sequences a rotation against.

#### Scenario: Rotation during a live challenge
- **WHEN** the owner attempts to change `coverageFreezer` while any proposal's coverage is frozen
- **THEN** the call reverts `CoverageFrozen`; the rotation is deferred, not forbidden

### Requirement: Challenge window bounds
`setChallengeWindow` SHALL reject zero, SHALL enforce the scan bound, and — when a registry is wired — SHALL enforce the floor `challengeWindow >= registry.reviewPeriod() + 7 days` (the maximum governor execution window), so a bucket always outlives the approve-to-execute gap and one bond cannot cover two live drains. `setGuardianRegistry` SHALL re-check the same floor against the incoming registry (tolerantly, when the registry answers `reviewPeriod()`), closing the wiring-order bypass. The window applies retroactively to already-booked buckets: shrinking it frees coverage early, growing it re-counts expired buckets.

#### Scenario: Window below the approve-execute gap
- **WHEN** the owner sets a challenge window below `reviewPeriod + 7 days` while a registry is wired
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Wiring a registry that breaks the floor
- **WHEN** the owner points the ledger at a registry whose `reviewPeriod` makes the current window sit below the floor
- **THEN** `setGuardianRegistry` reverts `InvalidParameter`

### Requirement: Risk-scaled proposer bond
`proposerBondWood(asset, requiredCoverage)` SHALL return the WOOD amount of the proposer bond: the coverage's USD value times `proposerBondBps` (default 100 = 1%), converted at `woodPriceX8()`. It SHALL return zero when the bps slice floors to zero USD and SHALL revert (fail closed) when the WOOD price is unset. `setProposerBondBps` SHALL accept only values up to 10_000.

#### Scenario: Bond with unset WOOD price
- **WHEN** `proposerBondWood` is called with a non-zero USD slice while `woodPriceX8()` is zero
- **THEN** the call reverts `InvalidParameter`

### Requirement: Exposure cap multiplier
`kNumerator` (default 1) SHALL scale the per-guardian exposure budget `k × slashableBondUsd`. `setKNumerator` SHALL reject zero. All parameter setters on the ledger SHALL be owner-only and SHALL emit `ParameterChangeFinalized` (or their dedicated event) with old and new values.

#### Scenario: Zero k rejected
- **WHEN** the owner sets `kNumerator` to zero
- **THEN** the call reverts `InvalidParameter`

### Requirement: Coverage-weighted guardian fees
Guardian compensation SHALL be coverage-weighted, not stake-weighted. At settlement the governor SHALL compute `guardianFee = grossProfit × snapshotGuardianFeeBps / 10_000` from the propose-time snapshot of `ProtocolConfig.guardianFeeBps`, pay it to the snapshotted guardians-fee recipient, and emit `GuardianFeeAccrued` ONLY on actual delivery (an escrowed transfer must not trigger the off-chain airdrop). Per-approver attribution SHALL come from `GuardianRegistry.getApproverCoverage`, which returns each approver's settled ALLOCATION from the ledger (`allocatedUsd`) — not their vote-stake weight and not their reservation — together with a `priced` flag that is false when the ledger cannot value the coverage; a caller MUST retry on `priced == false` rather than pay zeros. An unwired ledger returns all-zero with `priced == true`. The payout job SHALL call the permissionless `settleCoverage` before reading allocations so over-subscribed proposals are not over-paid.

#### Scenario: Fee attribution follows underwriting
- **WHEN** one approver booked the full coverage and another booked nothing (no free budget)
- **THEN** `getApproverCoverage` attributes the coverage entirely to the first, while stake-weight-based `getApproverWeights` would have paid both

#### Scenario: Attribution during a feed outage
- **WHEN** the asset feed is stale so `allocatedUsd` reverts
- **THEN** `getApproverCoverage` returns zeros with `priced == false` and the payout job retries instead of distributing

#### Scenario: Escrowed guardian fee
- **WHEN** the guardians-fee recipient transfer reverts and the fee escrows in the vault
- **THEN** `GuardianFeeAccrued` is not emitted, so the off-chain distributor cannot double-pay when the escrow is later claimed

### Requirement: Protocol fee ceiling constants
The protocol-wide performance-fee constants SHALL live in a single library (`src/FeeConstants.sol`): the hard agent performance-fee ceiling `MAX_PERFORMANCE_FEE_BPS = 1500` (15%) shared by governor and vault caps, and the default agent fee `DEFAULT_AGENT_FEE_BPS = 500` (5%) used as the vault getter's fallback.

#### Scenario: Shared ceiling
- **WHEN** either the governor's `maxPerformanceFeeBps` cap or the vault's agent-fee cap is enforced
- **THEN** both derive from the same `MAX_PERFORMANCE_FEE_BPS` constant and cannot silently diverge
