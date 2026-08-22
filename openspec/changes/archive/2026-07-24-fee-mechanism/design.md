# Fee Mechanism Design

> Original: `docs/specs/2026-07-24-fee-model-design.md` (rev. 3, 2026-07-24) +
> design reasoning from `docs/superpowers/plans/2026-07-24-fee-mechanism.md`.
> Status at archive time: Implemented (2026-07-31), landed via PR #68
> "apply-the-new-fee-model" (merged 2026-08-01). Scope: `ProtocolConfig`,
> `SyndicateVault`, `SyndicateGovernor`, `SyndicateFactory` (no strategy changes).

## Context

Earlier revisions of the design specified a per-trade **volume fee** with
strategy-side notional metering, turnover caps, live-vs-tab payment, and
per-strategy call sites. All of that was removed by product decision
(2026-07-24): Sherwood prices like a hedge fund — two depositor-facing numbers,
everyone else paid from internal splits — and no onchain fund charges a per-trade
fee. What remained, deliberately small:

1. A **management fee** (AUM, time-weighted, always-on), split
   agent/protocol/guardian.
2. A **performance fee** (profit above a **high-water mark**), split
   agent/protocol/guardian/owner.
3. **Crystallize-on-instant-exit** so Lane A withdrawers pay their fee share at
   exit instead of leaking it onto remaining depositors.
4. An **instant-exit fee** (redemption term, accrues to the vault).

The net effect on the codebase was *less* than the volume-fee design: no
per-trade metering, no strategy hot-path changes. The work concentrated in the
settlement math (`SyndicateGovernor`), one new stored value on the vault (the
high-water mark), and split configuration in `ProtocolConfig`.

### Baseline (pre-change fee code)

The single fee chokepoint was `SyndicateGovernor._distributeFees`
(`src/SyndicateGovernor.sol:1153`), reached from `_finishSettlement` (`:1062`),
only when `pnl > 0` (`:1092`). P&L was a pure balance delta net of mid-proposal
flows:

```solidity
pnl = int256(balanceAdjusted) - int256(snapshot) - ISyndicateVault(vault).interimNetFlow();
```

Existing rate storage: `ProtocolConfig.protocolFeeBps`/`guardianFeeBps` +
recipients, snapshotted onto the proposal at propose
(`src/SyndicateGovernor.sol:307-313`); vault `agentFeeBps` (performance) and
`managementFeeBps` (profit-gated pre-change). The rename and re-plumb reused
these slots; no storage was reordered (append-only, shrunk `__gap`).

**Verified before implementation:** the volume fee was never built —
`grep -rn "volumeFee\|_chargeVolume\|VolumeFeePaid" src/` returned nothing, so
its "removal" was a no-op; the only real deletion was the four-step sequential
waterfall in `_distributeFees`. Governor linear storage did not move — the split
snapshots live inside `StrategyProposal`, itself in the `_proposals` mapping, so
the frozen slot pins in `test/governor/GovernorLayoutPins.t.sol` (slots 0-81)
were untouched. The Lane B queue is structurally excluded from exit fees:
`VaultWithdrawalQueue.claim` reverts `VaultLocked` unless
`!redemptionsLocked()`, and the exit-fee gate requires `laneA == true` (which
requires `redemptionsLocked()`) — the two windows cannot overlap, so no
`caller`-based exemption was needed in `previewRedeem` (fortunate, since a view
function has no caller context).

## Goals / Non-Goals

**Goals:** two depositor-facing fees instead of six; management fee funds
continuous work (agent + guardians) in flat and losing months; performance fee
never double-charges the same recovered dollars (high-water mark); instant
exiters cannot shift their fee burden onto remaining depositors; exit timing is
fee-neutral between an instant exit and holding to settlement.

**Non-Goals / deferred (documented, not built):**

