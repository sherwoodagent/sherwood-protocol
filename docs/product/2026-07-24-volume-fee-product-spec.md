# The Volume Fee — Product Spec

**Status:** Proposed
**Date:** 2026-07-24
**Companion:** technical design in `docs/specs/2026-07-24-volume-fee-mechanism-design.md`

A small protocol fee on each trade a syndicate makes — so Sherwood's revenue grows
with activity, the way Hyperliquid's does, instead of depending entirely on
strategies ending in profit.

## The fee at a glance

| | |
|---|---|
| **Rate** | 0.02% of each trade's value (2 bps) |
| **Hard ceiling** | 0.10% — can never be set higher, by contract |
| **Charged** | Per trade — counted as trades happen, paid at wrap-up |
| **Who pays** | Active strategies; passive lending strategies pay ~nothing |
| **Goes to** | Protocol treasury → WOOD buybacks (phase 2) |
| **Rate lock** | Fixed when a strategy starts; no mid-run changes |

## The problem

Sherwood currently earns fees in exactly one situation: a strategy settles *and* it
made money. The protocol takes a slice of profit, guardians take a slice, the agent
takes a slice. If a strategy breaks even, loses, or simply hasn't settled yet, the
protocol earns nothing — even though the vault traded all month, guardians reviewed
every proposal, and the whole apparatus ran.

Three things are wrong with that:

- **Revenue is lumpy and fragile.** A flat market month means zero income,
  regardless of how much real activity Sherwood coordinated.
- **Activity is mispriced.** A portfolio strategy that rebalances every day and nets
  +0.5% pays the same fee as a buy-and-hold that nets +0.5% on a single trade — yet
  the first consumed far more guardian attention, infrastructure, and risk surface.
- **The guardian economy is underfunded.** Our own economic-security analysis flagged
  that a profit-only fee base can't reliably fund the guardian rewards that keep
  review honest. Fees tied to activity, not luck, fix the denominator.

## The model we're borrowing

Hyperliquid — the most profitable protocol in DeFi per dollar of TVL — charges a few
*hundredths of a percent* on every fill. Nobody notices any single fee; almost all of
it (~97%) flows to a protocol wallet that buys HYPE on the open market, roughly a
million dollars a day. Small take rate × large volume × mechanical buyback: revenue
scales with activity and is fully decoupled from whether any individual trader wins.

Hyperliquid even has a product for apps in exactly Sherwood's position — "builder
codes," which let an app that routes order flow add up to 0.10% on each trade it
sends. That 0.10% ceiling is the market's answer to "what is acceptable rent on
routed flow," and it's where we anchor our own hard cap. Sherwood routes managed flow
to DEX venues; the volume fee is our builder code, implemented at the protocol layer.

## How it works

Follow one proposal from the fee's point of view:

1. **Strategy starts → rate locks.** The current fee rate is stamped onto the run.
   It cannot rise mid-flight.
2. **Each trade → fee accrues.** Every swap adds 0.02% of its value to a running
   tab. No transfer yet.
3. **Settlement → the tab is paid.** Before capital returns to the vault, the tab
   (capped) goes to the treasury.
4. **Ongoing → WOOD buyback.** Treasury converts volume-fee revenue into open-market
   WOOD purchases.

Accruing per trade but paying once at settlement is deliberate: it keeps every trade
cheap (no extra token transfer per swap) while the economics still scale with volume
— which is the entire point. And because the tab is paid *before* profit is measured,
the volume fee simply looks like one more trading cost, the same as DEX swap fees.
The existing profit-fee waterfall doesn't change at all.

### What counts as a trade

**Counts:**
- Every swap a portfolio strategy makes — including rebalances, both directions
- Deploying capital into a liquidity pool
- Converting farmed rewards back to the vault asset

**Doesn't count:**
- Lending deposits and withdrawals — custody moves, not trades
- Exiting a liquidity pool — entry already paid; no double-charging the same capital
- Depositor deposits and withdrawals — LP flows are never fee'd

Rule of thumb: if the strategy is *taking a market position*, it's volume. If it's
*moving its own money around*, it isn't. A Moonwell supply strategy that deploys once
and unwinds once pays approximately nothing — correct, because it consumes the least
protocol attention per dollar.

## Who feels what

- **Depositors** — a small, visible, **bounded** cost: 0.02% per unit of turnover,
  far below the swap fees and price impact the same trades already pay. Total fees
  per proposal are hard-capped, and the fee can **never block a withdrawal**: if it
  can't be paid, it's skipped, not forced.
