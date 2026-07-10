// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";

/// @title ProtocolConfig
/// @notice Protocol-level fee params shared by all per-vault governors. Read
///         ONLY at propose time and snapshotted into `StrategyProposal`; never
///         read live at settle. Plain (non-upgradeable) Ownable2Step. If it ever
///         needs replacement, governors accept a new address via
///         `setProtocolConfig(address)` (factory-only); snapshotting means no
///         in-flight proposal is affected.
contract ProtocolConfig is Ownable2Step, IProtocolConfig {
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1000; // 10%
    uint256 public constant MAX_GUARDIAN_FEE_BPS = 500; // 5%

    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;
    uint256 public guardianFeeBps;
    address public guardiansFeeRecipient;

    constructor(address owner_) Ownable(owner_) {}

    function setProtocolFeeBps(uint256 newValue) external onlyOwner {
        if (newValue > MAX_PROTOCOL_FEE_BPS) revert InvalidProtocolFeeBps();
        if (newValue > 0 && protocolFeeRecipient == address(0)) revert InvalidProtocolFeeRecipient();
        uint256 old = protocolFeeBps;
        protocolFeeBps = newValue;
        emit ParameterChangeFinalized(keccak256("protocolFeeBps"), old, newValue);
    }

    function setProtocolFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) && protocolFeeBps > 0) revert InvalidProtocolFeeRecipient();
        address old = protocolFeeRecipient;
        protocolFeeRecipient = newRecipient;
        emit ProtocolFeeRecipientSet(old, newRecipient);
    }

    function setGuardianFeeBps(uint256 newValue) external onlyOwner {
        if (newValue > MAX_GUARDIAN_FEE_BPS) revert InvalidGuardianFeeBps();
        if (newValue > 0 && guardiansFeeRecipient == address(0)) revert InvalidGuardiansFeeRecipient();
        uint256 old = guardianFeeBps;
        guardianFeeBps = newValue;
        emit ParameterChangeFinalized(keccak256("guardianFeeBps"), old, newValue);
    }

    function setGuardiansFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) && guardianFeeBps > 0) revert InvalidGuardiansFeeRecipient();
        address old = guardiansFeeRecipient;
        guardiansFeeRecipient = newRecipient;
        emit GuardiansFeeRecipientSet(old, newRecipient);
    }
}
