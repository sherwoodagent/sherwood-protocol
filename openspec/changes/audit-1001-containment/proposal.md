# Audit 2026-10-01 containment fixes (V1-01, V1-04, V1-07, V2-03)

## Why

- **V1-01 (High).** `structural-batch-rules` treated every non-transfer call on the asset as allowance-shaped, without enumerating selectors. The launch asset (Paxos-shaped USDG) exposes `transferFromBatch(from[], to[], value[])`, which spends `msg.sender`'s allowance from each `from[i]`. Admitted as "allowance-shaped", a batch could move a depositor's undeposited wallet balance through their standing deposit allowance to the vault, unseen by every meter and priced at zero coverage. Any token extension can do the same, so the asset surface is closed to a named set.
- **V1-04 (Medium).** Both Morpho strategies took `marketParams.oracle` (and, in the supply strategy, `collateralToken`) from the proposer unchecked. Morpho Blue market creation is permissionless, so a proposer could point the vault at a market priced by its own oracle.
- **V1-07 (Low).** The CL strategy anchored the pool to whichever allowlisted factory the proposer named, not the position manager's own factory, so the pool-share cap and TWAP check could be read on one venue while the mint landed in another.
- **V2-03 (Low).** A rerange policy with `halfWidthTicks × triggerBps < 10_000` floors the trigger threshold to zero ticks, making the whole rerange budget spendable on demand.

## What Changes

- **BREAKING (asset batch surface)** `AssetCallRules.spenderOf` admits only `transfer`, `transferFrom` whose first argument is the vault, and the approve family (`approve`, `increaseAllowance`, `increaseApproval`, `decreaseAllowance`, `decreaseApproval`). Every other selector, reads included, reverts `UnrecognizedAssetSelector(selector)` before any call executes. The governor's propose-time mirror calls the same predicate, so a leg that proposes cannot revert at execute or settle on this rule. This reverses the "no selector enumerated" decision of `structural-batch-rules` (archive that change first).
- `ConcentratedLiquidityStrategy` requires `marketParams.oracle` to be an allowed counterparty at init and re-checks it at `execute()` and `rerange()`. `MorphoSupplyStrategy` requires the oracle, and the collateral token unless it equals the vault asset, at init and at `execute()` (`CounterpartyNotAllowed(counterparty, registry)`). Settle paths are not gated. A no-collateral market (`oracle == address(0)`) is refused unless `address(0)` is allowlisted.
- `ConcentratedLiquidityStrategy._initialize` requires `positionManager.factory() == uniswapFactory` (`PoolNotFromFactory`).
- `_requireValidRerangePolicy` requires `halfWidthTicks × triggerBps >= 10_000` (`InvalidRerangePolicy`).

## Impact

- `src/AssetCallRules.sol`, `src/interfaces/ISyndicateVault.sol` (new error), `src/strategies/ConcentratedLiquidityStrategy.sol`, `src/strategies/MorphoSupplyStrategy.sol` (new error). No storage change.
- Operations: before any Morpho-supply or CL clone-init, the registry owner allowlists the market's oracle (and, for supply, its non-asset collateral) with `setCounterpartyAllowed`.
