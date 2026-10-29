// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "../vendor/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "../vendor/uniswap/TickMath.sol";

interface IEthUsdAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/**
 * @title  WoodV3TwapFeed
 * @notice WOOD/USD on the `AggregatorV3` read surface, 8 decimals: the WOOD/WETH
 *         Uniswap V3 pool's own mean tick over `window`, times Chainlink ETH/USD.
 *         No stored state and no keeper.
 * @dev    The pool writes at most one observation per second, so a ring of
 *         `window + 1` slots cannot be evicted by swaps. The constructor requires
 *         that ring target (v1 audit F2, SHE-398).
 */
contract WoodV3TwapFeed {
    error InvalidParameter();
    /// @notice The pool's ring target is below `window + 1` slots.
    error RingTooShort();
    /// @notice The pool is below its depth floor, the ETH/USD leg is unusable, or
    ///         the price is zero or out of range.
    error PriceUnavailable();

    uint256 internal constant Q112 = 2 ** 112;
    uint32 public constant MIN_WINDOW = 30 minutes;
    uint8 internal constant MAX_ETH_FEED_DECIMALS = 18;

    address public immutable pool;
    address public immutable wood;
    address public immutable weth;
    /// @dev Derived from the pool's own `token0()`, never passed in.
    bool internal immutable _woodIsToken0;
    address public immutable ethUsdFeed;
    uint8 internal immutable _ethUsdFeedDecimals;
    uint256 public immutable ethUsdMaxAge;
    uint32 public immutable window;
    /// @dev Read-time floor on in-range liquidity. Not a manipulation control: a push
    ///      out of every range halts reads in that block (it fails closed).
    uint128 public immutable minV3Liquidity;

    constructor(
        address pool_,
        address wood_,
        address weth_,
        address ethUsdFeed_,
        uint256 ethUsdMaxAge_,
        uint32 window_,
        uint128 minV3Liquidity_
    ) {
        if (ethUsdMaxAge_ == 0 || minV3Liquidity_ == 0) revert InvalidParameter();
        if (window_ < MIN_WINDOW) revert InvalidParameter();

        address t0 = IUniswapV3Pool(pool_).token0();
        address t1 = IUniswapV3Pool(pool_).token1();
        // A pool holding anything other than exactly {WOOD, WETH} is refused.
        if (!((t0 == wood_ && t1 == weth_) || (t0 == weth_ && t1 == wood_))) revert InvalidParameter();

        // The target only grows, so the ring ends at `window + 1` slots or more. One that
        // already wrapped at a smaller size still evicts until it expands (SHE-398).
        (,,,, uint16 ringTarget,,) = IUniswapV3Pool(pool_).slot0();
        if (ringTarget <= window_) revert RingTooShort();

        uint8 dec = IEthUsdAggregator(ethUsdFeed_).decimals();
        if (dec > MAX_ETH_FEED_DECIMALS) revert InvalidParameter();

        pool = pool_;
        wood = wood_;
        weth = weth_;
        _woodIsToken0 = t0 == wood_;
        ethUsdFeed = ethUsdFeed_;
        _ethUsdFeedDecimals = dec;
        ethUsdMaxAge = ethUsdMaxAge_;
        window = window_;
        minV3Liquidity = minV3Liquidity_;
    }

    /// @notice The pool's TWAP over `window` in USD, 8 decimals. Reverts `OLD` (from the
    ///         pool) until its oldest observation is a window old.
    /// @dev    `updatedAt` is the read time, so a consumer's max-delay bound is inert.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (IUniswapV3Pool(pool).liquidity() < minV3Liquidity) revert PriceUnavailable();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        (int56[] memory cumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        uint256 woodEthX112 = _tickToX112(_meanTick(cumulatives[0], cumulatives[1]));
        uint256 priceX8 = Math.mulDiv(woodEthX112, _ethUsdX8(), Q112);
        if (priceX8 == 0 || priceX8 > uint256(type(int256).max)) revert PriceUnavailable();

        // Bounded against `type(int256).max` above; the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (1, int256(priceX8), block.timestamp, block.timestamp, 1);
    }

    /// @notice Always 8, matching the scale `ExposureLedger` normalises to.
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "WOOD / USD";
    }

    /// @dev Arithmetic-mean tick over `window`, rounded toward negative infinity
    ///      (v3-periphery `OracleLibrary.consult`). That overstates WOOD by up to one
    ///      tick when WOOD is token1.
    function _meanTick(int56 from, int56 to) internal view returns (int24) {
        int256 span = int256(uint256(window));
        int256 delta = int256(to) - int256(from);
        int256 mean = delta / span;
        if (delta < 0 && delta % span != 0) --mean;
        if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) revert PriceUnavailable();
        // Bounded against the tick range above; the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(mean);
    }

    /// @dev WETH per WOOD in X112. A V3 tick prices token1 in token0, hence the
    ///      reciprocal when WOOD is token1.
    function _tickToX112(int24 tick) internal view returns (uint256) {
        uint256 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = sqrtRatioX96 * sqrtRatioX96;
            return _woodIsToken0 ? Math.mulDiv(ratioX192, Q112, 1 << 192) : Math.mulDiv(1 << 192, Q112, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return _woodIsToken0 ? Math.mulDiv(ratioX128, Q112, 1 << 128) : Math.mulDiv(1 << 128, Q112, ratioX128);
    }

    function _ethUsdX8() internal view returns (uint256 priceX8) {
        (, int256 answer,, uint256 updatedAt,) = IEthUsdAggregator(ethUsdFeed).latestRoundData();
        if (answer <= 0) revert PriceUnavailable();
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > ethUsdMaxAge) revert PriceUnavailable();
        // `answer > 0` checked above; `_ethUsdFeedDecimals` bounded at construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        priceX8 = (uint256(answer) * 1e8) / (10 ** _ethUsdFeedDecimals);
        if (priceX8 == 0) revert PriceUnavailable();
    }
}
