# Sherwood Fee Model — Technical Design

**Date:** 2026-07-24 (rev. 3 — simplified to the two-number model; volume fee removed)
**Status:** Design — not implemented
**Scope:** `ProtocolConfig`, `SyndicateVault`, `SyndicateGovernor`, `BaseStrategy`/`IStrategy`
**Companion:** product framing in `docs/product/2026-07-24-fee-model-product-spec.md`

---

## 0. What this revision changes

Earlier revisions of this document specified a per-trade **volume fee** with
strategy-side notional metering, turnover caps, live-vs-tab payment, and per-strategy
call sites. **All of that is removed.** Product decision (2026-07-24): Sherwood
prices like a hedge fund — two depositor-facing numbers, everyone else paid from
internal splits — and no onchain fund charges a per-trade fee. What remains is
deliberately small:

1. A **management fee** (AUM, time-weighted, always-on), split agent/protocol/guardian.
2. A **performance fee** (profit above a **high-water mark**), split
   agent/protocol/guardian/owner.
3. **Crystallize-on-instant-exit** so Lane A withdrawers pay their fee share at exit
   instead of leaking it onto remaining depositors.
4. An **instant-exit fee** (redemption term, accrues to the vault).

The net effect on the codebase is *less* than the volume-fee design: no per-trade
metering, no strategy hot-path changes. The work is concentrated in the settlement
math (`SyndicateGovernor`), one new stored value on the vault (the high-water mark),
and split configuration in `ProtocolConfig`.

---

## 1. Today's fee code (unchanged facts)

The single fee chokepoint is `SyndicateGovernor._distributeFees`
(`src/SyndicateGovernor.sol:1153`), reached from `_finishSettlement` (`:1062`), only
when `pnl > 0` (`:1092`). P&L is a pure balance delta net of mid-proposal flows:

```solidity
pnl = int256(balanceAdjusted) - int256(snapshot) - ISyndicateVault(vault).interimNetFlow();
```

Existing rate storage:
- `ProtocolConfig.protocolFeeBps` / `guardianFeeBps` + recipients, snapshotted onto
  the proposal at propose (`src/SyndicateGovernor.sol:307-313`).
- Vault `agentFeeBps` (performance) and `managementFeeBps` (profit-gated today).

The rename and re-plumb below reuse these slots; no storage is reordered (append-only,
shrink `__gap`).

---

## 2. Target model

Two headline fees, each split by governance-set basis points that must sum to 10_000.

### 2.1 Management fee — AUM, time-weighted, always-on

- **Rate:** `managementFeeBps` (proposed 200 = 2%/yr), cap `MAX_MANAGEMENT_FEE_BPS`
  (proposed 300 = 3%/yr). Lives on the vault (per-fund), snapshotted at propose.
- **Base:** time-weighted deployed capital over the proposal. The strategy already
  has the hooks — capital changes on `execute`, mid-proposal Lane A `withdrawTo`
  pulls, and the `strategyMint`/`strategyBurn` custody hooks. Keep a TWA accumulator:
  `twa += base × (now − lastUpdate)` on each base-changing event; at settle
  `mgmtFee = twa × managementFeeBps / (10_000 × 365 days)`.
- **Paid regardless of P&L** — this is the always-on leg, so it is charged in
  `_finishSettlement` on *every* settlement, not gated on `pnl > 0`.
- **Split:** `mgmtSplit = {agentBps, protocolBps, guardianBps}` (proposed
  7000/2000/1000), summing to 10_000. The guardian slice is the always-on guardian
  funding that the volume fee previously promised for phase 3 — it now exists at v1.

### 2.2 Performance fee — profit above the high-water mark

- **Rate:** `performanceFeeBps` (proposed 2000 = 20%), cap unchanged
  (`MAX_PERFORMANCE_FEE_BPS = 1500`… **note:** the current 15% cap must be raised to
  ≥ 2000 to allow a 20% headline; decide final cap, proposed 3000/30%).
