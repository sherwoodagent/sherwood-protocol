# Concentrated-Liquidity LP Strategy Template

## Why

Sherwood ships two strategy templates: `MorphoSupplyStrategy` (supply one lending market) and `PortfolioStrategy` (swap/rebalance an allocation). Neither can express a market-making position, so the most common proposal shape on the Sherwood Trading Strategies datanet — provide concentrated liquidity to a tokenized-equity/USDG pool, funding the second leg by borrowing the stable rather than buying the volatile asset — is proposable but not executable. Agents can describe the strategy; the vault cannot run it.

Live venue data on Robinhood Chain (measured 2026-08-04) shapes the design and makes the guards non-optional:

- **The borrow leg is real and deep.** Morpho Blue chain 4663 has 68 markets; `spUSDG → USDG` at 91.5% LLTV carries $1.19M lendable at ~3.0% borrow APY (`syrupUSDG` $6.17M, `USDe` $20.15M, both 91.5%). Stable-wrapper collateral is where the depth is.
- **Equity collateral is dust.** NVDA/AAPL/TSLA/GOOGL markets exist at 62.5–86% LLTV with $0–$1.6k lendable. "Collateralize a stock token at size" is not executable on this chain.
- **RWA LP pools are thin and volatile in depth.** The deepest tokenized-equity/USDG pool on the chain is NVDA/USDG 0.05% at $820k TVL, with 24h volume ranging $0.65M–$15.5M over 14 days. A position sized as a free parameter rather than a share of measured depth becomes the pool.

A template that trusts a proposer's numbers unconditionally would let a single proposal take a 43%-of-pool position against a decaying venue. The guards below exist because that is the realistic failure, not a hypothetical one.

## What Changes

- **New strategy template `ConcentratedLiquidityStrategy`**, cloned per proposal via `StrategyFactory`, implementing `IStrategy` on `BaseStrategy`:
  - `execute()` — pull the vault asset, post it (or its configured yield-bearing wrapper) as Morpho collateral, borrow the quote leg, and mint one concentrated-liquidity position over a fixed tick range in a fixed pool.
  - `settle()` — burn the position, collect accrued fees, repay the borrow in full, withdraw collateral, and push the entire vault-asset balance back to the vault.
- **Init-time feasibility validation**, in the `MorphoSupplyStrategy` precedent's adversary order: the pool must exist and quote the vault asset; the Morpho market must exist and lend the vault asset; the requested borrow must fit the market's current lendable liquidity; the target LTV must clear the market's own LLTV by a fixed buffer; the position must not exceed a configured share of pool liquidity.
- **Execute-time price validation** — spot must sit within a bounded deviation of the pool TWAP before minting, so a proposal cannot be executed into a manipulated tick.
- **Permissionless, fully-determined reranging** — the approved policy (half-width, trigger fraction, minimum interval, maximum count, slippage floor) is fixed at initialization; a rerange re-centers the band on the current TWAP tick by formula, so no caller chooses the resulting range and anyone may trigger one once the conditions hold.
- **Bounded tunables via `updateParams`** — slippage floors and the settlement deadline are tunable by the proposer between execute and settle; the pool, market, sizes, active range, and the whole rerange policy are not.
- **Deliverable-maximum settlement**, mirroring `MorphoSupplyStrategy._settle`: when the borrow cannot be fully repaid or collateral cannot be fully withdrawn in one call, settle takes the deliverable maximum, emits a loud incomplete-settlement event, and leaves the residue recoverable through a permissionless post-settlement `sweep()`.
- **Deploy-ceremony registration** — a new script deploys the template and the owner approves it on `StrategyFactory`, extending the documented post-deploy validation reads.

No breaking changes: the template is additive, and existing clones, templates, and vault batches are untouched.

## Capabilities

### New Capabilities
- `concentrated-liquidity-strategy`: the CL LP + borrowed-leg strategy template — lifecycle (initialize/execute/settle/sweep), the feasibility and price guards that bound a proposer's parameters, position custody and fee accounting, and the incomplete-settlement recovery path.

### Modified Capabilities
- `deployment-docs`: the deploy ceremony gains a fourth script deploying the `ConcentratedLiquidityStrategy` template plus its position-manager wiring, and the post-deploy validation reads gain an approved-template assertion for it.

## Impact

**New code**
- `src/strategies/ConcentratedLiquidityStrategy.sol` — the template.
- `src/vendor/uniswap/` — minimal `INonfungiblePositionManager` / `IUniswapV3Pool` interfaces, following the existing `src/vendor/morpho/` vendoring pattern and the vendor manifest.
- `script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol`.
- `test/strategies/ConcentratedLiquidityStrategy.t.sol` plus a block-pinned fork test (excluded from the default CI job, per the fork-test convention).

**Touched code**
- `openspec/specs/deployment-docs/spec.md` — ceremony order and validation reads.
- `lib/VENDOR-MANIFEST.json` — new vendored Uniswap interfaces.

**Dependencies**
- Morpho Blue singleton on chain 4663 (already vendored and used by `MorphoSupplyStrategy`).
- A Uniswap V3-compatible position manager on Robinhood Chain. `PortfolioStrategy` already integrates `UniswapSwapAdapter` (v3+v4) per the deploy ceremony, so the swap surface is precedented; the position-manager surface is new and must be address-verified on-chain before the template is approved.

**Contract size** — Robinhood Chain's 98,304-byte limit leaves ample headroom; the legacy Base deployment is out of scope for this template.

**Tier and allowlist** — clones are uncertified and therefore tier 2 (`TIER_ARBITRARY`, full notional), matching existing strategy clones; guardian coverage is priced accordingly. Operationally the binding gate is the allowlist, not the tier: each clone needs an owner `setAdapterAllowed(clone, true)` before its batch can execute, and with `rerange()` the clone must stay allowlisted for the whole strategy period rather than only across execute and settle.

**Not in scope** — vault-side NAV pricing of a live LP position. This template holds custody and returns the vault asset on settlement, matching `MorphoSupplyStrategy`'s existing custody shape, so `epoch-nav` requirements are unchanged. Marking an open CL position to market for mid-proposal NAV is a separate change.
