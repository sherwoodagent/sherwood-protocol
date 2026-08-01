# Design

## Measured state (2026-08-01, chain 4663 mainnet)

Every number below was read on-chain, not assumed. Re-verify before
implementing — these move.

```
WOOD          0xF8BC08092C06dB6148114DCf82AF881F1085f92b   symbol "WOOD"
                                                totalSupply 1e9
ETH/USD feed  0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9   LIVE, 8 decimals
                                                answer $1,867.55, fresh
V2 pair       0xBF3BB81de6285b8310A028d1C2Cd38F9419d54C1
  factory     0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f   (a V2 FORK, see risks)
  token0      WETH   117.296 WETH
  token1      WOOD   48,359,980.69 WOOD
  blockTimestampLast 8 SECONDS before the read → accumulator ticking constantly
  price0CumulativeLast / price1CumulativeLast   both large, advancing

derived   1 WOOD = 2.4256e-6 ETH = $0.004530
          depth  ≈ $219k per side, ~$438k total
          implied mcap ≈ $4.5M
```

### Venues that do NOT work, recorded so nobody re-derives this

- **Uniswap V3**: four WOOD/WETH pools exist (fees 100/500/3000/10000) and all
  four are **empty shells** — `liquidity() == 0`, `observationCardinality == 1`,
  and three sit pinned at the max tick. They are initialized but never traded.
  This is a **trap**: `getPool(...)` returns a non-zero address, so a naive
  "does the pool exist?" check passes and then reads a garbage price from an
  empty pool. Do not wire V3.
- **Uniswap V4**: the PoolManager (`0x8366a39cc670b4001a1121b8f6a443a643e40951`)
  holds real balances, but V4 is a singleton with hooks and has no per-pool
  observation ring buffer. A TWAP needs an oracle hook attached **at pool
  creation**; it cannot be retrofitted by calling the pool.

The V2 pair is therefore the only viable TWAP source on this chain today.

## Why a ceiling, and not a fallback

"Conservative" points in **opposite directions** for the protocol's two prices,
which is why an unbiased price source is not automatically a safe one:

| | too LOW | too HIGH | safe bias |
|---|---|---|---|
| Asset price (`coverageUsd`) | understates required coverage → under-collateralized execution | proposals cannot reach quorum | HIGH |
| **WOOD price** (`woodPriceX8`) | guardians look under-collateralized → quorum harder | `slashableBondUsd` overstates → quorum clears on absent collateral | **LOW** |

A TWAP is direction-agnostic. `min(governance, twap)` makes it directional by
construction — the same trick `_haircut` already uses, and the same trap its
natspec documents (an earlier version haircut only the healthy path, making the
*fallback* less conservative than the primary).

## Manipulation arithmetic

For a constant-product pair, moving the price by factor `k` requires committing
`r × (√k − 1)` of the input reserve. At the measured reserves, `k = 2`:

```
117.296 WETH × (√2 − 1) = 48.585 WETH ≈ $90,738   committed instantaneously
```

Sustaining that across a TWAP window costs materially more: arbitrageurs trade
against the manipulated price continuously and keep the difference.

Applied to `min()`:

| Direction | Cost | Attacker gains |
|---|---|---|
| Push **up** | ~$90.7k + sustained arb bleed | **nothing** — `min` selects the governance number |
| Push **down** | ~$90.7k + sustained arb bleed | `slashableBondUsd` halves → quorum needs ~2× stake → proposals stall for the window |

The residual attack is a **denial-of-service with no payoff**. That is strictly
a better failure than the status quo's silent overvaluation, which is
theft-enabling.

## Decisions

1. **`min`, never `max`, never replacement.** The TWAP may only lower the
   price. This is the invariant the whole design rests on; a future refactor
   that promotes the TWAP to a primary source re-opens a $219k-deep pool as the
   protocol's collateral valuation. Encode it as a spec requirement, not a
   comment.
2. **Staleness guard — REVISED by the emergency-only doctrine.** The original
   decision was "drop the `min`, fall back to the governance number", justified
   because that is today's behaviour and therefore fails *same*, not *worse*.

   **That justification does not survive the owner decision of 2026-08-01.** It
   assumed the governance number is a maintained, roughly-correct price. Under
   emergency-only operation it is deliberately set HIGH and left alone — so
   falling back to it on TWAP staleness would fail in exactly the dangerous
   direction, and worse, it would do so precisely when the market data stopped
   arriving.

   Revised behaviour: on TWAP staleness, keep serving the **last known good
   TWAP**, progressively haircut as it ages, and let the governance number act
   only as the hard ceiling it now is. Properties:

   - routine → TWAP binds, no human in the loop;
   - TWAP stale → last real market price, drifting conservative as it ages, so
     quorum gets *harder*, never easier;
   - emergency → the multisig slams `woodUsdPriceX8` down and the `min` caps
     everything at once.

   Reverting is still refused, for the original reason: it would let anyone
   halt the protocol by not running a keeper.

   **OPEN — needs an owner call.** What happens at the end of the decay, when
   the last good TWAP is too old to trust at any haircut? The candidates are
   (a) floor the decay and keep serving a heavily-discounted price forever,
   (b) stop admitting *new* coverage while leaving existing operations priced,
   or (c) fall through to the governance number and accept that the emergency
   lever must then be used as a price after all. (b) is the most honest —
   degrading capability rather than silently degrading a number — but it is a
   larger change and touches `requireApproveQuorum` rather than just pricing.
   Flagged rather than guessed.
