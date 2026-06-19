// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {GovernorParameters} from "../src/GovernorParameters.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlacklistingERC20Mock} from "./mocks/BlacklistingERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "./mocks/MockRegistryMinimal.sol";
import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";

/// @title GuardianFeeBuyback (governor-level)
/// @notice Covers the buyback-WOOD redesign: the guardian-fee slice now routes
///         to the configurable `guardiansFeeRecipient` (a team multisig) via the
///         shared `_payFee` path instead of funding an on-chain registry pool.
///         The off-chain Merkl bot swaps the collected asset to WOOD and
///         airdrops weekly, reading the `GuardianFeeAccrued` event +
///         `registry.getApproverWeights`.
contract GuardianFeeBuybackTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    BlacklistingERC20Mock public usdc;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public guardiansFeeRecipient = makeAddr("guardiansFeeRecipient");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    uint256 public agentNftId;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant GUARDIAN_FEE_BPS = 200; // 2%

    function setUp() public {
        usdc = new BlacklistingERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        agentNftId = agentRegistry.mint(agent);

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (
                ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                })
            )
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        SyndicateGovernor govImpl = new SyndicateGovernor();
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                ISyndicateGovernor.InitParams({
                    owner: owner,
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days,
                    protocolFeeBps: 0,
                    protocolFeeRecipient: address(0),
                    guardianFeeBps: GUARDIAN_FEE_BPS,
                    guardiansFeeRecipient: guardiansFeeRecipient
                }),
                address(guardianRegistry)
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.prank(owner);
        governor.addVault(address(vault));

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

        vm.warp(block.timestamp + 1);
    }

    // ── Helpers ──

    function _noopCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc),
            data: abi.encodeCall(usdc.approve, (address(this), 0)),
            value: 0
        });
    }

    function _executeThroughSettle(uint256 perfFeeBps, uint256 duration) internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            perfFeeBps,
            duration,
            _noopCalls(),
            _noopCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(block.timestamp + 1);

        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.executeProposal(proposalId);
    }

    // ── 1. Guardian fee lands in the recipient (not the registry) on profit ──

    function test_settle_guardianFee_landsInRecipient_notRegistry() public {
        uint256 proposalId = _executeThroughSettle(0, 7 days);

        uint256 profit = 10_000e6;
        usdc.mint(address(vault), profit);
        uint256 expectedFee = (profit * GUARDIAN_FEE_BPS) / 10_000; // 200e6

        uint256 recipientBefore = usdc.balanceOf(guardiansFeeRecipient);
        uint256 registryBefore = usdc.balanceOf(address(guardianRegistry));

        vm.expectEmit(true, true, true, true, address(governor));
        emit ISyndicateGovernor.GuardianFeeAccrued(
            proposalId, address(usdc), guardiansFeeRecipient, expectedFee, uint64(vm.getBlockTimestamp() + 1 hours + 1)
        );

        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        assertEq(usdc.balanceOf(guardiansFeeRecipient) - recipientBefore, expectedFee, "fee to recipient");
        assertEq(usdc.balanceOf(address(guardianRegistry)) - registryBefore, 0, "registry untouched");
    }

    // ── 2. Zero-profit settle: no guardian fee, no event ──

    function test_settle_zeroProfit_noGuardianFee_noEvent() public {
        uint256 proposalId = _executeThroughSettle(0, 7 days);

        // No profit minted into the vault — pnl <= 0, _distributeFees not called.
        vm.recordLogs();
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 accrued = keccak256("GuardianFeeAccrued(uint256,address,address,uint256,uint64)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != accrued, "no GuardianFeeAccrued on zero profit");
        }
        assertEq(usdc.balanceOf(guardiansFeeRecipient), 0, "no fee to recipient");
    }

    // ── 3. setGuardianFeeBps coupling with the recipient ──

    function test_setGuardianFeeBps_revertsWhenRecipientUnset() public {
        // Turn off the fee, then clear the recipient (allowed while off).
        vm.startPrank(owner);
        governor.setGuardianFeeBps(0);
        governor.setGuardiansFeeRecipient(address(0));
        // Now raising the fee with no recipient must revert.
        vm.expectRevert(ISyndicateGovernor.InvalidGuardiansFeeRecipient.selector);
        governor.setGuardianFeeBps(100);
        vm.stopPrank();
    }

    function test_setGuardianFeeBps_succeedsAfterRecipientSet() public {
        vm.startPrank(owner);
        governor.setGuardianFeeBps(0);
        governor.setGuardiansFeeRecipient(address(0));
        // Re-set a recipient, then raising the fee succeeds.
        governor.setGuardiansFeeRecipient(guardiansFeeRecipient);
        governor.setGuardianFeeBps(150);
        vm.stopPrank();
        assertEq(governor.guardianFeeBps(), 150);
    }

    // ── 4. setGuardiansFeeRecipient(0) coupling + event ──

    function test_setGuardiansFeeRecipient_zeroReverts_whenFeeOn() public {
        // Fee is on (GUARDIAN_FEE_BPS) from setUp.
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidGuardiansFeeRecipient.selector);
        governor.setGuardiansFeeRecipient(address(0));
    }

    function test_setGuardiansFeeRecipient_zeroAllowed_whenFeeOff() public {
        vm.startPrank(owner);
        governor.setGuardianFeeBps(0);
        governor.setGuardiansFeeRecipient(address(0));
        vm.stopPrank();
        assertEq(governor.guardiansFeeRecipient(), address(0));
    }

    function test_setGuardiansFeeRecipient_emitsParameterChangeFinalized() public {
        address newRecipient = makeAddr("newRecipient");
        uint256 oldVal = uint256(uint160(guardiansFeeRecipient));
        uint256 newVal = uint256(uint160(newRecipient));
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(keccak256("guardiansFeeRecipient"), oldVal, newVal);
        vm.prank(owner);
        governor.setGuardiansFeeRecipient(newRecipient);
        assertEq(governor.guardiansFeeRecipient(), newRecipient);
    }

    // ── 5. initialize coupling ──

    function test_initialize_revertsWhenFeeOnButRecipientUnset() public {
        SyndicateGovernor govImpl = new SyndicateGovernor();
        bytes memory badInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                ISyndicateGovernor.InitParams({
                    owner: owner,
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days,
                    protocolFeeBps: 0,
                    protocolFeeRecipient: address(0),
                    guardianFeeBps: GUARDIAN_FEE_BPS,
                    guardiansFeeRecipient: address(0)
                }),
                address(guardianRegistry)
            )
        );
        vm.expectRevert(ISyndicateGovernor.InvalidGuardiansFeeRecipient.selector);
        new ERC1967Proxy(address(govImpl), badInit);
    }
}

