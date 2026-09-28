// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
 *         to a WETH depth floor. Both pairs are synced before every snapshot, so
 *         tails are zero.
 */
contract WoodPoolFeed {
    error InvalidParameter();
    /// @notice No window spanned yet, a pool below the depth floor, or an
    ///         unusable ETH/USD leg.
    error PriceUnavailable();

    event SnapshotRecorded(uint256 indexed pairIndex, uint256 cumulative, uint32 timestamp, uint32 spanFromPrevious);

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

    address public immutable pairA;
    address public immutable pairB;
    address public immutable wood;
    address public immutable weth;
    /// @dev Derived from each pair's own `token0()`, never passed in.
    bool internal immutable _woodIsToken0A;
    bool internal immutable _woodIsToken0B;
    address public immutable ethUsdFeed;
    uint8 internal immutable _ethUsdFeedDecimals;
    uint256 public immutable ethUsdMaxAge;
    uint256 public immutable window;
    /// @dev SPOT LIVENESS GATE, in the pool's WETH-side reserve: it refuses an
    ///      empty or dust pool, and is not a manipulation control -- supplied
    ///      depth passes it. The two-pool `min` is the manipulation control.
    uint256 public immutable minWethReserve;

    Observation[2] public previousObservation;
    Observation[2] public latestObservation;

    constructor(
        address pairA_,
        address pairB_,
        address wood_,
        address weth_,
        address ethUsdFeed_,
        uint256 ethUsdMaxAge_,
        uint256 window_,
        uint256 minWethReserve_
    ) {
        if (pairA_ == address(0) || pairB_ == address(0) || pairA_ == pairB_) {
            revert InvalidParameter();
        }
        if (wood_ == address(0) || weth_ == address(0) || wood_ == weth_) revert InvalidParameter();
        if (ethUsdFeed_ == address(0) || ethUsdMaxAge_ == 0 || minWethReserve_ == 0) revert InvalidParameter();
        if (window_ < MIN_WINDOW || window_ > MAX_SNAPSHOT_SPAN) revert InvalidParameter();

        uint8 dec = IAggregatorMinimal(ethUsdFeed_).decimals();
        if (dec > MAX_ETH_FEED_DECIMALS) revert InvalidParameter();

        pairA = pairA_;
        pairB = pairB_;
        wood = wood_;
        weth = weth_;
        _woodIsToken0A = _deriveWoodSide(pairA_, wood_, weth_);
        _woodIsToken0B = _deriveWoodSide(pairB_, wood_, weth_);
        ethUsdFeed = ethUsdFeed_;
        _ethUsdFeedDecimals = dec;
        ethUsdMaxAge = ethUsdMaxAge_;
        window = window_;
        minWethReserve = minWethReserve_;
    }

    /// @notice Roll each pool's snapshot pair forward once `window` has elapsed.
    ///         Permissionless, and a no-op rather than a revert when a pool is
    ///         early, empty or below the depth floor.
    /// @dev    Both pairs are synced first. `sync()` is permissionless and books
    ///         the standing price over the elapsed span, so an untraded pool still snapshots.
    function update() external {
        IUniswapV2PairMinimal(pairA).sync();
        IUniswapV2PairMinimal(pairB).sync();
        _update(0);
        _update(1);
    }

    /// @notice The lower of the two pools' TWAPs in USD, 8 decimals, with
    ///         `updatedAt` the OLDER of the two snapshots.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 twapA, uint32 tsA) = _twapX112(0);
        (uint256 twapB, uint32 tsB) = _twapX112(1);

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

    /// @dev A pair holding anything other than exactly {WOOD, WETH} is refused.
    function _deriveWoodSide(address pair, address wood_, address weth_) internal view returns (bool) {
        address t0 = IUniswapV2PairMinimal(pair).token0();
        address t1 = IUniswapV2PairMinimal(pair).token1();
        if (t0 == wood_ && t1 == weth_) return true;
        if (t0 == weth_ && t1 == wood_) return false;
        revert InvalidParameter();
    }

    function _pair(uint256 index) internal view returns (address pair, bool woodIsToken0) {
        return index == 0 ? (pairA, _woodIsToken0A) : (pairB, _woodIsToken0B);
    }

    function _update(uint256 index) internal {
        (address pair, bool woodIsToken0) = _pair(index);
        (uint256 cumulative, uint32 nowTs, bool ok) = _currentCumulative(pair, woodIsToken0);
        if (!ok) return;

        Observation memory latest = latestObservation[index];
        if (latest.timestamp == 0) {
            latestObservation[index] = Observation({cumulative: cumulative, timestamp: nowTs});
            emit SnapshotRecorded(index, cumulative, nowTs, 0);
            return;
        }

        uint32 span;
        // Pair timestamps wrap at 2^32 and so do these; the wrapping subtraction
        // is the correct span.
        unchecked {
            span = nowTs - latest.timestamp;
        }
        if (span < window) return;

        previousObservation[index] = latest;
        latestObservation[index] = Observation({cumulative: cumulative, timestamp: nowTs});
        emit SnapshotRecorded(index, cumulative, nowTs, span);
    }

    /// @dev Priced off stored snapshots only; live reserves are read as a depth
    ///      gate, never as a price.
    function _twapX112(uint256 index) internal view returns (uint256 avgX112, uint32 updatedAt) {
        (address pair, bool woodIsToken0) = _pair(index);
        Observation memory previous = previousObservation[index];
        Observation memory latest = latestObservation[index];
        if (previous.timestamp == 0 || latest.timestamp == 0) revert PriceUnavailable();

        uint32 span;
        unchecked {
            span = latest.timestamp - previous.timestamp;
        }
        if (span < window || span > MAX_SNAPSHOT_SPAN) revert PriceUnavailable();

        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pair).getReserves();
        if ((woodIsToken0 ? uint256(r1) : uint256(r0)) < minWethReserve) revert PriceUnavailable();

        // The pair's accumulator wraps at 2^256, so the difference is unchecked.
        unchecked {
            avgX112 = (latest.cumulative - previous.cumulative) / span;
        }
        if (avgX112 == 0) revert PriceUnavailable();
        return (avgX112, latest.timestamp);
    }

    function _storedCumulative(address pair, bool woodIsToken0) internal view returns (uint256) {
        return woodIsToken0
            ? IUniswapV2PairMinimal(pair).price0CumulativeLast()
            : IUniswapV2PairMinimal(pair).price1CumulativeLast();
    }

    function _currentCumulative(address pair, bool woodIsToken0)
        internal
        view
        returns (uint256 cumulative, uint32 nowTs, bool ok)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        nowTs = uint32(block.timestamp);
        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pair).getReserves();
        // The depth floor binds at SNAPSHOT time as well as at read time: a pool
        // below it never enters the average in the first place.
        if (r0 == 0 || r1 == 0 || (woodIsToken0 ? uint256(r1) : uint256(r0)) < minWethReserve) return (0, 0, false);

        // `update()` syncs the pair first, so the stored accumulator is current
        // as of this block and there is no tail left to account for.
        return (_storedCumulative(pair, woodIsToken0), nowTs, true);
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
