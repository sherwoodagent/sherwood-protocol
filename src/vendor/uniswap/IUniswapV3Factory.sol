// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  Vendored Uniswap V3 factory interface
/// @notice Provenance: Uniswap/v3-core `contracts/interfaces/IUniswapV3Factory.sol`
///         (GPL-2.0-or-later), reduced to the one accessor Sherwood consumes.
///
///         Upstream declares this under `pragma solidity >=0.5.0`; this file is
///         pinned to 0.8.28 to match the rest of `src/`. Interfaces carry no
///         code, so the pragma change cannot alter behaviour — the signature,
///         and therefore the selector, is byte-identical to the live factory on
///         Robinhood Chain 4663 at `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`.
///
/// @dev    Exists to generate a selector, not to type a response.
///         `ConcentratedLiquidityStrategy` reads `getPool` through a
///         length-checked raw staticcall, so a factory that cannot answer
///         resolves to `address(0)` — "this factory vouches for no pool at this
///         key" — instead of reverting `_initialize` undecodably.
interface IUniswapV3Factory {
    /// @notice The canonical pool for a token pair at a fee tier, or
    ///         `address(0)` if the factory never created one.
    /// @dev    The mapping is populated in BOTH token orderings upstream, so a
    ///         caller does not have to know which token sorts first.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
