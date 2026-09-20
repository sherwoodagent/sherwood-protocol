// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "../vendor/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "../vendor/uniswap/TickMath.sol";

interface IUniswapV2PairMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function sync() external;
}

interface IAggregatorMinimal {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/**
 * @title  WoodPoolFeed
 * @notice WOOD/USD on the `AggregatorV3` read surface, 8 decimals: the LOWER of
 *         two WOOD/WETH pool TWAPs over a window of at least 24h, each pool held
 *         to a depth floor. One leg is a Uniswap-V2-style pair, synced before
 *         every snapshot so tails are zero; the other is a Uniswap V3 pool. Both
 *         legs are averaged from accumulators this contract snapshots itself.
 */
contract WoodPoolFeed {
    error InvalidParameter();
    /// @notice No window spanned yet, a pool below its depth floor, or an
    ///         unusable ETH/USD leg.
    error PriceUnavailable();

    event SnapshotRecorded(uint256 cumulative, uint32 timestamp, uint32 spanFromPrevious);

    /// @dev UQ112x112 scaling factor, the format `UniswapV2Pair` accumulates in.
    uint256 internal constant Q112 = 2 ** 112;
    uint256 public constant MIN_WINDOW = 24 hours;
    /// @dev Ceiling on the span between the two snapshots a read averages over.
    uint256 public constant MAX_SNAPSHOT_SPAN = 7 days;
    uint8 internal constant MAX_ETH_FEED_DECIMALS = 18;

    struct Observation {
        uint256 cumulative;
        uint32 timestamp;
    }

    struct PoolObservation {
        int56 tickCumulative;
        uint32 timestamp;
    }

    address public immutable pairA;
    address public immutable pool;
    address public immutable wood;
    address public immutable weth;
    /// @dev Derived from each venue's own `token0()`, never passed in.
    bool internal immutable _woodIsToken0A;
    bool internal immutable _woodIsToken0Pool;
    address public immutable ethUsdFeed;
    uint8 internal immutable _ethUsdFeedDecimals;
    uint256 public immutable ethUsdMaxAge;
    uint256 public immutable window;
    /// @dev SPOT LIVENESS GATE, in the pair's WETH-side reserve: it refuses an
    ///      empty or dust pool, and is not a manipulation control -- supplied
    ///      depth passes it. The two-pool `min` is the manipulation control.
    uint256 public immutable minWethReserve;
    /// @dev The V3 equivalent of `minWethReserve`: in-range liquidity at the
    ///      time of the read, which is the depth actually standing behind the
    ///      pool's tick. Same gate, same non-claim about manipulation.
    uint128 public immutable minV3Liquidity;

    Observation public previousObservation;
    Observation public latestObservation;
    PoolObservation public previousPoolObservation;
    PoolObservation public latestPoolObservation;

    constructor(
        address pairA_,
        address pool_,
        address wood_,
        address weth_,
        address ethUsdFeed_,
        uint256 ethUsdMaxAge_,
        uint256 window_,
        uint256 minWethReserve_,
        uint128 minV3Liquidity_
    ) {
        if (pairA_ == address(0) || pool_ == address(0) || pairA_ == pool_) {
            revert InvalidParameter();
        }
        if (wood_ == address(0) || weth_ == address(0) || wood_ == weth_) revert InvalidParameter();
        if (ethUsdFeed_ == address(0) || ethUsdMaxAge_ == 0 || minWethReserve_ == 0) revert InvalidParameter();
        if (minV3Liquidity_ == 0) revert InvalidParameter();
        if (window_ < MIN_WINDOW || window_ > MAX_SNAPSHOT_SPAN) revert InvalidParameter();

        uint8 dec = IAggregatorMinimal(ethUsdFeed_).decimals();
        if (dec > MAX_ETH_FEED_DECIMALS) revert InvalidParameter();

        pairA = pairA_;
        pool = pool_;
        wood = wood_;
        weth = weth_;
        _woodIsToken0A = _deriveWoodSide(
            IUniswapV2PairMinimal(pairA_).token0(), IUniswapV2PairMinimal(pairA_).token1(), wood_, weth_
        );
        _woodIsToken0Pool =
            _deriveWoodSide(IUniswapV3Pool(pool_).token0(), IUniswapV3Pool(pool_).token1(), wood_, weth_);
        ethUsdFeed = ethUsdFeed_;
        _ethUsdFeedDecimals = dec;
        ethUsdMaxAge = ethUsdMaxAge_;
        window = window_;
        minWethReserve = minWethReserve_;
        minV3Liquidity = minV3Liquidity_;
    }

    /// @notice Roll both legs' snapshots forward once `window` has elapsed.
    ///         Permissionless, and a no-op rather than a revert when the pair is
    ///         early, empty or below the depth floor.
    /// @dev    The pair is synced first. `sync()` is permissionless and books the
    ///         standing price over the elapsed span, so an untraded pair still snapshots.
    function update() external {
        IUniswapV2PairMinimal(pairA).sync();
        _update();
    }

    /// @notice The lower of the two pools' TWAPs in USD, 8 decimals, with
    ///         `updatedAt` the OLDER of the two legs' readings.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 twapA, uint32 tsA) = _twapX112();
        (uint256 twapB, uint32 tsB) = _poolTwapX112();

        uint256 priceX8 = Math.mulDiv(twapA < twapB ? twapA : twapB, _ethUsdX8(), Q112);
        if (priceX8 == 0 || priceX8 > uint256(type(int256).max)) revert PriceUnavailable();

        uint256 updatedAt = tsA < tsB ? tsA : tsB;
        // Bounded against `type(int256).max` above; the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (1, int256(priceX8), updatedAt, updatedAt, 1);
    }

