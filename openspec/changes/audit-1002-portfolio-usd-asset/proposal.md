# Audit 2026-10-02: bind the Portfolio strategy to a $1 vault asset (FP-01)

## Why

- **FP-01 (High, dormant).** `PortfolioStrategy` prices every swap floor as if one unit of its asset were worth $1: the feeds are TOKEN/USD and `_tokensToValue` / `_valueToTokens` convert straight into asset units. Nothing enforced that assumption, and `_initialize` never checked `asset_` against the vault's asset. On a vault whose asset is not a dollar (WETH at $3,000), the buy floor sits about 3,000x below fair, so an outsider can sandwich `execute` (permissionless through `executeProposal`) and take almost the whole allocation; the sell floor sits about 3,000x above fair, so `settle` cannot clear. Dormant at launch because the only vault asset is USDG, but nothing in the code kept it that way.

## What Changes

- `PortfolioStrategy._initialize` requires `asset_ == IERC4626(vault()).asset()` (`AssetNotVaultAsset(asset, vaultAsset)`).
- `_initialize` and `_execute` read `coverageUsd(asset, 10 ** assetDecimals)` from the exposure ledger reached through `vault() → governor() → exposureLedger()` (the same hardened walk the file uses for `tierRegistry()`) and require it within `PEG_TOLERANCE_BPS = 100` (±1%, inclusive) of `1e18`. An unresolved ledger reverts `ExposureLedgerUnresolved()`; an unpriced asset, a stale feed or a price outside the band reverts `AssetNotUsdPegged(asset, usdPerUnit)`.
- `settle` and `rebalanceDelta` are not gated: an exit is never blocked by this check.
- No init-data ABI change, no new external function, no storage change, no ceremony change (USDG already has a ledger asset feed).

## Impact

- Specs: ADDS a `portfolio-strategy` requirement.
- `src/strategies/PortfolioStrategy.sol` only.
- Operations: a vault whose asset the ledger does not price at $1 cannot run the Portfolio strategy, even after the ledger owner gives that asset a feed.
