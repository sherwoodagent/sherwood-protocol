# Guardian Coverage Specification

## Purpose

Dollar-denominated coverage accounting for the guardian economic-security model: guardians who approve a coverage-consuming proposal book USD exposure against their slashable WOOD bond, execution requires the covering approvers' aggregate bond to meet the proposal's required coverage, and a live challenge freezes the committed coverage so accused collateral cannot exit. Implemented by `src/ExposureLedger.sol` (interface `src/interfaces/IExposureLedger.sol`), consumed by `GuardianRegistry` (recording at approve-vote time), `SyndicateGovernor` (covered-TVL check at propose, approve quorum at execute, guardian fee at settlement), `ChallengeGame` (freeze), and `StakedWood` (exit gate).
## Requirements
### Requirement: Slashable bond valuation
The ledger SHALL value a guardian's slashable bond in USD (8-decimal price) as `ownStake(g) × woodPriceX8() / 1e8`. Only the guardian's own stake counts — there is no delegated-inbound term. The stake basis SHALL depend on the read:

- The public `slashableBondUsd` view and the free-budget cap in `recordApproval` read the guardian's LIVE stake (`swood.guardianStake`).
- Every per-proposal read that values a lock — the approval slot floor and the execute-time quorum (anchored at the current block), and after execution `coverageUsdOf`, `liabilityUsd` / `unsharedLiabilityUsd` and `slashBpsFor` (anchored at `executedAt`) — SHALL use `swood.slashableStakeAt(g, anchor)`, the basis the verdict slash recovers from, so stake added at or after the anchor instant is never counted as coverage for that proposal.

#### Scenario: Bond priced from own stake
- **WHEN** `slashableBondUsd(guardian)` is called for a guardian with staked WOOD
- **THEN** it returns the guardian's own live stake multiplied by the current haircut WOOD/USD price, with no delegated component

#### Scenario: Post-execution top-up is not coverage
- **WHEN** a guardian tops up its stake after the proposal it approved has executed, and a post-execution coverage read (coverage, liability, or slash rate) values that guardian
- **THEN** the guardian is valued at its stake as of the execution instant (clamped to live), and the top-up moves none of the proposal's coverage figures

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
Exposure SHALL be booked into epoch buckets of immutable width `epochLength` anchored at `epochGenesis` (deploy time), denominated in WOOD. `openExposure(guardian)` SHALL sum every bucket whose challenge window has not elapsed — from bucket `(elapsed − challengeWindow) / epochLength` (0 when `elapsed <= challengeWindow`) forward through `(elapsed + 60 days) / epochLength` — so forward-dated settlement bookings are counted and a bucket expires exactly at `bucketEnd + challengeWindow`. `epochLength` SHALL be immutable because changing it would shift every existing bucket index. The bucket walk SHALL require no price read: the adversary here is a WOOD-feed outage or manipulation, and a capacity check that depends on a price can be starved or inflated by it.

#### Scenario: Bucket expiry recycles budget
- **WHEN** a bucket's end plus the challenge window has elapsed
- **THEN** that bucket no longer counts toward `openExposure` and the guardian's budget recycles

#### Scenario: Forward-dated bookings are visible
- **WHEN** a commitment was booked into a future settlement bucket
- **THEN** `openExposure` includes it immediately, so the batching cap sees pledged budget as consumed

#### Scenario: Capacity is readable without a price
- **WHEN** the WOOD price feed is unconfigured or stale
- **THEN** `openExposure` still returns, because it is pure WOOD arithmetic

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

### Requirement: Coverage freeze pins release and exit
`freezeCoverage` and `unfreezeCoverage` SHALL be callable only by the owner-set `coverageFreezer` (the challenge game). A freeze SHALL pin exactly one proposal's committed coverage — never the guardians' whole stake or other approvals — blocking `releaseApproval` for that proposal and incrementing a per-guardian frozen-commitment COUNT for every listed approver with a live lock. `hasFrozenCoverage(guardian)` SHALL report whether any frozen proposal names the guardian or a pin on the guardian is still in force (through its deadline, inclusive), and sWOOD gates the unstake claim on it, so bucket expiry (pure wall-clock) cannot let accused collateral walk out mid-challenge. A freeze SHALL ALSO re-bucket every listed approver's lock so that it keeps counting against that guardian's capacity for as long as the challenge can be live — the second adversary the wall clock enables is not the accused walking out but the accused *locking again* on budget the expired bucket wrongly reports as free, and `hasFrozenCoverage` does nothing for that. The per-guardian counters SHALL move only when a flag flips, and unfreeze SHALL clear exactly the per-guardian marks its freeze set and return each lock to its resting bucket (below).

