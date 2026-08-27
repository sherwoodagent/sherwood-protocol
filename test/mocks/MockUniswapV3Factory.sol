// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap V3 factory stand-in holding the canonical
///         `(token0, token1, fee) -> pool` registry.
/// @dev    Exists because `ConcentratedLiquidityStrategy._initialize` resolves a
///         pool's provenance THROUGH the factory rather than from the pool's own
///         `factory()` answer. A fixture that seats an EOA as the factory cannot
///         express that question at all — the strategy reads `getPool` and an
///         address with no code answers nothing, which is (correctly) treated as
///         "not vouched for".
///
///         `register` is deliberately unpermissioned and does NOT deploy: tests
///         construct their pools directly and then tell this contract which one
///         is canonical for a key. That is what lets a test seat a genuine pool
///         for `(usdg, nvda, fee)` and separately hand the strategy an impostor
///         claiming the same key — the exact configuration the provenance check
///         has to separate.
contract MockUniswapV3Factory {
    /// @notice `token0 => token1 => fee => pool`, populated symmetrically so a
    ///         caller need not know the canonical token ordering.
    mapping(address => mapping(address => mapping(uint24 => address))) internal _pools;

    /// @notice Seat `pool` as the canonical venue for the token pair at `fee`.
    function register(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[tokenA][tokenB][fee] = pool;
        _pools[tokenB][tokenA][fee] = pool;
    }

    /// @notice Zero for an unregistered key, matching upstream.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[tokenA][tokenB][fee];
    }
}
