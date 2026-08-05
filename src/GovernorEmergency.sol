// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {ProposalLifecycle} from "./ProposalLifecycle.sol";

/// @title GovernorEmergency
/// @notice Abstract — emergency settlement paths extracted for bytecode headroom.
///         Inherited by SyndicateGovernor alongside GovernorParameters.
///
///         All emergency state (call hash, call array, review lifecycle) is
///         owned by GuardianRegistry. Governor entrypoints are thin wrappers that
///         delegate to the registry and execute calls on the vault.
///
///         - `unstick`: vault owner rescues a proposal stuck in Executed state by
///           running its pre-committed settlement calls (no guardian review).
///         - `emergencySettleWithCalls`: vault owner proposes owner-supplied
///           settlement calls. Opens a guardian review on the registry.
///         - `cancelEmergencySettle`: vault owner withdraws their review.
///         - `finalizeEmergencySettle`: once the review period has elapsed and the
///           block quorum was not reached, the owner executes the reviewed calls.
abstract contract GovernorEmergency is ProposalLifecycle {
    // ── Virtual accessors (implemented by SyndicateGovernor) ──
    //
    // `_proposals` and `_guardianRegistry` are inherited from `ProposalLifecycle`,
    // which owns the lifecycle state. What remains virtual below is governor-owned.

    function _getSettlementCalls(uint256) internal view virtual returns (BatchExecutorLib.Call[] storage);
    /// @dev The RAW, propose-time-declared per-call settlement caps, before any
    ///      coverage scaling. No path in this abstract reads these directly:
    ///      `unstick` replays the voted settlement batch under
    ///      `_getEffectiveSettlementCallCaps` below, the SAME coverage-scaled caps
    ///      `settleProposal` uses, so a batch that would revert `CallCapExceeded`
    ///      under `settleProposal` cannot be drained for more via `unstick`. Kept
    ///      declared so the concrete governor's override keeps compiling.
    function _getSettlementCallCaps(uint256) internal view virtual returns (uint256[] storage);
    /// @dev The coverage-scaled per-call settlement caps, persisted ONCE at execute
    ///      (an identity copy of the raw caps when the quorum gate did not run or
    ///      coverage was full, and never left empty for an `Executed` proposal)
    ///      and reused byte-identical by `settleProposal`. `unstick` MUST read
    ///      from here, not from `_getSettlementCallCaps`: the raw declaration is
    ///      priced against `maxCapital`, the coverage the proposal was VOTED on,
    ///      not the coverage it actually RAISED — replaying the raw caps would let
    ///      `unstick` drain up to the full uncovered declaration whenever a
    ///      partially-covered proposal's scaled caps would revert under
    ///      `settleProposal`.
    function _getEffectiveSettlementCallCaps(uint256) internal view virtual returns (uint256[] storage);
    function _emergencyReentrancyEnter() internal virtual;
    function _emergencyReentrancyLeave() internal virtual;
    function _finishSettlementHook(uint256 pid, StrategyProposal storage p)
        internal
        virtual
        returns (int256 pnl, uint256 totalFee);

    // ── Reentrancy modifier (shares status var with SyndicateGovernor) ──

    modifier emergencyNonReentrant() {
        _emergencyReentrancyEnter();
        _;
        _emergencyReentrancyLeave();
    }

    /// @dev Shared vault-owner gate. Reachable from SyndicateGovernor (which inherits
    ///      this abstract). Bytecode lever: folds 6 identical inline copies into one.
    function _requireVaultOwner(address vault) internal view {
        if (msg.sender != ISyndicateVault(vault).owner()) revert NotVaultOwner();
    }

    // ── Emergency settle lifecycle ──

    /// @notice Rescues a proposal stuck in Executed state past its duration by
    ///         running the governance-approved pre-committed settlement calls.
    /// @dev Does NOT require active owner stake — the calls were already voted on.
    function unstick(uint256 proposalId) external emergencyNonReentrant {
        StrategyProposal storage p = _proposals[proposalId];
        _requireVaultOwner(p.vault);
        if (p.state != ProposalState.Executed) revert ProposalNotExecuted();
        if (block.timestamp < p.executedAt + p.strategyDuration) revert StrategyDurationNotElapsed();
        // Same EFFECTIVE capital cap as `settleProposal` — NOT `p.maxCapital`.
        // That is the propose-time declaration the vote covered;
        // `p.effectiveMaxCapital` is the same declaration scaled down to what the
        // coverage cohort actually raised, and is the SAME value `executeProposal`
        // and `settleProposal` are bounded by. Replaying under `p.maxCapital`
        // would let a proposer size a settlement leg so the scaled cap reverts
        // `CallCapExceeded` under `settleProposal` — making that path permanently
        // unavailable — then drain up to the FULL uncovered declaration through
        // this one, which requires no guardian review. An honest unwind is
        // net-inflow and passes any finite cap, so the tightening costs a genuine
        // rescue nothing.
        //
        // Same EFFECTIVE stored settlement caps too: `unstick` REPLAYS the voted
        // batch under the coverage-scaled per-call caps `settleProposal` uses, no
        // more. Relief from an over-tight scaled cap is the guardian-reviewed
        // `emergencySettleWithCalls` path, not this one.
        ISyndicateVault(p.vault)
            .executeGovernorBatch(
                _getSettlementCalls(proposalId), _getEffectiveSettlementCallCaps(proposalId), p.effectiveMaxCapital
            );
        _finishSettlementHook(proposalId, p);
    }

    /// @notice Vault owner opens an emergency review on a stuck proposal with
    ///         owner-supplied unwind calls. Requires bonded owner stake.
    ///         All call storage is delegated to the registry.
    function emergencySettleWithCalls(uint256 proposalId, BatchExecutorLib.Call[] calldata calls)
        external
        emergencyNonReentrant
    {
        StrategyProposal storage p = _proposals[proposalId];
        _requireVaultOwner(p.vault);
        if (p.state != ProposalState.Executed) revert ProposalNotExecuted();
        if (block.timestamp < p.executedAt + p.strategyDuration) revert StrategyDurationNotElapsed();

        IGuardianRegistry reg = IGuardianRegistry(_guardianRegistry);
        // STRICTLY POSITIVE, not merely "meets the requirement". `posted == 0`
        // is checked on its own rather than left to the comparison because the
        // comparison alone is satisfiable at zero: a registry (or sWOOD) whose
        // `requiredOwnerBond` reads 0 makes this `0 < 0` — false — so the gate
        // passed with nothing bonded, `slashOwnerBond` returned early on
        // `amount == 0`, and the deterrent behind `finalizeEmergencySettle` —
        // owner-supplied calldata run with EMPTY per-call caps, bounded only by
        // `effectiveMaxCapital` — was a no-op. sWOOD's `requiredOwnerBond` now
        // floors at `MIN_OWNER_BOND_FLOOR` and so can no longer report 0, but
        // `_guardianRegistry` is a settable pointer and this is a security gate:
        // it states the invariant locally and fails closed on any registry that
        // stops enforcing it. Deliberately redundant with the sWOOD floor.
        //
        // Strands nothing that matters: `unstick` replays the ALREADY-VOTED
        // settlement batch above with no bond requirement at all, so the honest
        // stuck-proposal path is untouched. This gate covers only the path that
        // lets the owner write the calldata.
        uint256 posted = reg.ownerStake(p.vault);
        if (posted == 0 || posted < reg.requiredOwnerBond(p.vault)) revert OwnerBondInsufficient();

        bytes32 h = keccak256(abi.encode(calls));
        reg.openEmergency(proposalId, h, calls);
        emit EmergencySettleProposed(proposalId, msg.sender, h, uint64(block.timestamp + reg.reviewPeriod()));
    }

    /// @notice Vault owner withdraws their open emergency review before resolution.
    function cancelEmergencySettle(uint256 proposalId) external emergencyNonReentrant {
        StrategyProposal storage p = _proposals[proposalId];
        _requireVaultOwner(p.vault);
        if (p.state != ProposalState.Executed) revert ProposalNotExecuted();
        IGuardianRegistry reg = IGuardianRegistry(_guardianRegistry);
        if (!reg.isEmergencyOpen(address(this), proposalId)) revert EmergencyNotProposed();
        reg.cancelEmergency(proposalId);
        emit EmergencySettleCancelled(proposalId, msg.sender);
    }

    /// @notice Resolves a reviewed emergency settle and executes the approved calls.
    ///         Registry returns the stored calls; governor executes them on the vault.
    function finalizeEmergencySettle(uint256 proposalId) external emergencyNonReentrant {
        StrategyProposal storage p = _proposals[proposalId];
        _requireVaultOwner(p.vault);
        if (p.state != ProposalState.Executed) revert ProposalNotExecuted();

        IGuardianRegistry reg = IGuardianRegistry(_guardianRegistry);
        (bool blocked, BatchExecutorLib.Call[] memory calls) = reg.finalizeEmergency(proposalId);
        if (blocked) revert EmergencySettleBlocked();

        // Same EFFECTIVE capital cap as `settleProposal`/`unstick` — NOT
        // `p.maxCapital`: using the full propose-time declaration here reopens the
        // same coverage widening `unstick` had, just gated behind guardian review
        // and the owner bond instead of open to anyone. An honest emergency unwind
        // is net-inflow and passes any finite cap, INCLUDING a coverage-floored
        // `effectiveMaxCapital` of zero — and it cannot brick a genuine rescue by
        // construction: reaching `Executed` required the ORIGINAL execute batch to
        // pass under this SAME value, so a proposal that deployed real net capital
        // necessarily has a nonzero cap here. The cap is only ever zero for a
        // proposal whose execute leg moved nothing — exactly the
        // deploy-nothing-drain-on-the-rescue-path attack this closes.
        //
        // EMPTY caps: these are owner-supplied rescue calls with no propose-time
        // declaration to enforce — guardian review, the owner bond and the
        // `effectiveMaxCapital` meter bound them instead. Must NOT per-call-meter
        // here: this is precisely the escape hatch for a proposal stuck by a
        // settlement-leg `CallCapExceeded`, so enforcing per-call caps could brick
        // on the very declaration that stranded the proposal. The BATCH-level
        // ceiling is tightened regardless, since that is not what the escape hatch
        // was designed to relax.
        ISyndicateVault(p.vault).executeGovernorBatch(calls, new uint256[](0), p.effectiveMaxCapital);
        (int256 pnl,) = _finishSettlementHook(proposalId, p);
        emit EmergencySettleFinalized(proposalId, pnl);
    }

    /// @dev Per-abstract upgrade-hygiene storage gap.
    uint256[10] private __emergencyGap;
}
