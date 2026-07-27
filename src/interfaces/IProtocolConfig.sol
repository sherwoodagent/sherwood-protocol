// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IProtocolConfig {
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);
    event ProtocolFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event GuardiansFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    error InvalidProtocolFeeBps();
    error InvalidGuardianFeeBps();
    error InvalidProtocolFeeRecipient();
    error InvalidGuardiansFeeRecipient();

    /// @notice Reverts when the protocol-wide strategy-duration ceiling is set
    ///         below `MIN_PROTOCOL_MAX_STRATEGY_DURATION`. Zero is permitted and
    ///         means "unset / no ceiling".
    error InvalidMaxStrategyDuration();

    function protocolFeeBps() external view returns (uint256);
    function protocolFeeRecipient() external view returns (address);
    function guardianFeeBps() external view returns (uint256);
    function guardiansFeeRecipient() external view returns (address);

    /// @notice Protocol-wide ceiling on `strategyDuration`; 0 = unset/no ceiling.
    /// @dev    Read by `GovernorParameters` when validating a vault's own
    ///         `maxStrategyDuration` (ADR 2026-07-26).
    function maxStrategyDuration() external view returns (uint256);
}
