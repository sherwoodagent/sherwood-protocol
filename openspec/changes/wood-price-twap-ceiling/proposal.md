# Bound the WOOD governance price with a DEX TWAP ceiling

> ## ⚠️ THE TWO-NUMBER MODEL BELOW IS SUPERSEDED
>
> See `design-revision-2026-08-01.md`. The split into a high emergency ceiling
> plus a snug maintained fallback is withdrawn: it pointed the `min` at a
> number specified never to bind, which left the TWAP effectively unbounded
> upward. The revision collapses back to **one** maintained reference that
> caps the TWAP, serves as the staleness fallback, and doubles as the
> emergency brake when lowered.
>
> The **Why** section below stands unchanged and is still the reason to do
> this work.

## Why

**There is no Chainlink WOOD/USD feed on Robinhood Chain 4663, and none is
expected by launch.** Verified against `chains/4663.json`: the address book
carries 16 Chainlink feeds — ETH, USDG, USDC, BTC, LINK and the tokenized
stocks — and no WOOD feed. It has no `WOOD_TOKEN` entry at all; only testnet
`46630` does.

That makes the "fallback" the **primary**, indefinitely:

```
woodPriceX8()  →  feed == address(0)  →  _haircut(woodUsdPriceX8)
                                              │
                          woodHaircutBps defaults to 10_000 (no haircut)
                                              ↓
                        price = woodUsdPriceX8, RAW, multisig-maintained
```

Three consequences, none of which the current design was shaped for:

1. **The dangerous direction is silent.** `slashableBondUsd =
   guardianStake × woodPriceX8`. If the manual number sits *above* market,
   guardians appear better collateralized than they are and
   `requireApproveQuorum` clears on collateral that does not exist. Nothing
   reverts, nothing is emitted.
2. **The alarm is nulled.** `woodPriceDetail()` exposes `usingFallback` as the
   signal that pricing is degraded. With no feed it is permanently `true`, so
   the observability built for exactly this state stops carrying information
   precisely because the state is permanent rather than transient.
3. **Drift is the default, not the exception.** WOOD is live and thin
   (~$4.5M implied cap; see design.md for measured reserves).
   `MIN_PRICE_UPDATE_INTERVAL` is 1 day, so a fast drawdown between multisig
   updates puts the protocol in the overvalued state without anyone erring.

## What changes

A new `WoodTwapOracle` reads the live WOOD/WETH Uniswap-V2-style pair's
cumulative-price accumulator, converts to USD through the existing ETH/USD
Chainlink feed, and `ExposureLedger` uses it as a **ceiling on the governance
number, never as a replacement**:

```
price = min(woodUsdPriceX8, twapUsd) × woodHaircutBps
```

The `min` is the whole design. It admits the TWAP only in the direction where
manipulating it cannot pay:

- TWAP pushed **up** → `min` ignores it; the attack is inert.
- TWAP pushed **down** → bonds valued lower, quorum harder to clear. A
  denial-of-service with no payoff, priced in design.md.

Trading a theft-enabling failure (silent overvaluation) for a costly,
payoff-free DoS is the direction worth taking.

When the TWAP is unavailable or its snapshot is stale, the `min` is skipped and
the governance number stands alone — **exactly today's behaviour**, so the
change can only fail *same*, never *worse*.

## Impact

- New contract `src/pricing/WoodTwapOracle.sol` (permissionless `update()`,
  `view` `consult()`).
- `src/ExposureLedger.sol`: `_woodPrice` gains the ceiling; new owner setter to
  wire/unwire the oracle (unwire must stay possible, mirroring `setWoodFeed`).
- Interface + layout goldens; deploy wiring; tests.
- **Does NOT change** what happens when a Chainlink WOOD feed eventually
  arrives — the ceiling composes with it unchanged.

## Not in scope, deliberately

- Asset-side (`coverageUsd`) fallbacks. That path reverts today and has eight
  call sites with per-site guard decisions already made; changing them all at
  once is a separate question.
- Promoting the TWAP to a primary price source. See design.md — pair depth
  forbids it, and that constraint must survive future refactors.

## Operating doctrine: `setWoodUsdPrice` is an EMERGENCY lever, not a feed

**Owner decision, 2026-08-01.** The governance number is not to be maintained
as a routine price. It is set once as a standing ceiling and touched only in an
emergency.

This removes recurring human judgment from the pricing path and leaves humans
only a brake. It also forces a split, because **one number cannot be both a
brake and a fallback**: a brake wants to sit high so it never binds, a fallback
must be accurate the moment it is needed. Set high it is a dangerous fallback;
set snug it needs exactly the maintenance this doctrine exists to remove.

So there are two, each with one job (owner decision, option A):

| | Value | Touched | Role |
|---|---|---|---|
| `woodUsdPriceX8` (existing) | HIGH, non-binding | **emergency only** | ceiling, applied as `min` to whichever source is live |
| `woodFallbackPriceX8` (new) | snug, conservative | maintained | the price used when the TWAP is stale |
| TWAP | — | nobody | **the routine price** |

The existing setter stays where it is: `setWoodUsdPrice` is already
brake-shaped — unbounded immediate downward moves, upward capped at 2× per
interval, zero as the emergency stop — so `woodUsdPriceX8` becomes the ceiling
unchanged.

Resolution order:

```
source = twap fresh            ? twapUsd
       : woodFallbackPriceX8≠0 ? woodFallbackPriceX8
       :                         REVERT NoWoodPrice

price  = haircut( min(source, woodUsdPriceX8) )
```

The ceiling caps **both** branches on purpose — capping only the TWAP branch
would leave the fallback unthrottled exactly when the brake is being pulled.
The revert is a deploy-misconfiguration guard, not a runtime state; see
design.md decision 3 for why a loud failure beats serving `0` here.

## What lowering `woodHaircutBps` does and does not buy

Correcting an earlier, looser framing: **the haircut does not make the price
more accurate.** It pre-funds an allowance for how wrong the price may be.

Bonds are overvalued once `manual × haircut > true price`, so the haircut is
exactly a pre-funded allowance for a drawdown between updates:

| `woodHaircutBps` | tolerates manual overstating by | absorbs a WOOD crash of |
|---|---|---|
| 10_000 (today) | 0% | **0%** — any drop overvalues immediately |
| 7_000 | 42.9% | 30% |
| 6_000 | 66.7% | 40% |
| 5_000 (floor) | 100% | **50%** |

Two honest limits:

1. It is a **constant factor against an unbounded error**. It covers one crash
   of a known size; it does not cover a number nobody ever updates. Under the
   emergency-only doctrine above, that limit is load-bearing rather than
   theoretical.
2. **There is no signal when the allowance is exhausted** — the same blind spot
   as `usingFallback` being permanently true.

So the haircut is worth setting because it converts an unbounded silent failure
into a bounded one. It is **not** a substitute for this change: only something
that tracks reality (the TWAP ceiling, or a real feed) lets the protocol notice
on its own.

Related: issue #31 (`maxSlashBps` at 9,999) is the same inequality — collateral
worth less than the model claims. Both defaults currently sit on the wrong
side; decide them together.
