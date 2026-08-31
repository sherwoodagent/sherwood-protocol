# Proposal: BasisArbStrategy — cross-venue triangular basis template

## Why

The Sherwood datanet's most structurally interesting pod ("GME/gme Bankr Arb")
described a real category of trade — a tokenized RWA priced against its meme
twin on Bankr, arbitraged against the RWA's USDG venue — but its referenced
venue was fabricated: the named Bankr GME/gme pool does not exist on chain
(codeless address, and the pod's `pool_url` resolves to a USDG/WETH pool).

Probing Robinhood Chain mainnet (4663, 2026-08-31) showed the pattern is real
on a different pair, at ~10x the claimed liquidity:

| leg | venue | pool | measured |
|---|---|---|---|
| AI/NVDA | Bankr (Uniswap v4 hook) | id `0xcbdf…ce27` in PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951` | $12.4M TVL, $2.7M/day, 70bps dynamic fee |
| NVDA/USDG 0.05% | Uniswap v3 | `0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3` | $1.4M TVL, $8.1M/day |
| AI/WETH 1% | Uniswap v3 | `0xc4a21f9d6485fc5893dd4a491b320a83daf4da1d` | $1.2M TVL, $9.3M/day |
| USDG/WETH 0.01% | Uniswap v3 | `0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca` | $6.9M TVL |

Two AI→USDG routes exist (via NVDA on Bankr, via WETH on v3). Their price gap
is a pure on-chain-observable basis — no oracle dependency at all.

No existing template can express this: `ConcentratedLiquidityStrategy` and
`MorphoSupplyStrategy` are single-venue position holders;
`PortfolioStrategy` rebalances against oracle marks, not venue-vs-venue.
Per-trade sandbox proposals cannot express it either — propose→execute is
~30h of governance latency against a basis that lives minutes.

## The economics gate (open, and load-bearing)

Live same-block sampling (`~/.sherwood/ai-nvda-basis/samples2.csv`, 30s
cadence) shows the basis oscillating ±60bps around zero against a structural
fee floor of ~176bps (70 Bankr + 100 AI/WETH + 5 NVDA/USDG + 1 USDG/WETH).
A traced Bankr swap was itself an aggregator routing this exact triangle:
professional flow already compresses the spread.

**Ship-gate: implementation may merge, but the template is only proposed to a
live vault if the sampled distribution shows |basis| > fee floor + 30bps
slippage margin in ≥ 0.5% of samples over ≥ 7 days.** Otherwise the template
stays shelved as infrastructure for the next pair Bankr lists (the dex's
roster — SAYLORMOON/MSTR, EARN/SPY, DOGGIE/TSLA — keeps minting candidates).
The strategy contract is pair-agnostic by construction for exactly this
reason: legs are `init` parameters, not constants.

## What changes

- New strategy template `BasisArbStrategy` (clone-per-proposal, like the
  existing templates), registered on the `StrategyFactory` allowlist.
- v1 is an **inventory triangle**: hold vault asset, and on each poke execute
  buy-cheap-route / sell-rich-route atomically, ending flat in the vault
  asset. No Morpho borrow leg (the pod's USDe loop adds a liquidation surface
  for ~20bps of carry — deferred to a v2 if ever).
- Permissionless `pokeArb()` in the mold of `ConcentratedLiquidityStrategy.
  rerange()`: the CONTRACT verifies the trigger (live two-route basis exceeds
  `minBasisBps`, which must itself exceed the summed pool fees) and bounds
  the trade (`maxTradeNotional`, slippage floor on the output leg). Anyone
  may call; calling when the basis is thin reverts.
- Guardian chain-book additions (sherwood-guardian, separate PR): the v4
  PoolManager and Universal Router as known targets, so proposals naming this
  template survive the fleet's unknown-counterparty rules.

## Non-goals

- No Morpho leverage leg (v2 candidate, separate proposal).
- No keeper/off-chain executor in this repo — pokes are permissionless; the
  orquestra adapter may poke, but nothing here depends on it.
- No new oracle plumbing: the basis is defined entirely by pool state, and
  spot-manipulation risk is bounded by atomicity + slippage bounds (a
  manipulated read can only cause a revert or a still-profitable fill).
- Not fixing the datanet's fabricated-evidence pod (tracked separately).

## Capabilities touched

- `basis-arb-strategy` (new): the template's behavior.
- `strategy-factory` (delta): one new allowlisted template entry.
