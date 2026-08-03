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
    /// @dev The stored per-call settlement caps (issue #43), mirroring
    ///      `_getSettlementCalls`. `unstick` replays the voted settlement
    ///      batch under these SAME caps — it does not relax the declaration
    ///      the batch was priced with.
    function _getSettlementCallCaps(uint256) internal view virtual returns (uint256[] storage);
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
        // Same maxCapital cap as execute/settle: an honest unwind is net-inflow
        // and passes any finite cap; only extraction parked in the pre-committed
        // settlement calls can trip it. Same stored settlement caps too (issue
        // #43) — `unstick` REPLAYS the voted batch, so it carries the exact
        // caps that batch was priced with; relief from an over-tight cap is
        // the guardian-reviewed `emergencySettleWithCalls` path, not this one.
        ISyndicateVault(p.vault)
            .executeGovernorBatch(_getSettlementCalls(proposalId), _getSettlementCallCaps(proposalId), p.maxCapital);
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
        if (reg.ownerStake(p.vault) < reg.requiredOwnerBond(p.vault)) revert OwnerBondInsufficient();

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

        // Same maxCapital cap as execute/settle: an honest emergency unwind is
        // net-inflow and passes any finite cap; only extraction smuggled into
        // the owner-supplied calls can trip it. EMPTY caps (issue #43): these
        // are owner-supplied rescue calls with no propose-time declaration to
        // enforce — guardian review + the owner bond + the maxCapital meter
        // bound them instead. Must not per-call-meter here: this is precisely
        // the escape hatch for a proposal stuck by a settlement-leg
        // `CallCapExceeded` (design.md D3) — enforcing caps on the rescue path
        // could brick on the very declaration that stranded the proposal.
        ISyndicateVault(p.vault).executeGovernorBatch(calls, new uint256[](0), p.maxCapital);
        (int256 pnl,) = _finishSettlementHook(proposalId, p);
        emit EmergencySettleFinalized(proposalId, pnl);
    }

    /// @dev Per-abstract upgrade-hygiene storage gap.
    uint256[10] private __emergencyGap;
}
