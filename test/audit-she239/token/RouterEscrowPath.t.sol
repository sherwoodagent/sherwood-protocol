// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {SyndicateVault} from "../../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../../src/interfaces/ISyndicateVault.sol";
import {SyndicateGovernor} from "../../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../../src/interfaces/ISyndicateGovernor.sol";
import {GovernorBeacon} from "../../../src/GovernorBeacon.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {ProtocolFeeRouter} from "../../../src/ProtocolFeeRouter.sol";
import {PaxosLikeMock} from "./WeirdTokenMocks.sol";
import {MockAgentRegistry} from "../../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../../helpers/TierRegistryFixture.sol";

/// @notice A real settlement pays the protocol leg into the router, which forwards it (SHE-239).
contract RouterEscrowPathTest is Test {
    SyndicateGovernor internal governor;
    SyndicateVault internal vault;
    ProtocolConfig internal protocolConfig;
    PaxosLikeMock internal usdg;
    MockAgentRegistry internal agentRegistry;
    ProtocolFeeRouter internal router;

    address internal owner = makeAddr("owner");
    address internal safe = makeAddr("safe");
    address internal foundation = makeAddr("foundation");
    address internal agent = makeAddr("agent");
    address internal lp1 = makeAddr("lp1");
    address internal guardianRecipient = makeAddr("guardianRecipient");
    address internal oldRecipient = makeAddr("oldRecipient");

    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant DEPOSIT = 1_000_000e6;

    function setUp() public {
        router = new ProtocolFeeRouter(safe);
        protocolConfig = new ProtocolConfig(owner);
        vm.startPrank(owner);
        protocolConfig.setProtocolFeeRecipient(address(router));
        protocolConfig.setGuardiansFeeRecipient(guardianRecipient);
        vm.stopPrank();

        usdg = new PaxosLikeMock();
        BatchExecutorLib executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));
        uint256 agentNftId = agentRegistry.mint(agent);

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdg),
                    name: "Sherwood Vault",
                    symbol: "swUSDG",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 200
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));
        vm.startPrank(owner);
        vault.registerAgent(agentNftId, agent);
        vault.setAgentFeeBps(2000);
        vm.stopPrank();

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        GovernorBeacon beacon = new GovernorBeacon(address(govImpl), owner);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(new MockRegistryMinimal()),
                address(protocolConfig),
                address(this),
                address(deployTierRegistry(address(this))),
                _params()
            )
        );
        governor = SyndicateGovernor(address(new BeaconProxy(address(beacon), govInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("depositsRestricted()"), abi.encode(false));
        vm.mockCall(address(this), abi.encodeWithSignature("ownerOnlyProposals()"), abi.encode(false));

        usdg.mint(lp1, DEPOSIT);
        vm.startPrank(lp1);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT, lp1);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _params() internal pure returns (ISyndicateGovernor.GovernorParams memory) {
        return ISyndicateGovernor.GovernorParams({
            votingPeriod: VOTING_PERIOD,
            executionWindow: 1 days,
            vetoThresholdBps: 4000,
            maxPerformanceFeeBps: 2000,
            cooldownPeriod: 1 hours,
            collaborationWindow: 48 hours,
            maxCoProposers: 5,
            minStrategyDuration: 1 hours,
            maxStrategyDuration: 30 days
        });
    }

    function _noopCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(usdg.approve, (address(this), 0)), value: 0
        });
    }

    function _propose() internal returns (uint256 id) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory calls = _noopCalls();
        vm.prank(agent);
        id = governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            env,
            calls,
            GovEnvelope.defaultCaps(env.maxCapital, calls.length),
            calls,
            GovEnvelope.defaultCaps(env.maxCapital, calls.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _executeAndSettle(uint256 id) internal {
        vm.prank(lp1);
        governor.vote(id, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(agent);
        governor.settleProposal(id);
    }

    function _execute(uint256 id) internal {
        vm.prank(lp1);
        governor.vote(id, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
    }

    function _settle(uint256 id) internal {
        vm.prank(agent);
        governor.settleProposal(id);
    }

    function _toFoundation() internal {
        ProtocolFeeRouter.Allocation[] memory a = new ProtocolFeeRouter.Allocation[](1);
        a[0] = ProtocolFeeRouter.Allocation({target: foundation, bps: 10_000});
        vm.prank(safe);
        router.setAllocations(a);
    }

    /// USDG paused at settle (transfers only): every fee leg escrows, settlement completes; after
    /// unpause anyone pulls the router's leg in via claimEscrowedFees and distribute forwards it.
    function test_pausedAtSettle_escrow_unpause_claim_distribute() public {
        uint256 id = _propose();
        _execute(id);
        usdg.setPaused(true);
        _settle(id);

        uint256 owed = governor.unclaimedFees(address(vault), address(router), address(usdg));
        assertGt(owed, 0, "router leg escrowed");
        assertEq(governor.outstandingEscrow(address(vault), address(usdg)) >= owed, true);

        // Still paused: the claim's transfer reverts and the escrow slot survives (CEI rollback).
        vm.expectRevert(PaxosLikeMock.Paused.selector);
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(governor.unclaimedFees(address(vault), address(router), address(usdg)), owed);

        usdg.setPaused(false);
        vm.prank(makeAddr("anyone"));
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(usdg.balanceOf(address(router)), owed);

        _toFoundation();
        router.distribute(address(usdg));
        assertEq(usdg.balanceOf(foundation), owed);
    }

    /// Full Paxos pause (approve blocked too): here the UNWIND batch (usdg.approve) reverts first, so
    /// the whole settlement reverts and nothing escrows. Trace-confirmed: the revert fires inside
    /// executeGovernorBatch, before any transferPerformanceFee. An unwind that does not touch USDG
    /// reaches _payFee and escrows instead (see test_pausedAtSettle_*).
    function test_fullPaxosPause_unwindTouchingUsdgRevertsSettlement() public {
        uint256 id = _propose();
        _execute(id);
        usdg.setPauseApprovals(true);
        usdg.setPaused(true);
        vm.prank(agent);
        vm.expectRevert(PaxosLikeMock.Paused.selector);
        governor.settleProposal(id);
        usdg.setPaused(false);
        _settle(id);
        assertGt(usdg.balanceOf(address(router)), 0, "delivered directly after unpause");
    }

    /// L-2 (escrow side): while the router is frozen the escrow is booked against the router key
    /// forever. The governor pays escrow only to msg.sender, so no other address can ever claim
    /// it; the vault reserves it out of totalAssets indefinitely.
    function test_L2_frozenRouterEscrowIsBoundToTheRouterKey() public {
        usdg.freeze(address(router), true);
        uint256 id = _propose();
        _execute(id);
        _settle(id);

        uint256 owed = governor.unclaimedFees(address(vault), address(router), address(usdg));
        assertGt(owed, 0);

        vm.expectRevert(abi.encodeWithSelector(PaxosLikeMock.Frozen.selector, address(router)));
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));

        // The Safe has no redirect: claiming as itself finds nothing.
        vm.prank(safe);
        governor.claimUnclaimedFees(address(vault), address(usdg));
        assertEq(usdg.balanceOf(safe), 0);
        assertEq(governor.outstandingEscrow(address(vault), address(usdg)), owed, "reserved in the vault indefinitely");
    }

    /// A claim cannot be blocked by griefers outside the active-proposal window: after settle and
    /// before the next execute, anyone can pull. During a live proposal it reverts (by design).
    function test_claimRevertsOnlyWhileTheVaultHasAnActiveProposal() public {
        uint256 id = _propose();
        _execute(id);
        usdg.setPaused(true);
        _settle(id);
        usdg.setPaused(false);

        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        uint256 id2 = _propose();
        _execute(id2);
        vm.expectRevert(ISyndicateGovernor.VaultProposalActive.selector);
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        _settle(id2);
        router.claimEscrowedFees(address(governor), address(vault), address(usdg));
        assertEq(governor.unclaimedFees(address(vault), address(router), address(usdg)), 0);
    }
}
