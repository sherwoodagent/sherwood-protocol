## 1. Portfolio $1 asset binding (FP-01)

- [x] 1.1 `_initialize` binds `asset_` to the vault's ERC4626 asset (`AssetNotVaultAsset`).
- [x] 1.2 `_initialize` and `_execute` require the ledger to price one asset unit within ±1% of $1, fail closed (`ExposureLedgerUnresolved`, `AssetNotUsdPegged`); settle and `rebalanceDelta` are not gated.
- [x] 1.3 Regression test `test/audit-fixes/PortfolioStrategy_usdPeggedAsset.t.sol`; Portfolio fixtures that used a WETH asset move to a $1 asset priced by a ledger stub.