- **Base:** profit *above the high-water mark* only (§3), not raw positive `pnl`.
- **Split:** `perfSplit = {agentBps, protocolBps, guardianBps, ownerBps}` (proposed
  6000/1500/1500/1000), summing to 10_000. This replaces today's sequential waterfall
  (protocol → guardian → agent → owner), which compounded four separate haircuts;
  a single split on one base is both simpler and cheaper for depositors.

### 2.3 Removed

- The entire volume fee: `ProtocolConfig.volumeFeeBps`, `BaseStrategy` metering
  (`_chargeVolume`, `_volumeFeePaid/Owed`, TWA-of-notional, turnover cap), all
  per-strategy call sites, and the `VolumeFeePaid`/`VolumeAccrued`/`VolumeTabCleared`
  events. None of it is built.
- The sequential four-fee waterfall in `_distributeFees` — replaced by the two
  split-distributions above.

---

## 3. High-water mark

The gap this fixes: today profit is measured per proposal against the execute-time
balance, so a fund that loses under proposal N and recovers under proposal N+1 pays
performance fees on the *same* recovered dollars twice.

**Design (single share-class, per-share-price mark — the Enzyme/dHEDGE convention):**

- Store `highWaterPricePerShare` on the vault (one `uint256`, appended to `__gap`),
  initialized to the ERC-4626 price-per-share at first deposit.
- At settlement, compute `pps = totalAssets() / totalSupply()` (using the same
  post-settlement, post-management-fee assets). Performance is charged only on
  `max(pps − highWaterPricePerShare, 0) × totalSupply` — i.e. the profit that lifts
  the fund above its prior peak, not raw `pnl`.
- After charging, ratchet `highWaterPricePerShare = max(old, pps_after_fee)`.
- **Ordering:** management fee first (it lowers `pps`), then the HWM check, then the
  performance fee. This matches how every reference implementation sequences it and
  avoids charging performance on assets the management fee already took.

Hurdle rate: **not** included (needs a benchmark oracle; rare onchain). The HWM
storage slot is the natural place to add a hurdle later (a hurdle is a shifted mark).

Known limitation (documented, accepted): a single global per-share mark can't
perfectly equalize investors who enter at different times (the TradFi
"series/equalization" problem). Onchain single-share-class vaults universally accept
this because new depositors buy at the *current* (already-appreciated) price, which
self-corrects the entry side; the residual is crystallization-dilution, bounded by
settling every proposal. Per-depositor marks would require non-fungible shares —
out of scope.

---

## 4. Collection mechanic

Fees are computed at settlement and **paid from vault assets** to the split
recipients before capital is released — reusing `transferPerformanceFee`
(`src/SyndicateVault.sol:543`, `onlyGovernor`) and the `_payFee` try/catch escrow
(`src/SyndicateGovernor.sol:1267`) so a bricked recipient never blocks settlement.

**Considered and deferred: share-dilution collection.** The onchain standard (Set,
Enzyme, dHEDGE, Yearn, Balancer) is to mint fee shares to recipients rather than
transfer assets — the recipient gets a NAV claim, no assets leave, fully-deployed
strategies never liquidate to pay a fee. Formula: `feeShares = totalSupply × f /
(1 − f)` where `f` is the fee fraction (Set's exact form; dHEDGE uses the linear
`totalSupply × f` approximation; Enzyme compounds via `rpow`). This is strictly
better for capital efficiency and is the recommended eventual mechanic, but it is an
architecture change to the vault share ledger and interacts with the ERC-4626
inflation-attack defenses (`_decimalsOffset`) — so it's out of scope for v1 per the
product decision. Asset-based collection ships first; dilution is a clean follow-up
that changes *how* fees are paid, not *what* is owed.

### 4.1 Crystallize fees on instant exit

