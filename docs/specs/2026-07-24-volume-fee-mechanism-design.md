# Volume-Based Fee Mechanism Design

**Date:** 2026-07-24
**Status:** Design — not implemented
**Scope:** `ProtocolConfig`, `BaseStrategy`/`IStrategy`, strategy templates, (optionally) `SyndicateGovernor`

---

## 1. Motivation — why profit-only settlement fees are structurally thin

Every protocol fee Sherwood charges today is **profit-contingent and settlement-time**.
The single fee chokepoint is `SyndicateGovernor._distributeFees`
(`src/SyndicateGovernor.sol:1153`), reached only from `_finishSettlement` (`:1062`),
and only when `pnl > 0` (`:1092`). The waterfall:

1. `protocolFee = profit × protocolFeeBps` (≤ 10%, snapshotted from `ProtocolConfig` at propose)
2. `guardianFee = profit × guardianFeeBps` (≤ 5%)
3. `agentFee = netProfit × performanceFeeBps` (≤ 15%)
4. `mgmtFee = (netProfit − agentFee) × managementFeeBps` (≤ 5%) — note: despite the
   name, this is charged on **net profit**, not AUM, so it is effectively a second
   performance fee.

Consequences:

- **Flat or losing proposals generate zero protocol revenue** — the vault traded,
  guardians reviewed, infrastructure ran, and the protocol earned nothing.
- Revenue is proportional to *realized P&L per proposal*, not to *activity*. A grid
  strategy that turns its book over 50× and nets +0.5% pays the same as a buy-and-hold
  that nets +0.5% on one trade.
- `docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md` (§ worked
  economics, lines 460–476) already flags the profit-only fee base as **insufficient to
  fund guardian ROE** at realistic vault sizes.

Hyperliquid's economics point the other way: a small fee on **every unit of traded
notional**, regardless of profitability, compounded by volume. This document
researches that mechanism and specifies how to implement its analogue in Sherwood.

---

## 2. How Hyperliquid's fee mechanism works (research summary)

### 2.1 Per-fill fees on notional

Every fill is charged as `fee = filledNotional × rate`. Base rates (entry tier):

| Market | Taker | Maker |
|---|---|---|
| Perps | 0.045% (4.5 bps) | 0.015% (1.5 bps) |
| Spot | 0.070% (7 bps) | 0.040% (4 bps) |

(Hyperliquid has since cut base rates further ahead of its native-stablecoin launch;
the structure, not the exact numbers, is what matters here.)

### 2.2 Volume tiers and staking discounts

- Rates compress along **14-day rolling volume** tiers: taker 4.5 bps → 4.0 bps above
  $5M → 3.5 bps above $25M → ~2.4 bps at $5B+. Top-tier makers receive a **rebate**
  (≈ −0.3 bps) — the venue pays them.
- **Staking HYPE** grants up to ~40% off, stacking multiplicatively with the volume
  tier. High-volume stakers land in the 1.4–1.8 bps taker band.
- Referrals: 4% discount for referees, referrer earns 10% of referee fees.

### 2.3 Where the fees go

- ~97–99% of orderbook fees flow to the **Assistance Fund**, a protocol wallet that
  **buys HYPE on the open market** (≈ $1M+/day, > $1.3B cumulative); a portion of P&L
  flows to **HLP** (the community liquidity pool). The buyback is protocol policy, not
  a smart-contract invariant.
- The flywheel: tiny take rate × enormous volume × mechanical buyback. Fee revenue is
  a function of *activity*, fully decoupled from whether any individual trader profits.

### 2.4 Builder codes — the venue-native "fee on every trade" rail

Hyperliquid lets third-party apps ("builders") that route orders attach a per-order
fee: the user signs a one-time `ApproveBuilderFee(maxFeeRate, builder)`, and the
builder includes `{b: builderAddress, f: feeTenthsBps}` on each order. The venue
deducts the fee from the fill's USDC leg and credits the builder natively. Caps:
**10 bps on perps, 100 bps on spot**.