#### Scenario: Freeze by non-freezer
- **WHEN** any address other than `coverageFreezer` calls `freezeCoverage` or `unfreezeCoverage`
- **THEN** the call reverts `NotCoverageFreezer`

#### Scenario: Accused guardian cannot exit
- **WHEN** a proposal naming a guardian is frozen and the guardian's epoch buckets have aged out
- **THEN** `hasFrozenCoverage(guardian)` is true and the sWOOD unstake claim is refused until the challenge resolves and unfreezes

#### Scenario: Accused guardian cannot re-lock the frozen budget
- **WHEN** a proposal naming a guardian is frozen, enough wall-clock time passes that the lock's original bucket would have expired, and the guardian approves another proposal
- **THEN** the frozen lock still counts in `openExposure`, so the new lock is clamped to the budget genuinely free and never overlaps the frozen one

#### Scenario: Repeated freeze
- **WHEN** `freezeCoverage` is called a second time for the same proposal, as a concurrent filing does
- **THEN** the per-guardian counters do not drift, and a lock moves again only if the second call's `liveUntil` lies in a later bucket — never earlier

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
`kNumerator` (default 1) SHALL scale the per-guardian exposure budget `k × guardianStake`, in WOOD. `setKNumerator` SHALL reject zero. All parameter setters on the ledger SHALL be owner-only and SHALL emit `ParameterChangeFinalized` (or their dedicated event) with old and new values. At `k = 1` the ledger SHALL guarantee containment whenever each convicted approver's lock is at least `minSlashBps` of its slash basis: because `Σ live locks ≤ live stake`, burning one proposal's lock leaves `stake − lock_A ≥ Σ_{j≠A} lock_j`, so a conviction on one proposal leaves every other proposal the guardian backs fully covered. A lock below that floor is slashed at `minSlashBps` of the basis, more than the lock, and can eat into the stake backing the guardian's other locks. Any `k > 1` is deliberate leverage that trades containment away, and the setter's documentation SHALL say so; the adversary is a future operator raising `k` for capital efficiency without understanding that it reintroduces cross-proposal contagion.

#### Scenario: Zero k rejected
- **WHEN** the owner sets `kNumerator` to zero
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Containment at the default
- **WHEN** `kNumerator` is 1, a guardian backs proposals A and B, its lock on A is at least `minSlashBps` of its basis, and A is convicted
- **THEN** after the burn the guardian's remaining stake is at least B's lock, so B's coverage from that guardian is unchanged

#### Scenario: Leverage is legible
- **WHEN** `kNumerator` is raised above 1
- **THEN** a guardian may lock more WOOD across proposals than they hold, and a conviction on one may leave the others under-covered by exactly the excess — the documented cost of the setting

### Requirement: Coverage-weighted guardian fees
Guardian compensation SHALL be coverage-weighted, not stake-weighted. At settlement the governor SHALL pay the guardian share of the management fee (`mgmtFee × snapshotMgmtSplit.guardianBps / 10_000`) and of the performance fee (`perfFee × snapshotPerfSplit.guardianBps / 10_000`) to the snapshotted guardians-fee recipient, and emit `GuardianFeeAccrued` ONLY on actual delivery of each (an escrowed transfer must not trigger the off-chain airdrop). Per-approver attribution SHALL come from `GuardianRegistry.getApproverCoverage`, which returns each approver's LOCK valued by the ledger (`coverageUsdOf`: `min(lock, slashable stake) × woodPriceX8()`, the stake anchored at `executedAt` once the proposal has executed, UNCAPPED — a guardian who locked more took more risk and earns proportionally more) — not their vote-stake weight — together with a `priced` flag that is false when the ledger cannot value the coverage; a caller MUST retry on `priced == false` rather than pay zeros. An unwired ledger returns all-zero with `priced == true`. No settlement step precedes attribution: with no cohort cap there is no over-reservation to collapse, so the lock a guardian holds at payout IS their attribution. The adversary is a fee-payout job that pays on a stale or missing price — the `priced` flag is what stops it.

#### Scenario: Fee attribution follows underwriting
- **WHEN** two approvers hold equal stake and one locked most of it on the proposal while the other locked a small amount
- **THEN** `getApproverCoverage` attributes coverage by lock, while stake-weight-based `getApproverWeights` would weigh them equally

#### Scenario: Larger lock earns a larger share
- **WHEN** two approvers locked 300 and 100 WOOD on the same proposal and both hold at least that much slashable stake
- **THEN** `getApproverCoverage` attributes coverage in a 3:1 ratio, with no cap applied even if the sum exceeds the proposal's need

