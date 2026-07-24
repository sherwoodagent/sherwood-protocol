# The Volume Fee — Product Spec

**Status:** Proposed
**Date:** 2026-07-24
**Companion:** technical design in `docs/specs/2026-07-24-volume-fee-mechanism-design.md`

A small protocol fee on each trade a fund makes — so Sherwood's revenue grows
with activity, the way Hyperliquid's does, instead of depending entirely on
strategies ending in profit.

## The fee at a glance

| | |
|---|---|
| **Rate** | 0.02% of each trade's value (2 bps) |
| **Hard ceiling** | 0.10% — can never be set higher, by contract |
| **Charged** | Per trade — skimmed from each trade's cash leg, in real time |
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
2. **Each trade → fee is taken.** 0.02% of the trade is skimmed from its cash leg
   and sent straight to the treasury.
3. **Settlement → remainder clears.** Trades with no cash leg ran a tab; it's paid
   before capital returns to the vault.
4. **Ongoing → WOOD buyback.** Treasury converts volume-fee revenue into open-market
   WOOD purchases.

The fee is paid **per trade, in real time** — exactly how Hyperliquid deducts fees
from each fill's cash leg. Gas on Robinhood Chain is negligible, so there's no reason to batch;
the treasury (and eventually the buyback) sees revenue continuously, not once a
month. The only exception is a trade that doesn't touch the vault's cash asset at
all (say, rebalancing straight from ETH into AERO) — there's no cash leg to skim, so
that trade's fee goes on a tab that clears at settlement. Either way every fee is
paid *before* profit is measured, so the volume fee simply looks like one more
trading cost, the same as DEX swap fees, and the profit-fee waterfall doesn't change
at all.

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

## The full fee stack — a hedge fund for agents

Sherwood is a hedge fund where the manager is an agent, so the fee stack follows the
hedge-fund template: the classic **"2 and 20"**, sized for our stack as **"2 and
10"**. A hedge fund manager gets paid whether or not the fund made money — the
management fee on assets covers the cost of running the book, and the carry rewards
performance on top. Sherwood's agents get the same deal:

| Fee | Goes to | Rate | Charged on | Paid when |
|---|---|---|---|---|
| **Management fee** | Agent(s) | 2%/yr, pro-rated per proposal | fund capital (AUM) | **Always** — profit, flat, or loss |
| **Volume fee** (new) | Treasury → buyback | 0.02% | every trade's value | **Always** — profit, flat, or loss |
| Performance fee (carry) | Lead agent + co-proposers | 10% default (up to 15%) | profit after protocol & guardian cuts | Profitable settlements only |
| Protocol fee | Treasury | 5% (cap 10%) | settlement profit | Profitable settlements only |
| Guardian fee | Guardian network | 3% (cap 5%) | settlement profit | Profitable settlements only |
| Owner fee | Fund owner | ≤ 5% | profit after the agent's carry | Profitable settlements only |
| Creation fee | Treasury | flat | launching a fund | Once, at creation |

(The owner fee is today's contract "management fee," renamed — it was always
profit-gated, so the name was misleading. The true AUM-based management fee is new,
and it belongs to the agent who runs the money.)

**Deliberate sizing: the agent is the largest fee earner in the stack — in every
market.** The management fee means an agent earns on flat and losing months, like
any fund manager; the carry makes good months much better; and the protocol and
guardian network run well below their contract caps so their combined take stays
below the agent's. Guardian fees are split among the guardians who reviewed the
proposal, weighted by their stake, and paid out weekly. Agent fees (management and
carry both) split between the lead and any co-proposers at proportions they agreed
at proposal time.

### One good month, everyone's cut

The same $1M fund, ending a 30-day proposal $21,500 up before Sherwood fees
(rates: management 2%/yr, protocol 5%, guardian 3%, carry 10%, owner 5%):

| Step | Who | Amount | Running remainder |
|---|---|---:|---:|
| Volume fee (paid trade by trade, during the month) | Treasury | $1,500 | $20,000 measured profit |
| Management fee — 2%/yr × 30 days on $1M | Agent(s) | **$1,644** | $18,356 |
| Protocol fee — 5% of profit | Treasury | $918 | $17,438 |
| Guardian fee — 3% of profit | Guardian network | $551 | $16,887 |
| Performance fee — 10% of the remainder | Agent(s) | **$1,689** | $15,198 |
| Owner fee — 5% of the remainder | Fund owner | $760 | $14,438 |
| **Depositors keep** | Shareholders | **$14,438** | +1.44% for the month |

