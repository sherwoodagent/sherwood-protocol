// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @title PerVaultParams.t
/// @notice Task 21 — per-vault governance parameters:
///           1. owner setters freeze while a proposal is open, thaw at settle
///           2. initialize enforces the 24h voting floor + 20% veto floor
///              (through a real BeaconProxy, the factory's deploy path)
///           3. settlement charges the PROPOSE-TIME fee snapshot, not a
///              post-vote ProtocolConfig change
contract PerVaultParamsTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GovernorBeacon public beacon;
    ProtocolConfig public protocolConfig;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public protocolRecipient = makeAddr("protocolRecipient");

    uint256 public agentNftId;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.startPrank(owner);
        protocolConfig.setProtocolFeeRecipient(protocolRecipient);
        protocolConfig.setProtocolFeeBps(100); // 1% at propose time
        vm.stopPrank();

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        // Governor rides a real beacon — exactly the factory's deploy path.
        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        beacon = new GovernorBeacon(address(govImpl), owner);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (address(vault), address(guardianRegistry), address(protocolConfig), address(this), _validParams())
        );
        governor = SyndicateGovernor(address(new BeaconProxy(address(beacon), govInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _validParams() internal pure returns (ISyndicateGovernor.GovernorParams memory) {
        return ISyndicateGovernor.GovernorParams({
            votingPeriod: VOTING_PERIOD,
            executionWindow: EXECUTION_WINDOW,
            vetoThresholdBps: 4000,
            maxPerformanceFeeBps: 1500,
            cooldownPeriod: 1 days,
            collaborationWindow: 48 hours,
            maxCoProposers: 5,
            minStrategyDuration: 1 hours,
            maxStrategyDuration: 30 days
        });
    }

    function _noopCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(this), 0)), value: 0
        });
    }

    function _propose() internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            GovEnvelope.permissive(address(vault)),
            _noopCalls(),
            _noopCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _settleThrough(uint256 proposalId) internal {
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(proposalId);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(proposalId);
    }

    // ──────────────────────────────────────────────────────────────
    // 1. Param freeze during open proposals
    // ──────────────────────────────────────────────────────────────

    function test_setterRevertsWhileProposalActive() public {
        _propose();
        assertGt(governor.openProposalCount(), 0, "proposal open");
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ParamsFrozenDuringProposal.selector);
        governor.setVotingPeriod(2 days);
    }

    /// @notice P8 (review): the factory rescue path (forceSetParams) bypasses
    ///         the whenNoActiveProposal freeze that blocks the owner setters.
    function test_forceSetParamsBypassesFreezeWhileProposalOpen() public {
        _propose();
        assertGt(governor.openProposalCount(), 0, "proposal open");

        // Owner setter is frozen.
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ParamsFrozenDuringProposal.selector);
        governor.setVotingPeriod(2 days);

        // forceSetParams (factory-only; this test contract is the factory)
        // applies despite the freeze — still bounds-checked.
        ISyndicateGovernor.GovernorParams memory gp = governor.getGovernorParams();
        gp.votingPeriod = 2 days;
        governor.forceSetParams(gp);
        assertEq(governor.getGovernorParams().votingPeriod, 2 days, "force applied under freeze");
    }

    function test_setterSucceedsAfterSettle() public {
        uint256 proposalId = _propose();
        _settleThrough(proposalId);
        assertEq(governor.openProposalCount(), 0, "no open proposals after settle");

        vm.prank(owner);
        governor.setVotingPeriod(2 days);
        assertEq(governor.getGovernorParams().votingPeriod, 2 days, "setter applied post-settle");
    }

    // ──────────────────────────────────────────────────────────────
    // 2. Initialize bounds (through the BeaconProxy deploy path)
    // ──────────────────────────────────────────────────────────────

    function test_initializeRevertsOnSub24hVotingPeriod() public {
        ISyndicateGovernor.GovernorParams memory gp = _validParams();
        gp.votingPeriod = 23 hours;
        bytes memory init = abi.encodeCall(
            SyndicateGovernor.initialize,
            (address(vault), address(guardianRegistry), address(protocolConfig), address(this), gp)
        );
        vm.expectRevert(ISyndicateGovernor.InvalidVotingPeriod.selector);
        new BeaconProxy(address(beacon), init);
    }

    function test_initializeRevertsOnSub20PctVetoThreshold() public {
        ISyndicateGovernor.GovernorParams memory gp = _validParams();
        gp.vetoThresholdBps = 1999;
        bytes memory init = abi.encodeCall(
            SyndicateGovernor.initialize,
            (address(vault), address(guardianRegistry), address(protocolConfig), address(this), gp)
        );
        vm.expectRevert(ISyndicateGovernor.InvalidVetoThresholdBps.selector);
        new BeaconProxy(address(beacon), init);
    }

    // ──────────────────────────────────────────────────────────────
    // 3. Fee snapshot at propose beats a post-vote config change
    // ──────────────────────────────────────────────────────────────

    function test_settleUsesSnapshotNotUpdatedConfig() public {
        uint256 proposalId = _propose(); // snapshots 100 bps

        // Config jumps to the 10% max AFTER voters saw 1%.
        vm.prank(owner);
        protocolConfig.setProtocolFeeBps(1000);

        // 10k profit lands mid-strategy.
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(proposalId);
        usdc.mint(address(vault), 10_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        // Protocol fee = 1% of 10k (the snapshot), NOT 10%.
        assertEq(usdc.balanceOf(protocolRecipient), 100e6, "settle charges the propose-time snapshot");
    }
}