#### Scenario: Attribution during a feed outage
- **WHEN** the WOOD feed is stale so `coverageUsdOf` reverts
- **THEN** `getApproverCoverage` returns zeros with `priced == false` and the payout job retries instead of distributing

#### Scenario: Escrowed guardian fee
- **WHEN** the guardians-fee recipient transfer reverts and the fee escrows in the vault
- **THEN** `GuardianFeeAccrued` is not emitted, so the off-chain distributor cannot double-pay when the escrow is later claimed

### Requirement: Protocol fee ceiling constants
The protocol-wide performance-fee constants SHALL live in a single library (`src/FeeConstants.sol`): the hard agent performance-fee ceiling `MAX_PERFORMANCE_FEE_BPS = 2500` (25%) shared by governor and vault caps, the governor's shipped default cap `DEFAULT_MAX_PERFORMANCE_FEE_BPS = 2000` (20%), and the default agent fee `DEFAULT_AGENT_FEE_BPS = 2000` (20%) used as the vault getter's fallback. The default agent fee SHALL equal `DEFAULT_MAX_PERFORMANCE_FEE_BPS`, so an unset vault charges exactly the headline rate and only an explicit governor parameter change goes above it; the hard ceiling sits above both so that change has somewhere to go.

#### Scenario: Shared ceiling
- **WHEN** either the governor's `maxPerformanceFeeBps` cap or the vault's agent-fee cap is enforced
- **THEN** both derive from the same `MAX_PERFORMANCE_FEE_BPS` constant and cannot silently diverge

### Requirement: Frozen and pinned locks are re-bucketed to their true liability end
The ledger SHALL keep each lock in the epoch bucket that matches how long the lock is actually live, moving it when a freeze, an unfreeze, or a pin changes that answer, so that the existing bucket scan counts it for exactly that long without any second accumulator or any additional read on the capacity path. On freeze, each listed approver's lock SHALL move to the bucket containing the challenge's pinned worst-case end (`filedAt + voteWindowAtFiling`, passed by the freezer as `liveUntil`), never earlier than the bucket it occupies. On unfreeze, each lock SHALL move to its resting bucket: the later of the bucket it was booked into and the bucket of any standing pin on it, deliberately NOT floored at the current bucket — so a challenge resolved before settlement can never leave the settlement drain uncovered, a re-armed re-challenge window is held by its pin, and an acquitted guardian's capacity is not held for a further epoch. The move MAY be to an earlier bucket than the frozen one, including one that has already expired. A move SHALL update the lock's recorded epoch, and release and retirement SHALL unwind the lock from that recorded (current) epoch — never from a recomputed booking-time epoch — so a moved lock leaves neither a phantom in its new bucket nor a negative in its old one. A re-bucket target beyond the coverage horizon SHALL be clamped to the horizon's edge, because a bucket outside the bounded scan is invisible to it — the exact un-counting this requirement exists to prevent. Moving a lock to the bucket it already occupies SHALL be a no-op. The adversary throughout is a guardian who has been accused, or whose lock is pinned, and who uses the wall-clock expiry of the original bucket to have that lock stop counting while it remains slashable.

#### Scenario: Freeze extends the lock to the challenge's worst-case end
- **WHEN** a challenge is filed against a proposal whose approvers' locks sit in a bucket that expires before `filedAt + voteWindowAtFiling`
- **THEN** each lock is moved to the bucket containing that end, and `openExposure` for each approver is unchanged at the moment of the move

#### Scenario: Unfreeze returns the lock to its resting bucket
- **WHEN** the challenge terminates and coverage is unfrozen after the lock's booked bucket has passed, with no pin on the lock
- **THEN** each lock is moved back to its booked bucket, so it stops counting as soon as that bucket's expiry has passed

#### Scenario: Unfreeze before settlement keeps the settlement bucket
- **WHEN** a challenge is filed and resolved before the proposal settles, while the lock's booked bucket is still ahead of the current one
- **THEN** the unfreeze returns the lock to its booked bucket, not the current one, so the budget stays held until the settlement drain can no longer be challenged

#### Scenario: Freeze never moves a lock earlier
- **WHEN** a challenge's worst-case end falls in a bucket earlier than the one the lock already occupies
- **THEN** the lock stays where it is

#### Scenario: Retire after a move unwinds the right bucket
- **WHEN** a lock has been re-bucketed by a freeze and later unfrozen, and its retirement window has elapsed
- **THEN** `retireApproval` subtracts the lock from the bucket it currently occupies, and every bucket the lock ever visited sums to zero for that lock

