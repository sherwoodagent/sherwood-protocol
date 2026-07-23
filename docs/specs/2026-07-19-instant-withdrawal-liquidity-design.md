# Instant-Withdrawal Liquidity Design

**Date:** 2026-07-19
**Status:** Implemented (core) — branch `feat/instant-withdrawal-liquidity`. See `docs/superpowers/plans/2026-07-19-instant-withdrawal-liquidity.md`.
**Scope:** `SyndicateVault`, `SyndicateGovernor`, `BaseStrategy`/`IStrategy`, `VaultWithdrawalQueue`

---

## 0. Implementation status (2026-07-20)

**Delivered and tested** (both user asks + correct accounting):

- **Part A — enforced idle buffer.** `minBufferBps` (owner-set, ≤50%, default 0) enforced in `executeGovernorBatch` against the pre-batch float. Commits `8bddd57`, `c914fa2`.
- **Part B — strategy-level liquidity.** `IStrategy.availableLiquidity()`/`withdrawTo()` with inert `BaseStrategy` defaults; `SyndicateVault._withdraw` pulls the shortfall from the active strategy in-tx (balance-diff verified, `UnwindShortfall` on under-delivery), gated on Lane A live-NAV. `maxWithdraw`/`maxRedeem` capacity = float + strategy liquidity. Commits `95cdcce`, `ebb3dba`.
- **Settlement PnL correction.** `_interimNetFlow` accumulator on the vault; `SyndicateGovernor._finishSettlement` subtracts it so mid-proposal LP flows are never charged fees / misread as strategy loss (also fixes a **pre-existing** fee-on-principal bug). Commit `93354d0`.
- **Concrete strategy.** `MoonwellSupplyStrategy.availableLiquidity()`/`withdrawTo()` via `redeemUnderlying`, `getCash`-capped. Commit `bea6f6c`.
- **EIP-170.** Vault was at the 24,576-byte ceiling; cold-path admin logic was extracted to `SyndicateVaultAdminLib` (delegatecall, storage-ref) to free ~1.2 KB (commit `74ffaa7`). A later rescue-function extraction was tried and reverted — small functions cost more in delegatecall dispatch than their inlined bodies save.

**Deferred** (documented, not built):

- **`minHoldingPeriod` anti-flash-arb cooldown (§6).** The vault sits at the EIP-170 ceiling and a lean implementation still needs ~150 B over the ~50 B margin; further library extraction of small functions is counter-productive. The G1 Lane-A per-holder lock (`_laneALockPid`) already blocks the primary intra-proposal deposit→exit MEV, so this is belt-and-suspenders. Storage slots (`minHoldingPeriod`, `lastDepositAt`) remain reserved for a future dedicated size pass.
- **`instantExitFeeBps` and `maxUnwindSlippageBps` (§6).** As already noted below — G1 covers cycling; slippage is a per-strategy concern (Moonwell `redeemUnderlying` has none).

**Follow-ups for CI (need a Base RPC endpoint unavailable in the dev sandbox):**

- Pinned-block Base fork test for `MoonwellSupplyStrategy.withdrawTo` against the live mUSDC market (mock-based coverage exists and passes).
- Property-based invariant suite (reserve-seniority, settlement-PnL integrity under interleaved flows, no-exit-without-pricing). The full 1378-test non-fork suite passes; a fuzz harness would further harden the `_interimNetFlow` invariant.

**Known pre-existing bug (out of scope):** `invariant_reservedAssetsLeFloatWhenUnlocked` fails with a 1-wei `reserve > float` off-by-one in the async-redeem queue accounting — reproduced identically on the pre-branch commit. Worth a separate fix.

---

## 1. Motivation

Today an LP cannot exit the vault while a strategy proposal is live. The lock chain:

1. `SyndicateGovernor.executeProposal` sets `_activeProposal` (`SyndicateGovernor.sol:369`); it is cleared only in `_finishSettlement` (`:917`), which cannot run before `executedAt + strategyDuration`.
2. `SyndicateVault.redemptionsLocked()` (`SyndicateVault.sol:469-473`) is true for that whole window.
3. While locked, `maxWithdraw`/`maxRedeem` return 0 (`:759`, `:771` via `_laneBOnly`), so every ERC-4626 exit reverts. Deposits revert `DepositsLocked` (`:716`) unless Lane A live-NAV is available.