Fees crystallize at settlement, but a **Lane A instant exit** happens mid-proposal at
a live oracle price with no fee deducted — so without special handling the exiter
escapes their share of both fees and leaks it onto the depositors who stay (the
crystallization / free-ride problem). **Lane B queue exits are already correct:** they
claim at the frozen settle price, stamped *after* `_distributeFees`, so they bear
their share automatically. The fix is only needed on the instant path.

**Charge the exiting shares their pro-rata accrued fees at exit** — the
Hyperliquid-vault model (profit share collected per depositor at withdrawal). For an
instant exit of `s` shares out of supply `S` at price-per-share `pps`:

```
perfFeeExit = max(pps - highWaterPricePerShare, 0) * s * performanceFeeBps / 10_000
mgmtFeeExit = (s / S) * mgmtFeeAccruedUncollected          // pro-rata of fund-level accrual to now
netProceeds = pps * s - perfFeeExit - mgmtFeeExit          // instant-exit fee (Sec. 5) then applies to the net
```

- `perfFeeExit` / `mgmtFeeExit` route to the split recipients immediately via
  `_payFee` (or escrow to settle); the **instant-exit fee** (Sec. 5) then applies to
  the net and goes to the vault. The two are independent and stack in that order.
- **No double-count at settlement, by construction:** the exiting shares are *burned*
  at exit, so they leave `totalSupply` and are absent from the settlement
  performance-fee base. For the management fee, track a running
  `mgmtFeeCrystallized` (sum collected via exits) and charge only
  `mgmtFeeDue_total - mgmtFeeCrystallized` at settle.
- **HWM is not ratcheted on a partial exit** — it advances only at settlement
  crystallization. Charging `perfFeeExit` against the current (un-advanced) mark is
  correct and conservative; remaining holders keep measuring from the same mark.
- Consistent with the global per-share HWM (Sec. 3): the exiter pays exactly the
  per-share performance fee the fund would charge at settle, just early, on the
  shares that are leaving.

Net effect: **exit timing is fee-neutral.** Instant exiters pay at exit, queue
exiters pay via the post-fee settle price, and neither shifts fee burden onto the
depositors who stay. (Share-dilution collection, Sec. 4, would achieve this
automatically — crystallize-on-exit is the asset-based equivalent.)

---

## 5. Instant-exit fee (early-exit penalty, on top of §4.1)

This is a **second, independent charge** that stacks on the fee crystallization of
§4.1 — do not conflate them. §4.1 makes an instant exiter pay the fees they *already
owe* (fair share, to the fee recipients); the instant-exit fee is an **additional
penalty** for the *privilege* of leaving early — jumping the settlement queue and
forcing the strategy to source liquidity or unwind ahead of schedule. Different
purpose, different destination:

| | §4.1 fee crystallization | §5 instant-exit fee |
|---|---|---|
| What | your accrued management + performance fees | an extra early-exit penalty |
| Why | you can't dodge fees you owe by leaving early | compensate remaining depositors for the early unwind |
| Goes to | fee recipients (agent/protocol/guardian/owner) | the **vault** (remaining depositors) |
| Applies to | the exiting shares' NAV | the net proceeds after §4.1 |

`instantExitFeeBps` was specced and deferred in the instant-withdrawal design
(`docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md` §6) on vault
bytecode headroom. Robinhood Chain lifts the EIP-170 24 KB ceiling, so it ships as
designed:

- ≤ 200 bps (proposed 50), charged only on the `withdrawTo`-sourced portion of a
  **Lane A instant** exit; the Lane B queue never pays it.
- **Accrues to the vault** (remaining depositors), not the protocol — an
  anti-mercenary redemption term, not revenue. Precedent: Enzyme's "burn"-type exit
  fee that benefits remaining holders.
- **Order at exit:** crystallize §4.1 fees to recipients first, then apply this
  penalty to the net, then release proceeds. So an instant exiter bears *both* — the
  fees they'd owe anyway, plus the early-exit penalty on top.
- No deposit fee.

