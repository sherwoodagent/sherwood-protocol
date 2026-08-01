# Instant-Withdrawal Liquidity Design

> Original: docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md (2026-07-19). Status at archive time: Implemented (core) — branch `feat/instant-withdrawal-liquidity`. Scope: `SyndicateVault`, `SyndicateGovernor`, `BaseStrategy`/`IStrategy`, `VaultWithdrawalQueue`.

## Context

### Motivation

An LP could not exit the vault while a strategy proposal was live. The lock chain:

1. `SyndicateGovernor.executeProposal` sets `_activeProposal`; it is cleared only in `_finishSettlement`, which cannot run before `executedAt + strategyDuration`.
2. `SyndicateVault.redemptionsLocked()` is true for that whole window.
3. While locked, `maxWithdraw`/`maxRedeem` return 0 (via `_laneBOnly`), so every ERC-4626 exit reverts. Deposits revert `DepositsLocked` unless Lane A live-NAV is available.

The only mid-strategy exit was the Lane B async queue (`requestRedeem`) — but its `claim` only pays out **after** settlement, at the frozen settle price. So in practice: *users wait for the strategy to finish.*

**Goal:** users can withdraw at any time. Two levers, both industry-standard:

- **(A) Liquidity buffer** — a governance-enforced % of assets stays idle in the vault, never deployed to the strategy.
- **(B) Strategy-level liquidity** — strategies that can service on-demand entry/exit do so mid-lifecycle; the vault pulls from them in the same transaction when the buffer is short.

Lane B remains the fallback when both are exhausted — a buffer is *not* a solvency guarantee.

### Industry survey (verified sources)

Three families of designs, all points on one axis — how much sits idle, and what happens when idle runs dry:

| Pattern | Protocols | Mechanics |
|---|---|---|
| Buffer + synchronous drain | Yearn v3, Morpho V1/V2 | Governance-set idle floor (`minimum_total_idle` / idle market first in queues). Withdrawals serve from idle; shortfall pulled from strategies **in the same tx** via an ordered queue (Yearn `default_queue`, ≤10) or a designated `liquidityAdapter` (Morpho V2). Withdrawer eats pro-rata unrealized loss, bounded by user-supplied `maxLoss` bps. |
| Always-liquid pool | GMX GLP, Hyperliquid vaults, Morpho `forceDeallocate` | Redeem directly against pool equity at live NAV including unrealized PnL. GLP: 15-min post-mint cooldown as arb protection. Hyperliquid: withdrawal proportionally closes open positions at withdraw time; time-locks (1d user vaults / 4d HLP) instead of unwind-waits. Morpho: `forceDeallocate` guarantees exit with ≤2% penalty. |
| Async request/claim | ERC-7540, Lido, Maple, EtherFi, Centrifuge | `requestRedeem` escrows shares immediately (Pending → Claimable → Claimed); `previewRedeem` MUST revert. Lido: request = transferable ERC-721, no reward accrual while queued, can finalize below 1:1 on losses. Maple: FIFO, <24h typical, up to 30d in stress. Centrifuge `SyncDepositVault`: sync deposits + async redemptions — entering is easy, exiting is not. |

Key precedents adopted here:

- **Yearn v3 `minimum_total_idle`** → Part A buffer parameter.
- **Morpho V2 `liquidityAdapter` / Yearn withdrawal queue** → Part B same-tx strategy pull.
- **Yearn "withdrawer takes his share of unrealised losses"** → live-NAV pricing on instant exit.
- **GLP post-mint cooldown / Morpho ≤2% deallocation penalty** → anti-griefing guardrails.
- **Documented failure mode:** Morpho vaults went briefly illiquid in Nov 2025 when idle buffers depleted during ecosystem-wide risk-off; ~80% of queued withdrawals cleared within 3 days via utilization-driven rate spikes, not the buffer. Buffers delay runs; they do not prevent them.

Sherwood already had partial versions of everything above:

- Lane B queue ≈ ERC-7540 request/claim.
- `LeveragedAerodromeCLStrategy` custody model (`deposit()`/`redeem()` via `strategyMint`/`strategyBurn`) ≈ strategy-level liquidity, but bespoke to one strategy.
- Lane A live-NAV (`_liveNAV`) with vault-side pricing via `PriceRouter` ≈ mark-to-market share pricing.
- `QueueReserveBreached` post-batch float floor ≈ a reserve floor, covering only settled-but-unclaimed queue assets.

This design generalizes those pieces instead of inventing new machinery.

