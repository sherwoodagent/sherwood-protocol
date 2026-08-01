# Bound the WOOD governance price with a DEX TWAP ceiling

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

## Ship-order note

`woodHaircutBps` is currently 10_000 (no haircut) and can be lowered to 5_000
today with **no code change**. Setting it to 6_000–7_000 buys real margin
against the drift this proposal addresses and does not depend on any of the
work here. That is the launch-week mitigation; this change is what removes the
multisig from the pricing loop afterwards.