Storage slots were already reserved. This is independent of the management/performance
work and can land in the same release or a follow-up.

---

## 6. ProtocolConfig / vault changes

- `ProtocolConfig`: replace the two flat rate fields with the split configs
  (`mgmtSplitBps`, `perfSplitBps` structs) + their caps; keep recipients. Snapshotted
  onto the proposal at propose exactly as `protocolFeeBps`/`guardianFeeBps` are today
  (`src/SyndicateGovernor.sol:307-313`).
- Vault: `managementFeeBps` semantics change from profit-gated to AUM-time-weighted
  (rename the accessor for clarity; storage slot reused). Add
  `highWaterPricePerShare`. Raise `MAX_PERFORMANCE_FEE_BPS` to the chosen cap.
- Governor: `_distributeFees` rewritten from a four-step sequential waterfall to two
  split-distributions (management always; performance on above-HWM profit). The
  self-managed-strategy path (`selfManagesFees`, `:1098`) folds its management +
  performance legs the same way `LeveragedAerodromeCLStrategy` already self-collects
  `protocolFeeOwed`.

Subgraph: `managementFee` / `performanceFee` per proposal with their splits, and the
high-water-mark series. The `VolumeFee` entity from the prior draft is dropped.

---

## 7. Implementation checklist

1. `ProtocolConfig`: split-config structs + caps + getters in `IProtocolConfig`;
   snapshot onto the proposal.
2. Vault: management-fee semantics → AUM/time-weighted; `highWaterPricePerShare`
   (append to `__gap`); raise perf cap.
3. Strategy: TWA-of-deployed-capital accumulator for the management-fee base
   (updated on execute / `withdrawTo` / share hooks). No per-trade code.
4. Governor `_finishSettlement` / `_distributeFees`: management fee always; HWM gate;
   performance fee on above-HWM profit; two split-distributions via `_payFee`.
5. Crystallize-on-instant-exit (Sec. 4.1): charge exiting shares their pro-rata
   management + performance fees at Lane A exit; track `mgmtFeeCrystallized`;
   share burn keeps settlement from double-charging.
6. Instant-exit fee: revive `instantExitFeeBps` (Lane A only, accrues to vault).
7. Tests: management accrual (flat/loss months still charge it; time-weighting under
   mid-proposal exits); HWM (no double-charge across a loss-then-recover; ratchet);
   crystallize-on-exit (instant exiter pays management + performance at exit; no
   double-count at settle; queue exiter pays via settle price; exit timing is
   fee-neutral vs an equivalent hold-to-settle depositor); split sums = 10_000;
   agent-earns-most invariant; fail-open payment; self-managed path parity.
7. Docs: README fee table; flip this spec + the product spec to "implemented".

---

## Appendix — research basis

- **Onchain fund fee mechanics** (Enzyme v4, dHEDGE, Yearn v3, Set, Balancer Managed
  Pools, Index Coop, Hyperliquid vaults): all charge management (AUM-streaming) and
  performance fees; all performance fees use a per-share high-water mark; **none**
  charge a per-trade/volume fee. Share-dilution minting is the universal collection
  mechanic. Sources: Enzyme specs (`specs.enzyme.finance`), dHEDGE docs
  (`docs.dhedge.org`), Yearn v3 (`docs.yearn.fi`), Set `StreamingFeeModule.sol`,
  Balancer `ExternalAUMFees.sol`, Hyperliquid vault docs.
- **Hedge-fund fee structure** (2-and-20, high-water marks ~85% prevalence, hurdle
  rates, fee compression to ~1.3-and-16): AlphaMaven, Preqin, With Intelligence, CAIA,
  Thinking Ahead Institute "A Fairer Deal on Fees", Bloomberg (pass-through fee load).
- **HWM math & ERC-4626 fee conventions:** OpenZeppelin `ERC4626Fees`, EIP-4626,
  SS&C (series vs equalization), Enzyme HWM issue #212.