3. **Window length: ≥ 1 hour, configurable, bounded.** The live risk is
   sustained down-manipulation, and cost scales with the window. Short windows
   are cheap to hold; excessively long ones stop tracking a real drawdown,
   which is what the ceiling is for. Bound the setter both ways.
4. **Permissionless `update()`.** Anyone may snapshot. This replaces a
   *judgment* keeper (a multisig choosing a number) with a *mechanical* one (a
   bot calling a function) — the point of the change. No access control, no
   discretion, no privileged keeper to compromise.
5. **Unwire must stay possible.** Mirror `setWoodFeed`'s zero-address unwire and
   its rationale: a bad oracle address must not be able to take the pricing
   path with it. `_woodPrice` already demonstrates the `code.length` +
   `try/catch` pattern this needs.
6. **USD leg via the existing ETH/USD Chainlink feed**, subject to the same
   staleness treatment as everything else. If that feed is stale, the TWAP is
   unavailable → ceiling skipped → governance number stands.

## Risks and preconditions

- ~~**The factory is not canonical Uniswap**~~ — **RESOLVED 2026-08-01, proven
  standard.** The factory (`0x8bcE…937f`) is not a Uniswap deployment, but the
  pair contract is byte-identical Uniswap V2. Proof by CREATE2 derivation:

  ```
  salt    = keccak(WETH ‖ WOOD)        = 0x4ae4de5c…9831
  init    = canonical UniswapV2Pair    = 0x96e8ac42…845f
  CREATE2(0x8bcE…937f, salt, init)     = 0xbf3bb81d…54c1
  actual deployed pair                 = 0xBF3BB81d…54C1     MATCH
  ```

  A CREATE2 address commits to the exact creation bytecode, so reproducing the
  live address from Uniswap's canonical init-code hash means the deployed
  contract came from byte-identical V2 pair code — forging it would require a
  keccak256 preimage collision. This is stronger than reading verified source.
  Corroborated by the 11,293-byte runtime (right size for `UniswapV2Pair`) and
  by an encoding sanity check: `price0CumulativeLast / (spot × 2^112)` implies
  a pair age of ~8.8 days, which is plausible and would be absurd under any
  other fixed-point format.

  Therefore confirmed: `_update` advances the accumulator on the first
  interaction per block, cumulatives are UQ112x112, `blockTimestampLast` wraps
  at 2^32, standard 0.3% fee. Only residual is a metamorphic redeploy
  (selfdestruct + re-CREATE2), which `UniswapV2Pair` cannot do — it contains no
  `SELFDESTRUCT`, and post-EIP-6780 it would not clear code regardless.
- **Quiet-pair degradation.** The standard `currentCumulativePrices` helper
  extrapolates the gap since the last interaction using *current spot*. The
  pair is presently traded every few seconds so this is inert — but a long
  quiet stretch degrades the TWAP toward spot, which is the manipulable
  quantity. The staleness bound must be tight enough that a dead pair becomes
  *unavailable* rather than silently becoming a spot oracle.
- **Depth vs. exposure.** $219k per side against coverage that may reach
  millions. Tolerable only because the ceiling is one-directional. This is the
  concrete reason decision 1 is an invariant.
- **New audit surface pre-launch.** A new contract in the pricing path competes
  with launch work. `woodHaircutBps` (see proposal ship-order note) is the
  zero-code mitigation available immediately; this change is the follow-on.

## Alternatives considered

- **Governance number alone (status quo).** No griefing vector, but silent
  overvaluation is theft-enabling and the `usingFallback` alarm is nulled.
- **TWAP as the primary price.** Rejected: a $438k pool would become the
  valuation basis for the entire guardian collateral model.
- **Deviation check instead of a ceiling** (reject a governance number that
  strays from the TWAP beyond a threshold). Equivalent protection in the
  dangerous direction but adds a revert path — and reverting inside
  `_woodPrice` is exactly what `setWoodFeed`'s unwire rationale exists to
  prevent.
- **Seeding a V3 pool to grow cardinality.** Rejected: it means creating the
  oracle venue ourselves, thinner than the existing V2 pair, with the same
  one-directional caveat and additional capital cost.