#### Scenario: Target beyond the horizon is clamped
- **WHEN** a freeze's worst-case end lies beyond `now + MAX_COVERAGE_HORIZON`
- **THEN** the lock is moved to the last bucket inside the horizon rather than to a bucket the scan cannot see, and `hasFrozenCoverage` continues to block exit regardless

#### Scenario: Re-bucketing composes
- **WHEN** the same lock is frozen, unfrozen, then pinned, then retired
- **THEN** each step reads the lock's current epoch, the intermediate bucket sums are consistent after every step, and the final retirement leaves the guardian's buckets at their pre-lock values

### Requirement: Pinning a lock extends its bucket to the pin's expiry
`pinCoverageUntil(governor, proposalId, until)` SHALL be callable only by the owner-set `coverageFreezer` and SHALL act on every listed approver of the proposal holding a non-zero lock. For each it SHALL raise, monotonically, both the guardian's pin (read by `hasFrozenCoverage`) and the lock's own pin deadline (read by `retireApproval`) — a shorter `until` than the current pin leaves them unchanged — and SHALL move the lock to the bucket containing `until` whenever that bucket is later than the one the lock currently occupies — never earlier — clamped to the coverage horizon. A pinned lock SHALL count against the guardian's capacity until at least `until`, and `retireApproval` SHALL refuse it with `CoveragePinnedActive` until then. There is no unpin: pin expiry is time-based, which is exactly why the bucket mechanism — itself time-based — is the right enforcer. The adversary is a guardian whose challenge failed on a missed quorum and whose proposal's re-challenge window the challenge game re-armed and pinned, who would otherwise see the pinned lock fall out of `openExposure` on the original bucket's clock and re-lock that budget elsewhere.

#### Scenario: Pin by non-freezer
- **WHEN** any address other than `coverageFreezer` calls `pinCoverageUntil`
- **THEN** the call reverts `NotCoverageFreezer`

#### Scenario: Pin extends capacity accounting
- **WHEN** a lock is pinned to an `until` beyond its current bucket's expiry and the original expiry passes
- **THEN** the lock still counts in `openExposure` until the bucket containing `until` expires

#### Scenario: Shorter pin does not move the lock earlier
- **WHEN** `pinCoverageUntil` is called with an `until` earlier than the lock's current bucket expiry
- **THEN** the pin deadline is unchanged, the lock stays in its current bucket, and the call is a no-op beyond the event

#### Scenario: Retire refused while pinned
- **WHEN** `retireApproval` is called for a lock whose `until` has not yet passed
- **THEN** the call reverts `CoveragePinnedActive`

### Requirement: Approval recording books a guardian-declared WOOD lock
`recordApproval(governor, proposalId, guardian, lockWood)` SHALL be callable only by the wired guardian registry and SHALL be idempotent per (proposal, guardian). It SHALL lock `min(lockWood, free budget)` WOOD, where free budget is `kNumerator × guardianStake(guardian) − openExposure(guardian)`, all in WOOD. The lock SHALL be booked into the epoch bucket containing `executeBy + strategyDuration` (floored at the current epoch), recorded per guardian as the single figure that is at once the guardian's booking, pledge and slash base, appended to the ledger's own approver list, and announced via `ExposureRecorded`. There SHALL be no cohort cap: a proposal's locks MAY sum to more than its requirement, and nothing SHALL later reduce a lock other than release or retirement. The adversary this shape defends against is any party who could move a guardian's slash base after the fact: with booking and pledge the same number, written once and erased only by release or retirement, no permissionless pass exists that can shrink or grow it.

#### Scenario: Successful lock
- **WHEN** the registry records an approval carrying a WOOD amount for a guardian with free budget on a priceable, in-horizon proposal, and the lock clears the slot floor
- **THEN** `min(lockWood, free)` is added to the settlement bucket and recorded for the guardian, and the guardian joins the approver list with `ExposureRecorded` emitted

#### Scenario: Cohort over-subscribes
- **WHEN** the locks of a proposal's approvers sum to more than the proposal's priced requirement
- **THEN** every lock is recorded in full and none is written down — an over-subscribed proposal is a well-covered one

#### Scenario: Unauthorized caller
- **WHEN** any address other than the wired guardian registry calls `recordApproval` or `releaseApproval`
- **THEN** the call reverts `NotGuardianRegistry`

#### Scenario: Repeat recording is a no-op
- **WHEN** `recordApproval` is called again for a (proposal, guardian) that already holds a non-zero lock
- **THEN** nothing changes (vote-change round trips cannot double-lock)

