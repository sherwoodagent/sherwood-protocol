// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITierRegistry {
    function tierOf(address target, bytes4 selector) external view returns (uint8 tier, uint16 boundBps);
    /// @notice May be bound by a strategy template as a venue (market, position manager,
    ///         swap adapter, price feed, token). Confers nothing to a governor batch.
    function isCounterpartyAllowed(address counterparty) external view returns (bool);
    /// @notice The code class `target` belongs to: non-zero iff it is an ERC-1167 clone of a
    ///         certified template, minted by `strategyFactory`. `bytes32(0)` otherwise.
    function classOf(address target) external view returns (bytes32);
    /// @notice The `StrategyFactory` whose clone provenance class membership requires.
    function strategyFactory() external view returns (address);
}
