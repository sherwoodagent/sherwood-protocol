## MODIFIED Requirements

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
- **THEN** `openExposure` and the free-budget computation still return, because both are pure WOOD arithmetic

### Requirement: Approval recording books a guardian-declared WOOD lock
`recordApproval(governor, proposalId, guardian, lockWood)` SHALL be callable only by the wired guardian registry and SHALL be idempotent per (proposal, guardian). It SHALL lock exactly `min(lockWood, free budget)` WOOD — never a USD-derived reservation and never the still-uncovered remainder — where free budget is `kNumerator × slashableStake(guardian) − openExposure(guardian)`, all in WOOD. The lock SHALL be booked into the epoch bucket containing `executeBy + strategyDuration` (floored at the current epoch), recorded per-guardian as the single figure that is at once the guardian's booking, pledge and slash base, appended to the ledger's own approver list, and announced via `ExposureRecorded`. There SHALL be no cohort cap: the sum of locks across a proposal's approvers MAY exceed the proposal's requirement, and nothing SHALL later reduce a lock other than release or retirement. The adversary this shape defends against is any party who could move a guardian's slash base after the fact: with booking and pledge the same number, written once and erased only by release or retirement, no permissionless pass exists that can shrink or grow it.

#### Scenario: Successful lock
- **WHEN** the registry records an approval carrying a WOOD amount for a guardian with free budget on an in-horizon proposal with non-zero coverage
- **THEN** `min(lockWood, free)` is added to the settlement bucket and recorded per-guardian, and the guardian joins the approver list with `ExposureRecorded` emitted

#### Scenario: Cohort over-subscribes
- **WHEN** the locks of a proposal's approvers sum to more than the proposal's priced requirement
- **THEN** every lock is recorded in full and none is written down — an over-subscribed proposal is a well-covered one

#### Scenario: Declaration exceeds free budget
- **WHEN** a guardian declares more WOOD than their free budget
- **THEN** the lock is clamped to the free budget, so the cap binds without failing the vote

#### Scenario: Unauthorized caller
- **WHEN** any address other than the wired guardian registry calls `recordApproval` or `releaseApproval`
- **THEN** the call reverts `NotGuardianRegistry`

#### Scenario: Repeat recording is a no-op
- **WHEN** `recordApproval` is called again for a (proposal, guardian) that already holds a non-zero lock
- **THEN** nothing changes (vote-change round trips cannot double-lock)

### Requirement: Booking failures never fail the approve vote
`recordApproval` SHALL lock nothing and return — never revert — when the proposal's required coverage prices to zero, when the guardian has no free budget (`openExposure >= cap`), when the declared amount is zero, or when settlement lies beyond the coverage horizon. The exposure cap is enforced by locking zero and letting the execute-time quorum fail, not by reverting the vote; `ExposureCapExceeded` is retained in the ABI but never thrown. A WOOD-price outage SHALL NOT be a booking-failure case: the lock is WOOD and needs no price.

#### Scenario: Guardian with exhausted budget
- **WHEN** a guardian whose open exposure already meets or exceeds `kNumerator × slashableStake` casts an approve vote
- **THEN** the vote succeeds, the ledger locks nothing, and the proposal can only execute if other approvers cover it

#### Scenario: Unpriceable asset at vote time
- **WHEN** the vault asset's feed is unconfigured or stale during an approve vote
- **THEN** the vote succeeds with nothing locked, so the review is never forced block-only

#### Scenario: Unpriceable WOOD at vote time
- **WHEN** the WOOD feed is unconfigured or stale during an approve vote
- **THEN** the lock is still recorded — the guardian's declaration is WOOD and the cap is WOOD, so no price is consulted

### Requirement: Execute-time approve quorum
`requireApproveQuorum(governor, proposalId, asset, requiredCoverage)` SHALL revert `InsufficientApproveCoverage` unless the covering approvers' aggregate `Σ min(lock_i, live slashableStake_i) × woodPriceX8()` meets `coverageUsd(asset, requiredCoverage)`. The approver set SHALL come from the ledger's own list, never the registry's. Zero committed approvers SHALL always revert, even at zero priced coverage. The governor SHALL invoke this check at execute for every proposal with a wired ledger, non-zero `requiredCoverage`, and `envelopeTier >= quorumTierThreshold`; zero-`requiredCoverage` proposals keep optimistic passage. This is the single point at which WOOD is converted to USD for coverage; the adversary is a guardian whose lock has become worth less than they declared (unstake, or a WOOD price fall), who MUST count at the shrunken live value.

