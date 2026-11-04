// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {She470Harness} from "./She470Harness.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

/// @notice SHE-483 (L-5): a same-owner `rotateOwner` re-bond keeps the agent set.
contract RebondKeepsAgentsTest is She470Harness {
    MockStrategy internal template;

    function setUp() public {
        _setUpProtocol();
        _deposit(lp, 100_000e6);
        template = new MockStrategy();
        vm.prank(owner);
        p.strategies.setTemplateApproval(address(template), true);
    }

    /// @notice After the documented 5.1 re-bond the owner stays an agent and its live clone still answers it.
    function test_sameOwnerRebond_keepsAgentAndCloneProposer() public {
        bytes memory data = abi.encode(address(p.asset), address(0x1), uint256(1), uint256(1), false);
        vm.prank(owner);
        address clone = p.strategies.cloneAndInit(address(template), address(p.vault), owner, data);
        BatchExecutorLib.Call[] memory exec = new BatchExecutorLib.Call[](1);
        exec[0] = _call(clone, abi.encodeCall(BaseStrategy.execute, ()));
        uint256[] memory caps = new uint256[](1);
        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](1);
        settle[0] = _call(clone, abi.encodeCall(BaseStrategy.settle, ()));
        uint256 pid = _propose(owner, clone, 1 hours, 100_000e6, 10_000, exec, caps, settle, caps);
        _passReviewAndExecute(pid);

        // Blocked emergency round burns the owner bond.
        vm.warp(p.governor.getProposal(pid).executedAt + 1 hours + 1);
        BatchExecutorLib.Call[] memory none = new BatchExecutorLib.Call[](0);
        vm.prank(owner);
        p.governor.emergencySettleWithCalls(pid, none);
        vm.prank(guardian);
        p.registry.voteBlockEmergencySettle(address(p.governor), pid);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        p.registry.resolveEmergencyReview(address(p.governor), pid);
        assertEq(p.registry.ownerStake(address(p.vault)), 0, "bond burned");

        uint256 bond = p.swood.minOwnerStake();
        p.wood.mint(owner, bond);
        vm.startPrank(owner);
        p.wood.approve(address(p.swood), bond);
        p.swood.prepareOwnerStake(bond);
        p.swood.approveOwnerStakeBinding(address(p.vault));
        p.factory.rotateOwner(address(p.vault), owner);
        vm.stopPrank();

        assertTrue(p.vault.isAgent(owner), "agent set kept on a same-owner rotation");
        vm.prank(owner);
        MockStrategy(clone).updateParams("");
        assertEq(MockStrategy(clone).updateCount(), 1);
    }
}
