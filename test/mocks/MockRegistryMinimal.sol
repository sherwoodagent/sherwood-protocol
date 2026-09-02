// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";
import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";

/// @notice Minimal guardian-registry mock exposing the read surface consumed by
///         SyndicateGovernor: `reviewPeriod()` (called during `propose` /
///         `settleProposal` to compute `reviewEnd`), `resolveReview()` (called
///         on the Approved edge after the review window elapses), and
///         `getReviewState()` (consulted by `getProposalState`).
///
///         Defaults model a "no review" cohort so governor unit tests that
///         pre-date the guardian-review lifecycle keep their previous
///         semantics: `reviewPeriod == 0` (no review window), `resolveReview`
///         returns `false` (never blocks), and `getReviewState` returns
///         `resolved = true, blocked = false` so `_resolveAfterVote` maps a
///         passing vote straight to Approved once the vote window closes.
///
///         Used by governor unit tests that exercise the optimistic path and
///         don't need a full `GuardianRegistry` + WOOD + staking setup. Tests
///         that drive the guardian-review lifecycle (open/resolve/slash) must
///         use a real `GuardianRegistry` proxy.
///
///         Declares `is IGuardianRegistry` so the compiler enforces interface
///         conformance: any interface change that isn't mirrored here fails
///         `forge build` instead of silently breaking ~27 consumer test files
///         with `unrecognized function selector`. Every interface member the
///         governor's mocked happy path never touches reverts with
///         `NotImplemented()` — a loud failure if a test wanders onto it.
contract MockRegistryMinimal is IGuardianRegistry {
    /// @notice Raised by every interface member this mock deliberately does
    ///         not model. Use a real `GuardianRegistry` proxy for those paths.
    error NotImplemented();

    uint256 public reviewPeriod;

    function setReviewPeriod(uint256 r) external {
        reviewPeriod = r;
    }

    function resolveReview(address, uint256) external pure returns (bool blocked) {
        return false;
    }

    function getReviewState(address, uint256) external pure returns (bool opened, bool resolved, bool blocked) {
        // `resolved = true` so _resolveAfterVote skips straight to Approved
        // when reviewPeriod == 0. `blocked = false` so the vote outcome sticks.
        return (true, true, false);
    }

    /// @dev V2: `_finishSettlement` calls `isEmergencyOpen` to decide whether
    ///      to cancel a dangling emergency review. Returns false so the cancel
    ///      branch is skipped in governor unit tests.
    function isEmergencyOpen(address, uint256) external pure returns (bool) {
        return false;
    }

    /// @dev V2: stub so governor unit tests compile. Never called when
    ///      `isEmergencyOpen` returns false.
    function cancelEmergency(uint256) external pure {}

    /// @notice Tracks calls so cancel-during-GuardianReview tests can assert
    ///         the governor invokes the registry hook on proposer cancel.
    uint256 public cancelReviewCallCount;
    uint256 public lastCancelledProposalId;

    /// @dev Called by the governor when the proposer cancels during
    ///      `GuardianReview`. Production registry rejects this after
    ///      `reviewEnd`; the mock unconditionally records the call.
    function cancelReview(uint256 proposalId) external {
        cancelReviewCallCount++;
        lastCancelledProposalId = proposalId;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Not modeled — revert loudly. Interface conformance stubs only.
    // ─────────────────────────────────────────────────────────────────────

    function voteOnProposal(address, uint256, GuardianVoteType, uint256) external pure {
        revert NotImplemented();
    }

    function addGovernor(address, address) external pure {
        revert NotImplemented();
    }

    /// @dev The governor pushes the review window here at every Draft/Pending
    ///      transition (review registration). Accepted as a no-op: this mock
    ///      models a "no review" cohort, so there is no window state to keep.
    ///      Reverting would brick `propose()` for every governor unit test.
    function registerReview(uint256, uint256, uint256) external pure {}

    function reviewWindow(address, uint256) external pure returns (uint64, uint64) {
        revert NotImplemented();
    }

    function vaultOf(address) external pure returns (address) {
        revert NotImplemented();
    }

    function openEmergency(uint256, bytes32, BatchExecutorLib.Call[] calldata) external pure {
        revert NotImplemented();
    }

    function finalizeEmergency(uint256) external pure returns (bool, BatchExecutorLib.Call[] memory) {
        revert NotImplemented();
    }

    function openReview(address, uint256) external pure {
        revert NotImplemented();
    }

    function resolveEmergencyReview(address, uint256) external pure {
        revert NotImplemented();
    }

    function voteBlockEmergencySettle(address, uint256) external pure {
        revert NotImplemented();
    }

    function fundSlashAppealReserve(uint256) external pure {
        revert NotImplemented();
    }

    function refundSlash(address, uint256) external pure {
        revert NotImplemented();
    }

    function pause() external pure {
        revert NotImplemented();
    }

    function unpause() external pure {
        revert NotImplemented();
    }

    /// @dev The stub is never paused: it has no pause state to flip, and the
    ///      governor consults this before holding a proposal in GuardianReview.
    function paused() external pure returns (bool) {
        return false;
    }

    function setBlockQuorumBps(uint256) external pure {
        revert NotImplemented();
    }

    function setExposureLedger(address) external pure {
        revert NotImplemented();
    }

    function exposureLedger() external pure returns (IExposureLedger) {
        revert NotImplemented();
    }

    function getApproverWeights(address, uint256) external pure returns (address[] memory, uint128[] memory, uint128) {
        revert NotImplemented();
    }

    function getApproverCoverage(address, uint256) external pure returns (address[] memory, uint256[] memory, bool) {
        revert NotImplemented();
    }

    /// @dev Read by `ProposalLifecycle._afterVote` in place of the old
    ///      `getReviewState` 4-tuple. `Cleared` is the exact translation of this
    ///      mock's long-standing default (`resolved = true, blocked = false`):
    ///      a passing vote maps straight to Approved once the vote window
    ///      closes, preserving the "no review" cohort semantics above.
    function outcomeOf(address, uint256) external pure returns (ReviewOutcome) {
        return ReviewOutcome.Cleared;
    }

    /// @dev Modeled rather than reverting, because this mock IS the case
    ///      `SyndicateFactory.setGuardianRegistry` calls a "stateless beta stub"
    ///      (Sherlock run #1 #28): that check probes `factory()` and accepts
    ///      either this factory's own address (alignment) or `address(0)` (no
    ///      factory binding), rejecting anything else — a revert included. This
    ///      mock has no factory binding, so `address(0)` is the honest answer;
    ///      reverting made the stub unswappable and failed a check it is meant
    ///      to pass. Tests needing an ALIGNED registry must use a real
    ///      `GuardianRegistry` proxy, which stores the factory it was
    ///      initialized with.
    function factory() external pure returns (address) {
        return address(0);
    }

    function swood() external pure returns (IStakedWood) {
        revert NotImplemented();
    }

    function ownerStake(address) external pure returns (uint256) {
        revert NotImplemented();
    }

    function minOwnerStake() external pure returns (uint256) {
        revert NotImplemented();
    }

    function requiredOwnerBond(address) external pure returns (uint256) {
        revert NotImplemented();
    }
}
