# Volume-Based Fee Mechanism Design

**Date:** 2026-07-24 (rev. 2 — Hyperliquid strategies removed from scope)
**Status:** Design — not implemented
**Scope:** `ProtocolConfig`, `BaseStrategy`/`IStrategy`, strategy templates, (optionally) `SyndicateGovernor`
**Out of scope:** `HyperliquidPerpStrategy` / `HyperliquidGridStrategy` — these templates
are not moving forward and are excluded from the design.

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
- Revenue is proportional to *realized P&L per proposal*, not to *activity*. A
  portfolio strategy that rebalances daily and nets +0.5% pays the same as a
  buy-and-hold that nets +0.5% on one trade.
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

### 2.4 Builder codes — the conceptual template

Hyperliquid also lets third-party apps that route orders attach a per-order fee
(`ApproveBuilderFee` + per-order `{builder, fee}`, capped at **10 bps on perps**);
the venue deducts it from each fill and credits the builder natively. Sherwood sits in
exactly that "builder" position relative to the venues its strategies trade on — the
protocol routes managed flow — so the builder-fee cap is a useful market anchor for
what rent on routed flow is considered acceptable. Since the Hyperliquid strategy
templates are not moving forward, Sherwood implements this at the protocol layer over
its DEX venues rather than using any venue-native rail.

---

## 3. What Sherwood can meter today

Findings from the codebase survey:

- **The vault/governor has zero visibility into trading volume.** Strategy trades run
  through proposer-only `updateParams(bytes)` (`src/strategies/BaseStrategy.sol:102`)
  and never touch the vault. The governor sees only the asset-balance snapshot at
  execute (`src/SyndicateGovernor.sol:393`), the balance at settle, and
  `interimNetFlow`.
- **Traded notional is already known at every venue call site:**
  - `PortfolioStrategy` knows swap `amountIn` at each `swapAdapter.swap(...)` call
    (`:289, 311, 386, 400, 537, 559`), including `rebalance()` / `rebalanceDelta`.
  - `AerodromeLPStrategy` knows amounts at `addLiquidity` (`:232`),
    `removeLiquidity` (`:278`), and reward-conversion swaps (`:309`).
  - `LeveragedAerodromeCLStrategy` knows notional at its borrow/supply/rebalance and
    swap sites (self-managed fee path, §4.6).
  - Moonwell supply templates (`MoonwellSupplyStrategy`, `WstETHMoonwellStrategy`,
    `MamoYieldStrategy`) have essentially one deploy and one unwind per proposal —
    near-zero volume, near-zero volume fee, which is the intended outcome for
    passive strategies.
- Because the remaining venues are **atomic AMM/lending interactions, executed
  notional is exactly observable onchain** at the moment of the call — there is no
  submitted-vs-filled gap and no need for oracles or fill attestations. (This is
  cleaner than metering an offchain orderbook venue, where only submitted intents are
  visible to the EVM.)
- Existing per-trade machinery is caps-only (trade counts, per-order size bounds) —
  nothing accumulates notional today.

---

## 4. Design

### 4.1 Shape: pay per trade, settle the remainder

The fee is **charged and paid per trade, in real time** — the Hyperliquid model,
where each fill's fee is deducted from its cash (USDC) leg immediately. Gas on Base
is negligible, so there is no batching argument; paying live also gives the treasury
(and the eventual buyback) a continuous revenue stream instead of a lump at settle.

The one genuine constraint is denomination: the fee is owed in the vault asset, and
a strategy mid-run may hold none of it at trade time (fully deployed; token→token
rebalances have no asset leg). So:

```
per trade:   fee = tradedNotional × volumeFeeBps / 10_000          (asset units)
             if asset.balanceOf(strategy) >= fee → transfer fee → protocolFeeRecipient
             else                               → feeOwed += fee   (tab)
at settle:   pay min(feeOwed, remaining cap, availableBalance) → protocolFeeRecipient
```

In practice most Portfolio/Aerodrome trades have an asset leg (or leave the strategy
holding float), so the tab is the fallback, not the norm. The turnover cap (§4.5) is
enforced against the running total of paid + owed, so live payment never exceeds it.

### 4.2 New protocol parameter — `ProtocolConfig.volumeFeeBps`

`ProtocolConfig` is the cleanest home: plain `Ownable2Step`, already the source of the
two protocol-wide fee rates, already snapshotted onto every proposal at propose time
(`src/SyndicateGovernor.sol:307-313`).

