// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {She470Harness, She470PullStrategy} from "./She470Harness.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

/// @notice SHE-486 (L-8): a block vote on an emergency round lands only while the proposal is Executed.
contract EmergencyVoteAfterSettleTest is She470Harness {
    She470PullStrategy internal s;
    uint256 internal pid;

    function setUp() public {
        _setUpProtocol();
        _deposit(lp, 100_000e6);
        s = new She470PullStrategy(address(p.vault), owner);
        p.strategies.registerStrategy(address(s));
        pid = _pullProposal(owner, s, 1_000e6, 100_000e6, 10_000, 1 hours);
        _passReviewAndExecute(pid);
        s.push(address(p.asset), 1_000e6);
        vm.warp(p.governor.getProposal(pid).executedAt + 1 hours + 1);
        BatchExecutorLib.Call[] memory none = new BatchExecutorLib.Call[](0);
        vm.prank(owner);
        p.governor.emergencySettleWithCalls(pid, none);
    }

    /// @notice After a third-party settle a block vote reverts and resolving leaves the owner bond intact.
    function test_blockVoteAfterThirdPartySettle_reverts() public {
        uint256 bond = p.registry.ownerStake(address(p.vault));
        assertGt(bond, 0);
        vm.prank(lp);
        p.governor.settleProposal(pid);

        vm.prank(guardian);
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        p.registry.voteBlockEmergencySettle(address(p.governor), pid);

        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        p.registry.resolveEmergencyReview(address(p.governor), pid);
        assertEq(p.registry.ownerStake(address(p.vault)), bond, "bond intact");
    }

    /// @notice Control: a block cast before the settle still burns the bond at resolve.
    function test_blockVoteBeforeSettle_stillBurns() public {
        vm.prank(guardian);
        p.registry.voteBlockEmergencySettle(address(p.governor), pid);
        vm.prank(lp);
        p.governor.settleProposal(pid);

        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        p.registry.resolveEmergencyReview(address(p.governor), pid);
        assertEq(p.registry.ownerStake(address(p.vault)), 0, "bond burned");
    }
}
