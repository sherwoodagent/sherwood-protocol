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

    /// @notice An LP-vetoed proposal, not yet flushed, refuses both an approval and a block.
    function test_vote_revertsOnVetoedProposalBeforeFlush() public {
        uint256 pid = _propose();
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.prank(lp1);
        gov.vote(pid, ISyndicateGovernor.VoteType.Against);
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        assertEq(uint256(gov.stateOf(pid)), uint256(ISyndicateGovernor.ProposalState.Rejected));

        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        _vote(g1, pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        _vote(g2, pid, IGuardianRegistry.GuardianVoteType.Block);

        gov.resolveProposalState(pid);
        (, bool resolved,) = registry.getReviewState(address(gov), pid);
        assertTrue(resolved, "flush closes the review");
    }

    /// @notice At `== voteEnd` the governor is still Pending, so the vote waits one second.
    function test_vote_revertsAtVoteEndWhileGovernorPending() public {
        uint256 pid = _propose();
        uint256 voteEnd = gov.getProposal(pid).voteEnd;
        vm.warp(voteEnd);
        assertEq(uint256(gov.stateOf(pid)), uint256(ISyndicateGovernor.ProposalState.Pending));

        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        _vote(g1, pid, IGuardianRegistry.GuardianVoteType.Approve);

        vm.prank(agent);
        gov.cancelProposal(pid);
        (, bool resolved,) = registry.getReviewState(address(gov), pid);
        assertTrue(resolved, "cancel closes the review");
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
}