### 2.5 Why builder codes do NOT solve this for Sherwood today

Sherwood's Hyperliquid strategies place orders **onchain via CoreWriter**, not through
the exchange API: `L1Write.sendLimitOrder(asset, isBuy, limitPx, sz, reduceOnly, tif,
cloid)` → `ICoreWriter(0x3333…3333).sendRawAction` (`src/hyperliquid/L1Write.sol:101`).

- The CoreWriter **limit-order action has no builder field**. Builder attribution is
  per-order and only exists on the exchange-API path.
- `L1Write.sendApproveBuilderFee(maxFeeRate, builder)` (`src/hyperliquid/L1Write.sol:275`,
  action `0x0100000c`) is already vendored in the repo (currently zero call sites),
  but approving a builder is useless when no order can carry the builder code.
- Fills are not observable from the EVM at all — orders leave as intents and the
  filled size/price never comes back. The only onchain-readable notional is
  `accountMarginSummary.ntlPos` (a position *stock*, not traded *flow*).

**Conclusion:** the venue-native rail is closed to us for CoreWriter-placed orders
(worth revisiting if Hyperliquid ever adds a builder field to the CoreWriter order
action). Sherwood must meter and charge volume itself, at the protocol layer. If
Sherwood ever routes orders through an API agent wallet operated by offchain infra,
builder codes become the drop-in monetization for that path — keep
`sendApproveBuilderFee` vendored.

---

## 3. What Sherwood can meter today — and what it cannot

Findings from the codebase survey:

- **The vault/governor has zero visibility into trading volume.** Strategy trades run
  through proposer-only `updateParams(bytes)` (`src/strategies/BaseStrategy.sol:102`)
  and never touch the vault. The governor sees only the asset-balance snapshot at
  execute (`src/SyndicateGovernor.sol:393`), the balance at settle, and
  `interimNetFlow`.
- **Per-order notional is already computed at every Hyperliquid call site — then
  thrown away.** `approxUsd = sz × limitPx / 1e6` exists purely as a bounds check:
  `HyperliquidPerpStrategy.sol:270, 327, 365`; `HyperliquidGridStrategy.sol:274`.
- `PortfolioStrategy` knows swap `amountIn` at each `swapAdapter.swap(...)` call
  (`:289, 311, 386, 400, 537, 559`); `AerodromeLPStrategy` knows amounts at
  `addLiquidity`/`removeLiquidity`/reward swaps.
- Existing per-trade machinery is caps-only: `tradesToday`/`maxTradesPerDay` (count),
  `maxPositionSize`/`maxOrderSize` (per-order bound), `maxOrdersPerTick`.
- **Fee base must be *submitted* notional, not filled notional** (fills invisible
  onchain, §2.5). This is the one place we diverge from Hyperliquid by necessity.

---

## 4. Design

### 4.1 Shape: accrue per trade, collect at settlement

The fee is **earned per trade** (that is what makes revenue scale with volume) but
**paid once per proposal at settlement**. Real-time payment is impossible anyway for
the Hyperliquid strategies — their capital lives on HyperCore mid-run and only returns
to the EVM through the Circle bridge at sweep. Batching payment changes cash timing,
not economics.

```
per trade:      feeOwed += tradedNotional × volumeFeeBps / 10_000   (in asset units)
at settle:      pay min(feeOwed, cap, availableBalance) → protocolFeeRecipient
```

### 4.2 New protocol parameter — `ProtocolConfig.volumeFeeBps`

`ProtocolConfig` is the cleanest home: plain `Ownable2Step`, already the source of the
two protocol-wide fee rates, already snapshotted onto every proposal at propose time
(`src/SyndicateGovernor.sol:307-313`).

```solidity
uint16 public constant MAX_VOLUME_FEE_BPS = 10;   // hard cap: 0.10% of notional
uint16 public volumeFeeBps;                        // default 2 (0.02%)
```