The only mid-strategy exit is the Lane B async queue (`requestRedeem`, `SyndicateVault.sol:804-830`) — but its `claim` only pays out **after** settlement, at the frozen settle price. So in practice: *users wait for the strategy to finish.*

**Goal:** users can withdraw at any time. Two levers, both industry-standard:

- **(A) Liquidity buffer** — a governance-enforced % of assets stays idle in the vault, never deployed to the strategy.
- **(B) Strategy-level liquidity** — strategies that can service on-demand entry/exit do so mid-lifecycle; the vault pulls from them in the same transaction when the buffer is short.

Lane B remains the fallback when both are exhausted — a buffer is *not* a solvency guarantee (see §8).

## 2. Industry survey (verified sources)

Three families of designs, all points on one axis — how much sits idle, and what happens when idle runs dry:

| Pattern | Protocols | Mechanics |
|---|---|---|
| Buffer + synchronous drain | Yearn v3, Morpho V1/V2 | Governance-set idle floor (`minimum_total_idle` / idle market first in queues). Withdrawals serve from idle; shortfall pulled from strategies **in the same tx** via an ordered queue (Yearn `default_queue`, ≤10) or a designated `liquidityAdapter` (Morpho V2). Withdrawer eats pro-rata unrealized loss, bounded by user-supplied `maxLoss` bps. |
| Always-liquid pool | GMX GLP, Hyperliquid vaults, Morpho `forceDeallocate` | Redeem directly against pool equity at live NAV including unrealized PnL. GLP: 15-min post-mint cooldown as arb protection. Hyperliquid: withdrawal proportionally closes open positions at withdraw time; time-locks (1d user vaults / 4d HLP) instead of unwind-waits. Morpho: `forceDeallocate` guarantees exit with ≤2% penalty. |
| Async request/claim | ERC-7540, Lido, Maple, EtherFi, Centrifuge | `requestRedeem` escrows shares immediately (Pending → Claimable → Claimed); `previewRedeem` MUST revert. Lido: request = transferable ERC-721, no reward accrual while queued, can finalize below 1:1 on losses. Maple: FIFO, <24h typical, up to 30d in stress. Centrifuge `SyncDepositVault`: sync deposits + async redemptions — entering is easy, exiting is not. |

Key precedents adopted here:

- **Yearn v3 `minimum_total_idle`** → Part A buffer parameter.
- **Morpho V2 `liquidityAdapter` / Yearn withdrawal queue** → Part B same-tx strategy pull.
- **Yearn "withdrawer takes his share of unrealised losses"** → live-NAV pricing on instant exit (§5).
- **GLP post-mint cooldown / Morpho ≤2% deallocation penalty** → anti-griefing guardrails (§6).
- **Documented failure mode:** Morpho vaults went briefly illiquid in Nov 2025 when idle buffers depleted during ecosystem-wide risk-off; ~80% of queued withdrawals cleared within 3 days via utilization-driven rate spikes, not the buffer. Buffers delay runs; they do not prevent them.

Sherwood already has partial versions of everything above:

- Lane B queue ≈ ERC-7540 request/claim.
- `LeveragedAerodromeCLStrategy` custody model (`deposit()`/`redeem()` via `strategyMint`/`strategyBurn`, `SyndicateVault.sol:921-938`) ≈ strategy-level liquidity, but bespoke to one strategy.
- Lane A live-NAV (`_liveNAV`, `SyndicateVault.sol:610-621`) with vault-side pricing via `PriceRouter` ≈ mark-to-market share pricing.
- `QueueReserveBreached` post-batch float floor (`SyndicateVault.sol:444`) ≈ a reserve floor, currently covering only settled-but-unclaimed queue assets.

This spec generalizes those pieces instead of inventing new machinery.

## 3. Part A — Enforced liquidity buffer

### 3.1 Parameter

```solidity
uint16 public minBufferBps; // e.g. 1_000 = 10%; 0 disables the buffer
```

- Set at `initialize` via `InitParams`, updatable by governance (`setMinBufferBps`), bounded `<= 5_000` (50%) to keep the vault useful.
- Semantics: after any governor batch executes, the vault's idle asset balance must cover **both** the queue reserve and the buffer.

### 3.2 Enforcement point

Extend the existing post-batch check in `executeGovernorBatch` (`SyndicateVault.sol:422-445`):

```
before: revert QueueReserveBreached if balance < reservedQueueAssets()
after:  revert BufferBreached      if balance < reservedQueueAssets() + _bufferTarget()
```