### Requirement: Per-approver slash rates are the lock over the slash basis
`slashBpsFor(governor, proposalId)` SHALL return, positionally aligned with the ledger's approver list, each approver's slash rate in bps of the SLASH BASIS the staking contract will burn against — `swood.slashableStakeAt(g, executedAt)` = `min(max(liability, votable stake) at executedAt − 1, live stake)` once the proposal has executed, live stake before — computed as their LOCK for this proposal divided by that basis, rounding UP so the burn never falls below the lock by truncation. The denominator is the basis and not raw live stake deliberately: the staking contract burns `basis × rate`, so only a basis-denominated rate yields `min(lock, basis)`; a raw-live denominator would let a convicted guardian who tops up AFTER the drain dilute their own burn while the anchored basis excludes the top-up. A rate SHALL saturate at 10_000 bps when the lock meets or exceeds the basis or the basis is zero. A guardian with a zero lock (released) SHALL owe 0 bps. The lock is written once by `recordApproval` and erased only by release or retirement, both of which a filed challenge blocks, so no party can move a slash basis while a challenge is live. The view SHALL NOT read a price: the lock and the stake are both WOOD. An anchored variant, `slashBpsForAt(governor, proposalId, anchor)`, SHALL expose the same computation at a caller-supplied raw anchor (`0` reads live stake; a future anchor reverts `VerdictNotPast`), so the review-path slash (anchored at review open, before any execution) and the verdict-path slash (anchored at `executedAt`) derive their lock rates from ONE formula and cannot drift; `slashBpsFor` is that view at `executedAt`. The stake envelope `[minSlashBps, maxSlashBps]` applied by the staking contract is what floors the rate, so `minSlashBps` is the single deterrence floor: a guardian who declares a negligible lock contributes negligibly to quorum and is still slashed at least `minSlashBps` of its basis on conviction.

#### Scenario: Rate priced on the lock
- **WHEN** an approver locked 500 WOOD on a proposal and their slash basis at conviction is 2,000 WOOD
- **THEN** their rate is 2,500 bps — the lock over the basis — before the staking envelope is applied

#### Scenario: Post-drain top-up does not dilute the burn
- **WHEN** an approver held 2,000 WOOD at `executedAt`, locked 500, and staked 2,000 more after execution
- **THEN** the rate is still 2,500 bps of the 2,000 basis, so the burn is 500 — the top-up neither shields the lock nor is burned

#### Scenario: Lock exceeds the basis
- **WHEN** an approver's slash basis is zero or below their lock
- **THEN** the rate is pinned at 10_000 bps and recovery is bounded by the basis — the shortfall is the residual after the execute-time quorum, not a gate hole

#### Scenario: Negligible declaration still pays the floor
- **WHEN** an approver locked 1 wei of WOOD and the proposal is convicted
- **THEN** their raw rate rounds up to 1 bps and the staking envelope raises it to `minSlashBps`, so a token declaration does not buy a token penalty

#### Scenario: Price feed down at conviction
- **WHEN** the WOOD feed is unconfigured or stale when `slashBpsFor` is read
- **THEN** the rates are still returned — a conviction never waits on a price

### Requirement: Cohort liability is the lock sum capped at need
`liabilityUsd(governor, proposalId)` SHALL return `min(needUsd, Σ min(lock_i, slashable stake_i) × woodPriceX8())`, with each stake anchored at the proposal's `executedAt` (live before execution) — the cohort's single-number recoverable liability for THIS proposal. It SHALL return 0 without pricing the need when the recoverable sum is 0. `unsharedLiabilityUsd` SHALL return the same figure; with no cohort cap and no pro-rata there is no distinct shared basis to pro-rate against. Both SHALL revert on an unpriceable WOOD feed or a stale or unconfigured vault-asset feed (sizing a challenger's bond off an unvouched price is the unsafe direction). The cap at `needUsd` bounds bond sizing only: on conviction every approver's full lock is still slashed. The adversary is a cohort that over-subscribes a proposal to inflate the bond a challenger must post; the cap makes over-subscription cost the challenger nothing. The anchor stops an accused cohort from topping up after the drain to raise its own filing bond with stake the verdict cannot reach.

#### Scenario: Over-subscribed cohort does not inflate the challenger bond
- **WHEN** approvers have locked WOOD worth $1,500 against a proposal whose need is $1,000
- **THEN** `liabilityUsd` returns $1,000, and a challenger's bond is sized off $1,000

#### Scenario: Under-subscribed cohort reports what it can pay
- **WHEN** approvers' locks are worth $600 against a $1,000 need
- **THEN** `liabilityUsd` returns $600

