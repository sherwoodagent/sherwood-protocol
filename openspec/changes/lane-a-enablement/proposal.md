# Lane A Enablement

## Why

The instant-liquidity lane (Lane A) is fully specced and wired — PriceRouter, per-kind adapters, vault-side live NAV, fail-closed degradation — but it is dark in production: no `IPriceAdapter` implementation exists in `src/`, and no strategy overrides `BaseStrategy`'s empty `positions()` default. Every syndicate today is queue-only (Lane B). Enabling Lane A on Robinhood Chain turns "instant entry/exit during an active proposal" from spec text into a live product property, starting with the venues where positions are safely priceable on-chain: tokenized-stock spot baskets (Chainlink feeds) and Morpho Blue USDG supply (pure view accounting).

## What Changes

- New `Erc20SpotAdapter` — first production `IPriceAdapter`. Prices `ERC20_SPOT` positions as `token.balanceOf(holder)` × Chainlink push-feed price, with staleness and sanity gates; anything off returns `ok = false` (fail-closed to Lane B).
- `PortfolioStrategy` becomes Lane-A-capable: overrides `positions()` (one `ERC20_SPOT` position per basket slot), `availableLiquidity()` (quote-based sellable value), and `withdrawTo()` (same-tx unwind of exactly the shortfall via the existing swap-adapter path).
- New `MorphoSupplyStrategy` — supplies the vault asset (USDG) to a Morpho Blue market; positions priced by a new `MorphoSupplyAdapter` via pure view share→asset conversion; instant liquidity up to the market's available liquidity. Simplest possible Lane A strategy and proof-of-life for the whole path.
- Haircut/arbitrage analysis — quantifies the oracle-price vs. execution-price gap an instant exit imposes on remaining LPs, and derives recommended per-kind `haircutBps` and `instantCap` values from real Robinhood DEX depth. Deliverable is parameter recommendations plus adversary-cost bounds, recorded in design and operator docs.
- Governance/ops wiring documentation: adapter registration, `setLaneAEnabled`, haircut and cap setting for the two new kinds.

Non-goals: perps venues (Lighter) — structurally unpriceable on-chain, stays Lane B; Uniswap LP positions — deferred (TWAP/deviation machinery is its own change).

## Capabilities

### New Capabilities

- `erc20-spot-pricing`: behavior of the `Erc20SpotAdapter` — quantity read from venue, Chainlink push-feed pricing, staleness/deviation gates, fail-closed semantics, decimal handling.
- `portfolio-strategy-lane-a`: Lane A surface of `PortfolioStrategy` — `positions()` enumeration, `availableLiquidity()` quoting, `withdrawTo()` shortfall unwind and delivery verification, interaction with rebalance-in-progress states.
- `morpho-supply-strategy`: the Morpho Blue supply strategy and its adapter — supply/withdraw lifecycle, view-only valuation, liquidity capped by market state, settle behavior.

### Modified Capabilities

<!-- None. Lane A vault/router behavior (epoch-nav, syndicate-vault) is already
     specced and unchanged; this change supplies the first conforming
     implementations and their parameters. -->

## Impact

- New contracts: `src/pricing/Erc20SpotAdapter.sol`, `src/pricing/MorphoSupplyAdapter.sol`, `src/strategies/MorphoSupplyStrategy.sol`.
- Modified: `src/strategies/PortfolioStrategy.sol` (positions/liquidity overrides — additive, no change to execute/settle/rebalance behavior).
- No changes to `SyndicateVault`, `PriceRouter`, or governor contracts — they already consume this surface.
- New external dependency: Morpho Blue on Robinhood Chain (`0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`); Chainlink push feeds for tokenized stocks (already a `PortfolioStrategy` dependency).
- Ops: PriceRouter owner must register adapters and enable kinds before any Lane A effect; parameters (haircuts, caps) come from the analysis workstream.
- Equity-market-hours side effect: stale equity feeds outside trading hours close Lane A automatically (by design, fail-closed).
