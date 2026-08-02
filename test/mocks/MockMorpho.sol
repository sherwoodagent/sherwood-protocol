// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, IIrm, Id, MarketParams, Market, Position as MorphoPosition} from "../../src/vendor/morpho/IMorpho.sol";
import {MathLib, SharesMathLib, MarketParamsLib} from "../../src/vendor/morpho/MorphoLibs.sol";

/// @notice Settable per-second borrow rate (WAD), with a revert switch so
///         adapter tests can prove the fail-closed path on IRM failure.
contract MockIrm is IIrm {
    uint256 public rate;
    bool public reverting;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        require(!reverting, "MockIrm: reverting");
        return rate;
    }
}

/// @notice Functional Morpho Blue mock: real supply/withdraw/position
///         bookkeeping and storage-side interest accrual using the SAME
///         vendored math the strategy/adapter use view-side, so a view
///         valuation and a subsequent state-touching call must agree exactly.
///         Borrow is simulated via `simulateBorrow` (tokens leave the mock,
///         utilization rises) — enough for valuation-with-pending-interest,
///         utilization-capped liquidity, and fail-closed adapter tests.
contract MockMorpho is IMorpho {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    mapping(Id => Market) internal _market;
    mapping(Id => MarketParams) internal _idToMarketParams;
    mapping(Id => mapping(address => MorphoPosition)) internal _position;

    // ── Market administration (test-side) ──

    function createMarket(MarketParams memory marketParams) external returns (Id id) {
        id = marketParams.id();
        require(_market[id].lastUpdate == 0, "MockMorpho: market exists");
        _idToMarketParams[id] = marketParams;
        _market[id].lastUpdate = uint128(block.timestamp);
    }

    function setFee(Id id, uint128 fee) external {
        _market[id].fee = fee;
    }

    /// @notice Raise utilization: books `assets` as borrowed and moves the
    ///         loan tokens out to `to` (so the mock's token balance tracks
    ///         real idle liquidity).
    function simulateBorrow(MarketParams memory marketParams, uint256 assets, address to) external {
        Id id = marketParams.id();
        _accrue(marketParams, id);
        Market storage m = _market[id];
        uint256 shares = assets.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        m.totalBorrowAssets += uint128(assets);
        m.totalBorrowShares += uint128(shares);
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "MockMorpho: insufficient liquidity");
        IERC20(marketParams.loanToken).transfer(to, assets);
    }

    /// @notice Clear the whole borrow side: accrues, then pulls the accrued
    ///         borrow total from `msg.sender` back into the mock — so a full
    ///         supply-side unwind (settle) has token backing for the interest.
    function simulateRepayAll(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        _accrue(marketParams, id);
        Market storage m = _market[id];
        uint256 assets = m.totalBorrowAssets;
        m.totalBorrowAssets = 0;
        m.totalBorrowShares = 0;
        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
    }

    // ── IMorpho views ──

    function market(Id id) external view returns (Market memory) {
        return _market[id];
    }

    function position(Id id, address user) external view returns (MorphoPosition memory) {
        return _position[id][user];
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _idToMarketParams[id];
    }

    // ── IMorpho mutations ──

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, "MockMorpho: market not created");
        require(assets != 0 && shares == 0, "MockMorpho: assets-mode only");

        _accrue(marketParams, id);
        Market storage m = _market[id];
        uint256 mintedShares = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);
        _position[id][onBehalf].supplyShares += mintedShares;
        m.totalSupplyAssets += uint128(assets);
        m.totalSupplyShares += uint128(mintedShares);

        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, mintedShares);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, "MockMorpho: market not created");
        require(msg.sender == onBehalf, "MockMorpho: not authorized");
        require((assets != 0) != (shares != 0), "MockMorpho: inconsistent input");

        _accrue(marketParams, id);
        Market storage m = _market[id];
        if (assets != 0) {
            shares = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);
        } else {
            assets = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        }

        MorphoPosition storage pos = _position[id][onBehalf];
        require(pos.supplyShares >= shares, "MockMorpho: insufficient position");
        pos.supplyShares -= shares;
        m.totalSupplyAssets -= uint128(assets);
        m.totalSupplyShares -= uint128(shares);
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "MockMorpho: insufficient liquidity");

        IERC20(marketParams.loanToken).transfer(receiver, assets);
        return (assets, shares);
    }

    function accrueInterest(MarketParams memory marketParams) external {
        _accrue(marketParams, marketParams.id());
    }

    // ── Internal: storage-side accrual, mirror of MorphoBalancesLib ──

    function _accrue(MarketParams memory marketParams, Id id) internal {
        Market storage m = _market[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed != 0 && m.totalBorrowAssets != 0) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRateView(marketParams, _market[id]);
            uint256 interest = uint256(m.totalBorrowAssets).wMulDown(borrowRate.wTaylorCompounded(elapsed));
            m.totalBorrowAssets += uint128(interest);
            m.totalSupplyAssets += uint128(interest);
            if (m.fee != 0) {
                uint256 feeAmount = interest.wMulDown(m.fee);
                uint256 feeShares =
                    feeAmount.toSharesDown(uint256(m.totalSupplyAssets) - feeAmount, m.totalSupplyShares);
                // Fee shares accrue to the mock itself — only the share-price
                // dilution matters to the suites using this mock.
                _position[id][address(this)].supplyShares += feeShares;
                m.totalSupplyShares += uint128(feeShares);
            }
        }
        m.lastUpdate = uint128(block.timestamp);
    }
}
