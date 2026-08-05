// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITierRegistry {
    function tierOf(address target, bytes4 selector) external view returns (uint8 tier, uint16 boundBps);
    /// @notice May receive vault funds through a governor batch, and be named as
    ///         a batch callee at all. The STRONG grant.
    function isAdapterAllowed(address adapter) external view returns (bool);
    /// @notice May be bound by a strategy template as a lending market, position
    ///         manager or collateral token. The WEAK grant: implied by
    ///         `isAdapterAllowed` and implying none of it.
    function isCounterpartyAllowed(address counterparty) external view returns (bool);
}
