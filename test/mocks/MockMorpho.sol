// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, IIrm, Id, MarketParams, Market, Position as MorphoPosition} from "../../src/vendor/morpho/IMorpho.sol";
import {MathLib, SharesMathLib, MarketParamsLib} from "../../src/vendor/morpho/MorphoLibs.sol";

/// @notice Morpho Blue's oracle surface: collateral price quoted in loan-token
///         units, scaled by `ORACLE_PRICE_SCALE` (1e36).
interface IMockOracle {
    function price() external view returns (uint256);
}

uint256 constant ORACLE_PRICE_SCALE = 1e36;

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
///         Two borrow surfaces, deliberately kept separate: `simulateBorrow`
///         moves only the market totals (a third party raising utilization —
///         enough for valuation-with-pending-interest, utilization-capped
///         liquidity, and fail-closed adapter tests), while `borrow`/`repay`
///         below book the caller's OWN `borrowShares`, which is what a strategy
///         that has to unwind its own debt needs to see go to zero.
contract MockMorpho is IMorpho {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    mapping(Id => Market) internal _market;
    mapping(Id => MarketParams) internal _idToMarketParams;
    mapping(Id => mapping(address => MorphoPosition)) internal _position;

    /// @notice Ceiling on a single `withdrawCollateral`. TEST-ONLY.
    /// @dev    The deliverable-maximum settlement path has a withdraw-short
    ///         branch that is otherwise unreachable in a mock with no oracle:
    ///         with debt cleared, upstream would always release the collateral.
    ///         Lower this to force the shortfall and prove settle emits rather
    ///         than reverts. Defaults to no cap.
    uint256 public collateralWithdrawCap = type(uint256).max;

    function setCollateralWithdrawCap(uint256 cap) external {
        collateralWithdrawCap = cap;
    }

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

    /// @notice Force the market's four totals directly, bypassing supply/borrow
    ///         bookkeeping and token backing.
    /// @dev    TEST-ONLY, and deliberately unbacked: it exists to construct
    ///         states at the edge of what the singleton's uint128 fields can
    ///         hold — the only band where an accrual accumulated in uint256
    ///         locals disagrees with upstream's `toUint128`-narrowed arithmetic.
    ///         Do not use it to model ordinary markets; `simulateBorrow` /
    ///         `simulateRepayAll` keep token balances honest and should be
    ///         preferred everywhere else.
    function forceTotals(
        Id id,
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares
    ) external {
        Market storage m = _market[id];
        m.totalSupplyAssets = totalSupplyAssets;
        m.totalSupplyShares = totalSupplyShares;
        m.totalBorrowAssets = totalBorrowAssets;
        m.totalBorrowShares = totalBorrowShares;
    }

    /// @notice Force a position's supply shares. TEST-ONLY, same caveat as
    ///         `forceTotals`.
    function forcePosition(Id id, address who, uint128 supplyShares) external {
        _position[id][who].supplyShares = supplyShares;
    }

    /// @notice Roll `lastUpdate` back so a view accrual sees `secs` of pending
    ///         interest without warping the whole test's clock forward.
    function backdate(Id id, uint128 secs) external {
        _market[id].lastUpdate -= secs;
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

    // ── IMorpho: collateral / borrow side ──
    //
    // Real bookkeeping, unlike `simulateBorrow` above: these move the CALLER's
    // position, not just the market totals, because a borrower that unwinds its
    // own debt has to see its own `borrowShares` go to zero.

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory)
        external
    {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, "MockMorpho: market not created");
        require(assets != 0, "MockMorpho: zero assets");

        _position[id][onBehalf].collateral += uint128(assets);
        IERC20(marketParams.collateralToken).transferFrom(msg.sender, address(this), assets);
    }

    /// @dev Upstream refuses a withdrawal that would leave the position
    ///      unhealthy. This mock has no oracle, so it enforces the ONE
    ///      consequence the settlement ordering actually depends on — debt must
    ///      be cleared first — rather than pretending to price collateral.
    ///      `collateralWithdrawCap` is the separate, explicit lever for the
    ///      withdraw-short case.
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, "MockMorpho: market not created");
        require(msg.sender == onBehalf, "MockMorpho: not authorized");
        require(assets <= collateralWithdrawCap, "MockMorpho: withdraw capped");

        _accrue(marketParams, id);
        MorphoPosition storage pos = _position[id][onBehalf];
        require(pos.collateral >= assets, "MockMorpho: insufficient collateral");
        // MODELS MORPHO BLUE'S ACTUAL RULE, not "debt must be zero" (pashov
        // finding #8). Upstream `withdrawCollateral` permits a withdrawal while
        // debt is outstanding provided the position stays healthy —
        //   maxBorrow = collateral * price / ORACLE_PRICE_SCALE * lltv / WAD
        //   require(maxBorrow >= borrowed)
        // The previous `borrowShares == 0` require encoded the SAME wrong
        // assumption the strategy bug was made of, so a fix could not be
        // observed through it. Zero-debt behaviour is unchanged.
        if (pos.borrowShares != 0) {
            Market storage m = _market[id];
            uint256 borrowed = m.totalBorrowShares == 0
                ? 0
                : (uint256(pos.borrowShares) * uint256(m.totalBorrowAssets)) / uint256(m.totalBorrowShares);
            uint256 price = IMockOracle(marketParams.oracle).price();
            uint256 maxBorrow =
                ((uint256(pos.collateral) - assets) * price / ORACLE_PRICE_SCALE) * marketParams.lltv / 1e18;
            require(maxBorrow >= borrowed, "MockMorpho: insufficient collateral");
        }

        pos.collateral -= uint128(assets);
        IERC20(marketParams.collateralToken).transfer(receiver, assets);
    }

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, "MockMorpho: market not created");
        require(msg.sender == onBehalf, "MockMorpho: not authorized");
        require(assets != 0 && shares == 0, "MockMorpho: assets-mode only");

        _accrue(marketParams, id);
        Market storage m = _market[id];
        uint256 mintedShares = assets.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        _position[id][onBehalf].borrowShares += uint128(mintedShares);
        m.totalBorrowAssets += uint128(assets);
        m.totalBorrowShares += uint128(mintedShares);
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "MockMorpho: insufficient liquidity");

        IERC20(marketParams.loanToken).transfer(receiver, assets);
        return (assets, mintedShares);
    }

    /// @dev Shares-mode rounds the owed assets UP, mirroring upstream: repaying
    ///      an exact share count must never leave the debt fractionally short,
    ///      because a single dust share left behind blocks `withdrawCollateral`.
    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, "MockMorpho: market not created");
        require((assets != 0) != (shares != 0), "MockMorpho: inconsistent input");

        _accrue(marketParams, id);
        Market storage m = _market[id];
        if (assets != 0) {
            shares = assets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        }

        MorphoPosition storage pos = _position[id][onBehalf];
        require(pos.borrowShares >= shares, "MockMorpho: repay exceeds debt");
        pos.borrowShares -= uint128(shares);
        m.totalBorrowAssets -= uint128(assets);
        m.totalBorrowShares -= uint128(shares);

        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, shares);
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
