// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IProtocolConfig {
    /// @notice Division of the always-on management fee. Shares are in basis
    ///         points and MUST sum to `FeeConstants.BPS_DENOMINATOR`.
    /// @dev Packed into one slot. `uint16` holds any legal share (max 10 000).
    struct MgmtSplit {
        uint16 agentBps;
        uint16 protocolBps;
        uint16 guardianBps;
    }

    /// @notice Division of the performance fee. Shares are in basis points and
    ///         MUST sum to `FeeConstants.BPS_DENOMINATOR`.
    /// @dev The fund owner earns only on the profit side, which is why this
    ///      split has a fourth leg the management split does not.
    struct PerfSplit {
        uint16 agentBps;
        uint16 protocolBps;
        uint16 guardianBps;
        uint16 ownerBps;
    }

    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);
    event ProtocolFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event GuardiansFeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event MgmtSplitSet(uint16 agentBps, uint16 protocolBps, uint16 guardianBps);
    event PerfSplitSet(uint16 agentBps, uint16 protocolBps, uint16 guardianBps, uint16 ownerBps);

    error InvalidMgmtSplit();
    error InvalidPerfSplit();

    /// @notice Reverts when the protocol-wide strategy-duration ceiling is set
    ///         below `MIN_PROTOCOL_MAX_STRATEGY_DURATION`. Zero is permitted and
    ///         means "unset / no ceiling".
    error InvalidMaxStrategyDuration();

    /// @notice Where the protocol's share is sent. Zero unwires the leg — the
    ///         governor folds that share into the agent's remainder rather than
    ///         escrowing it against `address(0)`.
    function protocolFeeRecipient() external view returns (address);

    /// @notice Where the guardian network's share of each fee is sent. Same
    ///         zero semantics as above.
    function guardiansFeeRecipient() external view returns (address);

    /// @notice Protocol-wide ceiling on `strategyDuration`; 0 = unset/no ceiling.
    /// @dev    Read by `GovernorParameters` when validating a vault's own
    ///         `maxStrategyDuration`.
    function maxStrategyDuration() external view returns (uint256);

    /// @notice The management-fee split in force now.
    /// @dev Read at propose time and snapshotted onto the proposal; never read
    ///      live at settle. Seeded valid at construction, so the all-zero state
    ///      is unreachable for a real config.
    function mgmtSplit() external view returns (MgmtSplit memory);

    /// @notice The performance-fee split in force now. Same snapshot semantics
    ///         as `mgmtSplit`.
    function perfSplit() external view returns (PerfSplit memory);
}
