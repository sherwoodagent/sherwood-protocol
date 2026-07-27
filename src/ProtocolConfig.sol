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

    /// @notice Floor on the protocol-wide strategy-duration ceiling. Guards the
    ///         degenerate setting: a ceiling below the shortest usable strategy
    ///         would make every vault unproposable protocol-wide in one
    ///         transaction.
    uint256 public constant MIN_PROTOCOL_MAX_STRATEGY_DURATION = 1 days;

    /// @notice Highest tier `TierRegistry` can report. 0 = closed-loop,
    ///         1 = oracle-bounded, 2 = uncertified — and 2 is the DEFAULT for
    ///         any `(target, selector)` carrying no certification entry.
    uint8 public constant MAX_VALID_ENVELOPE_TIER = 2;

    /// @notice `maxEnvelopeTier` sentinel meaning "no protocol ceiling".
    ///
    /// @dev    DELIBERATELY NOT ZERO. This convention differs from its sibling
    ///         `maxStrategyDuration` below, and the difference is the point.
    ///
    ///         For a duration, 0 is not a meaningful setting — a zero-second
    ///         ceiling makes nothing proposable — so spending 0 on "unset"
    ///         costs nothing. For a tier, EVERY value in [0, 2] is meaningful
    ///         and **0 is the strictest one**: "only closed-loop adapters may
    ///         execute" is precisely the future tightening ADR 2026-07-27
    ///         contemplates. A 0-means-unset convention would make that
    ///         configuration inexpressible, and would fail SILENTLY — a
    ///         governance call seating 0 would read back as "no ceiling" and
    ///         the protocol would go on admitting tier 1 forever, with nothing
    ///         reverting to say so.
    ///
    ///         `type(uint8).max` also makes the check sites free: no tier can
    ///         exceed it, so `tier > maxEnvelopeTier` is self-disabling and
    ///         needs no sentinel branch that could be forgotten at one site.
    uint8 public constant NO_ENVELOPE_TIER_CEILING = type(uint8).max;

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

    /// @notice Protocol-wide CEILING on a proposal's `envelopeTier`. A proposal
    ///         resolving above it can neither be proposed nor executed
    ///         (ADR 2026-07-27). **Launch value 1.**
    ///
    /// @dev    Why refuse rather than price: `2026-07-26-roe-validation.md`
    ///         measures guardian ROE at **0.0% at tier 2** — the entire cohort
    ///         fee pool exactly equals one guardian's expected annual tail
    ///         loss — against 9.5% at tier 1 and 49.5% at tier 0. Guardians
    ///         cannot rationally underwrite tier 2 at k = 1, and a cohort that
    ///         will not participate is the likelier failure than one that
    ///         colludes. Refusing what cannot be priced beats pricing it wrong.
    ///
    ///         Because tier 2 is what `TierRegistry` returns for an
    ///         UNCERTIFIED `(target, selector)`, a ceiling of 1 means **no
    ///         proposal may execute an uncertified call**. Certification is
    ///         therefore a launch prerequisite and an ongoing operating cost,
    ///         not an optimisation.
    ///
    ///         Defaults to `NO_ENVELOPE_TIER_CEILING`, not 0 — see that
    ///         constant. A deployment that never seats this parameter is
    ///         unbounded (matching `maxStrategyDuration`'s posture for
    ///         pre-existing deployments), which is why `DeployPlanB` asserts
    ///         `maxEnvelopeTier <= 1` as a pre-flight rather than trusting the
    ///         default.
    ///
    ///         Enforced at BOTH propose (`_snapshotTierAndGate`) and execute
    ///         (`executeProposal`): live tier can exceed the propose-time
    ///         snapshot after a lazy demotion, so a propose-only ceiling would
    ///         let a demoted adapter execute at tier 2.
    uint8 public maxEnvelopeTier = NO_ENVELOPE_TIER_CEILING;

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Seat the protocol-wide envelope-tier ceiling.
    /// @param  newValue a valid tier (0, 1 or 2) or `NO_ENVELOPE_TIER_CEILING`.
    /// @dev    Like `setMaxStrategyDuration`, this does NOT retroactively bind
    ///         in-flight proposals at propose time — but unlike it, the ceiling
    ///         IS re-read at execute, so LOWERING it can strand an already
    ///         Approved proposal whose tier now breaches it. That is deliberate:
    ///         the ceiling encodes what guardians are willing to underwrite
    ///         right now, and an in-flight proposal is exactly the exposure
    ///         governance just decided it does not want.
    function setMaxEnvelopeTier(uint8 newValue) external onlyOwner {
        if (newValue > MAX_VALID_ENVELOPE_TIER && newValue != NO_ENVELOPE_TIER_CEILING) {
            revert InvalidMaxEnvelopeTier();
        }
        uint8 old = maxEnvelopeTier;
        maxEnvelopeTier = newValue;
        emit ParameterChangeFinalized(keccak256("maxEnvelopeTier"), old, newValue);
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