- **Share-dilution fee collection.** The onchain standard (Set, Enzyme, dHEDGE,
  Yearn, Balancer) mints fee shares to recipients instead of transferring
  assets, so a fully-deployed strategy never liquidates to pay a fee. Strictly
  better for capital efficiency, but it is an architecture change to the vault
  share ledger that interacts with the ERC-4626 inflation-attack defenses
  (`_decimalsOffset`) — out of scope for v1. Asset-based collection ships first;
  dilution is a clean follow-up that changes *how* fees are paid, not *what* is
  owed.
- **Hurdle rate.** Not included (rare onchain, needs a benchmark oracle).
  `highWaterPricePerShare` is the natural place to add one later (a hurdle is a
  shifted mark).
- **Per-depositor marks / series accounting.** A single global per-share mark
  cannot perfectly equalize investors who enter at different times (the TradFi
  "series/equalization" problem). Onchain single-share-class vaults universally
  accept this because new depositors buy at the current, already-appreciated
  price, which self-corrects the entry side; the residual is
  crystallization-dilution, bounded by settling every proposal. Per-depositor
  marks would require non-fungible shares.
- **Staking discounts and the WOOD buyback.** Product-spec rollout items 2 and
  3, downstream of this contract release.
- **Subgraph indexing.** `managementFee`/`performanceFee` per proposal with
  their splits, plus the high-water-mark series, is deferred to the subgraph
  repo; the events emitted here (`ManagementFeeCharged`, `PerformanceFeeCharged`,
  `HighWaterMarkUpdated`, `ExitFeesCrystallized`) carry everything needed.

## Decisions

### Implementation deviations (authoritative)

Where the original design document and the shipped code disagreed, the code is
right. Five deviations, all decided 2026-07-24:

**D1 — The management-fee accumulator lives on the vault, not on strategies.**
The original spec put a TWA accumulator on the strategy. There are 12+ concrete
strategies (`src/strategies/*.sol`), all deployed as ERC-1167 clones, each
needing its own accumulator and its own test. But every base-changing event
already passes through `SyndicateVault`: the execute-time capital snapshot
(`SyndicateGovernor.sol:395`), Lane A deposits (`SyndicateVault.sol:866`), Lane A
instant exits (`SyndicateVault.sol:909`), and the custody hooks
`strategyMint`/`strategyBurn` (`SyndicateVault.sol:1083`/`:1098`). One vault-side
accumulator is complete and touches no strategy code. It stores an
**asset-seconds integral** and restamps its base from `totalAssets()` on each
event, which lets the share-denominated custody hooks participate without any
share→asset conversion.

