// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap V3 pool stand-in carrying a REAL observation ring.
/// @dev    `write`/`grow`/`observe` are ported line for line from v3-core
///         `Oracle.sol` (wrapping arithmetic put under `unchecked`), so the span
///         the ring can serve is whatever the write HISTORY makes it, not a flag
///         a test sets. `MockUniswapV3Pool` decides `observe` from
///         `observeReverts`, which cannot answer who is able to flip it.
contract MockUniswapV3PoolRing {
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 3000;
    int24 public constant tickSpacing = 60;
    address public factory;

    uint128 public liquidity;
    int24 public tick;
    uint160 public sqrtPriceX96;

    mapping(uint256 slot => Observation) public observations;
    uint16 public observationIndex;
    uint16 public observationCardinality;
    uint16 public observationCardinalityNext;

    /// @notice Writes actually performed, i.e. observation slots consumed.
    uint256 public writes;

    constructor(address token0_, address token1_, int24 startTick, uint128 liquidity_) {
        token0 = token0_;
        token1 = token1_;
        tick = startTick;
        liquidity = liquidity_;
        // `Oracle.initialize`
        observations[0] = Observation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        observationCardinality = 1;
        observationCardinalityNext = 1;
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    function setFactory(address f) external {
        factory = f;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, observationIndex, observationCardinality, observationCardinalityNext, 0, true);
    }

    /// @dev `Oracle.grow`: raises the TARGET only, and pays for each new slot.
    function increaseObservationCardinalityNext(uint16 next) external {
        uint16 current = observationCardinalityNext;
        if (next <= current) return;
        for (uint16 i = current; i < next; i++) {
            observations[i].blockTimestamp = 1;
        }
        observationCardinalityNext = next;
    }

    /// @notice One swap. `UniswapV3Pool.swap` writes an observation only when the
    ///         tick actually moves, and `Oracle.write` then no-ops if an
    ///         observation already carries this block's TIMESTAMP — so at most
    ///         one slot per second, whatever the block rate.
    function swap(int24 newTick) external {
        if (newTick == tick) return;
        (observationIndex, observationCardinality) = _write(
            observationIndex,
            uint32(block.timestamp),
            tick,
            liquidity,
            observationCardinality,
            observationCardinalityNext
        );
        tick = newTick;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) = _observeSingle(
                uint32(block.timestamp), secondsAgos[i], tick, observationIndex, liquidity, observationCardinality
            );
        }
    }

    /// @notice The span the ring can currently serve, in seconds.
    function ringSpan() external view returns (uint32) {
        Observation memory newest = observations[observationIndex];
        Observation memory oldest = observations[(uint256(observationIndex) + 1) % observationCardinality];
        if (!oldest.initialized) oldest = observations[0];
        unchecked {
            return newest.blockTimestamp - oldest.blockTimestamp;
        }
    }

    // ── `Oracle.sol` ──

    function _transform(Observation memory last, uint32 blockTimestamp, int24 t, uint128 liq)
        private
        pure
        returns (Observation memory)
    {
        uint32 delta;
        unchecked {
            delta = blockTimestamp - last.blockTimestamp;
        }
        return Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: last.tickCumulative + int56(t) * int56(uint56(delta)),
            secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128
                + ((uint160(delta) << 128) / (liq > 0 ? liq : 1)),
            initialized: true
        });
    }

    function _write(
        uint16 index,
        uint32 blockTimestamp,
        int24 t,
        uint128 liq,
        uint16 cardinality,
        uint16 cardinalityNext
    ) private returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = observations[index];
        if (last.blockTimestamp == blockTimestamp) return (index, cardinality);
        if (cardinalityNext > cardinality && index == (cardinality - 1)) cardinalityUpdated = cardinalityNext;
        else cardinalityUpdated = cardinality;
        indexUpdated = (index + 1) % cardinalityUpdated;
        observations[indexUpdated] = _transform(last, blockTimestamp, t, liq);
        ++writes;
    }

    function _lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        if (a <= time && b <= time) return a <= b;
        unchecked {
            uint256 aAdjusted = a > time ? a : a + 2 ** 32;
            uint256 bAdjusted = b > time ? b : b + 2 ** 32;
            return aAdjusted <= bAdjusted;
        }
    }

    function _binarySearch(uint32 time, uint32 target, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 l = (uint256(index) + 1) % cardinality;
        uint256 r = l + cardinality - 1;
        uint256 i;
        while (true) {
            i = (l + r) / 2;
            beforeOrAt = observations[i % cardinality];
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }
            atOrAfter = observations[(i + 1) % cardinality];
            bool targetAtOrAfter = _lte(time, beforeOrAt.blockTimestamp, target);
            if (targetAtOrAfter && _lte(time, target, atOrAfter.blockTimestamp)) break;
            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    function _getSurroundingObservations(
        uint32 time,
        uint32 target,
        int24 t,
        uint16 index,
        uint128 liq,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        beforeOrAt = observations[index];
        if (_lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) return (beforeOrAt, atOrAfter);
            else return (beforeOrAt, _transform(beforeOrAt, target, t, liq));
        }

        beforeOrAt = observations[(uint256(index) + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = observations[0];

        // THE LINE THE FINDING TURNS ON.
        require(_lte(time, beforeOrAt.blockTimestamp, target), "OLD");

        return _binarySearch(time, target, index, cardinality);
    }

    function _observeSingle(uint32 time, uint32 secondsAgo, int24 t, uint16 index, uint128 liq, uint16 cardinality)
        private
        view
        returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128)
    {
        if (secondsAgo == 0) {
            Observation memory last = observations[index];
            if (last.blockTimestamp != time) last = _transform(last, time, t, liq);
            return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
        }

        uint32 target;
        unchecked {
            target = time - secondsAgo;
        }

        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            _getSurroundingObservations(time, target, t, index, liq, cardinality);

        if (target == beforeOrAt.blockTimestamp) {
            return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
        } else if (target == atOrAfter.blockTimestamp) {
            return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
        } else {
            uint32 observationTimeDelta;
            uint32 targetDelta;
            unchecked {
                observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
                targetDelta = target - beforeOrAt.blockTimestamp;
            }
            return (
                beforeOrAt.tickCumulative
                    + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(uint56(observationTimeDelta)))
                    * int56(uint56(targetDelta)),
                beforeOrAt.secondsPerLiquidityCumulativeX128
                    + uint160(
                        (uint256(
                                    atOrAfter.secondsPerLiquidityCumulativeX128
                                        - beforeOrAt.secondsPerLiquidityCumulativeX128
                                )
                                * targetDelta) / observationTimeDelta
                    )
            );
        }
    }
}