The agent's total is **$3,333** ($1,644 management + $1,689 carry) — more than
double the protocol and guardians combined ($1,469). On a **flat month** the table
becomes two lines: the treasury's $1,500 volume fee and the agent's $1,644
management fee. The agent gets paid for managing, hedge-fund style; guardians stay
profit-gated until their phase-3 volume share; and the carry is still where the real
upside lives, so the incentive to perform is intact.

### What the volume fee changes for each of them

**Nothing is taken from anyone's slice.** The profit-fee percentages, order, and
recipients are untouched. The volume fee is paid out of trading like a venue cost,
so measured profit — the base everyone's percentage applies to — is slightly lower
(in the example above, ~$320 less across all four profit fees combined). That's the
entire impact on agents and managers.

**Guardians are the ones whose economics genuinely improve.** Review effort doesn't
depend on the market going up — a flat month takes as much guardian attention as a
good one, but today it pays $0. The phase-3 revenue share gives the guardian network
income proportional to activity reviewed, which is what our economic-security
analysis says the network needs to stay honestly staffed.

The fund owner's fee stays profit-gated (renamed "owner fee" to say what it is).
The people paid regardless of markets are the ones doing work regardless of
markets: the agent managing the book (management fee), the protocol running the
rails (volume fee), and — from phase 3 — the guardians reviewing proposals.

## Who feels what

- **Depositors** — a small, visible, **bounded** cost: 0.02% per unit of turnover,
  far below the swap fees and price impact the same trades already pay. Total fees
  per proposal are hard-capped, and the fee can **never block a withdrawal**: if it
  can't be paid, it's skipped, not forced.
- **Agents** — **the largest fee earner in the stack, in every market**: a
  hedge-fund-style deal of 2%/yr management fee on capital (paid profit or not)
  plus 10–15% carry on profits, together sized to beat protocol and guardians
  combined. The volume fee is one more line in the cost model, priced like venue
  fees, with the rate **locked when the proposal starts**. Later: stake WOOD,
  trade cheaper (phase 3).
- **Guardians** — today guardian rewards exist only when strategies profit. Volume
  fees create a revenue stream proportional to **how much reviewing there is to do**
  — the phase-3 revenue share is aimed directly at the guardian-funding gap.
- **WOOD holders** — the Hyperliquid flywheel, sized for Sherwood: protocol revenue
  that exists in flat markets, converted into **recurring open-market WOOD
  buybacks** — demand tied to protocol usage, not token emissions.

## The numbers

A $1M fund running a portfolio strategy that rebalances about a quarter of the
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

### Four funds, four fee profiles

What the fee actually costs across the real strategy lineup, per month at 0.02%:

| Fund | Capital | What it does | Monthly volume | Volume fee |
|---|---:|---|---:|---:|
| Stable yield (Moonwell USDC lending) | $500k | Deploys once, earns interest, unwinds at settle | $0 — lending isn't volume | **$0** |
| LP yield (Aerodrome USDC/ETH) | $250k | Enters the pool once, sells AERO rewards weekly (~$1.5k/wk) | ~$256k first month, then ~$6k | **~$51**, then ~$1 |
| Leveraged LP (Leveraged Aerodrome CL) | $500k | Re-ranges ~2×/week, rotating ~40% of the book each time | ~$1.7M | **~$350** |
| Active portfolio (BTC/ETH/SOL basket) | $1M | Rebalances ~25% of the book daily | ~$7.5M | **~$1,500** |

Most funds pay a few dollars to a few hundred a month; only genuinely active
trading reaches four figures — and that's exactly the flow that consumes the most
guardian review, pricing infrastructure, and risk surface.

## Rollout

1. **Turn it on** *(contract release)* — volume fee live at 0.02%, all revenue to
   the protocol treasury, and the agent's hedge-fund deal in place: 2%/yr AUM
   management fee (new) plus the carry default raised to 10%, with protocol at 5%
   and guardian at 3% (config changes) so the agent-earns-most ordering holds from
   day one. Every trade and every fee visible on-chain and in the app — funds get a
   real "volume" stat for free.
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
  shown per fund. Depositors can see exactly what activity cost before they
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
5. **Management fee rate and cap.** 2%/yr proposed (the hedge-fund standard), with
   a 3%/yr contract cap. Decide whether the fund owner shares it or it goes to the
   agent alone (proposed: agent alone; the owner keeps their profit-gated fee).

## What success looks like

Two quarters after launch: **volume fees are a meaningful share of protocol revenue**
(target: comparable to profit fees across a cycle), **revenue in flat months is
nonzero** for the first time, the buyback is running on a published cadence, and no
settlement has ever been delayed by a fee. If active agents route *away* from
Sherwood because of the fee, the rate is too high — that's what the dial is for.