**D2 — Exit-time fees are retained by the vault, not transferred at exit.** The
spec routed `perfFeeExit`/`mgmtFeeExit` to recipients immediately via `_payFee`.
The vault cannot resolve those recipients: the agent is the proposal's
`proposer` in governor storage, and the protocol/guardian recipients live on the
propose-time snapshot on `StrategyProposal`. Resolving them from `_withdraw`
would mean a governor call on the ERC-4626 hot path plus a new brick vector.
Instead the exiting shares' fees are booked into `_crystallizedMgmt`/
`_crystallizedPerf` on the vault, **excluded from `totalAssets()`** (so the
remaining holders' price-per-share is unaffected — the same economic result),
and paid to the correct snapshot recipients at the next settlement through the
existing `_payFee` escrow. Net incidence is identical; the exit path stays
call-free.

**D3 — `selfManagesFees` exempts the performance leg only.** The spec folded
both legs into the self-managed path. That flag exists because float-delta PnL
misreads custody deposits as profit — a defect in *profit measurement*. The
management fee is capital × time and does not use PnL, so the exemption does
not reach it.

**D4 — The management rate is read live at settle, not snapshotted.**
`SyndicateVault._managementFeeBps` is written only at `initialize` and has no
setter, so it cannot move between propose and settle; a snapshot would be
equivalent, and `propose` had no spare Yul stack slot for the extra read. The
two *splits* are snapshotted, since governance can change those at any time.

**D5 — Ordering constraints the original text did not state.** Releasing
crystallized fees raises `totalAssets()`, so the performance base must be read
*before* `consumeCrystallizedPerf()`. And `previewWithdraw` cannot invert the
kinked exit-fee function in closed form: it iterates, grossing each shortfall up
by the penalty rate so it converges from above rather than approaching the
target from below forever.

### Rate and cap decisions (from the implementation plan)

**Idle capital earns no management fee — decided 2026-07-24: accept the
behaviour, correct the product-spec wording.** The accrual base is stamped at
`executeProposal` and zeroed at settle, so capital sitting in the vault between
proposals accrues nothing. This matches the design's "time-weighted deployed
capital over the proposal" but contradicted the product spec's "2%/yr on fund
assets (AUM) … Always" — corrected in Task 10.

Charging continuously is not merely more work — it is **blocked on recipient
resolution**. The management split is 70/20/10, and "the agent" is
`proposal.proposer` (`SyndicateGovernor.sol:1157`); the protocol/guardian
recipients and both splits come from the propose-time snapshot on
`StrategyProposal`. Between proposals there is no proposal, so there is no
address to send the agent's 70% to. A permissionless `crystallizeManagementFee()`
would hit exactly the wall that forced deviation D2 on the exit path.

The behaviour is also defensible on the merits: between proposals nobody is
managing the money, guardians have nothing to review, and `redemptionsLocked()`
is false so LPs can withdraw freely. A management fee with no management would
be the anomaly, not its absence. Exposure is a function of duty cycle only —
with the factory default `cooldownPeriod: 1 hours` against strategy durations up
to 30 days, back-to-back proposals lose a rounding error; the real (accepted)
case is a fund whose agent stops proposing while LPs stay deposited, which
charges 0%/yr.

Rejected alternatives:
- *Carry the gap into the next settlement* (rebase the base to vault float at
  settle instead of zeroing). Closes cooldown gaps, does not close dormancy, and
  forces `_adjustMgmtBase` onto the unconditional deposit/withdraw paths — a
  permanent ~5k gas cost on every deposit for a partial fix.
- *Move the mgmt-fee recipients onto the vault + permissionless crystallize.*
  Fully closes it, but the agent's 70% would go to a standing vault address
  rather than the proposer who earned it, breaking the "agent is the largest
  earner" incentive the product spec is built on — a product decision, not an
  implementation one.

**Final performance-fee cap — decided 2026-07-24: `MAX_PERFORMANCE_FEE_BPS` =
3000 (30%).** The ceiling is not the headline rate; it is the outer bound
governance can ever set. Three limits stack below it:

| Limit | Value | Owner | Enforced at |
|---|---|---|---|
| `FeeConstants.MAX_PERFORMANCE_FEE_BPS` | 3000 | protocol (code) | `GovernorParameters.MAX_PERFORMANCE_FEE_CAP` + `SyndicateVault.MAX_AGENT_FEE_BPS` |
| `_params.maxPerformanceFeeBps` | per-vault, tunable; factory default 2000 | governor params | `_clampPerformanceFee` at propose AND at settle |
| `vault.performanceFeeBps()` | proposed headline 2000 | vault owner | `setAgentFeeBps`, snapshotted at propose |

A vault that never calls `setAgentFeeBps` charges `FeeConstants.DEFAULT_AGENT_FEE_BPS`
= 500 (5%), unchanged.

**Factory default `maxPerformanceFeeBps` — decided 2026-07-24: 2000 (the
headline), not the 3000 ceiling.** `_clampPerformanceFee` resolves a
vault/param conflict **silently** (emits `FeeClamped`, does not revert), so the
default decides which way a misconfiguration fails. At 3000 it fails open — a
vault owner can unilaterally `setAgentFeeBps(3000)` and charge 30% on day one
with no oversight. At 2000 it fails closed — the agent earns the headline and an
event is emitted; charging more than advertised requires an explicit, visible
governor param change. Fail-closed is the right default for a depositor-facing
rate. Implemented as `FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS`, a named
constant rather than a literal in `SyndicateFactory`, so it cannot drift out of
sync with the protocol ceiling.

### 1. Management fee — AUM, time-weighted, always-on

- **Rate:** `managementFeeBps` (2%/yr), cap `MAX_MANAGEMENT_FEE_BPS` (3%/yr).
  Lives on the vault (per-fund), snapshotted implicitly (D4).
- **Base:** time-weighted deployed capital over the proposal, via a TWA
  accumulator: `twa += base × (now − lastUpdate)` on each base-changing event;
  at settle `mgmtFee = twa × managementFeeBps / (10_000 × 365 days)`.
- Paid regardless of P&L — charged in `_finishSettlement` on *every* settlement,
  not gated on `pnl > 0`.
- **Split:** `mgmtSplit = {agentBps, protocolBps, guardianBps}` (70/20/10),
  summing to 10,000. The guardian slice is the always-on guardian funding the
  volume fee previously promised for a later phase — it exists at v1 instead.

### 2. Performance fee — profit above the high-water mark

- **Rate:** `performanceFeeBps` (20%), cap raised to `MAX_PERFORMANCE_FEE_BPS` =
  3000 (30%) — the prior 15% cap could not accommodate a 20% headline.
- **Base:** profit above the high-water mark only (§3 below), not raw positive
  `pnl`.
- **Split:** `perfSplit = {agentBps, protocolBps, guardianBps, ownerBps}`
  (60/15/15/10), summing to 10,000 — replacing the prior sequential waterfall
  (protocol → guardian → agent → owner), which compounded four separate
  haircuts; a single split on one base is both simpler and cheaper for
  depositors.

### 3. High-water mark

The gap this fixes: previously, profit was measured per proposal against the
execute-time balance, so a fund that lost under proposal N and recovered under
proposal N+1 paid performance fees on the same recovered dollars twice.

Design (single share-class, per-share-price mark — the Enzyme/dHEDGE
convention):

- Store `highWaterPricePerShare` on the vault (one `uint256`, appended to
  `__gap`), initialized to the ERC-4626 price-per-share at first deposit.
- At settlement, compute `pps = totalAssets() / totalSupply()` (post-settlement,
  post-management-fee assets). Performance is charged only on
  `max(pps − highWaterPricePerShare, 0) × totalSupply` — the profit that lifts
  the fund above its prior peak, not raw `pnl`.
- After charging, ratchet `highWaterPricePerShare = max(old, pps_after_fee)`.
- **Ordering:** management fee first (it lowers `pps`), then the HWM check, then
  the performance fee — matching every reference implementation's sequencing
  and avoiding charging performance on assets the management fee already took.

**Known limitation (documented, accepted):** a single global per-share mark
cannot perfectly equalize investors who enter at different times (see Non-Goals
above).

### 4. Collection mechanic

Fees are computed at settlement and paid from vault assets to the split
recipients before capital is released — reusing `transferPerformanceFee`
(`src/SyndicateVault.sol:543`, `onlyGovernor`) and the `_payFee` try/catch escrow
(`src/SyndicateGovernor.sol:1267`) so a bricked recipient never blocks
settlement.

**Considered and deferred: share-dilution collection** (see Non-Goals) — the
onchain standard, strictly better for capital efficiency, but out of scope for
v1 as an architecture change to the vault share ledger.

#### 4.1 Crystallize fees on instant exit

Fees crystallize at settlement, but a Lane A instant exit happens mid-proposal
at a live oracle price with no fee deducted — so without special handling the
exiter escapes their share of both fees and leaks it onto the depositors who
stay (the crystallization / free-ride problem). Lane B queue exits are already
correct: they claim at the frozen settle price, stamped *after*
`_distributeFees`, so they bear their share automatically. The fix is only
needed on the instant path.

**Charge the exiting shares their pro-rata accrued fees at exit** — the
Hyperliquid-vault model (profit share collected per depositor at withdrawal).
For an instant exit of `s` shares out of supply `S` at price-per-share `pps`:

```
perfFeeExit = max(pps - highWaterPricePerShare, 0) * s * performanceFeeBps / 10_000
mgmtFeeExit = (s / S) * mgmtFeeAccruedUncollected          // pro-rata of fund-level accrual to now
netProceeds = pps * s - perfFeeExit - mgmtFeeExit          // instant-exit fee (§5) then applies to the net
```

- `perfFeeExit`/`mgmtFeeExit` are booked to `_crystallizedMgmt`/
  `_crystallizedPerf` and paid at settlement (deviation D2, not "immediately via
  `_payFee`" as originally specced); the instant-exit fee (§5) then applies to
  the net and goes to the vault. The two are independent and stack in that
  order.
- **No double-count at settlement, by construction:** the exiting shares are
  burned at exit, so they leave `totalSupply` and are absent from the
  settlement performance-fee base. For the management fee, track a running
  `mgmtFeeCrystallized` (sum collected via exits) and charge only
  `mgmtFeeDue_total - mgmtFeeCrystallized` at settle.
- **HWM is not ratcheted on a partial exit** — it advances only at settlement
  crystallization. Charging `perfFeeExit` against the current (un-advanced) mark
  is correct and conservative; remaining holders keep measuring from the same
  mark.

Net effect: **exit timing is fee-neutral.** Instant exiters pay at exit, queue
exiters pay via the post-fee settle price, and neither shifts fee burden onto
the depositors who stay.

### 5. Instant-exit fee (early-exit penalty, on top of §4.1)

A **second, independent charge** that stacks on the fee crystallization of
§4.1 — do not conflate them. §4.1 makes an instant exiter pay the fees they
already owe (fair share, to the fee recipients); the instant-exit fee is an
additional penalty for the *privilege* of leaving early — jumping the
settlement queue and forcing the strategy to source liquidity or unwind ahead of
schedule.

| | §4.1 fee crystallization | §5 instant-exit fee |
|---|---|---|
| What | your accrued management + performance fees | an extra early-exit penalty |
| Why | you can't dodge fees you owe by leaving early | compensate remaining depositors for the early unwind |
| Goes to | fee recipients (agent/protocol/guardian/owner) | the vault (remaining depositors) |
| Applies to | the exiting shares' NAV | the net proceeds after §4.1 |

`instantExitFeeBps` was specced and deferred in the instant-withdrawal design
(`docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md` §6) on vault
bytecode headroom. Robinhood Chain lifts the EIP-170 24 KB ceiling (to 98,304
bytes), so it ships as designed:

- ≤200 bps (proposed 50), charged only on the `withdrawTo`-sourced portion of a
  Lane A instant exit; the Lane B queue never pays it.
- Accrues to the vault (remaining depositors), not the protocol — an
  anti-mercenary redemption term, not revenue. Precedent: Enzyme's "burn"-type
  exit fee that benefits remaining holders.
- **Order at exit:** crystallize §4.1 fees to recipients first, then apply this
  penalty to the net, then release proceeds.

**Instant-exit-penalty basis — the pulled-portion argument (open, not
blocking).** The penalty was implemented on the *pulled portion only* (the part
of an exit that forces the strategy to unwind), not on the whole exit. Both
bases are exact and monotone under `previewRedeem`
(`d(net)/d(assets) = 1 − bps/10_000 > 0`), so quote correctness does not
differentiate them. Three things do:

| | Pulled portion (implemented) | Whole exit |
|---|---|---|
| `previewWithdraw` | kinked at the float boundary, not cleanly invertible — grosses up once and rounds conservatively (deviation D5), burning marginally more shares than strictly needed | exactly invertible: `net = gross × (1 − bps/10_000)` |
| Quote stability | depends on float — another exit earlier in the same block can turn a 0 quote into a nonzero one | constant |
| Incidence | only exits that forced an unwind pay | every instant exit pays, including ones idle float absorbed |

The argument against the implemented basis: it creates a race — in a rush for
the exit, the first out pays nothing (float covers them) and the last pays
full, correct on damage grounds but adding pressure to run early (the opposite
of what an anti-mercenary term wants). Kept as specced because it matches the
fee's stated purpose and the run pressure is second-order: instant-exit
capacity is already bounded by `IStrategy.availableLiquidity()`
(`SyndicateVault.sol:755`) regardless of the penalty. The flat-basis alternative
remains a one-line change (`_exitPenalty` collapses to
`(netAssets * bps) / FeeConstants.BPS_DENOMINATOR`) if reconsidered later.

### 6. ProtocolConfig / vault changes

- `ProtocolConfig`: replace the two flat rate fields with the split configs
  (`mgmtSplitBps`, `perfSplitBps` structs) + their caps; keep recipients.
  Snapshotted onto the proposal at propose exactly as `protocolFeeBps`/
  `guardianFeeBps` were.
- Vault: `managementFeeBps` semantics change from profit-gated to
  AUM-time-weighted (accessor renamed for clarity; storage slot reused). Add
  `highWaterPricePerShare`. Raise `MAX_PERFORMANCE_FEE_BPS` to the chosen cap.
- Governor: `_distributeFees` rewritten from a four-step sequential waterfall to
  two split-distributions (management always; performance on above-HWM
  profit). The self-managed-strategy path (`selfManagesFees`) folds its
  management + performance legs the same way `LeveragedAerodromeCLStrategy`
  already self-collects `protocolFeeOwed` — except management is never skipped
  (D3).

Subgraph: `managementFee`/`performanceFee` per proposal with their splits, and
the high-water-mark series — deferred (see Non-Goals).

## Risks / Trade-offs

- **Fail-open payment.** A bricked fee recipient never blocks settlement
  (`_payFee` try/catch escrow), which is the intended trade-off — settlement
  liveness over guaranteed same-block payment.
- **Idle-capital exemption is intentional but has an edge case.** A fund whose
  agent stops proposing while LPs remain deposited charges 0%/yr — accepted
  because there is genuinely no management happening, but it means the
  guardian-funding story only holds while proposals keep flowing.
- **Single global high-water mark** cannot perfectly equalize investors across
  entry times; residual risk is bounded by settling every proposal (see
  Non-Goals).
- **Instant-exit-penalty race pressure** (pulled-portion basis) creates a
  first-out-pays-nothing dynamic under a rush of simultaneous exits; judged
  second-order given the existing `availableLiquidity()` bound on instant-exit
  capacity, but flagged for reconsideration if observed in practice.

## Appendix — research basis

- **Onchain fund fee mechanics** (Enzyme v4, dHEDGE, Yearn v3, Set, Balancer
  Managed Pools, Index Coop, Hyperliquid vaults): all charge management
  (AUM-streaming) and performance fees; all performance fees use a per-share
  high-water mark; **none** charge a per-trade/volume fee. Share-dilution
  minting is the universal collection mechanic. Sources: Enzyme specs
  (`specs.enzyme.finance`), dHEDGE docs (`docs.dhedge.org`), Yearn v3
  (`docs.yearn.fi`), Set `StreamingFeeModule.sol`, Balancer
  `ExternalAUMFees.sol`, Hyperliquid vault docs.
- **Hedge-fund fee structure** (2-and-20, high-water marks ~85% prevalence,
  hurdle rates, fee compression to ~1.3-and-16): AlphaMaven, Preqin, With
  Intelligence, CAIA, Thinking Ahead Institute "A Fairer Deal on Fees",
  Bloomberg (pass-through fee load).
- **HWM math & ERC-4626 fee conventions:** OpenZeppelin `ERC4626Fees`, EIP-4626,
  SS&C (series vs equalization), Enzyme HWM issue #212.