## Goals / Non-Goals

- **Goals:** LPs can exit at any time up to `instantCapacity() = availableFloat + activeStrategyLiquidity` while a proposal is live; buffer floor enforced at deployment time; settlement PnL stays correct under mid-proposal flows; strictly additive (feature off by default, all existing strategies unchanged).
- **Non-Goals:** unconditional instant exit (excess routes to Lane B — documented loudly); partial-fill `withdrawTo` (all-or-revert in v1); `instantExitFeeBps` and `maxUnwindSlippageBps` (deferred — G1 Lane-A lock covers intra-proposal cycling, slippage is a per-strategy concern); `minHoldingPeriod` (deferred on EIP-170 grounds, storage reserved); locked-profit streaming (Yearn `profit_max_unlock_time` — the report-step problem it solves does not exist here since PnL realizes once per proposal and Lane A NAV is continuous).

## Decisions

### Part A — Enforced liquidity buffer

Parameter:

```solidity
uint16 public minBufferBps; // e.g. 1_000 = 10%; 0 disables the buffer
```

- Owner-settable (`setMinBufferBps`), bounded `<= 5_000` (50%) to keep the vault useful. (As-built deviation from the original spec: setter-only with default 0, **no `InitParams` extension** — avoids a 10+ file constructor sweep and is storage-safe on live proxies.)
- Semantics: after any governor batch executes, the vault's idle asset balance must cover **both** the queue reserve and the buffer.

Enforcement point — extends the existing post-batch check in `executeGovernorBatch`:

```
before: revert QueueReserveBreached if balance < reservedQueueAssets()
after:  revert BufferBreached      if balance < reservedQueueAssets() + bufferTarget
```