```solidity
uint16 public constant MAX_VOLUME_FEE_BPS = 10;   // hard cap: 0.10% of notional
uint16 public volumeFeeBps;                        // default 2 (0.02%)
```

- The 10 bps cap mirrors Hyperliquid's builder-fee cap on perps — the ceiling the
  largest venue considers acceptable rent on routed flow (§2.4).
- Default 2 bps keeps the drag small relative to the venue costs (swap fees, price
  impact) the strategy already pays on the same flow.
- Recipient: reuse `protocolFeeRecipient`. No new trust assumptions.
- Add the getter to `IProtocolConfig` (5th getter, same pattern).

### 4.3 Strategy-side metering — `BaseStrategy`

Trades are invisible outside the strategy, so the strategy must self-meter. Append to
`BaseStrategy` (storage appended to its `__gap`):

```solidity
uint256 internal _volumeFeePaid;      // asset units, transferred so far this run
uint256 internal _volumeFeeOwed;      // asset units, tab for trades with no asset leg
uint16  internal _volumeFeeBpsCached; // snapshotted at execute()
uint256 internal _volumeFeeBase;      // funded capital at execute(), for the cap

function _chargeVolume(uint256 notionalAsset) internal {
    if (_volumeFeeBpsCached == 0) return;
    uint256 fee = notionalAsset * _volumeFeeBpsCached / 10_000;
    fee = _capRemaining(fee);                       // running cap, §4.5
    if (fee == 0) return;
    if (asset.balanceOf(address(this)) >= fee && _tryPayFee(fee)) {
        _volumeFeePaid += fee;                      // paid live — the normal path
        emit VolumeFeePaid(notionalAsset, fee);
    } else {
        _volumeFeeOwed += fee;                      // tab — cleared at settle
        emit VolumeAccrued(notionalAsset, _volumeFeeOwed);
    }
}
```

`_tryPayFee` is a non-reverting transfer (try/catch) so a paused/blocklisted
recipient degrades to the tab instead of bricking the trade path.

- **Rate snapshot at `execute()`**: the strategy caches `volumeFeeBps` (read via
  `vault → factory → protocolConfig`) when the run starts, clamped to
  `MAX_VOLUME_FEE_BPS`. This preserves the existing snapshot discipline — the rate a
  proposal voted on cannot be raised mid-run — without touching the governor.
- **What counts as volume** (asset-denominated notional at execution):
  - `PortfolioStrategy`: `amountIn` of every swap (all 6 call sites, including
    rebalances). Both directions count — a round trip is 2× notional, as on any venue.
  - `AerodromeLPStrategy`: swap legs and liquidity **adds** count; removes do not
    (entry and exit of the same LP would double-count the same capital). Reward
    conversions count at swap.
  - Moonwell supply/withdraw: **not** volume — lending deposits are custody moves,
    not trades. Passive strategies should pay ~nothing; that is the point of an
    activity-priced fee.
- Notional is measured in the vault asset. For non-asset legs (e.g. AERO rewards,
  volatile-token legs), value at the strategy's existing pricing path
  (`positions()` adapters / router) or, where unavailable, at the swap's realized
  asset-side amount — the conservative choice is whichever leg is already
  asset-denominated.

### 4.4 Collection — inside `BaseStrategy` settle path, not the governor

Most of the fee is paid live per trade (§4.1); what needs a collection point is the
**tab** — fees from trades that had no asset leg. Two candidates were considered:

**Option A (recommended): strategy clears the tab at `settle()`/final unwind.**
When the strategy has unwound and is about to return capital to the vault, it first
pays the outstanding tab:

```solidity
uint256 fee = _volumeFeeOwed;                   // already cap-limited at charge time
if (fee != 0) {
    uint256 pay = Math.min(fee, asset.balanceOf(address(this)));
    if (pay != 0) {
        asset.safeTransfer(protocolFeeRecipient, pay);
        emit VolumeTabCleared(pay, fee - pay);   // second arg = shortfall
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
  exactly like the swap fees the strategy already pays.

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

// running cap: how much of `fee` may still be charged this run (§4.1 calls this)
function _capRemaining(uint256 fee) internal view returns (uint256) {
    uint256 maxFee = _volumeFeeBase * VOLUME_FEE_TURNOVER_CAP
                     * _volumeFeeBpsCached / 10_000;
    uint256 charged = _volumeFeePaid + _volumeFeeOwed;
    return charged >= maxFee ? 0 : Math.min(fee, maxFee - charged);
}
```