#### Scenario: Aggregate coverage across a cohort
- **WHEN** two guardians each lock WOOD worth $600k at execute and both are approvers on a $1M-coverage proposal
- **THEN** the quorum passes on the aggregate — no single approver must cover the proposal alone

#### Scenario: Over-subscribed cohort passes
- **WHEN** the approvers' locks are worth more than the requirement at execute
- **THEN** the quorum passes; the excess is not written down and remains each guardian's own liability

#### Scenario: Bond shrank since the vote
- **WHEN** an approver's live stake (unstake, or a WOOD price fall) is now worth less than its lock
- **THEN** it counts at the shrunken live value, so coverage must still hold in dollars at execution

#### Scenario: No covering approver
- **WHEN** a coverage-consuming proposal at or above the tier threshold reaches execute with no live committed approver
- **THEN** execution reverts `InsufficientApproveCoverage` and the proposal expires at `executeBy` unless covering approvals arrive

### Requirement: Per-approver slash rates
`slashBpsFor(governor, proposalId)` SHALL return, positionally aligned with the ledger's approver list, each approver's slash rate in bps of their own live slashable stake: their LOCK for this proposal divided by their live stake, rounding UP so the burn never falls below the lock by truncation. A rate SHALL saturate at 10_000 bps when the lock meets or exceeds the live stake or the live stake is zero. A guardian with a zero lock (released, or an approval that locked nothing) SHALL owe 0 bps. The basis SHALL be the lock and nothing else — never a pro-rata allocation, never a live-priced share — because the adversary is anyone able to move a slash basis while a challenge is live: the lock is written once by `recordApproval` and erased only by release or retirement, both of which a filed challenge blocks. The view SHALL NOT read a price: the lock and the stake are both WOOD. The stake envelope `[minSlashBps, maxSlashBps]` applied by the staking contract is what floors the rate, so `minSlashBps` is the single deterrence floor: a guardian who declares a negligible lock contributes negligibly to quorum and is still slashed at least `minSlashBps` of everything they hold on conviction.

#### Scenario: Rate priced on the lock
- **WHEN** an approver locked 500 WOOD on a proposal and holds 2,000 WOOD of live stake at conviction
- **THEN** their rate is 2,500 bps — the lock over the live stake — before the staking envelope is applied

#### Scenario: Lock exceeds live stake
- **WHEN** an approver's live stake is zero or below their lock
- **THEN** the rate is pinned at 10_000 bps and recovery is bounded by the live stake — the shortfall is the residual after the execute-time quorum, not a gate hole

#### Scenario: Negligible declaration still pays the floor
- **WHEN** an approver locked 1 wei of WOOD and the proposal is convicted
- **THEN** their raw rate rounds up to 1 bps and the staking envelope raises it to `minSlashBps`, so a token declaration does not buy a token penalty

#### Scenario: Price feed down at conviction
- **WHEN** the WOOD feed is unconfigured or stale when `slashBpsFor` is read
- **THEN** the rates are still returned — a conviction never waits on a price

### Requirement: Exposure cap multiplier
`kNumerator` (default 1) SHALL scale the per-guardian exposure budget `k × slashableStake`, in WOOD. `setKNumerator` SHALL reject zero. All parameter setters on the ledger SHALL be owner-only and SHALL emit `ParameterChangeFinalized` (or their dedicated event) with old and new values. At `k = 1` the ledger SHALL guarantee containment: because `Σ live locks ≤ live stake`, burning one proposal's lock leaves `stake − lock_A ≥ Σ_{j≠A} lock_j`, so a conviction on one proposal leaves every other proposal the guardian backs fully covered. Any `k > 1` is deliberate leverage that trades exactly that property away, and the setter's documentation SHALL say so; the adversary is a future operator raising `k` for capital efficiency without understanding that it reintroduces cross-proposal contagion.

#### Scenario: Zero k rejected
- **WHEN** the owner sets `kNumerator` to zero
- **THEN** the call reverts `InvalidParameter`

#### Scenario: Containment at the default
- **WHEN** `kNumerator` is 1, a guardian backs proposals A and B, and A is convicted
- **THEN** after the burn the guardian's remaining stake is at least B's lock, so B's coverage from that guardian is unchanged

#### Scenario: Leverage is legible
- **WHEN** `kNumerator` is raised above 1
- **THEN** a guardian may lock more WOOD across proposals than they hold, and a conviction on one may leave the others under-covered by exactly the excess — the documented cost of the setting

