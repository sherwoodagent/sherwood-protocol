// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {FeeConstants} from "./FeeConstants.sol";

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

    /// @notice Floor on the protocol-wide strategy-duration ceiling. Guards the
    ///         degenerate setting: a ceiling below the shortest usable strategy
    ///         would make every vault unproposable protocol-wide in one
    ///         transaction.
    uint256 public constant MIN_PROTOCOL_MAX_STRATEGY_DURATION = 1 days;

    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;
    uint256 public guardianFeeBps;
    address public guardiansFeeRecipient;

    /// @notice Protocol-wide CEILING on `strategyDuration`; every vault's own
    ///         `maxStrategyDuration` is clamped to it (ADR 2026-07-26).
    ///
    /// @dev    Lives here rather than on the vault because a strategy's duration
    ///         determines how long the approving GUARDIANS carry exposure, and
    ///         the vault owner is not the party bearing that risk. Before this,
    ///         a vault owner could seat `maxStrategyDuration` anywhere up to
    ///         `ABSOLUTE_MAX_STRATEGY_DURATION` (3650 days) and bind guardians
    ///         for a decade per approval.
    ///
    ///         It is also what lets v1 skip §3.4a's epoch chaining: a bounded
    ///         duration means one commitment spans the whole risk window, so
    ///         predicate 5 is enforceable without renewal, NAV checkpointing or
    ///         claims-made attribution.
    ///
    ///         ZERO MEANS UNSET, hence unbounded — preserving the behaviour of
    ///         every deployment made before this parameter existed. A live
    ///         protocol should seat it; `GovernorParameters` treats 0 as "no
    ///         protocol ceiling" rather than "nothing is proposable", because
    ///         failing closed here would brick existing vaults on upgrade.
    uint256 public maxStrategyDuration;

    /// @dev Private with an explicit struct getter rather than `public`: the
    ///      auto-getter would return a flat tuple, and every consumer here
    ///      wants the struct whole so it can be snapshotted onto a proposal in
    ///      one assignment.
    MgmtSplit private _mgmtSplit;
    PerfSplit private _perfSplit;

    /// @dev Seeded with the launch splits so a config is valid from birth. This
    ///      contract is not upgradeable, so adopting the two-number fee model
    ///      means deploying a fresh one and re-pointing governors via
    ///      `setProtocolConfig` — seeding at that moment removes the "operator
    ///      forgot to set the split" failure class entirely. Combined with the
    ///      setters' sum check, an invalid split is unreachable rather than
    ///      merely discouraged. Governance can still change either at will.
    constructor(address owner_) Ownable(owner_) {
        // Management 70/20/10 — the agent manages the book, the protocol runs
        // the rails, the guardian network reviews. The guardian slice is the
        // always-on funding the economic-security analysis called for: review
        // effort does not stop when markets go flat.
        _mgmtSplit = MgmtSplit({agentBps: 7000, protocolBps: 2000, guardianBps: 1000});
        // Performance 60/15/15/10 — the fund owner earns only on the profit
        // side, which is why this leg exists here and not above.
        _perfSplit = PerfSplit({agentBps: 6000, protocolBps: 1500, guardianBps: 1500, ownerBps: 1000});
    }

    /// @inheritdoc IProtocolConfig
    function mgmtSplit() external view returns (MgmtSplit memory) {
        return _mgmtSplit;
    }

    /// @inheritdoc IProtocolConfig
    function perfSplit() external view returns (PerfSplit memory) {
        return _perfSplit;
    }

    /// @notice Set how the always-on management fee divides between the agent,
    ///         the protocol and the guardian network.
    /// @dev Only the sum is constrained, so a zero share is legal — governance
    ///      may route the whole fee to one party. The sum is widened to
    ///      `uint256` so the check does not depend on `uint16` headroom if a
    ///      field type ever changes.
    function setMgmtSplit(MgmtSplit calldata s) external onlyOwner {
        uint256 sum = uint256(s.agentBps) + s.protocolBps + s.guardianBps;
        if (sum != FeeConstants.BPS_DENOMINATOR) revert InvalidMgmtSplit();
        _mgmtSplit = s;
        emit MgmtSplitSet(s.agentBps, s.protocolBps, s.guardianBps);
    }

    /// @notice Set how the performance fee divides between the agent, the
    ///         protocol, the guardian network and the fund owner.
    /// @dev One division of one base — deliberately not the sequential
    ///      waterfall it replaces, which compounded four separate haircuts.
    function setPerfSplit(PerfSplit calldata s) external onlyOwner {
        uint256 sum = uint256(s.agentBps) + s.protocolBps + s.guardianBps + s.ownerBps;
        if (sum != FeeConstants.BPS_DENOMINATOR) revert InvalidPerfSplit();
        _perfSplit = s;
        emit PerfSplitSet(s.agentBps, s.protocolBps, s.guardianBps, s.ownerBps);
    }

    /// @dev Changing this does NOT retroactively bind in-flight proposals: the
    ///      governor snapshots parameters at propose time, so it only affects
    ///      proposals created afterwards.
    function setMaxStrategyDuration(uint256 newValue) external onlyOwner {
        if (newValue != 0 && newValue < MIN_PROTOCOL_MAX_STRATEGY_DURATION) {
            revert InvalidMaxStrategyDuration();
        }
        uint256 old = maxStrategyDuration;
        maxStrategyDuration = newValue;
        emit ParameterChangeFinalized(keccak256("maxStrategyDuration"), old, newValue);
    }

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
