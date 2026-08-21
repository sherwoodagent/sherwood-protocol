// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  Vendored Uniswap V3 pool interface
/// @notice Provenance: Uniswap/v3-core `contracts/interfaces/IUniswapV3Pool.sol`
///         and its `pool/*` parents (GPL-2.0-or-later), reduced to the surface
///         Sherwood consumes: the immutables needed to prove a pool quotes the
///         vault asset, `slot0`/`liquidity` for sizing and the spot tick, and
///         `observe` for the TWAP the execute-time guard is built on.
///
///         Upstream declares these under `pragma solidity >=0.5.0`; this file is
///         pinned to 0.8.28 to match the rest of `src/`. Interfaces carry no
///         code, so the pragma change cannot alter behaviour — the function
///         signatures, and therefore the selectors, are byte-identical to the
///         live deployment on Robinhood Chain 4663 at
///         `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`'s pools (verified
///         against `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca` in
///         `ConcentratedLiquidityStrategyFork.t.sol`).
///
///         `int24`/`uint160` widths are load-bearing: they are what makes a
///         tick round-trip through `abi.decode` without truncation. Do not
///         widen them to match a caller's convenience.
interface IUniswapV3Pool {
    /// @notice The first of the two tokens of the pool, sorted by address.
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address.
    function token1() external view returns (address);

    /// @notice The pool's fee in hundredths of a bip, i.e. 1e-6.
    function fee() external view returns (uint24);

    /// @notice The pool tick spacing. Ticks can only be used at multiples of
    ///         this value; the init-time range check keys on it.
    function tickSpacing() external view returns (int24);

    /// @notice The currently in-range liquidity available to the pool. This is
    ///         the denominator of the pool-share cap at init — NOT total value
    ///         locked, which counts out-of-range liquidity a position does not
    ///         actually compete with.
    function liquidity() external view returns (uint128);

    /// @notice The pool's factory, as the pool reports it.
    /// @dev    NOT a provenance check, and `src/` deliberately does not consult
    ///         it: an arbitrary contract answering these selectors reports
    ///         whatever address suits it, including the genuine factory's. A
    ///         pool's provenance is established the other way round, by asking
    ///         an allowlisted factory's `getPool` — see
    ///         `ConcentratedLiquidityStrategy._initialize` check (1). Retained
    ///         only because it is part of the vendored upstream surface.
    function factory() external view returns (address);

    /// @notice The 0th storage slot: current price, tick, and the observation
    ///         ring's state.
    /// @dev    `observationCardinality` is the field that decides whether
    ///         `observe` can serve the configured window at all. A pool with
    ///         cardinality 1 has no history: its "TWAP" is spot, which would
    ///         make the execute-time guard compare a value against itself and
    ///         pass unconditionally. The guard checks this explicitly rather
    ///         than inferring it from an `observe` revert.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice Cumulative tick and liquidity values as of each `secondsAgos`
    ///         from the current block timestamp.
    /// @dev    Reverts upstream (`OLD`) when the requested window predates the
    ///         oldest stored observation. The execute-time guard treats that
    ///         revert as fatal rather than falling back to spot — see
    ///         `ConcentratedLiquidityStrategy._twapTick`.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Increase the number of stored observations the pool keeps.
    /// @dev    Permissionless and monotonic upstream. Not called by the
    ///         strategy — vendored because the fork test uses it to bring a
    ///         thin pool up to a cardinality the TWAP window can serve, which
    ///         is exactly the remediation an operator would apply.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}
