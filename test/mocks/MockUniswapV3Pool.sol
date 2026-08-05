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
///         strategy divides.
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

    /// @notice Force `observe` to revert, standing in for a window older than the
    ///         ring's oldest observation (upstream reverts `OLD`).
    bool public observeReverts;
    /// @notice Force `observe` to return a malformed-length array, standing in
    ///         for a pool that answers the selector but not the contract.
    bool public observeShortArray;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        factory = factory_;
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    function setTicks(int24 spot, int24 twap) external {
        spotTick = spot;
        twapTick = twap;
    }

    function setObservationCardinality(uint16 c) external {
        observationCardinality = c;
    }

    function setObserveReverts(bool v) external {
        observeReverts = v;
    }

    function setObserveShortArray(bool v) external {
        observeShortArray = v;
    }

    function setFactory(address f) external {
        factory = f;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, spotTick, 0, observationCardinality, 0, 0, true);
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        if (next > observationCardinality) observationCardinality = next;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!observeReverts, "OLD");

        if (observeShortArray) {
            tickCumulatives = new int56[](1);
            secondsPerLiquidityCumulativeX128s = new uint160[](1);
            return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
        }

        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);

        // c[1] - c[0] == twapTick * window, so the strategy's division recovers
        // `twapTick` with no remainder and no floor-correction ambiguity.
        uint32 window = secondsAgos[0];
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(twapTick) * int56(uint56(window));
    }
}
