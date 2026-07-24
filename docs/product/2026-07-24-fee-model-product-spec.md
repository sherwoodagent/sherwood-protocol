# Sherwood Fee Model — Product Spec

**Status:** Proposed
**Date:** 2026-07-24
**Companion:** technical design in `docs/specs/2026-07-24-fee-model-design.md`

Sherwood funds charge **two numbers, like a hedge fund: "2 and 20"** — a 2%/yr
management fee and a 20% performance fee above a high-water mark. Every party that
gets paid — the agent, the protocol, the guardian network, the fund owner — is paid
*out of those two numbers* through internal splits. The depositor sees two fees, not
six.

## Why this changed

An earlier draft of this model had grown to six separate depositor-facing fees:
management, volume (per-trade), performance, protocol, guardian, and owner. That's
not how a fund is priced — it's how a fund gets *audited*. A real hedge fund pays a
whole cast (portfolio manager, analysts, prime broker, administrator, auditor) but
shows the investor **two numbers**. Everyone else's cut comes out of those two,
invisibly.

Two research findings drove the simplification:

- **No onchain fund charges a per-trade / volume fee.** Enzyme, dHEDGE, Yearn,
  Sommelier, Balancer, Index Coop, Ribbon, Arrakis — none of them. Per-trade fees
  exist only at the *exchange* layer (Hyperliquid's taker fees, builder codes). A
  volume fee on a fund has no precedent to inherit and reads as nickel-and-diming.
- **The management fee already does the volume fee's job.** The volume fee was
  originally added to earn revenue in flat months, back when performance-share was
  the *only* fee. But an always-on management fee on assets is the industry-standard,
  investor-understood way to earn in flat months — so once you have one, the volume
  fee is redundant.

So the volume fee is **removed**, and the four separate profit-side fees are **folded
into one 20% performance fee** that splits behind the scenes.

## The two numbers

| Fee | Rate | Charged on | Paid when |
|---|---|---|---|
| **Management fee** | 2%/yr | fund assets (AUM), time-weighted | **Always** — profit, flat, or loss |
| **Performance fee** | 20% | profit above the high-water mark | Profitable settlements only |

That's the whole depositor-facing picture, plus one-time and redemption terms
(below). The management fee keeps every party that does continuous work funded in
flat months; the performance fee rewards everyone on the upside.

### Where each number goes — the splits

The depositor pays "2 and 20." Behind each number, a governance-set split divides it
among the people who earn it:

**Management fee — 2%/yr, split three ways:**

| Recipient | Share | Effective rate |
|---|---|---:|
| Agent (manages the book) | 70% | 1.40%/yr |
| Protocol (runs the rails) | 20% | 0.40%/yr |
| Guardian network (reviews every proposal) | 10% | 0.20%/yr |

**Performance fee — 20% above high-water mark, split four ways:**

| Recipient | Share | Effective rate |
|---|---|---:|
| Agent (carry) | 60% | 12% of profit |
| Protocol | 15% | 3% of profit |
| Guardian network | 15% | 3% of profit |
| Fund owner (sponsor) | 10% | 2% of profit |

Two things fall out of this that matter:

- **The agent is still the largest earner, in every market** — 70% of the
  always-on fee and 60% of the carry. Managing the money is the best-paid role, as
  it should be.
- **Guardians now earn in flat months.** Giving the guardian network a slice of the
  *management* fee — 0.20%/yr on AUM, paid regardless of profit — is what replaces
  the volume fee's flat-month role, and it closes the guardian-funding gap our
  economic-security analysis flagged (review effort doesn't stop when markets go
  flat, so the funding shouldn't either). No separate fee required.

## The high-water mark

New, and table stakes: **the performance fee is only charged on gains above the
fund's previous peak.** If a fund runs $100 → $120 (fee paid) → $95 → $120, the
recovery from $95 back to $120 is *not* charged again — that ground was already
paid for. ~85% of hedge funds have this, and every onchain fund does (Enzyme,
dHEDGE, Hyperliquid vaults). Sherwood's per-proposal profit measurement didn't, which
meant a volatile fund could be charged twice on the same dollars. The mark is a
stored per-share price; the performance fee applies only to the delta above it, and
the mark ratchets up after each fee.

## What a good month looks like

A $1M fund, 30-day proposal, ending **+2.15% gross ($21,500)**, above its
high-water mark:

| Fee | Amount | Split |
|---|---:|---|
| Management — 2%/yr × 30 days on $1M | $1,644 | agent $1,151 · protocol $329 · guardian $164 |
| Performance — 20% of $21,500 | $4,300 | agent $2,580 · protocol $645 · guardian $645 · owner $430 |
| **Total fees** | **$5,944** | |
| **Depositors keep** | **$15,556** | +1.56% for the month |

The agent earns **$3,731** ($1,151 management + $2,580 carry) — more than the
protocol, guardians, and owner *combined* ($2,213). On a **flat month**, only the
management fee is charged — $1,644, split agent/protocol/guardian — and nobody earns
performance. The total fee load is **lower than the old six-fee stack** (which
extracted ~$7,000 on the same month once the volume fee and stacked cuts were added
up): fewer fees, and less of them.

## Getting in and out

Deposits and withdrawals stay open while a strategy is live. These are **redemption
terms, not headline fees:**

- **No deposit fee.** Entry friction kills fund growth; nothing is charged on the
  way in.
- **Instant exits can carry an early-redemption fee (≤ 2%, proposed 0.5%).** Leaving
  immediately at an oracle price — instead of waiting for the settlement queue —
  can cost a small fee that **accrues to the fund** (the depositors who stay), not
  the protocol. It's the hedge-fund early-redemption analogue, and it exists to
  discourage mercenary in-and-out flows, not to make money.
- **The queue is always free.** Waiting for settlement — the patient path — never
  costs the *early-redemption* fee.
- **Exit timing is fee-neutral — you pay your fee share either way.** Queue
  withdrawers claim at the settlement price, which is struck *after* fees, so their
  share is already deducted. Instant withdrawers have their management and
  performance fees crystallized and deducted *at the moment they exit* (the way a
  Hyperliquid vault charges its profit share at withdrawal). Neither can leave their
  fee burden on the depositors who stay.
- **Mid-proposal deposits are never mistaken for profit.** The vault nets flows out
  of the profit calculation and the management fee is time-weighted, so you only pay
  on capital that was actually in the fund, for the time it was there — a late
  deposit is never charged a performance fee on money it didn't earn.

## How fees are collected

Fees are computed at settlement and paid from the fund's assets before capital
returns to the vault — the same rail the protocol already uses. (The onchain
standard is to collect fees by *minting shares* to the recipient, so fully-deployed
strategies never liquidate to pay a fee; that's a cleaner mechanic we may adopt
later, but it's an implementation change, not a change to any of the economics
above.)

## Rollout

1. **Ship the two-number model** *(contract release)* — management + performance
   fees with their internal splits, the high-water mark, and the volume fee removed.
   Every fee and split visible on-chain and in the app.
2. **The buyback** *(treasury policy)* — the protocol's share of fees funds
   open-market WOOD purchases on a published cadence, the way Hyperliquid's
   Assistance Fund buys HYPE.
3. **Staking discounts** *(contract release)* — agents who stake WOOD earn a
   discount on the management/performance split they owe the protocol; staking
   demand on the supply side, buyback demand on the revenue side.

## Open decisions

1. **The two numbers.** "2 and 20" proposed. The industry has compressed to ~1.3
   and 16, so a crypto-native "1 and 15" or "1 and 20" would undercut TradFi and
   read as investor-friendly — at the cost of agent income. Lean: launch at 2 and
   20, keep the dials.
2. **The splits.** Management 70/20/10 (agent/protocol/guardian) and performance
   60/15/15/10 (agent/protocol/guardian/owner) proposed. All governance-set.
3. **Hurdle rate.** Not included (rare onchain, needs a benchmark). Revisit if
   depositors ask — ~half of TradFi allocators now want one.
4. **Fee collection via share dilution.** The onchain standard; deferred as a
   mechanic change. Current asset-based collection stands for launch.
5. **Instant-exit fee rate.** 0.5% proposed, capped 2%, accruing to the fund.

## What success looks like

Two quarters after launch: depositors describe Sherwood's fees in one breath ("two
and twenty, with a high-water mark") instead of enumerating six charges; the total
fee load is lower than the old stack; guardians are funded in flat months; the
buyback runs on a published cadence; and no settlement has ever been delayed by a
fee. If agents route away because the numbers are too high, that's what the dials
are for.
