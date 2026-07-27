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

    /// @notice Reverts when the protocol-wide envelope-tier ceiling is set to a
    ///         value that is neither a valid tier (0, 1, 2) nor the
    ///         `NO_ENVELOPE_TIER_CEILING` sentinel. Note that 0 IS valid here
    ///         and means "tier-0 adapters only" — it does NOT mean "unset".
    error InvalidMaxEnvelopeTier();

    function protocolFeeBps() external view returns (uint256);
    function protocolFeeRecipient() external view returns (address);
    function guardianFeeBps() external view returns (uint256);
    function guardiansFeeRecipient() external view returns (address);

    /// @notice Protocol-wide ceiling on `strategyDuration`; 0 = unset/no ceiling.
    /// @dev    Read by `GovernorParameters` when validating a vault's own
    ///         `maxStrategyDuration` (ADR 2026-07-26).
    function maxStrategyDuration() external view returns (uint256);

    /// @notice Protocol-wide ceiling on a proposal's `envelopeTier`
    ///         (ADR 2026-07-27). Launch value 1 — tier 2, the default for any
    ///         uncertified call, is refused.
    /// @dev    `type(uint8).max` = no ceiling. **Zero is a VALID setting**
    ///         meaning "tier-0 only", deliberately unlike `maxStrategyDuration`
    ///         where 0 means unset. Read by `SyndicateGovernor` at BOTH propose
    ///         and execute.
    function maxEnvelopeTier() external view returns (uint8);
}
