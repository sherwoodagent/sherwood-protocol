# Morpho markets allowlisted by id; CL settle slippage fixed at init (audit 2026-10-02 FP-02, FP-06)

## Why

- **FP-02 (Medium, dormant).** Both Morpho strategies admitted a market when its oracle, and (supply) its collateral, were individually allowlisted counterparties. Nothing tied the oracle to the collateral, and `irm` and `lltv` were never checked. From the parts the runbook allowlists, a proposer could build a loan == collateral market priced by the spUSDG oracle, or a correctly paired market with `irm == 0`, and freeze the vault's whole supply (verdict N-04). It also closes FP-25 in practice: only a vetted market, whose oracle prices its collateral at the wrapper's rate, can reach the CL leverage gate.
- **FP-06 (Medium, dormant).** The CL proposer could lower `settleSlippageBps` after execute down to 1 bp. A settle swap at the 10% pool-share cap costs about 54 bp, so every settle route then reverted and the LP position and Morpho collateral stayed on the clone (verdict N-01). A floor alone does not fix it: a ratchet down to the floor still bricks settle at the cap.

## What Changes

- `TierRegistry` gains an appended `mapping(bytes32 => bool)`, an owner-only `setMorphoMarketAllowed(bytes32 id, bool allowed)` emitting `MorphoMarketAllowedSet`, and the view `isMorphoMarketAllowed(bytes32 id)` (also on `ITierRegistry`). The registry is a plain create3 deployment, not a proxy.
- `MorphoSupplyStrategy` and the Morpho leg of `ConcentratedLiquidityStrategy` replace the separate oracle and collateral counterparty checks with one check that the market id (`MarketParamsLib.id`, all five fields) is allowlisted, read fail-closed, at init and again at execute (and at CL `rerange`). Refusal is `MorphoMarketNotAllowed(marketId, registry)`. The Morpho singleton check, the other CL counterparty checks and the CL rule that collateral is the vault asset or its wrapper are unchanged. Settle is not gated. `MorphoSupplyStrategy.CounterpartyNotAllowed` is removed (no remaining use).
- `ConcentratedLiquidityStrategy`: `settleSlippageBps` must be at least `MIN_SETTLE_SLIPPAGE_BPS = 50` at init, and `updateParams` reverts `ImmutableParam` for any non-zero slippage that differs from the stored value. The settle deadline stays tunable.

## Spec deltas

- ADDED here: the `tier-policy` Morpho-market allowlist requirement.
- Amended in place, not MODIFIED here, so the changes archive in any order (the precedent `audit-1001-containment` set): the `deployment-docs` requirement in `audit-1001-containment` (renamed to the market-id rule) and the `concentrated-liquidity-strategy` tunables requirement in `concentrated-liquidity-strategy`. Neither has reached `openspec/specs/` yet.

## Impact

- `src/TierRegistry.sol`, `src/interfaces/ITierRegistry.sol`, `src/strategies/MorphoSupplyStrategy.sol`, `src/strategies/ConcentratedLiquidityStrategy.sol`. No change to any init-data ABI or existing external signature; no storage change in a proxied contract.
- Operations: before a Morpho-supply or CL clone-init, the registry owner calls `setMorphoMarketAllowed(<id>, true)` after reading the market's five parameters from Morpho. For the known 4663 USDG market: `setMorphoMarketAllowed(0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114, true)`. Per-address oracle and collateral grants no longer admit a Morpho market. The deploy ceremony is unchanged.