/// @title GuardianFeeBuyback_RegistryWeights
/// @notice Covers the new `getApproverWeights` read getter on the real
///         `GuardianRegistry` + sWOOD harness. The off-chain Merkl bot uses it
///         to attribute the guardian fee to approvers.
contract GuardianFeeBuyback_RegistryWeightsTest is RegistryTestHarness {
    address approver = makeAddr("approver");
    address approver2 = makeAddr("approver2");
    address blocker = makeAddr("blocker");

    uint256 constant PID = 7;

    function setUp() public {
        _deployRegistryAndSwood(24 hours, 3000);
        // Cohort-at-open meets MIN_COHORT_STAKE_AT_OPEN (50k) so openReview
        // records weights rather than short-circuiting.
        _stakeGuardian(approver, 30_000e18, 1);
        _stakeGuardian(approver2, 20_000e18, 2);
        _stakeGuardian(blocker, 20_000e18, 3);
    }

    function _openReview() internal returns (uint256 voteEnd, uint256 reviewEnd) {
        voteEnd = vm.getBlockTimestamp() + 1;
        reviewEnd = voteEnd + 24 hours + 1;
        governor.setProposal(PID, voteEnd, reviewEnd);
        vm.warp(voteEnd);
        registry.openReview(PID);
        vm.warp(voteEnd + 1);
    }

    function test_getApproverWeights_returnsApproversAndDenominator() public {
        _openReview();

        vm.prank(approver);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.prank(approver2);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.prank(blocker);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Block, 0);

        (address[] memory approvers, uint128[] memory weights, uint128 totalApproveWeight) =
            registry.getApproverWeights(PID);

        assertEq(approvers.length, 2, "two approvers");
        assertEq(weights.length, 2, "weights match approvers");

        // Sum of weights equals the denominator; blocker excluded.
        uint256 sum;
        for (uint256 i = 0; i < weights.length; i++) {
            sum += weights[i];
        }
        assertEq(sum, uint256(totalApproveWeight), "sum of weights == denominator");
        assertEq(uint256(totalApproveWeight), 50_000e18, "30k + 20k approve weight");
    }

    function test_getApproverWeights_reflectsVoteChange() public {
        _openReview();

        vm.prank(approver);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.prank(approver2);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);

        // approver2 flips Approve -> Block, leaving only `approver`.
        vm.prank(approver2);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Block, 0);

        (address[] memory approvers, uint128[] memory weights, uint128 totalApproveWeight) =
            registry.getApproverWeights(PID);

        assertEq(approvers.length, 1, "only one approver after flip");
        assertEq(approvers[0], approver, "remaining approver is `approver`");
        assertEq(uint256(weights[0]), 30_000e18, "approver weight preserved");
        assertEq(uint256(totalApproveWeight), 30_000e18, "denominator dropped by the flipped weight");
    }

    function test_getApproverWeights_persistsPostSettle() public {
        (, uint256 reviewEnd) = _openReview();

        vm.prank(approver);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.prank(approver2);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);

        vm.warp(reviewEnd);
        registry.resolveReview(PID);

        // Arrays are not cleared at resolve — getter still works for the bot.
        (address[] memory approvers,, uint128 totalApproveWeight) = registry.getApproverWeights(PID);
        assertEq(approvers.length, 2, "approver set persists post-settle");
        assertEq(uint256(totalApproveWeight), 50_000e18, "denominator persists post-settle");
    }
}
