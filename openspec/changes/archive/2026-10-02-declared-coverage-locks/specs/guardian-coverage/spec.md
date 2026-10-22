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
- **THEN** `openExposure` still returns, because it is pure WOOD arithmetic

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

## ADDED Requirements

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

## REMOVED Requirements

### Requirement: Per-approver slash rates
**Reason**: Restated as "Per-approver slash rates are the lock over the slash basis": the rate is the guardian's own WOOD lock over its slash basis, not a share of a pro-rata allocation, and it reads no price.
**Migration**: None for callers; `slashBpsFor` keeps its signature. `slashBpsForAt` is added for the review path.

### Requirement: Allocation is pro-rata over the effective total
**Reason**: There is no cohort cap, so there is nothing to pro-rate. Each guardian's liability is their own lock; `liabilityUsd` is redefined above as the capped lock sum.
**Migration**: Consumers that read `allocatedUsd(governor, proposalId, guardian)` read the guardian's lock directly; consumers of `liabilityUsd` are unchanged in signature and receive the capped lock sum.

### Requirement: Coverage settlement returns over-reservations
**Reason**: Nothing over-reserves. Booking equals pledge for a lock's whole life, so there is no reservation cushion to collapse, no residue to assign, and no moment at which a permissionless pass could free capacity that is still slashable or fail to free capacity that is not.
**Migration**: `settleCoverage` and `CoverageSettled` are deleted, as are the governor's settlement-time coverage triggers; `reclaimProposerBond` remains, gated as the challenge-game specification states. Budget recycles exactly as the epoch buckets already specify — at `bucketEnd + challengeWindow` — or earlier on release or retirement.