As-built, `bufferTarget = balanceBefore * minBufferBps / 10_000` computed on the **pre-batch** asset balance (deviation from the spec's post-batch `totalAssets()` basis): deterministic, oracle-free, same "X% of the float at deployment time stays idle" semantics. A proposer can deploy at most `(1 − minBufferBps)` of the float; the amount is still proposer-chosen, the floor is just enforced.

Notes:

- The buffer is a **deployment-time constraint only**. Withdrawals may drain the buffer below target between batches — that is its purpose (Yearn treats `minimum_total_idle` the same way: enforced during debt updates, spendable by withdrawals).
- `rescueEth/ERC20/ERC721` remain locked during proposals (unchanged).
- Buffer replenishes naturally from new deposits (which sit as float) and at settlement.

### Part B — Instant exit while a strategy is live

**Unlocking the synchronous path.** Replace the blanket Lane-B-only gate with a liquidity-and-pricing gate. New behavior of `maxWithdraw`/`maxRedeem` while `redemptionsLocked()`:

```
if (!laneAAvailable())  return 0;                    // cannot price shares → Lane B only (unchanged)
else                    return min(ownerAssets, instantCapacity());
```

where `instantCapacity() = _availableFloat() + activeStrategyLiquidity()`.

- `laneAAvailable()` is the existing Lane A condition (router set, active strategy set, every position provably instant-eligible). **This is a hard requirement**: when Lane A is unavailable, `totalAssets()` is float-only, so any instant exit would be mispriced — exiters would be robbed or would rob remaining LPs. No pricing, no instant exit.
- `_availableFloat()` already nets out `reservedQueueAssets`.
- Deposits: the existing rule already admits deposits when Lane A is available; unchanged. This gives Centrifuge's `SyncDepositVault` asymmetry inverted — here both directions are sync when priceable, async otherwise.

**Strategy-level liquidity interface** — generalizes the custody model into `IStrategy`:

```solidity
/// @notice Assets the strategy can return to the vault on demand, in vault-asset terms,
///         net of unwind costs. 0 if the strategy does not support on-demand exit.
function availableLiquidity() external view returns (uint256);

/// @notice Unwind and transfer exactly `assets` of vault asset back to the vault.
function withdrawTo(uint256 assets) external; // onlyVault, all-or-revert
```

- `BaseStrategy` provides default implementations returning 0 / reverting `OnDemandExitUnsupported`, so existing strategies compile and behave exactly as before (Lane B only when float is exhausted).
- Liquid strategies (e.g. `MoonwellSupplyStrategy` — redeemable mToken position) override both. (`LeveragedAerodromeCLStrategy`'s refactor onto this interface was scoped out: its custody model already provides mid-lifecycle exit, `selfManagesFees` opts it out of governor PnL, and its `availableLiquidity` stays 0 so the vault never pulls from it.)
- Vault-side pull, inside `_withdraw`, before the asset transfer: `shortfall = assets > float ? assets - float : 0; if (shortfall > 0) IStrategy(activeStrategy).withdrawTo(shortfall)` — same tx, Yearn-queue pattern with queue length 1.
- Trust model unchanged: the vault never trusts strategy self-reports for **pricing** — `PriceRouter` prices positions vault-side. `availableLiquidity()` is only a serviceability signal; the pull path verifies delivery by balance-diff and reverts `UnwindShortfall` on shortfall.
- `withdrawTo` decreases the strategy's position mid-flight; the next `_liveNAV` read reflects it automatically since the router prices live positions.

**Interaction with Lane B and settlement.**

- Lane B (`requestRedeem`/`requestDeposit`) remains available and unchanged — the path when `laneAAvailable()` is false, when `instantCapacity()` is insufficient, or when the user prefers the frozen settle price.
- Settlement accounting: `_finishSettlement` computes `pnl = balance − capitalSnapshot`. Mid-lifecycle instant exits and deposits move the float, which would corrupt that delta. Fix: track a signed `_interimNetFlow` on the vault (increased by mid-proposal Lane A deposits, decreased by instant exits), and settle against `capitalSnapshot + interimNetFlow`. The custody model already solved the share-supply side via `strategyMint`/`strategyBurn`; this extends the same idea to the asset side. G-H1 (un-unwound positions still count as losses) is preserved because `withdrawTo` physically returns assets before they count.

### Share pricing during pending strategy PnL

Instant exits price at **live NAV** (Lane A): `totalAssets() = float + Σ PriceRouter-priced positions`, unrealized PnL included. Consequences, all deliberate:

- **Exiter eats pro-rata unrealized loss** (Yearn's bank-run defense). No first-exiter advantage — the loss is already in the price they exit at.
- **Exiter also realizes pro-rata unrealized gains.** Symmetric and fair; the accepted (documented) leak is that an exiter realizes gains fee-free mid-lifecycle (open question Q3 — leak accepted initially).
- **No frozen-price arbitrage between lanes.** Lane B settles at the post-fee settle price; instant exits settle at live NAV. Divergence is the fee + time premium a Lane B user accepts. An arbitrageur cannot hold both options on the same shares simultaneously (Lane B escrows shares at request).

**Considered and deferred:** Yearn's locked-profit streaming (`profit_max_unlock_time`). Sherwood realizes PnL once per proposal at settlement rather than via periodic harvest reports, and Lane A NAV is continuous, so the report-step problem Yearn solves does not exist here in the same form. Revisit if strategies ever gain mid-lifecycle `report()` semantics.

### Guardrails

| Risk | Guardrail | Precedent |
|---|---|---|
| Flash deposit → instant redeem around NAV moves (oracle latency arb) | `minHoldingPeriod` (per-account timestamp on deposit; Lane B exempt). **Deferred** — G1 Lane-A lock covers the primary vector; storage reserved. | GLP 15-min post-mint cooldown; Hyperliquid 1-day lock |
| Buffer/unwind griefing (cycling deposits+exits to force strategy churn) | `instantExitFeeBps` on the `withdrawTo`-sourced portion only. **Deferred** — G1 lock blocks intra-proposal cycling; a fee breaks EIP-4626 preview exactness unless previews are also overridden (EIP-170 cost). | Morpho `forceDeallocate` ≤2% penalty |
| Unwind slippage dumped on remaining LPs | `maxUnwindSlippageBps` inside `withdrawTo`. **Deferred** — per-strategy concern (Moonwell `redeemUnderlying` is slippage-free); revisit with the first AMM-position `withdrawTo` override. | Yearn `maxLoss` bound |
| PPS oracle manipulation (inflate NAV, exit rich) | Already mitigated: vault-side `PriceRouter` pricing, virtual-shares offset. Router feed hardening is out of scope here but load-bearing. | OZ 4626 defenses |
| Mass exit exhausts buffer + strategy liquidity | By design: instant path caps at `instantCapacity()`; excess must use Lane B. No promise of unconditional instant exit — documented loudly. | Morpho Nov-2025 illiquidity episode |

### Storage & interface changes (as built)

`SyndicateVault` (append-only, storage-gap accounting per repo convention): `minBufferBps` (uint16), `minHoldingPeriod` (uint32, reserved/unused), `_interimNetFlow` (int256), `lastDepositAt` mapping (reserved/unused) — `__gap` 35 → 32. Parameters are owner-set post-deploy (no `InitParams` change); defaults 0 = feature off. New errors: `BufferTooHigh`, `BufferBreached`, `UnwindShortfall`, `OnDemandExitUnsupported` (BaseStrategy). `IStrategy`: `availableLiquidity()`, `withdrawTo(uint256)` with source-compatible `BaseStrategy` defaults. `SyndicateGovernor._finishSettlement`: subtracts `interimNetFlow()`; the vault resets the accumulator in `onProposalSettled`.

### Key implementation decisions (locked in at plan time)

1. **No `InitParams` change** — setters only, defaults 0 (feature off); keeps 10+ construction sites untouched and the upgrade storage-safe.
2. **Buffer target computed on the pre-batch balance**, not `totalAssets()` — deterministic, no oracle dependency.
3. **`withdrawTo` is all-or-revert** — delivery verified by balance-diff; partial fills are a future extension (Q4).
4. **`instantExitFeeBps` deferred** — G1 Lane-A lock (`_laneALockPid`) already blocks intra-proposal deposit→exit cycling; a fee breaks 4626 preview exactness; EIP-170 budget.
5. **`nonReentrant` added to `_withdraw`** — the prior "no guard needed" rationale (no external calls on this path) no longer holds once `strategy.withdrawTo` is introduced.

## Risks / Trade-offs

### Security analysis

1. **Bank run.** The buffer converts "everyone waits for settlement" into "first `instantCapacity()` of exits are instant, rest queue." Live-NAV pricing removes the classic run *incentive* (early exiters gain nothing — losses are already marked), but not run *behavior* under panic. Lane B absorbs the overflow; it cannot be griefed into insolvency because instant exits stop exactly at capacity and `reservedQueueAssets` stays senior (`_availableFloat` netting, unchanged).
2. **Settlement accounting integrity.** `_interimNetFlow` is the critical invariant: `pnl` must equal true strategy performance regardless of interleaved instant flows. Property-based test required (deferred to CI follow-up). G-H1 (un-unwound positions = loss) preserved because `withdrawTo` physically returns assets before they count.
3. **Strategy as adversary.** `withdrawTo` is a new vault→strategy call while user funds are in flight. Reentrancy: `_withdraw` is `nonReentrant`; the strategy receives no control over accounting mid-call beyond delivering tokens (balance-diff verified). A malicious strategy can under-deliver → revert; it can already steal deployed funds today (strategies are governance-approved code), so trust surface is unchanged.
4. **Pricing gate is load-bearing.** Every instant-exit path MUST be behind `laneAAvailable()`. A regression that allows exit on float-only NAV is a critical theft-of-funds bug. Invariant test required.
5. **Custody-model coexistence.** `LeveragedAerodromeCLStrategy.deposit()/redeem()` bypasses vault gates by design (`strategyMint`/`strategyBurn`). Kept on its bespoke path (out of scope for the `withdrawTo` refactor) so flows are never double-counted in `_interimNetFlow`.

### Open questions (with resolutions)

- **Q1 — Default `minBufferBps`.** Resolved: owner setter, default 0, no protocol default (no `InitParams` field).
- **Q2 — `minHoldingPeriod` default.** Resolved by deferral: feature not built in this change (EIP-170); storage reserved.
- **Q3 — Performance fee on mid-lifecycle exits.** Accept the leak initially, document it; `instantExitFeeBps` would partially offset when/if built.
- **Q4 — Partial-fill `withdrawTo`.** All-or-revert (simpler invariants). Revisit if strategies with lumpy liquidity appear.

### Known pre-existing bug (out of scope)

`invariant_reservedAssetsLeFloatWhenUnlocked` fails with a 1-wei `reserve > float` off-by-one in the async-redeem queue accounting — reproduced identically on the pre-branch commit. Worth a separate fix.

### Sources

Primary: Yearn v3 `TECH_SPEC.md` + `VaultV3.vy` (github.com/yearn/yearn-vaults-v3), docs.yearn.fi v3 vault management / integration; EIP-7540 (eips.ethereum.org); Lido withdrawal-queue ERC-721 docs (docs.lido.fi); Morpho Vault V2 + liquidity docs (docs.morpho.org); Centrifuge vaults architecture (docs.centrifuge.io); GMX GLP docs (docs.gmx.io); Hyperliquid vault docs (hyperliquid.gitbook.io); Maple withdrawal process (maplefinance.gitbook.io); OpenZeppelin ERC-4626 exchange-rate-manipulation analysis. All claims 3-vote adversarially verified except where noted.
