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
    /// @notice Floor on the protocol-wide strategy-duration ceiling. Guards the
    ///         degenerate setting: a ceiling below the shortest usable strategy
    ///         would make every vault unproposable protocol-wide in one
    ///         transaction.
    uint256 public constant MIN_PROTOCOL_MAX_STRATEGY_DURATION = 1 days;

    /// @notice Where the protocol's share is sent — both the settlement splits
    ///         and the self-managed strategy's crystallisation.
    /// @dev A zero recipient unwires the leg: the governor folds its share into
    ///      the agent's remainder rather than paying `address(0)`, where the
    ///      transfer would revert and escrow permanently unclaimable.
    address public protocolFeeRecipient;

    /// @notice Where the guardian network's share of each fee is sent.
    /// @dev The rate lever is `mgmtSplit.guardianBps` / `perfSplit.guardianBps`;
    ///      this address is destination only.
    address public guardiansFeeRecipient;

    /// @notice Protocol-wide CEILING on `strategyDuration`; every vault's own
    ///         `maxStrategyDuration` is clamped to it.
    ///
    /// @dev    Lives here rather than on the vault because a strategy's duration
    ///         determines how long the approving GUARDIANS carry exposure, and
    ///         the vault owner is not the party bearing that risk.
    ///
    ///         It is also what lets v1 skip epoch chaining: a bounded
    ///         duration means one commitment spans the whole risk window, so
    ///         the exposure predicate is enforceable without renewal, NAV
    ///         checkpointing or claims-made attribution.
    ///
    ///         ZERO MEANS UNSET, hence unbounded, not "nothing is proposable".
    ///         `GovernorParameters` treats 0 as "no protocol ceiling" rather
    ///         than failing closed, since failing closed here would brick
    ///         existing vaults on upgrade.
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
        // the rails, the guardian network reviews. The guardian slice funds
        // review continuously: review effort does not stop when markets go flat.
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
    /// @dev One division of one base, avoiding a sequential waterfall that
    ///      would compound multiple haircuts.
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

    /// @notice Set where the protocol's share of each fee is sent.
    /// @dev Unconditional: a zero recipient has nothing to be inconsistent
    ///      with, so it simply unwires the leg.
    function setProtocolFeeRecipient(address newRecipient) external onlyOwner {
        address old = protocolFeeRecipient;
        protocolFeeRecipient = newRecipient;
        emit ProtocolFeeRecipientSet(old, newRecipient);
    }

    /// @notice Set where the guardian network's share of both fees is sent.
    /// @dev Unconditional: there is no `guardianFeeBps` to be inconsistent
    ///      with. Zero unwires the leg.
    function setGuardiansFeeRecipient(address newRecipient) external onlyOwner {
        address old = guardiansFeeRecipient;
        guardiansFeeRecipient = newRecipient;
        emit GuardiansFeeRecipientSet(old, newRecipient);
    }
}
