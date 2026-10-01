# Audit 2026-10-01 containment fixes (V1-01, V1-04, V1-07, V2-03)

## Why

- **V1-01 (High).** `structural-batch-rules` treated every non-transfer call on the asset as allowance-shaped, without enumerating selectors. The launch asset (Paxos-shaped USDG) exposes `transferFromBatch(from[], to[], value[])`, which spends `msg.sender`'s allowance from each `from[i]`. Admitted as "allowance-shaped", a batch could move a depositor's undeposited wallet balance through their standing deposit allowance to the vault, unseen by every meter and priced at zero coverage. Any token extension can do the same, so the asset surface is closed to a named set.
- **V1-04 (Medium).** Both Morpho strategies took `marketParams.oracle` (and, in the supply strategy, `collateralToken`) from the proposer unchecked. Morpho Blue market creation is permissionless, so a proposer could point the vault at a market priced by its own oracle.
- **V1-07 (Low).** The CL strategy anchored the pool to whichever allowlisted factory the proposer named, not the position manager's own factory, so the pool-share cap and TWAP check could be read on one venue while the mint landed in another.
- **V2-03 (Low).** The rerange trigger threshold could round below one tick spacing. A re-snapped range sits up to spacing/2 off the TWAP and the TWAP does not move inside a transaction, so a sub-spacing threshold let one caller repeat `rerange()` until `maxReranges`.

## What Changes

- **BREAKING (asset batch surface)** `AssetCallRules.spenderOf` admits only `transfer`, `transferFrom` whose first argument is the vault, and the approve family (`approve`, `increaseAllowance`, `increaseApproval`, `decreaseAllowance`, `decreaseApproval`). Every other selector, reads included, reverts `UnrecognizedAssetSelector(selector)` before any call executes. The governor's propose-time mirror calls the same predicate, so a leg that proposes cannot revert at execute or settle on this rule. This reverses the "no selector enumerated" decision of `structural-batch-rules`; that change's (unarchived) requirement is amended in place rather than MODIFIED here, so the two changes archive in either order.
- `ConcentratedLiquidityStrategy` requires `marketParams.oracle` to be an allowed counterparty at init and re-checks it at `execute()` and `rerange()`. `MorphoSupplyStrategy` requires the oracle, and the collateral token unless it equals the vault asset, at init and at `execute()` (`CounterpartyNotAllowed(counterparty, registry)`). Settle paths are not gated. A market with `oracle == address(0)` is refused; never allowlist `address(0)` (the registry would accept it and it would weaken every counterparty check).
- `ConcentratedLiquidityStrategy._initialize` requires `positionManager.factory() == uniswapFactory` (`PoolNotFromFactory`).
- `_requireTriggerReached` floors the trigger threshold at one tick spacing, so a second rerange in the same transaction always reverts `RerangeTriggerNotReached`.

## Impact

- Specs: the `syndicate-vault` asset-rule requirement is amended inside `structural-batch-rules`; this change ADDS the `deployment-docs` oracle/collateral requirement.
- `src/AssetCallRules.sol`, `src/interfaces/ISyndicateVault.sol` (new error), `src/strategies/ConcentratedLiquidityStrategy.sol`, `src/strategies/MorphoSupplyStrategy.sol` (new error). No storage change.
- Operations: before any Morpho-supply or CL clone-init, the registry owner allowlists the market's oracle (and, for supply, its non-asset collateral) with `setCounterpartyAllowed`.
