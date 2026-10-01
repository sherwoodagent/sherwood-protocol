## 1. Asset batch surface (V1-01)

- [x] 1.1 `AssetCallRules.spenderOf` admits only `transfer`, `transferFrom` from the vault and the approve family; other selectors revert `UnrecognizedAssetSelector`.
- [x] 1.2 `ISyndicateVault.UnrecognizedAssetSelector(bytes4)`.
- [x] 1.4 `structural-batch-rules` asset requirement amended in place (no dangling MODIFIED).
- [x] 1.3 Regression test `test/audit-fixes/AssetCallRules_v101UnrecognizedSelector.t.sol`; `StructuralBatchRules.t.sol` tests that pinned the open rule changed direction.

## 2. Morpho market counterparties (V1-04)

- [x] 2.1 CL: oracle bound at init and in `_requireCounterpartiesStillAllowed`.
- [x] 2.2 Supply: oracle and non-asset collateral bound at init and at execute.
- [x] 2.3 Regression test `test/audit-fixes/MorphoMarket_v104OracleBinding.t.sol`; fixtures allowlist the oracle and collateral.

## 3. CL venue binding and rerange floor (V1-07, V2-03)

- [x] 3.1 `positionManager.factory() == uniswapFactory` at init.
- [x] 3.2 Rerange trigger threshold floored at one tick spacing in `_requireTriggerReached`.
- [x] 3.3 Regression tests `test/audit-fixes/CLStrategy_v107PmFactoryBinding.t.sol`, `test/audit-fixes/CLStrategy_v203RerangeTriggerFloor.t.sol`; fork-test first reranges given at least one spacing of TWAP travel.
