// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IMorpho, IIrm, Id, MarketParams, Market} from "./IMorpho.sol";

/// @title  Vendored Morpho Blue math + periphery accounting
/// @notice Provenance (GPL-2.0-or-later, no behavioral changes):
///           - `MathLib`         ← morpho-org/morpho-blue `src/libraries/MathLib.sol`
///           - `SharesMathLib`   ← morpho-org/morpho-blue `src/libraries/SharesMathLib.sol`
///           - `MarketParamsLib` ← morpho-org/morpho-blue `src/libraries/MarketParamsLib.sol`
///           - `MorphoBalancesLib` ← morpho-org/morpho-blue periphery
///             `src/libraries/periphery/MorphoBalancesLib.sol`
///         Reimplemented locally so valuation has no runtime dependency beyond
///         the canonical singleton itself (design decision D6). Differences
///         from upstream are cosmetic only: accrual math runs in uint256 locals
///         instead of `toUint128`-checked struct fields (identical results for
///         any state the singleton can hold, since it enforces uint128 bounds),
///         and `MarketParamsLib.id` uses `keccak256(abi.encode(...))` instead
///         of upstream's equivalent hand-rolled assembly.

/// @notice WAD fixed-point + Taylor-series helpers (Morpho `MathLib`).
library MathLib {
    uint256 internal constant WAD = 1e18;

    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    /// @dev 3rd-order Taylor expansion of e^(x*n) - 1, Morpho's continuous-
    ///      compounding approximation for a per-second rate `x` over `n`
    ///      seconds: x*n + (x*n)^2/2e18 + (x*n)^3/6e36.
    function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }
}

/// @notice Supply/borrow share conversion with virtual offsets (Morpho
///         `SharesMathLib`). The virtual liquidity makes empty-market rates
///         well-defined and blunts share-price inflation attacks.
library SharesMathLib {
    using MathLib for uint256;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivDown(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivDown(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivUp(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivUp(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}

/// @notice `MarketParams → Id` derivation (Morpho `MarketParamsLib`).
library MarketParamsLib {
    function id(MarketParams memory marketParams) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(marketParams)));
    }
}

/// @notice View-side interest accrual (port of Morpho periphery
///         `MorphoBalancesLib`): reproduces exactly what the singleton's
///         `_accrueInterest` will write on the next state-touching call, so a
///         view valuation matches the assets a same-block withdraw delivers.
library MorphoBalancesLib {
    using MathLib for uint256;
    using SharesMathLib for uint256;

    /// @notice Market totals as they would stand after accruing pending
    ///         interest at `block.timestamp`.
    /// @dev    Faithful to the singleton: interest = totalBorrowAssets *
    ///         taylor(borrowRateView * elapsed), added to BOTH supply and
    ///         borrow totals; a nonzero fee additionally mints fee shares
    ///         (diluting the fee out of suppliers' share price exactly as the
    ///         singleton does).
    function expectedMarketBalances(IMorpho morpho, MarketParams memory marketParams)
        internal
        view
        returns (
            uint256 totalSupplyAssets,
            uint256 totalSupplyShares,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares
        )
    {
        Id marketId = MarketParamsLib.id(marketParams);
        Market memory market = morpho.market(marketId);

        totalSupplyAssets = market.totalSupplyAssets;
        totalSupplyShares = market.totalSupplyShares;
        totalBorrowAssets = market.totalBorrowAssets;
        totalBorrowShares = market.totalBorrowShares;

        uint256 elapsed = block.timestamp - market.lastUpdate;
        // Match upstream `MorphoBalancesLib`/`Morpho._accrueInterest`: a market
        // with `irm == address(0)` is a valid zero-rate market that accrues no
        // interest. Without this guard a codeless-address call reverts, which
        // would silently disable Lane A pricing for the whole vault the moment
        // any third party borrows a single wei from such a market.
        if (elapsed != 0 && totalBorrowAssets != 0 && marketParams.irm != address(0)) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, market);
            uint256 interest = totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            totalBorrowAssets += interest;
            totalSupplyAssets += interest;

            if (market.fee != 0) {
                uint256 feeAmount = interest.wMulDown(market.fee);
                // Fee shares are priced against totals excluding the fee
                // amount itself, matching the singleton.
                uint256 feeShares = feeAmount.toSharesDown(totalSupplyAssets - feeAmount, totalSupplyShares);
                totalSupplyShares += feeShares;
            }
        }
    }

    /// @notice `user`'s supply shares converted to loan-token assets over the
    ///         interest-accrued totals, rounding down (redeemable value).
    function expectedSupplyAssets(IMorpho morpho, MarketParams memory marketParams, address user)
        internal
        view
        returns (uint256)
    {
        Id marketId = MarketParamsLib.id(marketParams);
        uint256 supplyShares = morpho.position(marketId, user).supplyShares;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = expectedMarketBalances(morpho, marketParams);
        return supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }
}
