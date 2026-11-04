// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {She470Harness, She470PullStrategy} from "./She470Harness.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice SHE-487 (L-9): a registry pause after `reviewEnd` cannot hold a proposal past `executeBy`.
contract LifecyclePausedExpiryTest is She470Harness {
    She470PullStrategy internal s;

    function setUp() public {
        _setUpProtocol();
        _deposit(lp, 100_000e6);
        s = new She470PullStrategy(address(p.vault), owner);
        p.strategies.registerStrategy(address(s));
    }

    /// @notice Paused past `reviewEnd`, the proposal reads GuardianReview until `executeBy`, then Expired.
    function test_pausedAfterReviewEnd_expiresAtExecuteBy() public {
        uint256 pid = _pullProposal(owner, s, 1_000e6, 100_000e6, 10_000, 1 hours);
        _passReview(pid);
        assertEq(uint256(p.governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));

        vm.prank(owner);
        p.registry.pause();
        assertEq(
            uint256(p.governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.GuardianReview),
            "held in review while paused"
        );

        vm.warp(p.governor.getProposal(pid).executeBy + 1);
        assertEq(
            uint256(p.governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Expired),
            "expired past executeBy"
        );
        p.governor.resolveProposalState(pid);
        assertEq(uint256(p.governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Expired));
        assertEq(p.governor.openProposalCount(), 0, "vault released");
    }
}
