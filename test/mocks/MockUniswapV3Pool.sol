// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap V3 pool stand-in with an independently settable SPOT tick and
///         TWAP tick.
/// @dev    The two are deliberately decoupled. A real pool derives its TWAP from
///         accumulated observations, so making spot diverge from the average
///         means simulating a manipulation across many blocks. The guard under
///         test only reads `slot0().tick` and `observe`, so the honest way to
///         test it is to drive those two inputs directly and independently —
///         otherwise every "spot outside the bound" case would need a
///         multi-block price-history fixture to say something the guard decides
///         from two numbers.
///
///         `observe` synthesises the cumulative pair from `twapTick` so that
///         `(c[1] - c[0]) / window == twapTick` exactly, which is what the
///         strategy divides. `observe([0])` instead reports a REAL accumulator,
///         advancing at `twapTick` per second, because a consumer that
///         snapshots it twice has to recover the time-weighted tick from it.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    address public factory;

    uint128 public liquidity;

    int24 public spotTick;
    int24 public twapTick;
    uint16 public observationCardinality = 2;
    /// @notice The ring length the pool is GROWING TOWARD — `slot0`'s fifth field.
    /// @dev    Upstream, `increaseObservationCardinalityNext` raises ONLY this;
    ///         `observationCardinality` catches up one slot at a time as the pool
    ///         is written to. Collapsing the two into one number would let a test
    ///         assert that paying for a longer ring lengthens it instantly, which
    ///         is exactly the misconception the deploy script warns operators
    ///         about. `setObservationCardinality` is how a test simulates the
    ///         filling that closes the gap.
    uint16 public observationCardinalityNext = 2;
    /// @notice Calls to `increaseObservationCardinalityNext`, so a caller's
    ///         "already at target, skip the broadcast" path can be asserted as NO
    ///         CALL rather than as no visible change — the two are
    ///         indistinguishable otherwise, since the growth is monotonic.
    uint256 public cardinalityGrowCalls;

    /// @notice The pool's spot price as `sqrt(token1/token0) * 2^96`.
    /// @dev    Returned as `slot0()`'s first field, which this mock used to hard
    ///         -code to 0. `ConcentratedLiquidityStrategy._poolAnchoredMinOut`
    ///         reads it to build a swap floor that does not depend on the venue
    ///         `swapExtraData` routes through, and treats 0 as "unreadable" and
    ///         degrades — so leaving it at 0 made that floor silently inert in
    ///         every test rather than failing loudly. Tests that exercise the
    ///         floor MUST seat a real value via `setSqrtPriceX96`.
    ///
    ///         Kept independent of `spotTick` on purpose: this mock never had
    ///         tick<->price math and deriving one from the other would mean
    ///         vendoring `TickMath` into the test tree to check a contract that
    ///         deliberately avoids it.
    uint160 public sqrtPriceX96;

    /// @notice Force `observe` to revert, standing in for a window older than the
    ///         ring's oldest observation (upstream reverts `OLD`).
    bool public observeReverts;
    /// @notice Force `observe` to return a malformed-length array, standing in
    ///         for a pool that answers the selector but not the contract.
    bool public observeShortArray;

    /// @notice The tick accumulator `observe([0])` reports, as of `lastAccrual`.
    /// @dev    A synthesised pair always divides EXACTLY by the span, which is
    ///         what makes it useless for testing how a consumer rounds an
    ///         inexact quotient. Seating this number directly is how a test
    ///         hands a consumer a delta with a remainder — and a real pool's
    ///         cumulatives carry one almost always.
    int56 public tickCumulativeStored;
    uint32 public lastAccrual;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        factory = factory_;
        lastAccrual = uint32(block.timestamp);
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    /// @dev The elapsed span is booked at the OLD tick before the switch, so a
    ///      tick change never rewrites accumulated history.
    function setTicks(int24 spot, int24 twap) external {
        tickCumulativeStored = _liveTickCumulative();
        lastAccrual = uint32(block.timestamp);
        spotTick = spot;
        twapTick = twap;
    }

    /// @notice Seat the ring's ACTUAL length, i.e. simulate the pool having been
    ///         written to until the growth target was reached.
    /// @dev    Drags the target up with it: upstream can never hold
    ///         `observationCardinalityNext < observationCardinality`.
    function setObservationCardinality(uint16 c) external {
        observationCardinality = c;
        if (observationCardinalityNext < c) observationCardinalityNext = c;
    }

    function setObserveReverts(bool v) external {
        observeReverts = v;
    }

    function setObserveShortArray(bool v) external {
        observeShortArray = v;
    }

    /// @notice Seat the live accumulator at `c`, as of this block.
    function setTickCumulative(int56 c) external {
        tickCumulativeStored = c;
        lastAccrual = uint32(block.timestamp);
    }

    function _liveTickCumulative() internal view returns (int56) {
        return tickCumulativeStored + int56(twapTick) * int56(uint56(uint32(block.timestamp) - lastAccrual));
    }

    function setFactory(address f) external {
        factory = f;
    }

    function setSqrtPriceX96(uint160 v) external {
        sqrtPriceX96 = v;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, spotTick, 0, observationCardinality, observationCardinalityNext, 0, true);
    }

    /// @dev Monotonic, and it moves the TARGET ONLY — the ring itself does not
    ///      lengthen here, exactly as upstream.
    function increaseObservationCardinalityNext(uint16 next) external {
        ++cardinalityGrowCalls;
        if (next > observationCardinalityNext) observationCardinalityNext = next;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!observeReverts, "OLD");

        // `observe([0])` is the live accumulator: one element in, one out.
        if (secondsAgos.length == 1) {
            uint256 n = observeShortArray ? 0 : 1;
            tickCumulatives = new int56[](n);
            secondsPerLiquidityCumulativeX128s = new uint160[](n);
            if (n == 1) tickCumulatives[0] = _liveTickCumulative();
            return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
        }

        if (observeShortArray) {
            tickCumulatives = new int56[](1);
            secondsPerLiquidityCumulativeX128s = new uint160[](1);
            return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
        }

        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);

        // c[1] - c[0] == twapTick * window, so the strategy's division recovers
        // `twapTick` with no remainder and no floor-correction ambiguity. The
        // window is the one the CALLER asked for, so a consumer that observes
        // over the wrong span recovers the wrong tick.
        uint32 window = secondsAgos[0];
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(twapTick) * int56(uint56(window));
    }
}
