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
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";

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
        proposalId = governor.propose(address(vault),
            address(0),
            "ipfs://test",
            7 days,
            GovEnvelope.permissive(address(vault)),
            _noopCalls(),
            GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_noopCalls()).length),
            _noopCalls(),
            GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_noopCalls()).length),
            new ISyndicateGovernor.CoProposer[](0));
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Two-number fee model: split snapshots ──

    /// @notice A split change after propose must not reach an in-flight
    ///         proposal — the same immutability the fee *rates* above already
    ///         have. Without this, governance could re-price a proposal
    ///         voters had already approved.
    function test_splitChangeAfterProposeDoesNotAffectTheInFlightProposal() public {
        uint256 proposalId = _propose();

        vm.startPrank(owner);
        protocolConfig.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 5000, protocolBps: 3000, guardianBps: 2000}));
        protocolConfig.setPerfSplit(
            IProtocolConfig.PerfSplit({agentBps: 2500, protocolBps: 2500, guardianBps: 2500, ownerBps: 2500})
        );
        vm.stopPrank();

        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);

        assertEq(p.snapshotMgmtSplit.agentBps, 7000, "mgmt agent share must hold at the propose-time value");
        assertEq(p.snapshotMgmtSplit.protocolBps, 2000);
        assertEq(p.snapshotMgmtSplit.guardianBps, 1000);

        assertEq(p.snapshotPerfSplit.agentBps, 6000, "perf agent share must hold at the propose-time value");
        assertEq(p.snapshotPerfSplit.protocolBps, 1500);
        assertEq(p.snapshotPerfSplit.guardianBps, 1500);
        assertEq(p.snapshotPerfSplit.ownerBps, 1000);
    }

    /// @notice The mirror case: a change made BEFORE propose must be picked up,
    ///         or the snapshot would be a frozen constant rather than a
    ///         snapshot.
    function test_splitChangeBeforeProposeIsPickedUpByTheNextProposal() public {
        vm.startPrank(owner);
        protocolConfig.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 5000, protocolBps: 3000, guardianBps: 2000}));
        protocolConfig.setPerfSplit(
            IProtocolConfig.PerfSplit({agentBps: 2500, protocolBps: 2500, guardianBps: 2500, ownerBps: 2500})
        );
        vm.stopPrank();

        uint256 proposalId = _propose();
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);

        assertEq(p.snapshotMgmtSplit.agentBps, 5000);
        assertEq(p.snapshotMgmtSplit.protocolBps, 3000);
        assertEq(p.snapshotMgmtSplit.guardianBps, 2000);

        assertEq(p.snapshotPerfSplit.agentBps, 2500);
        assertEq(p.snapshotPerfSplit.ownerBps, 2500);
    }

    /// @dev Whatever was snapshotted must still divide a fee cleanly.
    function test_snapshottedSplitsSumToFullBasisPoints() public {
        uint256 proposalId = _propose();
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);

        assertEq(
            uint256(p.snapshotMgmtSplit.agentBps) + p.snapshotMgmtSplit.protocolBps + p.snapshotMgmtSplit.guardianBps,
            10_000
        );
        assertEq(
            uint256(p.snapshotPerfSplit.agentBps) + p.snapshotPerfSplit.protocolBps + p.snapshotPerfSplit.guardianBps
                + p.snapshotPerfSplit.ownerBps,
            10_000
        );
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

    /// @notice A post-vote config change must not reach an in-flight proposal.
    /// @dev Originally pulled `protocolFeeBps`, which no longer exists — the
    ///      protocol is paid a SHARE of each fee now, not a standalone rate off
    ///      gross profit (design.md Decision 9). Repointed at the split, which
    ///      is the lever carrying that meaning today: swinging the protocol to
    ///      90% mid-flight must not change what this proposal pays, because the
    ///      split was snapshotted at propose.
    function test_settleIgnoresPostVoteProtocolRateChange() public {
        uint256 proposalId = _propose();

        // Swing the protocol's share to nearly the whole fee AFTER voters saw
        // 20%. The old version of this test raised `protocolFeeBps`, which no
        // longer exists — the split IS the protocol's rate now, so this is the
        // lever that carries the same meaning.
        vm.prank(owner);
        protocolConfig.setMgmtSplit(IProtocolConfig.MgmtSplit({agentBps: 500, protocolBps: 9000, guardianBps: 500}));

        // 10k profit lands mid-strategy.
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(proposalId);
        usdc.mint(address(vault), 10_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        uint256 paid = usdc.balanceOf(protocolRecipient);
        assertGt(paid, 0, "the protocol is still paid, at its snapshotted share");
        // Under the snapshotted 20% the protocol takes 15% of a 20% performance
        // fee on the 10k gain — a few hundred. Had the post-vote 90% split
        // applied it would be an order of magnitude larger.
        assertLt(paid, 1_000e6, "and never at the post-vote split");
    }
}
