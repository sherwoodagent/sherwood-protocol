// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FeeConstants
/// @notice Single source of truth for the protocol-wide performance-fee
///         ceiling. Shared by the governor (the `maxPerformanceFeeBps` hard
///         cap, `MAX_PERFORMANCE_FEE_CAP`) and the vault (the `agentFeeBps`
///         hard cap, `MAX_AGENT_FEE_BPS`) so the two can never silently
///         diverge from a hand-edited literal (L1). Referenced as a
///         compile-time constant, so it adds no runtime bytecode.
library FeeConstants {
    /// @notice Hard ceiling on the agent performance fee, in basis points (15%).
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 1500;
}