- The 10 bps cap deliberately mirrors Hyperliquid's own builder-fee cap on perps —
  it is the ceiling the venue itself considers acceptable rent on routed flow.
- Default 2 bps sits below Hyperliquid's taker rate, so the drag on strategy returns
  stays small relative to venue fees the strategy already pays.
- Recipient: reuse `protocolFeeRecipient`. No new trust assumptions.
- Add the getter to `IProtocolConfig` (5th getter, same pattern).

### 4.3 Strategy-side metering — `BaseStrategy`

Trades are invisible outside the strategy, so the strategy must self-meter. Append to
`BaseStrategy` (storage appended to its `__gap`):

```solidity
uint256 internal _volumeFeeOwed;      // asset units, accumulated
uint16  internal _volumeFeeBpsCached; // snapshotted at execute()
uint256 internal _volumeFeeBase;      // funded capital at execute(), for the cap

function _accrueVolume(uint256 notionalAsset) internal {
    if (_volumeFeeBpsCached == 0) return;
    _volumeFeeOwed += notionalAsset * _volumeFeeBpsCached / 10_000;
    emit VolumeAccrued(notionalAsset, _volumeFeeOwed);
}
```

- **Rate snapshot at `execute()`**: the strategy caches `volumeFeeBps` (read via
  `vault → factory → protocolConfig`) when the run starts, clamped to
  `MAX_VOLUME_FEE_BPS`. This preserves the existing snapshot discipline — the rate a
  proposal voted on cannot be raised mid-run — without touching the governor.
- Call sites are exactly where notional is already computed:
  - `HyperliquidPerpStrategy`: after each `approxUsd` check (`:270, 327, 365`) and at
    the force-close path (`:478-485`, using `ntlPos` for the close notional).
  - `HyperliquidGridStrategy`: in `_placeOrders` (`:274`). **Do not** accrue on
    `_cancelOrders` — cancels are not volume, and grid strategies cancel/replace
    constantly.
  - `PortfolioStrategy`: `amountIn` (asset-denominated leg) at each swap call site.
  - `AerodromeLPStrategy`: swap legs and liquidity adds count once at entry; reward
    conversions count at swap. Removes do not double-count.
