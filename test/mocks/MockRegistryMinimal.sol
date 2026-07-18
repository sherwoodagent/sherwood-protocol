// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";

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

    function getReviewState(address, uint256)
        external
        pure
        returns (bool opened, bool resolved, bool blocked, bool cohortTooSmall)
    {
        // `resolved = true` so _resolveAfterVote skips straight to Approved
        // when reviewPeriod == 0. `blocked = false` so the vote outcome sticks.
        return (true, true, false, false);
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

    function addGovernor(address) external pure {
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

    function setBlockQuorumBps(uint256) external pure {
        revert NotImplemented();
    }

    function getApproverWeights(address, uint256) external pure returns (address[] memory, uint128[] memory, uint128) {
        revert NotImplemented();
    }

    function factory() external pure returns (address) {
        revert NotImplemented();
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
