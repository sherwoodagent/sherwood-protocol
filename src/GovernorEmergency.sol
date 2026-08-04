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
    /// @dev The RAW, propose-time-declared per-call settlement caps (issue
    ///      #43) — i.e. `_settlementCallCaps`, before any coverage scaling
    ///      (issue #27 design D7). No path in this abstract reads these
    ///      directly any more: `unstick` replays the voted settlement batch
    ///      under `_getEffectiveSettlementCallCaps` below, the SAME
    ///      coverage-scaled caps `settleProposal` uses, so a batch that
    ///      would revert `CallCapExceeded` under `settleProposal` cannot be
    ///      drained for more via `unstick` either. Kept declared (not
    ///      removed) purely so `SyndicateGovernor`'s existing override
    ///      keeps compiling / stays available to any other caller of the
    ///      raw declaration.
    function _getSettlementCallCaps(uint256) internal view virtual returns (uint256[] storage);
    /// @dev The coverage-scaled per-call settlement caps (issue #27 design
    ///      D7), i.e. `_effectiveSettlementCallCaps` — persisted ONCE at
    ///      execute (identity copy of the raw caps when the quorum gate did
    ///      not run or coverage was full; never left empty for an
    ///      `Executed` proposal) and reused byte-identical by
    ///      `settleProposal`. `unstick` MUST read from here, not from
    ///      `_getSettlementCallCaps`: the raw declaration is priced against
    ///      `maxCapital`, the coverage the proposal was VOTED on, not the
    ///      coverage it actually RAISED — replaying the raw caps would let
    ///      `unstick` drain up to the full uncovered declaration whenever a
    ///      partially-covered proposal's scaled caps would revert
    ///      `CallCapExceeded` under `settleProposal` (issue #181 audit-2,
    ///      the 9-agent finding). Implemented by `SyndicateGovernor` as
    ///      `return _effectiveSettlementCallCaps[id];` — see
    ///      `needsOwnerDecision` in the fixing agent's report; not yet wired
    ///      as of this edit.
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
        // Same EFFECTIVE capital cap as settleProposal — NOT `p.maxCapital`
        // (issue #181 audit-2): `p.maxCapital` is the propose-time
        // declaration the vote covered; `p.effectiveMaxCapital` is that
        // declaration scaled down to what the proposal's coverage cohort
        // actually raised (issue #27 design D3-D5), and is the SAME value
        // `executeProposal` and `settleProposal` are bounded by. `unstick`
        // replaying under `p.maxCapital` would let a proposer size a
        // settlement leg so the scaled cap reverts `CallCapExceeded` under
        // `settleProposal` — making `settleProposal` permanently
        // unavailable — and then drain up to the FULL uncovered
        // declaration through this path, which requires no guardian
        // review. An honest unwind is net-inflow and passes any finite
        // cap regardless of its size, so this tightening costs a genuine
        // rescue nothing.
        //
        // Same EFFECTIVE stored settlement caps too (issue #43 x #27
        // design D7) — `unstick` REPLAYS the voted batch under the
        // coverage-scaled per-call caps `settleProposal` uses, not the raw
        // propose-time declaration: it carries the exact caps that batch
        // would be metered against by `settleProposal`, no more. Relief
        // from an over-tight scaled cap is the guardian-reviewed
        // `emergencySettleWithCalls` / `finalizeEmergencySettle` path, not
        // this one.
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

        // Same EFFECTIVE capital cap as settleProposal/unstick — NOT
        // `p.maxCapital` (issue #181 audit-2): using the full propose-time
        // declaration here reopens the exact same 10x-coverage widening
        // `unstick` had, just gated behind guardian review + owner bond
        // instead of open to anyone. An honest emergency unwind is still
        // net-inflow and passes any finite cap, INCLUDING a coverage-
        // floored `effectiveMaxCapital` of zero — so this tightening does
        // not brick a genuine rescue. It cannot, by construction: reaching
        // `Executed` at all required the ORIGINAL execute batch to pass
        // under this SAME `p.effectiveMaxCapital` value (it is derived
        // once, at execute, and never recomputed), so a proposal that
        // actually deployed real net capital necessarily has a nonzero
        // `effectiveMaxCapital` here too — the cap is only ever zero for a
        // proposal whose execute leg moved nothing, i.e. exactly the
        // "propose, deploy nothing, drain on the rescue path" attack this
        // fix closes, not a proposal with real stuck capital to recover.
        //
        // EMPTY caps (issue #43): these are owner-supplied rescue calls
        // with no propose-time declaration to enforce — guardian review +
        // the owner bond + the effectiveMaxCapital meter bound them
        // instead. Must not per-call-meter here: this is precisely the
        // escape hatch for a proposal stuck by a settlement-leg
        // `CallCapExceeded` (design.md D3) — enforcing per-call caps on
        // the rescue path could brick on the very declaration that
        // stranded the proposal. The BATCH-level ceiling is tightened to
        // `effectiveMaxCapital` regardless, since that ceiling is not what
        // D3 was designed to relax (D3 is about the per-call caps).
        ISyndicateVault(p.vault).executeGovernorBatch(calls, new uint256[](0), p.effectiveMaxCapital);
        (int256 pnl,) = _finishSettlementHook(proposalId, p);
        emit EmergencySettleFinalized(proposalId, pnl);
    }

    /// @dev Per-abstract upgrade-hygiene storage gap.
    uint256[10] private __emergencyGap;
}
