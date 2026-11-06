// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {She470Harness, She470PullStrategy} from "./She470Harness.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

/// @notice SHE-479 (L-1) buffer floor net of the queue reserve; SHE-480 (L-2) no `Call.value`.
contract VaultBatchGuardsTest is She470Harness {
    She470PullStrategy internal s;

    function setUp() public {
        _setUpProtocol();
        _deposit(lp, 100_000e6);
        s = new She470PullStrategy(address(p.vault), owner);
        p.strategies.registerStrategy(address(s));
    }

    /// @dev Round trip 50k, lp queues half its shares; leaves reserve 50k and deployable 50k.
    function _seedReserve() internal {
        uint256 pid = _pullProposal(owner, s, 50_000e6, 100_000e6, 10_000, 1 hours);
        _passReviewAndExecute(pid);
        uint256 half = p.vault.balanceOf(lp) / 2;
        vm.prank(lp);
        p.vault.requestRedeem(half, lp);
        s.push(address(p.asset), 50_000e6);
        vm.warp(p.governor.getProposal(pid).executedAt + 1 hours);
        vm.prank(owner);
        p.governor.settleProposal(pid);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
    }

    /// @notice The buffer is charged on the deployable float only, not on the queue reserve.
    function test_buffer_notChargedOnQueueReserve() public {
        _seedReserve();
        uint256 deployable = p.vault.totalAssets();
        assertEq(p.vault.reservedQueueAssets(), 50_000e6);
        assertEq(deployable, 50_000e6);
        vm.prank(owner);
        p.vault.setMinBufferBps(1);
        uint256 pid = _pullProposal(owner, s, 49_994e6, deployable, 10_000, 1 hours);
        _passReviewAndExecute(pid);
        assertEq(uint256(p.governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice The net floor still binds an execute batch that deploys past it.
    function test_buffer_stillBindsOutflowPastNetFloor() public {
        _seedReserve();
        uint256 deployable = p.vault.totalAssets();
        vm.prank(owner);
        p.vault.setMinBufferBps(1);
        uint256 pid = _pullProposal(owner, s, 49_996e6, deployable, 10_000, 1 hours);
        _passReview(pid);
        vm.expectRevert(ISyndicateVault.BufferBreached.selector);
        p.governor.executeProposal(pid);
    }

    /// @notice Raising the buffer mid-proposal does not wedge a lossy settle.
    function test_buffer_raisedMidProposal_settleStillSettles() public {
        _seedReserve();
        uint256 deployable = p.vault.totalAssets();
        uint256 pid = _pullProposal(owner, s, deployable, deployable, 10_000, 1 hours);
        _passReviewAndExecute(pid);
        vm.prank(owner);
        p.vault.setMinBufferBps(5_000);
        s.push(address(p.asset), 10_000e6); // 80% loss
        vm.warp(p.governor.getProposal(pid).executedAt + 1 hours);
        vm.prank(owner);
        p.governor.settleProposal(pid);
        assertEq(uint256(p.governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
    }

    function _valueProposal(uint256 execValue, uint256 settleValue) internal returns (uint256 pid) {
        BatchExecutorLib.Call[] memory exec = new BatchExecutorLib.Call[](1);
        exec[0] = BatchExecutorLib.Call({
            target: address(s), data: abi.encodeCall(She470PullStrategy.sink, ()), value: execValue
        });
        uint256[] memory caps = new uint256[](1);
        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](1);
        settle[0] = BatchExecutorLib.Call({
            target: address(s), data: abi.encodeCall(She470PullStrategy.noop, ()), value: settleValue
        });
        pid = _propose(owner, address(s), 1 hours, 100_000e6, 10_000, exec, caps, settle, caps);
    }

    /// @notice A settle leg carrying value is refused at propose, before it can wedge settle.
    function test_callValue_refusedAtPropose() public {
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.CallValueNotAllowed.selector, 0));
        _valueProposal(0, 1);
    }

    /// @notice The vault refuses a value leg even when force-fed ETH could fund it.
    function test_callValue_refusedByVaultWithForceFedEth() public {
        vm.deal(address(p.vault), 1 ether);
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(s), data: abi.encodeCall(She470PullStrategy.sink, ()), value: 1 ether
        });
        uint256[] memory caps = new uint256[](1);
        vm.prank(address(p.governor));
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.CallValueNotAllowed.selector, 0));
        p.vault.executeGovernorBatch(calls, caps, 100_000e6);
        assertEq(address(p.vault).balance, 1 ether);
    }
}