Because fees are paid live (§4.1), the cap is enforced as a running limit at charge
time — once `paid + owed` reaches the cap, further trades charge nothing.

At 2 bps this caps total volume fees at 0.1% of funded capital per 1× of turnover,
worst case 10 bps × 50× = 0.5% per proposal — visible, bounded, and small next to the
existing per-strategy caps (trade counts, per-order size bounds) that already bound
churn. Guardians reviewing calldata see the strategy params that determine realistic
turnover.

### 4.6 Self-managed strategies

`selfManagesFees == true` strategies (`LeveragedAerodromeCLStrategy`) bypass the
governor waterfall entirely (`src/SyndicateGovernor.sol:1098`) but the volume-fee
leg doesn't live in the waterfall — it lives in the strategy. Add the same
`_chargeVolume` calls to its swap/rebalance sites and fold any tab into its existing
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

New events on `BaseStrategy`: `VolumeFeePaid(uint256 notional, uint256 fee)` (live,
per trade), `VolumeAccrued(uint256 notional, uint256 owedTotal)` (tab fallback), and
`VolumeTabCleared(uint256 paid, uint256 shortfall)`. Subgraph gains a `VolumeFee` entity
per proposal and a running `notionalTraded` on the strategy/vault entities — today the
subgraph tracks only `performanceFeeBps`/`performanceFee` (`subgraph/schema.graphql:100,107`).
This also gives the frontend a true "volume" stat per syndicate for free.

---

## 5. Worked economics — why this matters

$1M vault, `PortfolioStrategy` with daily rebalancing that turns over an average 25%
of the book per day, 30-day proposal, +2% net:

| Fee stream | Formula | Revenue |
|---|---|---|
| **Today**: protocol fee (10% of profit) | $1M × 2% × 10% | **$2,000** |
| **Today**: guardian fee (5% of profit) | $1M × 2% × 5% | $1,000 |
| **Volume fee @ 2 bps** | $1M × 0.25/day × 30d × 0.02% | **$1,500** |
| Same, flat month (0% P&L) | — | $1,500 vs **$0** today |

At 2 bps an actively rebalanced portfolio pays roughly as much in volume fees as in
profit fees on a good month — and it is the **only** revenue on a flat month, which is
the case the current model earns nothing on. A more aggressive strategy (1×/day
turnover) pays $6,000/month; a passive Moonwell supply pays ~$0. The fee prices
protocol attention by activity, which is exactly what the profit-only model fails to
do. Depositor drag at 25%/day turnover is 0.15%/month — well under the venue swap
fees and price impact the same flow already incurs, and proposers price it into
strategy selection the same way.

---

## 6. What is explicitly out of scope

- **Hyperliquid strategy templates** (`HyperliquidPerpStrategy`,
  `HyperliquidGridStrategy`) — not moving forward; no metering call sites are
  specified for them. (For the record: had they shipped, per-trade metering there
  would have had to price *submitted* rather than *filled* notional, because CoreWriter
  order fills are not observable from the EVM, and Hyperliquid's builder-code rail is
  unavailable to CoreWriter-placed orders. None of that complexity applies to the
  AMM-only scope.)
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
2. `BaseStrategy`: `_volumeFeePaid` / `_volumeFeeOwed` / `_volumeFeeBpsCached` / `_volumeFeeBase`
   (append into `__gap`), `_chargeVolume` (live pay + tab fallback), `_capRemaining`,
   settle-path tab clearing, events. Rate snapshot in the `execute()` path.
3. Per-strategy `_chargeVolume` call sites: Portfolio (6 swap sites),
   AerodromeLP (adds + swaps, 3 sites), LeveragedAerodromeCL (fold into
   `protocolFeeOwed`). Moonwell/Mamo/Venice templates: none (passive).
4. Tests: charge math per strategy (live pay + tab fallback); cap binding as a
   running limit; snapshot-at-execute (rate hike
   mid-run doesn't apply); payment senior to P&L (governor `pnl` reflects fee);
   fail-open on recipient revert; zero-rate short-circuit; no double-count on
   LP add/remove round trip.
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
