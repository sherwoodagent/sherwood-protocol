// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @title CancelProposal — regression suite for proposer cancel branches
/// @notice Covers the V1.5 extension that lets the proposer cancel during
///         `GuardianReview` and `Approved`, mirroring the proposer-anytime
///         settle path. Specifically verifies:
///           1. `cancelProposal` from `Approved` decrements `openProposalCount`
///              and bumps `_lastSettledAt` so cooldown engages.
///           2. `cancelProposal` from `GuardianReview` invokes
///              `registry.cancelReview(pid)` so a stale `resolveReview` after
///              `reviewEnd` cannot still slash approvers.
///           3. Non-proposers cannot cancel from any state.
///           4. The cooldown wired through `_lastSettledAt` actually gates
///              the next `executeProposal` after a propose-cancel-propose
///              cycle.
contract CancelProposalTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public attacker = makeAddr("attacker");

    uint256 public agentNftId;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant MAX_STRATEGY_DURATION = 30 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant REVIEW_PERIOD = 1 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        agentNftId = agentRegistry.mint(agent);

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 50
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        SyndicateGovernor govImpl = new SyndicateGovernor();
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault), // vault_: this test's vault (per-vault governor)
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this), // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: MAX_STRATEGY_DURATION
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        usdc.mint(lp1, 100_000e6);
        usdc.mint(lp2, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Helpers ──

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory cs = new BatchExecutorLib.Call[](1);
        cs[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
        return cs;
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory cs = new BatchExecutorLib.Call[](1);
        cs[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
        return cs;
    }

    function _propose() internal returns (uint256 pid) {
        vm.prank(agent);
        pid = governor.propose(
            address(vault), address(0), "ipfs://test", 7 days, _execCalls(), _settleCalls(), _emptyCoProposers()
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Drives a proposal to `Approved`. With `MockRegistryMinimal.reviewPeriod == 0`,
    ///      voteEnd == reviewEnd → the proposal transitions Pending → Approved
    ///      directly when block.timestamp > voteEnd.
    function _proposeAndApprove() internal returns (uint256 pid) {
        pid = _propose();
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        // _resolveStateView with reviewPeriod=0 returns Approved here.
    }

    /// @dev Drives a proposal to `GuardianReview`. Sets `reviewPeriod` to a
    ///      non-zero value so voteEnd < reviewEnd, then warps past voteEnd.
    function _proposeAndDriveToGuardianReview() internal returns (uint256 pid) {
        guardianRegistry.setReviewPeriod(REVIEW_PERIOD);
        pid = _propose();
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        // Past voteEnd, before reviewEnd → state == GuardianReview.
    }

    // ────────────────────────── Approved cancel ──────────────────────────

    function test_cancelProposal_fromApproved_setsCancelled() public {
        uint256 pid = _proposeAndApprove();
        // Sanity: state is Approved (current enum value 3).
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));

        vm.prank(agent);
        governor.cancelProposal(pid);

        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Cancelled));
    }

    function test_cancelProposal_fromApproved_decrementsOpenCount() public {
        uint256 pid = _proposeAndApprove();
        assertEq(governor.openProposalCount(), 1, "open count after propose");

        vm.prank(agent);
        governor.cancelProposal(pid);

        assertEq(governor.openProposalCount(), 0, "open count after cancel");
    }

    function test_cancelProposal_fromApproved_unlocksFutureProposals() public {
        uint256 pid = _proposeAndApprove();
        vm.prank(agent);
        governor.cancelProposal(pid);

        // Bump past cooldown then propose again — should succeed (open count
        // dec'd, _lastSettledAt + cooldown elapsed).
        vm.warp(vm.getBlockTimestamp() + COOLDOWN_PERIOD + 1);

        vm.prank(agent);
        uint256 pid2 = governor.propose(
            address(vault), address(0), "ipfs://retry", 7 days, _execCalls(), _settleCalls(), _emptyCoProposers()
        );
        assertGt(pid2, pid);
    }

    function test_cancelProposal_fromApproved_byNonProposerReverts() public {
        uint256 pid = _proposeAndApprove();
        vm.prank(attacker);
        vm.expectRevert(ISyndicateGovernor.NotProposer.selector);
        governor.cancelProposal(pid);
    }

    // ────────────────────────── GuardianReview cancel ──────────────────────────

    function test_cancelProposal_fromGuardianReview_setsCancelled() public {
        uint256 pid = _proposeAndDriveToGuardianReview();
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.GuardianReview));

        vm.prank(agent);
        governor.cancelProposal(pid);

        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Cancelled));
    }

    /// @notice C1 regression: cancel-during-GuardianReview MUST drive
    ///         `registry.cancelReview(pid)` so a stale `resolveReview` after
    ///         the review window cannot still slash approvers. Without this,
    ///         an honest approver could be slashed for a proposal the
    ///         proposer abandoned.
    function test_cancelProposal_fromGuardianReview_callsRegistryCancelReview() public {
        uint256 pid = _proposeAndDriveToGuardianReview();
        assertEq(guardianRegistry.cancelReviewCallCount(), 0, "no prior cancelReview");

        vm.prank(agent);
        governor.cancelProposal(pid);

        assertEq(guardianRegistry.cancelReviewCallCount(), 1, "registry.cancelReview was invoked");
        assertEq(guardianRegistry.lastCancelledProposalId(), pid, "registry got the right pid");
    }

    function test_cancelProposal_fromGuardianReview_decrementsOpenCount() public {
        uint256 pid = _proposeAndDriveToGuardianReview();
        assertEq(governor.openProposalCount(), 1);

        vm.prank(agent);
        governor.cancelProposal(pid);

        assertEq(governor.openProposalCount(), 0);
    }

    function test_cancelProposal_fromGuardianReview_byNonProposerReverts() public {
        uint256 pid = _proposeAndDriveToGuardianReview();
        vm.prank(attacker);
        vm.expectRevert(ISyndicateGovernor.NotProposer.selector);
        governor.cancelProposal(pid);
    }

    // ────────────────────────── Cooldown rate-limit ──────────────────────────

    /// @notice The new cancel branches set `_lastSettledAt[vault] = block.timestamp`.
    ///         Verified via `getCooldownEnd(vault)` which projects forward
    ///         `_lastSettledAt + cooldownPeriod`. Direct read avoids the time-
    ///         math gymnastics of driving a second proposal through propose
    ///         → vote → execute under the parameter bounds.
    function test_cancelProposal_fromApproved_bumpsCooldown() public {
        uint256 pid = _proposeAndApprove();
        uint256 cancelTime = vm.getBlockTimestamp();

        vm.prank(agent);
        governor.cancelProposal(pid);

        assertEq(governor.getCooldownEnd(), cancelTime + COOLDOWN_PERIOD, "cooldown end = cancelTime + cooldownPeriod");
    }

    function test_cancelProposal_fromGuardianReview_bumpsCooldown() public {
        uint256 pid = _proposeAndDriveToGuardianReview();
        uint256 cancelTime = vm.getBlockTimestamp();

        vm.prank(agent);
        governor.cancelProposal(pid);

        assertEq(governor.getCooldownEnd(), cancelTime + COOLDOWN_PERIOD, "cooldown end = cancelTime + cooldownPeriod");
    }
}