    /// @notice Always 8, matching the scale `ExposureLedger` normalises to.
    function decimals() external pure returns (uint8) {
        return 8;
    }

    /// @notice Human-readable feed name.
    function description() external pure returns (string memory) {
        return "WOOD / USD";
    }

    // -- Internals --

    /// @dev A venue holding anything other than exactly {WOOD, WETH} is refused.
    function _deriveWoodSide(address t0, address t1, address wood_, address weth_) internal pure returns (bool) {
        if (t0 == wood_ && t1 == weth_) return true;
        if (t0 == weth_ && t1 == wood_) return false;
        revert InvalidParameter();
    }

    function _update() internal {
        (uint256 cumulative, uint32 nowTs, bool ok) = _currentCumulative();
        if (!ok) return;
        int56 tickCumulative = _currentTickCumulative();

        Observation memory latest = latestObservation;
        if (latest.timestamp == 0) {
            latestObservation = Observation({cumulative: cumulative, timestamp: nowTs});
            latestPoolObservation = PoolObservation({tickCumulative: tickCumulative, timestamp: nowTs});
            emit SnapshotRecorded(cumulative, nowTs, 0);
            return;
        }

        uint32 span;
        // Pair timestamps wrap at 2^32 and so do these; the wrapping subtraction
        // is the correct span.
        unchecked {
            span = nowTs - latest.timestamp;
        }
        if (span < window) return;

        previousObservation = latest;
        latestObservation = Observation({cumulative: cumulative, timestamp: nowTs});
        previousPoolObservation = latestPoolObservation;
        latestPoolObservation = PoolObservation({tickCumulative: tickCumulative, timestamp: nowTs});
        emit SnapshotRecorded(cumulative, nowTs, span);
    }

    /// @dev Priced off stored snapshots only; live reserves are read as a depth
    ///      gate, never as a price.
    function _twapX112() internal view returns (uint256 avgX112, uint32 updatedAt) {
        Observation memory previous = previousObservation;
        Observation memory latest = latestObservation;
        if (previous.timestamp == 0 || latest.timestamp == 0) revert PriceUnavailable();

        uint32 span;
        unchecked {
            span = latest.timestamp - previous.timestamp;
        }
        if (span < window || span > MAX_SNAPSHOT_SPAN) revert PriceUnavailable();

        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pairA).getReserves();
        if ((_woodIsToken0A ? uint256(r1) : uint256(r0)) < minWethReserve) revert PriceUnavailable();

