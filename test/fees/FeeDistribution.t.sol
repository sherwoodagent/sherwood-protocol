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

/// @notice End-to-end settlement under the two-number fee model
///         (`specs/management-fee/spec.md`, `specs/performance-fee/spec.md`):
///         the management fee is charged on every settlement regardless of
///         P&L, the performance fee only above the high-water mark, and each
///         is ONE division of ONE base rather than the compounding waterfall
///         it replaced.
contract FeeDistributionTest is Test {
    SyndicateGovernor internal governor;
    SyndicateVault internal vault;
    GovernorBeacon internal beacon;
    ProtocolConfig internal protocolConfig;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;
    MockRegistryMinimal internal guardianRegistry;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal lp1 = makeAddr("lp1");
    address internal protocolRecipient = makeAddr("protocolRecipient");
    address internal guardianRecipient = makeAddr("guardianRecipient");

    uint256 internal agentNftId;

    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant EXECUTION_WINDOW = 1 days;
    /// @dev 2%/yr — the headline management rate.
    uint256 internal constant MGMT_BPS = 200;
    /// @dev 20% — the headline performance rate.
    uint256 internal constant PERF_BPS = 2000;

    uint256 internal constant DEPOSIT = 1_000_000e6;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.startPrank(owner);
        protocolConfig.setProtocolFeeRecipient(protocolRecipient);
        protocolConfig.setGuardiansFeeRecipient(guardianRecipient);
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
                    managementFeeBps: MGMT_BPS
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        vm.startPrank(owner);
        vault.registerAgent(agentNftId, agent);
        vault.setAgentFeeBps(uint16(PERF_BPS));
        vm.stopPrank();

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        beacon = new GovernorBeacon(address(govImpl), owner);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (address(vault), address(guardianRegistry), address(protocolConfig), address(this), _validParams())
        );
        governor = SyndicateGovernor(address(new BeaconProxy(address(beacon), govInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        usdc.mint(lp1, 100_000_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT, lp1);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _validParams() internal pure returns (ISyndicateGovernor.GovernorParams memory) {
        return ISyndicateGovernor.GovernorParams({
            votingPeriod: VOTING_PERIOD,
            executionWindow: EXECUTION_WINDOW,
            vetoThresholdBps: 4000,
            maxPerformanceFeeBps: PERF_BPS,
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

    /// @dev Vote through and execute, leaving the proposal live.
    function _execute(uint256 proposalId) internal {
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(proposalId);
    }

    /// @dev Propose, execute, hold for `heldFor`, then settle.
    function _runProposal(uint256 heldFor) internal returns (uint256 proposalId) {
        proposalId = _propose();
        _execute(proposalId);
        vm.warp(vm.getBlockTimestamp() + heldFor);
        vm.prank(agent);
        governor.settleProposal(proposalId);
    }

    /// @dev A pure gain: value appears in the vault, share count unchanged.
    function _gain(uint256 amount) internal {
        usdc.mint(address(vault), amount);
    }

    /// @dev A pure loss.
    function _loss(uint256 amount) internal {
        vm.prank(address(vault));
        usdc.transfer(makeAddr("sink"), amount);
    }

    function _paidOut() internal view returns (uint256) {
        return usdc.balanceOf(agent) + usdc.balanceOf(protocolRecipient) + usdc.balanceOf(guardianRecipient)
            + usdc.balanceOf(owner);
    }

    // ── The management fee is unconditional ──

    /// @notice A flat proposal — no profit, no loss — still pays the management
    ///         fee. This is what funds the agent and the guardian network in
    ///         months when there is nothing to share.
    function test_aFlatProposalStillPaysTheManagementFee() public {
        _runProposal(30 days);

        uint256 expected = (DEPOSIT * uint256(30 days) * MGMT_BPS) / (10_000 * 365 days);
        assertApproxEqRel(_paidOut(), expected, 1e15, "a flat month still pays 2%/yr pro-rata");
    }

    /// @notice And so does a losing one.
    function test_aLosingProposalStillPaysTheManagementFee() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        _loss(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        assertGt(_paidOut(), 0, "a loss does not excuse the management fee");
        assertEq(usdc.balanceOf(owner), 0, "but no performance fee is charged, so the owner earns nothing");
    }

    /// @notice The management fee splits three ways — the owner has no share of
    ///         it, only of the performance fee.
    function test_theManagementFeeSplitsThreeWays() public {
        _runProposal(30 days);

        uint256 total = _paidOut();
        assertApproxEqRel(usdc.balanceOf(agent), (total * 7000) / 10_000, 1e15, "agent 70%");
        assertApproxEqRel(usdc.balanceOf(protocolRecipient), (total * 2000) / 10_000, 1e15, "protocol 20%");
        assertApproxEqRel(usdc.balanceOf(guardianRecipient), (total * 1000) / 10_000, 1e15, "guardian 10%");
        assertEq(usdc.balanceOf(owner), 0, "the owner earns only on the profit side");
    }

    // ── The performance fee is gated on the mark ──

    /// @notice A profitable settlement charges both fees, and the performance
    ///         leg splits four ways.
    function test_aProfitableProposalChargesBothFees() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        _gain(200_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        assertGt(usdc.balanceOf(owner), 0, "the owner earns on the profit side");
        // 20% of a ~200k gain is ~40k; the management fee adds ~1.6k on top.
        assertGt(_paidOut(), 40_000e6, "both legs charged");
        assertLt(_paidOut(), 45_000e6, "and no more than that");
    }

    /// @notice The property the mark exists for, end to end: a fund that gains,
    ///         pays, loses, and recovers to its old peak is NOT charged a
    ///         second time on the same dollars.
    function test_aRecoveryToThePreviousPeakChargesNoPerformanceFee() public {
        uint256 p1 = _propose();
        _execute(p1);
        _gain(200_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(agent);
        governor.settleProposal(p1);

        uint256 ownerAfterFirst = usdc.balanceOf(owner);
        assertGt(ownerAfterFirst, 0, "round 1 charged a performance fee");

        // Round 2: down 250k then back up 250k — ends where it started.
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 p2 = _propose();
        _execute(p2);
        _loss(250_000e6);
        _gain(250_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(agent);
        governor.settleProposal(p2);

        assertEq(usdc.balanceOf(owner), ownerAfterFirst, "the recovery must not be charged again");
    }

    /// @notice The management fee is charged FIRST, so it lowers the price per
    ///         share before the mark comparison. A gain thin enough to be
    ///         erased by it leaves nothing to charge performance on.
    function test_theManagementFeeCanPushASettlementBelowTheMark() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        // A gain far smaller than 30 days of management fee on 1M (~1,644).
        _gain(100e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        assertEq(usdc.balanceOf(owner), 0, "the thin gain was consumed by the management fee");
    }

    // ── One base, not a waterfall ──

    /// @notice Every recipient's share is computed from the FULL fee, never
    ///         from what another recipient left behind. Under the old
    ///         four-step waterfall the later legs were charged on a shrinking
    ///         remainder; here the shares must sum back to the whole.
    function test_theSplitsDivideOneBaseAndSumBackToIt() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        _gain(200_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(agent);
        governor.settleProposal(proposalId);
        uint256 leftTheVault = vaultBefore - usdc.balanceOf(address(vault));

        // Nothing is stranded: every wei that left the vault reached a
        // recipient (rounding dust goes to the agent, never to the void).
        assertEq(_paidOut(), leftTheVault, "the splits must account for the whole fee");
    }

    /// @notice Depositors keep the rest. With the two-number model the total
    ///         load on a profitable month is materially below the old
    ///         four-haircut waterfall.
    function test_depositorsKeepTheRemainder() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        _gain(200_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        // 200k gross gain, ~40k performance + ~1.6k management taken.
        assertGt(vault.totalAssets(), 1_155_000e6, "depositors keep the large majority of the gain");
    }

    // ── Events ──

    function test_theManagementFeeIsAnnounced() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.recordLogs();
        vm.prank(agent);
        governor.settleProposal(proposalId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == ISyndicateGovernor.ManagementFeeCharged.selector) found = true;
        }
        assertTrue(found, "settlement must announce the management fee");
    }

    // ── Fail-open payment ──

    /// @notice A recipient that cannot be paid — the blacklisted-address case —
    ///         must not brick settlement. The fee escrows against them and the
    ///         other recipients are still paid.
    /// @dev The revert is injected on the vault's transfer entry point rather
    ///      than on the recipient itself: an ERC20 transfer never calls its
    ///      recipient, so a contract that reverts on `receive()` would happily
    ///      accept the tokens. `mockCallRevert` matches on a calldata prefix,
    ///      so pinning selector + asset + recipient targets exactly this
    ///      recipient's payments at whatever amount they turn out to be.
    function test_aBrickedRecipientDoesNotBrickSettlement() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        _gain(200_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.mockCallRevert(
            address(vault),
            abi.encodeWithSelector(ISyndicateVault.transferPerformanceFee.selector, address(usdc), guardianRecipient),
            "BLACKLISTED"
        );

        vm.prank(agent);
        governor.settleProposal(proposalId); // must not revert

        assertEq(uint8(governor.getProposalState(proposalId)), uint8(ISyndicateGovernor.ProposalState.Settled));
        assertEq(usdc.balanceOf(guardianRecipient), 0, "the bricked recipient received nothing");
        assertGt(usdc.balanceOf(agent), 0, "the others were still paid");
        assertGt(usdc.balanceOf(protocolRecipient), 0);
    }

    /// @notice And the money is not lost — it is claimable once the block
    ///         lifts. This matters most for crystallized fees, which were
    ///         already collected from an exiter: if they escrowed without being
    ///         recoverable they would be neither in the fund nor claimable.
    function test_anUnpayableFeeIsEscrowedAndRecoverable() public {
        uint256 proposalId = _propose();
        _execute(proposalId);
        _gain(200_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.mockCallRevert(
            address(vault),
            abi.encodeWithSelector(ISyndicateVault.transferPerformanceFee.selector, address(usdc), guardianRecipient),
            "BLACKLISTED"
        );
        vm.prank(agent);
        governor.settleProposal(proposalId);

        uint256 owed = governor.unclaimedFees(address(vault), guardianRecipient, address(usdc));
        assertGt(owed, 0, "the unpayable fee must be escrowed, not burned");

        // The block lifts; the recipient pulls. `clearMockedCalls` is
        // all-or-nothing, so the factory mock the vault needs to resolve its
        // governor has to be re-established afterwards.
        vm.clearMockedCalls();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        vm.prank(guardianRecipient);
        governor.claimUnclaimedFees(address(vault), address(usdc));

        assertEq(usdc.balanceOf(guardianRecipient), owed, "and is recoverable in full");
        assertEq(governor.unclaimedFees(address(vault), guardianRecipient, address(usdc)), 0, "escrow cleared");
    }

    // ── Idle capital ──

    /// @notice The gap between proposals is free, end to end.
    /// @dev The second proposal's base is the fund's assets AFTER the first
    ///      settlement took its fee, not the original deposit — so the
    ///      expectation is anchored to live assets rather than to `DEPOSIT`.
    function test_theGapBetweenProposalsIsFree() public {
        _runProposal(30 days);
        uint256 afterFirst = _paidOut();

        // Sit idle for a long time, then run a short proposal.
        vm.warp(vm.getBlockTimestamp() + 200 days);
        uint256 baseForSecond = vault.totalAssets();
        _runProposal(1 days);

        uint256 secondCharge = _paidOut() - afterFirst;
        uint256 expected = (baseForSecond * uint256(1 days) * MGMT_BPS) / (10_000 * 365 days);
        assertApproxEqRel(secondCharge, expected, 1e15, "only the 1 live day is charged");

        // The 200 idle days contributed nothing: charging them would be ~200x.
        assertLt(secondCharge, expected * 2, "the idle gap must not leak into the next proposal");
    }
}