where `_bufferTarget() = totalAssets() * minBufferBps / 10_000`, computed **after** the batch (so it reflects what actually left the vault). A proposer can therefore deploy at most `(1 − minBufferBps)` of assets; the amount is still proposer-chosen (no protocol-side allocation logic), the floor is just enforced.

Notes:

- The buffer is a **deployment-time constraint only**. Withdrawals may drain the buffer below target between batches — that is its purpose (Yearn treats `minimum_total_idle` the same way: enforced during debt updates, spendable by withdrawals).
- `rescueEth/ERC20/ERC721` remain locked during proposals (unchanged).
- Buffer replenishes naturally from new deposits (which sit as float) and at settlement.

## 4. Part B — Instant exit while a strategy is live

### 4.1 Unlocking the synchronous path

Replace the blanket Lane-B-only gate with a liquidity-and-pricing gate. New behavior of `maxWithdraw`/`maxRedeem` while `redemptionsLocked()`:

```
if (!laneAAvailable())  return 0;                    // cannot price shares → Lane B only (unchanged)
else                    return min(ownerAssets, instantCapacity());
```

where

```
instantCapacity() = _availableFloat() + activeStrategyLiquidity()
```

- `laneAAvailable()` is the existing Lane A condition (`_liveNAV` nonzero path: router set, active strategy set, every position provably instant-eligible). **This is a hard requirement**: when Lane A is unavailable, `totalAssets()` is float-only (`SyndicateVault.sol:680-683`), so any instant exit would be mispriced — exiters would be robbed or would rob remaining LPs. No pricing, no instant exit.
- `_availableFloat()` (`:644-648`) already nets out `reservedQueueAssets`.
- Deposits: the existing rule already admits deposits when Lane A is available (`:716`); unchanged. This gives us Centrifuge's `SyncDepositVault` asymmetry inverted — here both directions are sync when priceable, async otherwise.

### 4.2 Strategy-level liquidity interface

Generalize the custody model into `IStrategy`:

```solidity
/// @notice Assets the strategy can return to the vault on demand, in vault-asset terms,
///         net of unwind costs. 0 if the strategy does not support on-demand exit.
function availableLiquidity() external view returns (uint256);

/// @notice Unwind and transfer exactly `assets` of vault asset back to the vault.
///         MUST revert if it cannot deliver `assets` within `maxUnwindSlippageBps`.
function withdrawTo(uint256 assets) external; // onlyVault
```

- `BaseStrategy` provides default implementations returning 0 / reverting `OnDemandExitUnsupported`, so existing strategies compile and behave exactly as today (Lane B only when float is exhausted).
- Liquid strategies (e.g. `MoonwellSupplyStrategy` — redeemable mToken position) override both. `LeveragedAerodromeCLStrategy` refactors its bespoke `redeem()` internals onto this interface.
- Vault-side pull, inside `_withdraw` (`SyndicateVault.sol:738-749`), before the asset transfer:

```
shortfall = assets > float ? assets - float : 0;
if (shortfall > 0) IStrategy(activeStrategy).withdrawTo(shortfall);  // same tx, Yearn-queue pattern (queue length 1)
```

- Trust model unchanged: the vault never trusts strategy self-reports for **pricing** — `PriceRouter` prices positions vault-side. `availableLiquidity()` is only a serviceability signal; the pull path verifies delivery by balance-diff and reverts on shortfall (`UnwindShortfall`).
- `withdrawTo` decreases the strategy's position mid-flight; the next `_liveNAV` read reflects it automatically since the router prices live positions.

### 4.3 Interaction with Lane B and settlement

- Lane B (`requestRedeem`/`requestDeposit`) remains available and unchanged — it is the path when `laneAAvailable()` is false, when `instantCapacity()` is insufficient, or when the user prefers the frozen settle price.
- Settlement accounting (`_finishSettlement`, `SyndicateGovernor.sol:900-947`) computes `pnl = balance − capitalSnapshot`. Mid-lifecycle instant exits and deposits move the float, which would corrupt that delta. Fix: track a signed `interimNetFlow` on the vault (increased by mid-proposal deposits, decreased by instant exits **and** by `withdrawTo` pulls net of what was paid out), and settle against `capitalSnapshot + interimNetFlow`. The custody model already solved the share-supply side of this via `strategyMint`/`strategyBurn`; this extends the same idea to the asset side. Exact accounting to be pinned down in the implementation plan — it is the most delicate part of the change (G-H1 NatSpec, `SyndicateGovernor.sol:891-899`, must be preserved: un-unwound positions still count as losses).