        // The pair's accumulator wraps at 2^256, so the difference is unchecked.
        unchecked {
            avgX112 = (latest.cumulative - previous.cumulative) / span;
        }
        if (avgX112 == 0) revert PriceUnavailable();
        return (avgX112, latest.timestamp);
    }

    /// @dev Priced off the accumulator readings `update()` stored, so a ring the
    ///      market writes cannot make this leg unavailable; live liquidity is
    ///      read as a depth gate, never as a price.
    function _poolTwapX112() internal view returns (uint256 avgX112, uint32 updatedAt) {
        if (IUniswapV3Pool(pool).liquidity() < minV3Liquidity) revert PriceUnavailable();

        PoolObservation memory previous = previousPoolObservation;
        PoolObservation memory latest = latestPoolObservation;
        if (previous.timestamp == 0 || latest.timestamp == 0) revert PriceUnavailable();

        uint32 span;
        unchecked {
            span = latest.timestamp - previous.timestamp;
        }
        if (span < window || span > MAX_SNAPSHOT_SPAN) revert PriceUnavailable();

        avgX112 = _tickToX112(_meanTick(previous.tickCumulative, latest.tickCumulative, span));
        if (avgX112 == 0) revert PriceUnavailable();
        return (avgX112, latest.timestamp);
    }

    /// @dev `observe([0])` reads the LIVE accumulator: it is synthesised from the
    ///      newest observation, so no eviction of older ring slots can starve it.
    function _currentTickCumulative() internal view returns (int56) {
        uint32[] memory secondsAgos = new uint32[](1);
        (int56[] memory cumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        return cumulatives[0];
    }

    /// @dev Arithmetic-mean tick over the snapshots' span, rounded toward
    ///      NEGATIVE INFINITY: truncating division rounds a negative delta up,
    ///      which would report a WOOD price one tick better than the pool held.
    function _meanTick(int56 previous, int56 latest, uint32 spanSeconds) internal pure returns (int24) {
        int256 span = int256(uint256(spanSeconds));
        int256 delta = int256(latest) - int256(previous);
        int256 mean = delta / span;
        if (delta < 0 && delta % span != 0) --mean;
        if (mean < TickMath.MIN_TICK || mean > TickMath.MAX_TICK) revert PriceUnavailable();
        // Bounded against the tick range above; the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(mean);
    }

    /// @dev WETH per WOOD in X112 — the orientation and scale `_twapX112`
    ///      returns, so both legs meet the same `min` and the same USD
    ///      conversion. A V3 tick prices token1 in token0, hence the reciprocal
    ///      when WOOD is token1.
    function _tickToX112(int24 tick) internal view returns (uint256) {
        uint256 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = sqrtRatioX96 * sqrtRatioX96;
            return _woodIsToken0Pool ? Math.mulDiv(ratioX192, Q112, 1 << 192) : Math.mulDiv(1 << 192, Q112, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return _woodIsToken0Pool ? Math.mulDiv(ratioX128, Q112, 1 << 128) : Math.mulDiv(1 << 128, Q112, ratioX128);
    }

    function _storedCumulative() internal view returns (uint256) {
        return _woodIsToken0A
            ? IUniswapV2PairMinimal(pairA).price0CumulativeLast()
            : IUniswapV2PairMinimal(pairA).price1CumulativeLast();
    }

    function _currentCumulative() internal view returns (uint256 cumulative, uint32 nowTs, bool ok) {
        // forge-lint: disable-next-line(unsafe-typecast)
        nowTs = uint32(block.timestamp);
        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pairA).getReserves();
        // The depth floor binds at SNAPSHOT time as well as at read time: a pair
        // below it never enters the average in the first place.
        if (r0 == 0 || r1 == 0 || (_woodIsToken0A ? uint256(r1) : uint256(r0)) < minWethReserve) {
            return (0, 0, false);
        }

        // `update()` syncs the pair first, so the stored accumulator is current
        // as of this block and there is no tail left to account for.
        return (_storedCumulative(), nowTs, true);
    }

    function _ethUsdX8() internal view returns (uint256 priceX8) {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(ethUsdFeed).latestRoundData();
        if (answer <= 0) revert PriceUnavailable();
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > ethUsdMaxAge) revert PriceUnavailable();
        // `answer > 0` checked above; `_ethUsdFeedDecimals` bounded at construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        priceX8 = (uint256(answer) * 1e8) / (10 ** _ethUsdFeedDecimals);
        if (priceX8 == 0) revert PriceUnavailable();
    }
}
