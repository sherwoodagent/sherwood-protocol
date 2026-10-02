## ADDED Requirements

### Requirement: The Portfolio strategy only initialises and executes on a vault asset the ledger prices at $1

`PortfolioStrategy` floors every swap at a TOKEN/USD feed price converted straight into asset units, which is correct only when one unit of the asset is worth $1. `_initialize` SHALL require `asset_ == IERC4626(vault()).asset()` and revert `AssetNotVaultAsset(asset, vaultAsset)` otherwise.

`_initialize` and `_execute` SHALL resolve the exposure ledger through `vault() → governor() → exposureLedger()`, each hop a length-checked raw staticcall, and SHALL read `coverageUsd(asset, 10 ** assetDecimals)`. The result SHALL lie within `PEG_TOLERANCE_BPS = 100` of `1e18`, bounds inclusive. The check SHALL fail closed: an unresolved ledger reverts `ExposureLedgerUnresolved()`; an asset the ledger cannot price (`FeedNotConfigured`), a stale feed, or a price outside the band reverts `AssetNotUsdPegged(asset, usdPerUnit)`. A ledger feed alone SHALL NOT admit a non-dollar asset: the band, not the feed's presence, is the test.

`settle` and `rebalanceDelta` SHALL NOT run this check, so a depeg or an unwired ledger never blocks an exit.

#### Scenario: Non-dollar vault asset with a ledger feed
- **WHEN** a Portfolio clone is initialised on a WETH vault whose ledger prices WETH at $3,000
- **THEN** clone-init reverts `AssetNotUsdPegged(WETH, 3000e18)`

#### Scenario: Asset argument differs from the vault asset
- **WHEN** the init data names an asset other than the vault's ERC4626 asset
- **THEN** clone-init reverts `AssetNotVaultAsset(asset, vaultAsset)`

#### Scenario: Asset depegs between init and execute
- **WHEN** the ledger prices one asset unit outside $0.99–$1.01 at `execute()`
- **THEN** `execute()` reverts `AssetNotUsdPegged` and no vault funds move

#### Scenario: Asset depegs after execute
- **WHEN** the asset drifts outside the band, or the ledger is unwired, after `execute()`
- **THEN** `settle()` and `rebalanceDelta()` still run