### Requirement: Coverage-weighted guardian fees
Guardian compensation SHALL be coverage-weighted, not stake-weighted. At settlement the governor SHALL compute `guardianFee = grossProfit × snapshotGuardianFeeBps / 10_000` from the propose-time snapshot of `ProtocolConfig.guardianFeeBps`, pay it to the snapshotted guardians-fee recipient, and emit `GuardianFeeAccrued` ONLY on actual delivery (an escrowed transfer must not trigger the off-chain airdrop). Per-approver attribution SHALL come from `GuardianRegistry.getApproverCoverage`, which returns each approver's LOCK at live value from the ledger (`coverageUsdOf`: `min(lock, live slashable stake) × woodPriceX8()`, UNCAPPED — a guardian who locked more took more risk and earns proportionally more) — not their vote-stake weight — together with a `priced` flag that is false when the ledger cannot value the coverage; a caller MUST retry on `priced == false` rather than pay zeros. An unwired ledger returns all-zero with `priced == true`. No settlement step precedes attribution: with no cohort cap there is no over-reservation to collapse, so the lock a guardian holds at payout IS their attribution. The adversary is a fee-payout job that pays on a stale or missing price — the `priced` flag is what stops it.

#### Scenario: Fee attribution follows underwriting
- **WHEN** one approver locked WOOD on the proposal and another approver locked nothing (no free budget)
- **THEN** `getApproverCoverage` attributes the coverage entirely to the first, while stake-weight-based `getApproverWeights` would have paid both

#### Scenario: Larger lock earns a larger share
- **WHEN** two approvers locked 300 and 100 WOOD on the same proposal and both hold at least that much live stake
- **THEN** `getApproverCoverage` attributes coverage in a 3:1 ratio, with no cap applied even if the sum exceeds the proposal's need

#### Scenario: Attribution during a feed outage
- **WHEN** the WOOD feed is stale so `coverageUsdOf` reverts
- **THEN** `getApproverCoverage` returns zeros with `priced == false` and the payout job retries instead of distributing

#### Scenario: Escrowed guardian fee
- **WHEN** the guardians-fee recipient transfer reverts and the fee escrows in the vault
- **THEN** `GuardianFeeAccrued` is not emitted, so the off-chain distributor cannot double-pay when the escrow is later claimed

## ADDED Requirements

### Requirement: Cohort liability is the lock sum capped at need
`liabilityUsd(governor, proposalId)` SHALL return `min(needUsd, Σ min(lock_i, live stake_i) × woodPriceX8())` — the cohort's single-number recoverable liability for THIS proposal. `unsharedLiabilityUsd` SHALL return the same figure; with no cohort cap and no pro-rata there is no longer a distinct shared basis to pro-rate against. Both SHALL revert on an unpriceable WOOD feed (sizing a challenger's bond off an unvouched price is the unsafe direction). The cap at `needUsd` bounds bond sizing only: on conviction every approver's full lock is still slashed. The adversary is a cohort that over-subscribes a proposal to inflate the bond a challenger must post; the cap makes over-subscription cost the challenger nothing.

#### Scenario: Over-subscribed cohort does not inflate the challenger bond
- **WHEN** approvers have locked WOOD worth $1,500 against a proposal whose need is $1,000
- **THEN** `liabilityUsd` returns $1,000, and a challenger's bond is sized off $1,000

#### Scenario: Under-subscribed cohort reports what it can pay
- **WHEN** approvers' locks are worth $600 against a $1,000 need
- **THEN** `liabilityUsd` returns $600

## REMOVED Requirements

### Requirement: Allocation is pro-rata over the effective total
**Reason**: There is no cohort cap, so there is nothing to pro-rate. Each guardian's liability is their own lock; `liabilityUsd` is redefined above as the capped lock sum.
**Migration**: Consumers that read `allocatedUsd(governor, proposalId, guardian)` read the guardian's lock directly; consumers of `liabilityUsd` are unchanged in signature and receive the capped lock sum.

### Requirement: Coverage settlement returns over-reservations
**Reason**: Nothing over-reserves. Booking equals pledge for a lock's whole life, so there is no reservation cushion to collapse, no residue to assign, and no moment at which a permissionless pass could free capacity that is still slashable (SHE-212) or fail to free capacity that is not (SHE-225).
**Migration**: `settleCoverage`, `CoverageSettled`, and the governor's settlement-finalization and bond-reclaim triggers are deleted. Budget recycles exactly as the epoch buckets already specify — at `bucketEnd + challengeWindow` — or earlier on release or retirement.