- **Agents** — one more line in the cost model, priced the same way as venue fees.
  The rate is **locked when the proposal starts** — what shareholders voted on is
  what applies. Later: stake WOOD, trade cheaper (phase 3).
- **Guardians** — today guardian rewards exist only when strategies profit. Volume
  fees create a revenue stream proportional to **how much reviewing there is to do**
  — the phase-3 revenue share is aimed directly at the guardian-funding gap.
- **WOOD holders** — the Hyperliquid flywheel, sized for Sherwood: protocol revenue
  that exists in flat markets, converted into **recurring open-market WOOD
  buybacks** — demand tied to protocol usage, not token emissions.

## The numbers

A $1M syndicate running a portfolio strategy that rebalances about a quarter of the
book daily, over a 30-day proposal:

| Scenario | Protocol revenue today | With volume fee |
|---|---|---|
| Good month (+2% net) | $2,000 (profit fee) | **$3,500** (profit + volume) |
| Flat month (0%) | $0 | **$1,500** (volume only) |
| Losing month (−1%) | $0 | **$1,500** (volume only) |
| Passive strategy (Moonwell supply) | $0–2,000 | ≈ unchanged |

The depositor-side drag in the active scenario is 0.15% for the month — a fraction
of what the same flow already pays in venue costs. An aggressive strategy turning
the book daily would pay ~$6,000/month; a passive one pays nothing. **The fee prices
protocol attention by activity**, which is precisely what the profit-only model
cannot do.

## Rollout

1. **Turn it on** *(contract release)* — fee live at 0.02%, all revenue to the
   protocol treasury. Every trade and every fee visible on-chain and in the app —
   syndicates get a real "volume" stat for free.
2. **The buyback** *(treasury policy)* — treasury publishes a wallet and cadence,
   and converts volume-fee revenue into open-market WOOD purchases on a schedule.
   Policy first, contracts later — the same path Hyperliquid took with its
   Assistance Fund.
3. **Share & discount** *(contract release)* — a protocol-set share of volume fees
   streams to guardians/stakers, closing the guardian-funding gap. Agents who stake
   WOOD earn discounted fee rates — staking demand on the supply side, buyback
   demand on the revenue side.

## Guardrails

- **Never blocks an exit.** If the fee can't be paid at settlement, settlement
  proceeds anyway and the shortfall is recorded. Depositor withdrawals are senior to
  protocol revenue, always.
- **No mid-run surprises.** The rate a proposal launched with is the rate it pays.
  Governance can change the rate for future proposals only.
- **Hard-capped twice.** The rate can never exceed 0.10%, and total volume fees per
  proposal are capped at a fixed multiple of the capital deployed — so runaway churn
  (malicious or buggy) has a known worst case.
- **Nobody profits from wash trading.** The fee goes to the protocol, not the agent
  — inflating volume only costs the strategy money. The cap bounds the griefing
  case too.
- **Everything is visible.** Accruals and payments are on-chain events, indexed and
  shown per syndicate. Depositors can see exactly what activity cost before they
  deposit.

## Not in scope

- **Hyperliquid strategy templates.** The perp and grid strategies are not moving
  forward; this design covers DEX and lending strategies only. (Convenient side
  effect: on DEXs, executed trade size is exactly knowable on-chain at the moment of
  the trade — no oracles or estimates needed.)
- **Deposit/withdrawal fees.** Separately specced, separately deferred. Orthogonal.
- **Volume-tier discounts.** Hyperliquid discounts high-volume traders; Sherwood's
  per-vault flow is nowhere near the regime where that matters. Staking discounts
  (phase 3) are the differentiator that fits our token instead.
- **Contract-enforced buybacks.** Phase 2 is policy, like Hyperliquid's own fund.
  Automating it on-chain needs a WOOD price feed we don't have yet.

## Open decisions

1. **Launch rate: 0.02% proposed.** Alternatives: 0.01% (quieter start) or 0.05%
   (half the builder-code ceiling). Lean: start low; the cap leaves room to move.
2. **Should liquidity-pool *entries* count as volume, or only swaps?** Lean: count
   entries once — deploying into an LP is taking a market position.
3. **Turnover cap multiple: 50× deployed capital proposed.** Generous for any sane
   strategy; exists purely to bound the pathological case.
4. **Phase-3 split between guardians and buyback.** Needs the guardian-economics
   model finished first.

## What success looks like

Two quarters after launch: **volume fees are a meaningful share of protocol revenue**
(target: comparable to profit fees across a cycle), **revenue in flat months is
nonzero** for the first time, the buyback is running on a published cadence, and no
settlement has ever been delayed by a fee. If active agents route *away* from
Sherwood because of the fee, the rate is too high — that's what the dial is for.
