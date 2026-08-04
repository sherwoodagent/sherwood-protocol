// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  Vendored Morpho Blue types + minimal interfaces
/// @notice Provenance: morpho-org/morpho-blue `src/interfaces/IMorpho.sol` and
///         `src/interfaces/IIrm.sol` (GPL-2.0-or-later), reduced to the surface
///         Sherwood consumes: single-market supply/withdraw plus the view state
///         needed for share→asset valuation. No behavioral changes — struct
///         field order and widths are byte-identical to the canonical singleton
///         (verified against the live contract on Robinhood Chain 4663 at
///         `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` in
///         `MorphoSupplyMainnetFork.t.sol`).

/// @notice Market id: `keccak256(abi.encode(MarketParams))`.
type Id is bytes32;

/// @notice The five parameters that fully identify a Morpho Blue market.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Per-user position in a market. Named `Position` upstream — import
///         with an alias where it would clash with Sherwood's pricing
///         `Position` struct.
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice Aggregate market state. `totalSupplyAssets`/`totalBorrowAssets`
///         grow with interest accrual; `fee` is a WAD fraction of interest
///         minted to the fee recipient as supply shares.
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

/// @notice Minimal Morpho Blue singleton interface (supply side only).
interface IMorpho {
    function market(Id id) external view returns (Market memory m);
    function position(Id id, address user) external view returns (Position memory p);
    function idToMarketParams(Id id) external view returns (MarketParams memory marketParams);

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function accrueInterest(MarketParams memory marketParams) external;
}

/// @notice Morpho Blue interest rate model, view side.
interface IIrm {
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256);
}
