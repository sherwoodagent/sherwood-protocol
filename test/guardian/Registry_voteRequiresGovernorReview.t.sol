// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChallengeEndToEndBase} from "../challenge/ChallengeEndToEnd.t.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice SHE-471: a guardian vote lands only while the governor reports GuardianReview.
contract RegistryVoteRequiresGovernorReviewTest is ChallengeEndToEndBase {
    function _vote(address g, uint256 pid, IGuardianRegistry.GuardianVoteType t) internal {
        vm.prank(g);
        registry.voteOnProposal(address(gov), pid, t, type(uint256).max);
    }

    /// @dev Attempts a vote without failing the test; a landed vote is what the harm tests must not see.
    function _tryVote(address g, uint256 pid, IGuardianRegistry.GuardianVoteType t) internal returns (bool ok) {
        vm.prank(g);
        (ok,) =
            address(registry).call(abi.encodeCall(registry.voteOnProposal, (address(gov), pid, t, type(uint256).max)));
    }

    /// @dev g1 approves and g2 + g3 (57% of 70k, over the 30% block quorum) block.
    function _tryApproveAndBlock(uint256 pid) internal {
        _tryVote(g1, pid, IGuardianRegistry.GuardianVoteType.Approve);
        _tryVote(g2, pid, IGuardianRegistry.GuardianVoteType.Block);
        _tryVote(g3, pid, IGuardianRegistry.GuardianVoteType.Block);
    }

    function _vetoedAtVoteEndPlusOne() internal returns (uint256 pid) {
        pid = _propose();
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.prank(lp1);
        gov.vote(pid, ISyndicateGovernor.VoteType.Against);
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        assertEq(uint256(gov.stateOf(pid)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    /// @notice An LP-vetoed proposal, not yet flushed, refuses both an approval and a block.
    function test_vote_revertsOnVetoedProposalBeforeFlush() public {
        uint256 pid = _vetoedAtVoteEndPlusOne();

        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        _vote(g1, pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        _vote(g2, pid, IGuardianRegistry.GuardianVoteType.Block);
    }

    /// @notice At `== voteEnd` the governor is still Pending, so the vote waits one second.
    function test_vote_revertsAtVoteEndWhileGovernorPending() public {
        uint256 pid = _propose();
        vm.warp(gov.getProposal(pid).voteEnd);
        assertEq(uint256(gov.stateOf(pid)), uint256(ISyndicateGovernor.ProposalState.Pending));

        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        _vote(g1, pid, IGuardianRegistry.GuardianVoteType.Approve);
    }

    /// @notice Control: one second later the governor is in GuardianReview and the vote lands.
    function test_vote_landsOnceGovernorInReview() public {
        uint256 pid = _propose();
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        assertEq(uint256(gov.stateOf(pid)), uint256(ISyndicateGovernor.ProposalState.GuardianReview));
        _vote(g1, pid, IGuardianRegistry.GuardianVoteType.Approve);
        (bool opened,,) = registry.getReviewState(address(gov), pid);
        assertTrue(opened);
    }

    /// @notice Approve + blocking bloc on a vetoed, unflushed proposal, then flush and settle: g1 keeps 30,000 WOOD.
    function test_resolveReview_vetoedProposal_approverKeepsStake() public {
        uint256 pid = _vetoedAtVoteEndPlusOne();
        uint256 before = swood.guardianStake(g1);
        assertEq(before, G1_STAKE);

        _tryApproveAndBlock(pid);
        gov.resolveProposalState(pid);
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        bool convicted = registry.resolveReview(address(gov), pid);
        assertEq(swood.guardianStake(g1), before, "approver slashed for a vetoed proposal");
        assertFalse(convicted, "nothing to convict");
        (, bool resolved, bool blocked) = registry.getReviewState(address(gov), pid);
        assertTrue(resolved, "flush closes the review");
        assertFalse(blocked, "no bloc could form");
    }

    /// @notice Same at `== voteEnd` with the proposer's Pending-branch cancel: g1 keeps 30,000 WOOD.
    function test_resolveReview_cancelledAtVoteEnd_approverKeepsStake() public {
        uint256 pid = _propose();
        vm.warp(gov.getProposal(pid).voteEnd);
        uint256 before = swood.guardianStake(g1);
        assertEq(before, G1_STAKE);

        _tryApproveAndBlock(pid);
        vm.prank(agent);
        gov.cancelProposal(pid);
        assertEq(uint256(gov.stateOf(pid)), uint256(ISyndicateGovernor.ProposalState.Cancelled));
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        bool convicted = registry.resolveReview(address(gov), pid);
        assertEq(swood.guardianStake(g1), before, "approver slashed for a cancelled proposal");
        assertFalse(convicted, "nothing to convict");
        (, bool resolved, bool blocked) = registry.getReviewState(address(gov), pid);
        assertTrue(resolved, "cancel closes the review");
        assertFalse(blocked, "no bloc could form");
    }
}
