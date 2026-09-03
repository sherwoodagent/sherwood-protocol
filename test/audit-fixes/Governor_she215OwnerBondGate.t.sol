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
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title Governor_she215OwnerBondGate
/// @notice SHE-215, governor half: pins the `ownerBondLive` gate on both the
///         propose and execute legs (design:
///         `openspec/changes/owner-bond-proposal-gate`).
contract GovernorShe215OwnerBondGateTest is Test {
    SyndicateGovernor internal governor;
    ProtocolConfig internal protocolConfig;
    SyndicateVault internal vault;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    ERC20Mock internal targetToken;
    MockAgentRegistry internal agentRegistry;
    MockRegistryMinimal internal guardianRegistry;

    ISyndicateGovernor.RiskEnvelope internal permissiveEnv;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");

    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant EXECUTION_WINDOW = 1 days;
    uint256 internal constant STRATEGY_DURATION = 7 days;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();

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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        // The exploit's precondition: the vault owner is also a registered agent.
        // Minted OUTSIDE the prank — an argument-position external call would
        // consume the one-shot prank before `registerAgent` is reached.
        uint256 agentNftId = agentRegistry.mint(agent);
        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(protocolConfig),
                address(this),
                address(deployTierRegistry(address(this))),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));

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
        permissiveEnv = GovEnvelope.permissive(address(vault));
    }

    // ── helpers ──

    function _executeCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
    }

    function _settlementCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
    }

    function _propose() internal returns (uint256 proposalId) {
        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory ex = _executeCalls();
        BatchExecutorLib.Call[] memory st = _settlementCalls();
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://she215",
            STRATEGY_DURATION,
            permissiveEnv,
            ex,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, ex.length),
            st,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, st.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _approve(uint256 proposalId) internal {
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // =====================================================================
    // propose
    // =====================================================================

    /// @notice The control: a bonded vault proposes exactly as before.
    function test_propose_succeedsWhileTheOwnerBondIsLive() public {
        uint256 proposalId = _propose();
        assertGt(proposalId, 0, "a bonded vault still proposes");
    }

    /// @notice The finding, propose leg: an unbonded vault fails closed with a named error.
    /// @dev    MUTATION-CHECKED: deleting the gate from `_propose` makes this call succeed.
    function test_propose_revertsWhenTheOwnerBondIsNotLive() public {
        guardianRegistry.setOwnerBondLive(false);

        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory ex = _executeCalls();
        BatchExecutorLib.Call[] memory st = _settlementCalls();
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.OwnerBondNotLive.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://she215",
            STRATEGY_DURATION,
            permissiveEnv,
            ex,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, ex.length),
            st,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, st.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @notice Re-funding the slot reopens the lane: the gate is a state check, not a latch.
    function test_propose_reopensOnceTheBondIsRestored() public {
        guardianRegistry.setOwnerBondLive(false);
        guardianRegistry.setOwnerBondLive(true);

        uint256 proposalId = _propose();
        assertGt(proposalId, 0, "a re-funded slot proposes again");
    }

    // =====================================================================
    // executeProposal
    // =====================================================================

    /// @notice The finding, execute leg: a bond that leaves after approval stops execution.
    /// @dev    MUTATION-CHECKED: deleting the gate from `executeProposal` lets this succeed.
    function test_executeProposal_revertsWhenTheBondLeavesAfterApproval() public {
        uint256 proposalId = _propose();
        _approve(proposalId);

        // The bond exits between approval and execution.
        guardianRegistry.setOwnerBondLive(false);

        vm.expectRevert(ISyndicateGovernor.OwnerBondNotLive.selector);
        governor.executeProposal(proposalId);
    }

    /// @notice The control for the execute leg: the same proposal executes with a live bond.
    function test_executeProposal_succeedsWhileTheOwnerBondIsLive() public {
        uint256 proposalId = _propose();
        _approve(proposalId);

        governor.executeProposal(proposalId);
        assertEq(governor.getActiveProposal(), proposalId, "executed with a live bond");
    }

    /// @notice A proposal blocked by a departing bond is not bricked: it recovers in window.
    function test_executeProposal_recoversWhenTheBondIsRestoredInWindow() public {
        uint256 proposalId = _propose();
        _approve(proposalId);

        guardianRegistry.setOwnerBondLive(false);
        vm.expectRevert(ISyndicateGovernor.OwnerBondNotLive.selector);
        governor.executeProposal(proposalId);

        guardianRegistry.setOwnerBondLive(true);
        governor.executeProposal(proposalId);
        assertEq(governor.getActiveProposal(), proposalId, "the approved proposal was never bricked");
    }
}