- One honest limitation, stated openly: for GTC orders this meters **submitted**
  notional, and a cancel-heavy strategy could accrue fees on orders that never fill.
  For the grid strategy, accrue on placement and refund on clean cancel-by-cloid
  (`_volumeFeeOwed -= min(owed, orderNotional × rate)`) so only resting-or-filled
  exposure pays. IOC orders (the perp strategy's default) have no such gap.

### 4.4 Collection — inside `BaseStrategy` settle path, not the governor

Two candidate collection points were considered:

**Option A (recommended): strategy pays at `settle()`/final sweep.**
When the strategy's settle path has swept funds back to the EVM and is about to return
capital to the vault, it first transfers the fee:

```solidity
uint256 fee = _cappedVolumeFee();               // §4.5
if (fee != 0) {
    uint256 pay = Math.min(fee, asset.balanceOf(address(this)));
    if (pay != 0) {
        asset.safeTransfer(protocolFeeRecipient, pay);
        emit VolumeFeePaid(pay, fee - pay);      // second arg = shortfall
    }
}
```

- Self-contained per strategy; **zero governor/vault bytecode** — decisive, because
  the governor runtime is at 24,550 of the 24,576-byte EIP-170 ceiling and the vault
  had to extract an admin lib to fit (see instant-withdrawal spec §0).
- Mirrors the established precedent: `LeveragedAerodromeCLStrategy` already
  self-collects a `protocolFeeOwed` USDC liability and pays
  `factory.protocolConfig().protocolFeeRecipient` directly (`:601-614`).
- Because the fee leaves the strategy **before** the vault balance is read at
  `_finishSettlement`, the volume fee is naturally senior to the P&L waterfall and
  the profit-fee math needs no changes: `pnl` is simply computed net of volume fees,
  exactly like venue fees the strategy already pays.

**Option B (rejected for v1): governor reads `IStrategy.volumeFeeOwed()` at
`_finishSettlement` and pays via the `_payFee` escrow rail.** Cleaner audit trail and
uses the existing brick-resistant try/catch escrow, but: (a) no governor bytecode
headroom; (b) a live settle-time strategy call is exactly the TOCTOU/brick surface the
`selfManagesFees` snapshot discipline was built to avoid; (c) the strategy holds the
cash anyway — routing it strategy→vault→recipient adds a hop for nothing.

**Fail-open, never brick settle:** wrap the transfer in try/catch (or pre-check); on
failure emit `VolumeFeeShortfall` and continue. A fee must never block depositor
exits — same principle as `_payFee`'s escrow (`src/SyndicateGovernor.sol:1267`).

### 4.5 Anti-abuse: the turnover cap

The rate is protocol-set and capped, and the fee flows to the protocol — so nobody
*profits* from inflating volume. The residual risk is **griefing/waste**: a malicious
or buggy proposer churning the book to bleed depositors into fees. Bound it:

```solidity
uint16 public constant VOLUME_FEE_TURNOVER_CAP = 50;   // max fee base = 50× funded capital

function _cappedVolumeFee() internal view returns (uint256) {
    uint256 maxFee = _volumeFeeBase * VOLUME_FEE_TURNOVER_CAP
                     * _volumeFeeBpsCached / 10_000;
    return Math.min(_volumeFeeOwed, maxFee);
}
```

At 2 bps this caps total volume fees at 0.1% of funded capital per 1× of turnover,
worst case 10 bps × 50× = 0.5%… per proposal — visible, bounded, and small next to the
existing per-order caps (`maxPositionSize`, `maxTradesPerDay`, `maxOrdersPerTick`)
that already bound churn. Guardians reviewing calldata see the strategy params that
determine realistic turnover.

### 4.6 Self-managed strategies

`selfManagesFees == true` strategies (`LeveragedAerodromeCLStrategy`) bypass the
governor waterfall entirely (`src/SyndicateGovernor.sol:1098`) but the volume-fee
leg doesn't live in the waterfall — it lives in the strategy. Add the same
`_accrueVolume` calls to its swap/rebalance sites and fold payment into its existing
`protocolFeeOwed` settlement, keeping one payment path per strategy.

### 4.7 Distribution — the Hyperliquid analogue, phased

| Phase | Mechanism | HL analogue |
|---|---|---|
| **v1** | 100% of volume fees → `protocolFeeRecipient` (treasury multisig) | Assistance Fund wallet |
| **v2 (policy)** | Treasury runs a periodic **WOOD buyback** from volume-fee revenue; publish the wallet + cadence | AF's HYPE buyback (~policy, not contract-enforced — same as HL) |
| **v3 (contract)** | Split: X% to a guardian/sWOOD reward stream (fixes the guardian-ROE gap flagged in the economic-security spec), remainder to buyback | HLP share of fees |
| **v3 (discount)** | `volumeFeeBps` discount tiers keyed on the **agent's sWOOD stake** (read from `StakedWood` checkpoints at propose) — staking WOOD lowers the vault's trading costs | HYPE staking discounts |

Volume tiers (HL §2.2) are deliberately **not** replicated in v1: 14-day rolling
volume tracking onchain is state-heavy, and Sherwood's flow per vault is nowhere near
the regime where tiering matters. The staking discount is the right first
differentiator because it creates WOOD demand from the supply side (agents), matching
the buyback demand from the revenue side.

### 4.8 Events + subgraph

New events on `BaseStrategy`: `VolumeAccrued(uint256 notional, uint256 owedTotal)`,
`VolumeFeePaid(uint256 paid, uint256 shortfall)`. Subgraph gains a `VolumeFee` entity
per proposal and a running `notionalTraded` on the strategy/vault entities — today the
subgraph tracks only `performanceFeeBps`/`performanceFee` (`subgraph/schema.graphql:100,107`).
This also gives the frontend a true "volume" stat per syndicate for free.

---

## 5. Worked economics — why this matters

$1M vault, Hyperliquid grid strategy, 1× book turnover/day, 30-day proposal, +2% net:

| Fee stream | Formula | Revenue |
|---|---|---|
| **Today**: protocol fee (10% of profit) | $1M × 2% × 10% | **$2,000** |
| **Today**: guardian fee (5% of profit) | $1M × 2% × 5% | $1,000 |
| **Volume fee @ 2 bps** | $1M × 1×/day × 30d × 0.02% | **$6,000** |
| Same, flat month (0% P&L) | — | $6,000 vs **$0** today |

At 2 bps the volume fee **triples** protocol revenue on a profitable month and is the
*only* revenue on a flat month — while costing the strategy less than half of what it
already pays Hyperliquid in taker fees (4.5 bps) on the same flow. The drag on
depositors is 0.6%/month at 1×/day turnover; proposers price that into strategy
selection exactly as they price venue fees, and low-turnover strategies
(Moonwell supply, LP holds) pay almost nothing — which is correct: they consume the
least protocol attention per dollar.

---

## 6. What is explicitly out of scope

- **Entry/exit fees** — `instantExitFeeBps` was specced and deferred
  (`docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md` §6); orthogonal to
  this design and still blocked on vault bytecode headroom.
- **AUM-based management fee** — a genuine time-on-capital fee is a separate design
  (today's "management fee" is profit-gated); volume fees cover the activity axis.
- **Onchain-enforced buyback** — like Hyperliquid, buyback is treasury policy in v1;
  contract enforcement (v3) needs a WOOD price feed the protocol doesn't have yet
  (flagged in the guardian economic-security spec, lines 702–710).

## 7. Implementation checklist

1. `ProtocolConfig`: `volumeFeeBps` + `MAX_VOLUME_FEE_BPS` + setter + getter in
   `IProtocolConfig`. (Small, isolated, no proxy-layout risk — plain Ownable contract.)
2. `BaseStrategy`: `_volumeFeeOwed` / `_volumeFeeBpsCached` / `_volumeFeeBase`
   (append into `__gap`), `_accrueVolume`, `_cappedVolumeFee`, settle-path payment,
   events. Rate snapshot in the `execute()` path.
3. Per-strategy `_accrueVolume` call sites: Perp (4 sites incl. force-close), Grid
   (place + cancel-refund), Portfolio (6 swap sites), AerodromeLP (3 sites),
   LeveragedAerodromeCL (fold into `protocolFeeOwed`).
4. Tests: accrual math per strategy; cap binding; snapshot-at-execute (rate hike
   mid-run doesn't apply); payment senior to P&L (governor `pnl` reflects fee);
   fail-open on recipient revert; grid cancel-refund; zero-rate short-circuit.
5. Subgraph: `VolumeFee` entity + handlers.
6. Docs: README fee table + this spec's status flip.

---

## Appendix — sources (Hyperliquid research)

- Hyperliquid docs: Fees; Builder Codes (fee caps 10 bps perps / 100 bps spot;
  `ApproveBuilderFee` signed by main wallet; per-order `{b, f}` attribution)
- Datawallet, "Hyperliquid Fees Explained" — base rates, tiers, staking discounts
- Mint Ventures, "A Quick Overview of Hyperliquid" — fee → Assistance Fund / HLP split
- CoinShares/etfdb, "Inside Hyperliquid: How the Fee Engine Works" — ~97% of fees to
  AF buybacks; ≈$1M/day cadence
- Chainstack / Ambit Labs — CoreWriter action encodings (limit order carries
  `asset,isBuy,limitPx,sz,reduceOnly,tif,cloid`; no builder field)