## 5. Share pricing during pending strategy PnL

Instant exits price at **live NAV** (Lane A): `totalAssets() = float + Σ PriceRouter-priced positions`, unrealized PnL included. Consequences, all deliberate:

- **Exiter eats pro-rata unrealized loss** (Yearn's bank-run defense: "if there are unrealised losses, the user will take his share"). No first-exiter advantage — the loss is already in the price they exit at.
- **Exiter also realizes pro-rata unrealized gains.** Symmetric and fair; the settlement fee skim (§4.3 `interimNetFlow`) must ensure performance fees are still charged on gains paid out mid-lifecycle, or accept the leak and document it (open question Q3).
- **No frozen-price arbitrage between lanes.** Lane B settles at the post-fee settle price; instant exits settle at live NAV. Divergence between them is the fee + time premium a Lane B user accepts. An arbitrageur cannot hold both options on the same shares simultaneously (Lane B escrows shares at request).

**Considered and deferred:** Yearn's locked-profit streaming (`profit_max_unlock_time` — profits locked as vault-held shares, linearly unlocked, smooths PPS and kills report-sandwiching). Sherwood realizes PnL once per proposal at settlement rather than via periodic harvest reports, and Lane A NAV is continuous, so the report-step problem Yearn solves does not exist here in the same form. Revisit if strategies ever gain mid-lifecycle `report()` semantics.

## 6. Guardrails

| Risk | Guardrail | Precedent |
|---|---|---|
| Flash deposit → instant redeem around NAV moves (oracle latency arb) | `minHoldingPeriod` (per-account timestamp on deposit; instant exit reverts before it elapses; Lane B exempt). Default 15 min – 1 day, governance-set. | GLP 15-min post-mint cooldown; Hyperliquid 1-day lock |
| Buffer/unwind griefing (cycling deposits+exits to force strategy churn) | `instantExitFeeBps` charged **only on the portion sourced via `withdrawTo`** (float-sourced exits are free). Fee accrues to the vault (remaining LPs). Bounded ≤ 200 bps. | Morpho `forceDeallocate` ≤2% penalty |
| Unwind slippage dumped on remaining LPs | `maxUnwindSlippageBps` enforced inside `withdrawTo` (strategy reverts if it cannot deliver within bound); exit falls back to Lane B on revert. | Yearn `maxLoss` bound |
| PPS oracle manipulation (inflate NAV, exit rich) | Already mitigated: vault-side `PriceRouter` pricing, virtual-shares offset (`SyndicateVault.sol:584-586`). `minHoldingPeriod` removes the flash-loan variant. Router feed hardening is out of scope here but load-bearing. | OZ 4626 defenses |
| Mass exit exhausts buffer + strategy liquidity | By design: instant path caps at `instantCapacity()`; excess must use Lane B. No promise of unconditional instant exit — documented loudly. | Morpho Nov-2025 illiquidity episode |

## 7. Storage & interface changes

`SyndicateVault` (append-only, storage-gap accounting per repo convention):

```solidity
uint16 public minBufferBps;          // Part A
uint16 public instantExitFeeBps;     // §6
uint32 public minHoldingPeriod;      // §6, seconds
int256 internal _interimNetFlow;     // §4.3 settlement correction
mapping(address => uint40) public lastDepositAt; // §6 cooldown
```

- `InitParams` extended with the three parameters; validation in `initialize` (`minBufferBps <= 5_000`, `instantExitFeeBps <= 200`).
- Setters: `setMinBufferBps`, `setInstantExitFeeBps`, `setMinHoldingPeriod` — same access pattern as existing parameter setters.
- New errors: `BufferBreached`, `UnwindShortfall`, `HoldingPeriodActive`, `OnDemandExitUnsupported`.
- `IStrategy`: add `availableLiquidity()`, `withdrawTo(uint256)`; `BaseStrategy` defaults keep all existing strategies source-compatible.
- `SyndicateGovernor._finishSettlement`: read/reset `_interimNetFlow` in the PnL computation.

## 8. Security analysis

1. **Bank run.** The buffer converts "everyone waits for settlement" into "first `instantCapacity()` of exits are instant, rest queue." Live-NAV pricing removes the classic run *incentive* (early exiters gain nothing — losses are already marked), but not run *behavior* under panic. Lane B absorbs the overflow; it cannot be griefed into insolvency because instant exits stop exactly at capacity and `reservedQueueAssets` stays senior (`_availableFloat` netting, unchanged).
2. **Settlement accounting integrity.** `_interimNetFlow` is the critical invariant: `pnl` must equal true strategy performance regardless of interleaved instant flows. Property-based test required (§9). G-H1 (un-unwound positions = loss) preserved because `withdrawTo` physically returns assets before they count.
3. **Strategy as adversary.** `withdrawTo` is a new vault→strategy call while user funds are in flight. Reentrancy: `_withdraw` is already `nonReentrant`; the strategy receives no control over accounting mid-call beyond delivering tokens (balance-diff verified). A malicious strategy can under-deliver → revert; it can already steal deployed funds today (strategies are governance-approved code), so trust surface is unchanged.
4. **Pricing gate is load-bearing.** Every instant-exit path MUST be behind `laneAAvailable()`. A regression that allows exit on float-only NAV is a critical theft-of-funds bug. Invariant test required.
5. **Custody-model coexistence.** `LeveragedAerodromeCLStrategy.deposit()/redeem()` bypasses vault gates by design (`strategyMint`/`strategyBurn` NatSpec, `SyndicateVault.sol:899-938`). Its refactor onto `withdrawTo` must not double-count flows in `_interimNetFlow` (strategy-initiated vs vault-initiated paths).

## 9. Test plan

- **Unit:** buffer enforcement (`BufferBreached` at exact boundary; batch deploying `(1−buffer)` succeeds); setter bounds; holding-period reverts; exit-fee applied only to `withdrawTo`-sourced portion.
- **Flow:** instant exit fully from float; exit spanning float + `withdrawTo`; exit exceeding `instantCapacity()` reverts with Lane B still available; exit while `laneAAvailable() == false` returns `maxWithdraw == 0`.
- **Invariant/fuzz:** (a) `pnl` at settlement equals strategy-only performance under random interleavings of deposits, instant exits, Lane B requests, and `withdrawTo` pulls; (b) `balance ≥ reservedQueueAssets` always; (c) no instant exit ever executes at float-only pricing.
- **Fork:** `MoonwellSupplyStrategy.withdrawTo` on pinned Base block (pin per guardrails — no `latest`); `LeveragedAerodromeCLStrategy` refactor parity with its current `redeem()`.
- **Regression:** full existing suite (Lane B lifecycle, settle-price stamping, queue claims/cancels) unchanged when `minBufferBps == 0` and no strategy overrides `withdrawTo` — i.e., the feature is strictly additive.

## 10. Open questions

- **Q1 — Default `minBufferBps`.** 10% (Yearn-ish curator practice) vs per-syndicate choice at creation with 0 allowed. Recommendation: init parameter, no protocol default.
- **Q2 — `minHoldingPeriod` default.** 15 min (GLP) vs 1 day (Hyperliquid). Recommendation: 1 hour default, governance-tunable.
- **Q3 — Performance fee on mid-lifecycle exits.** Skim pro-rata fee on the gain component of instant exits (exact, complex) vs settle-time-only fees (accepts a small leak where an exiter realizes gains fee-free). Recommendation: accept the leak initially, document it; `instantExitFeeBps` partially offsets.
- **Q4 — Should `withdrawTo` support partial fills?** Current spec: all-or-revert (simpler invariants). Yearn supports partial with `maxLoss`. Revisit if strategies with lumpy liquidity appear.

## 11. Sources

Primary: Yearn v3 `TECH_SPEC.md` + `VaultV3.vy` (github.com/yearn/yearn-vaults-v3), docs.yearn.fi v3 vault management / integration; EIP-7540 (eips.ethereum.org); Lido withdrawal-queue ERC-721 docs (docs.lido.fi); Morpho Vault V2 + liquidity docs (docs.morpho.org); Centrifuge vaults architecture (docs.centrifuge.io); GMX GLP docs (docs.gmx.io); Hyperliquid vault docs (hyperliquid.gitbook.io); Maple withdrawal process (maplefinance.gitbook.io); OpenZeppelin ERC-4626 exchange-rate-manipulation analysis. All claims 3-vote adversarially verified except where noted.
