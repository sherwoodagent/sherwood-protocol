// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockWoodTwapOracle} from "./mocks/MockWoodTwapOracle.sol";
import {GovEnvelope} from "./helpers/GovEnvelope.sol";
import {deployTierRegistry} from "./helpers/TierRegistryFixture.sol";

/// @dev Chainlink-shaped USD feed: fixed answer, `decimals`, fresh `updatedAt`.
contract MockFeedSCT {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }
}

/// @notice Minimal `IExposureLedger`-shaped stand-in whose `settleCoverage`
///         ALWAYS reverts (a generic failure, not the ledger's own realistic
///         `NoWoodPrice`). Used to prove the governor's bare catch is
///         agnostic to the revert reason (design D2). Implements only what
///         `propose`/`executeProposal` touch when no bond escrow is wired:
///         `quorumTierThreshold()` returns a value no envelope tier ever
///         meets, so the approve-quorum gate at execute is skipped and no
///         real guardian approval is needed to reach settlement.
contract RevertingLedgerMock {
    function requireWithinCoveredTvlCap(address, uint256) external pure {}
    function requireWithinCoverageHorizon(uint256, uint256) external pure {}

    function quorumTierThreshold() external pure returns (uint8) {
        return 255;
    }

    function settleCoverage(address, uint256) external pure {
        revert("mock: settleCoverage always reverts");
    }
}

/// @title SettleCoverageSelfTriggerTest
/// @notice Issue #33 — `settleCoverage` self-triggers from settlement
///         finalization (`_finishSettlement`, covering `settleProposal`,
///         `unstick`, `finalizeEmergencySettle`) and from a successful
///         `reclaimProposerBond`, per openspec change
///         `settle-coverage-self-trigger`. Drives a REAL `GuardianRegistry` +
///         `StakedWood` + `ExposureLedger` stack (mirrors
///         `CoverageEndToEnd.t.sol`'s fixture) so every dollar of exposure is
///         booked by an actual guardian approval, and the trigger's collapse
///         is observed through the ledger's own `openExposureUsd`.
///
/// @dev    Fixture scale: vault asset USDG (6-dec, $1.00 feed), no
///         TierRegistry wired => tier 2 => requiredCoverage == maxCapital ==
///         $1,000. FOUR guardians (g1-g4) each stake 20,000 WOOD == $1,000
///         slashable at the fixture's $0.05/WOOD effective price -- matching
///         proposal.md's own worked example: four approvers reserve
///         4,000e18 in aggregate against a $1,000 need, collapsing to
///         1,000e18 once `settleCoverage` runs (250e18 each, pro-rata).
contract SettleCoverageSelfTriggerTest is Test {
    // ── Shared infrastructure ──
    ERC20Mock public usdg;
    ERC20Mock public wood;
    ERC20Mock public targetToken;
    BatchExecutorLib public executorLib;
    MockAgentRegistry public agentRegistry;
    ProtocolConfig public protocolConfig;
    StakedWood public swood;
    GuardianRegistry public registry;
    ExposureLedger public ledger;
    MockFeedSCT public feed;
    ProposerBondEscrow public escrow;

    // ── Main syndicate under test ──
    SyndicateVault public vaultA;
    SyndicateGovernor public govA;

    // ── Second syndicate: no bond escrow, ledger = RevertingLedgerMock —
    //    isolates the "generic revert" failure case from the real ledger's
    //    own realistic NoWoodPrice revert.
    SyndicateVault public vaultC;
    SyndicateGovernor public govC;
    RevertingLedgerMock public revertingLedger;

    address public owner = makeAddr("owner");
    address public ledgerOwner = makeAddr("ledgerOwner");
    address public agentA = makeAddr("agentA");
    address public agentC = makeAddr("agentC");
    address public lp = makeAddr("lp");
    address public random = makeAddr("random");

    address public g1 = makeAddr("guardian1");
    address public g2 = makeAddr("guardian2");
    address public g3 = makeAddr("guardian3");
    address public g4 = makeAddr("guardian4");
    // Dedicated to the gas-snapshot test (3.8) only, so its single-approver
    // measurements never dilute — or get diluted by — g1-g4's use in the
    // 4-approver case within the same test function.
    address public gGasBaseline = makeAddr("guardianGasBaseline");
    address public gGas1 = makeAddr("guardianGas1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 45 days; // >= epochLength (28d) + challengeWindow (14d)
    uint256 constant EPOCH_LENGTH = 28 days;

    uint256 constant GUARDIAN_STAKE = 20_000e18; // $1,000 each at the $0.05 haircut
    uint256 constant DEPOSIT = 60_000e6;

    uint256 constant MAX_CAPITAL = 1_000e6; // $1,000 tier-2 notional
    uint256 constant COVERAGE_USD = 1_000e18;
    /// @dev Each of the four equal approvers' pro-rata share once the
    ///      A-fold reservation collapses: 4,000e18 reserved against a
    ///      1,000e18 need -> 250e18 each, summing back to the need exactly.
    uint256 constant SHARE_USD = COVERAGE_USD / 4;
    uint256 constant BOND_WOOD = 200e18; // $1,000 x 1% / $0.05

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(owner);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: COOL_DOWN,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

        (govA, vaultA) = _deploySyndicate();
        (govC, vaultC) = _deploySyndicate();
        registry.addGovernor(address(govA), address(vaultA));
        registry.addGovernor(address(govC), address(vaultC));

        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vaultA)), abi.encode(address(govA))
        );
        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vaultC)), abi.encode(address(govC))
        );

        vm.startPrank(owner);
        vaultA.registerAgent(agentRegistry.mint(agentA), agentA);
        vaultC.registerAgent(agentRegistry.mint(agentC), agentC);
        vm.stopPrank();

        usdg.mint(lp, 2 * DEPOSIT);
        vm.startPrank(lp);
        usdg.approve(address(vaultA), DEPOSIT);
        vaultA.deposit(DEPOSIT, lp);
        usdg.approve(address(vaultC), DEPOSIT);
        vaultC.deposit(DEPOSIT, lp);
        vm.stopPrank();

        // ── Guardian cohort, matured to par.
        _stakeGuardian(g1, GUARDIAN_STAKE, 1);
        _stakeGuardian(g2, GUARDIAN_STAKE, 2);
        _stakeGuardian(g3, GUARDIAN_STAKE, 3);
        _stakeGuardian(g4, GUARDIAN_STAKE, 4);
        _stakeGuardian(gGasBaseline, GUARDIAN_STAKE, 5);
        _stakeGuardian(gGas1, GUARDIAN_STAKE, 6);
        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        // ── Owner stake, bound for vaultA (emergency-path tests).
        wood.mint(owner, MIN_OWNER_STAKE);
        vm.prank(owner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(owner);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        swood.bindOwnerStake(owner, address(vaultA));

        // ── Real ExposureLedger, wired both ways onto govA/registry.
        ledger = new ExposureLedger(ledgerOwner, address(swood), EPOCH_LENGTH);
        feed = new MockFeedSCT(1e8, 8);
        MockWoodTwapOracle woodTwap = new MockWoodTwapOracle(0.05e8);
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8);
        ledger.setWoodTwapOracle(address(woodTwap));
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(owner);
        registry.setExposureLedger(address(ledger));

        escrow = new ProposerBondEscrow(address(wood), address(registry), address(ledger));
        govA.setExposureLedger(address(ledger));
        govA.setBondEscrow(address(escrow));

        wood.mint(agentA, 1_000_000e18);
        vm.prank(agentA);
        wood.approve(address(escrow), type(uint256).max);

        // ── govC: RevertingLedgerMock only, no bond escrow, no covered-TVL/
        //    bond gates to satisfy — the generic-revert isolation syndicate.
        revertingLedger = new RevertingLedgerMock();
        govC.setExposureLedger(address(revertingLedger));

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Fixture helpers ──

    function _deploySyndicate() internal returns (SyndicateGovernor gov, SyndicateVault v) {
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
                    managementFeeBps: 0
                }))
        );
        v = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(v),
                address(registry),
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
        gov = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
    }

    function _stakeGuardian(address who, uint256 amount, uint256 agentId) internal {
        wood.mint(who, amount);
        vm.startPrank(who);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(amount, agentId);
        vm.stopPrank();
    }

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(targetToken), data: abi.encodeCall(targetToken.approve, (address(usdg), 1)), value: 0
        });
    }

    /// @dev The settle leg is `approve(targetToken, 0)` — it moves nothing out,
    ///      so every proposal here declares a ZERO settle cap.
    ///      `requiredCoverage` sums the exec and settle legs, so declaring a
    ///      full `MAX_CAPITAL` on both would bill twice the notional these
    ///      proposals can move. It went unnoticed while the harness governors
    ///      ran registry-less, where the flat tier-2 default ignores declared
    ///      caps; the registry is mandatory at init since pashov finding #1.
    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(usdg.approve, (address(targetToken), 0)), value: 0
        });
    }

    function _propose(SyndicateGovernor gov, address v, address as_, uint256 duration) internal returns (uint256) {
        BatchExecutorLib.Call[] memory exec = _execCalls();
        BatchExecutorLib.Call[] memory settle = _settleCalls();
        vm.prank(as_);
        return gov.propose(
            v,
            address(0),
            "ipfs://settle-coverage-self-trigger",
            duration,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            exec,
            GovEnvelope.defaultCaps(MAX_CAPITAL, exec.length),
            settle,
            GovEnvelope.defaultCaps(0, settle.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _openReview(SyndicateGovernor gov, uint256 pid) internal {
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
    }

    function _vote(SyndicateGovernor gov, uint256 pid, address guardian) internal {
        vm.prank(guardian);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function _voteAllFour(SyndicateGovernor gov, uint256 pid) internal {
        _vote(gov, pid, g1);
        _vote(gov, pid, g2);
        _vote(gov, pid, g3);
        _vote(gov, pid, g4);
    }

    function _pastReview(SyndicateGovernor gov, uint256 pid) internal {
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
    }

    function _state(SyndicateGovernor gov, uint256 pid) internal view returns (uint256) {
        return uint256(gov.getProposal(pid).state);
    }

    /// @dev Full propose -> 4-approver review -> execute, for govA. Returns
    ///      the proposal id with executedAt stamped and executeBy fixed.
    function _proposeApproveExecute(uint256 duration) internal returns (uint256 pid) {
        pid = _propose(govA, address(vaultA), agentA, duration);
        _openReview(govA, pid);
        _voteAllFour(govA, pid);
        _pastReview(govA, pid);
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @dev Sums CoverageSettleFailed emits from `emitter` in the given logs.
    function _countCoverageSettleFailed(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 n) {
        bytes32 topic0 = ISyndicateGovernor.CoverageSettleFailed.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    function _countCoverageSettled(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 n) {
        bytes32 topic0 = IExposureLedger.CoverageSettled.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    // ── 3.1 Settlement past executeBy collapses the cohort's reservations ──

    function test_settleProposal_pastExecuteBy_collapsesReservations() public {
        uint256 pid = _proposeApproveExecute(3 days);
        // SHE-225: the collapse now lands AT EXECUTE, so the A-fold reservation
        // is already gone before settlement runs. Settlement re-running the pass
        // is idempotent, which is what the rest of this test pins.
        assertEq(ledger.openExposureUsd(g1), SHARE_USD, "g1 already collapsed at execute");
        assertEq(ledger.openExposureUsd(g2), SHARE_USD, "g2 already collapsed at execute");
        assertEq(ledger.openExposureUsd(g3), SHARE_USD, "g3 already collapsed at execute");
        assertEq(ledger.openExposureUsd(g4), SHARE_USD, "g4 already collapsed at execute");

        uint256 executeBy = govA.getProposal(pid).executeBy;
        vm.warp(govA.getProposal(pid).executedAt + 3 days);
        assertGt(block.timestamp, executeBy, "precondition: settling strictly after executeBy");

        vm.recordLogs();
        vm.prank(random); // non-proposer settle after the full strategyDuration
        govA.settleProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Settled));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 0, "no failure expected");
        assertEq(_countCoverageSettled(logs, address(ledger)), 1, "settlement re-runs the pass idempotently");

        // Pro-rata: 4 equal approvers, aggregate reserved 4,000e18 vs a
        // 1,000e18 need -> 250e18 each, summing back to the need exactly. The
        // re-run at settlement re-derives the same split from unchanged pledges.
        assertEq(ledger.openExposureUsd(g1), SHARE_USD, "g1 holds its pro-rata share");
        assertEq(ledger.openExposureUsd(g2), SHARE_USD, "g2 holds its pro-rata share");
        assertEq(ledger.openExposureUsd(g3), SHARE_USD, "g3 holds its pro-rata share");
        assertEq(ledger.openExposureUsd(g4), SHARE_USD, "g4 holds its pro-rata share");
    }

    // ── 3.1b The execute-time collapse itself (SHE-225 regression) ──

    /// @notice THE SHE-225 REGRESSION. Before the fix the cohort left
    ///         `executeProposal` holding `A x coverage` and only
    ///         `_settleCoverageBestEffort` (past `executeBy`) or
    ///         `reclaimProposerBond` could collapse it — so a proposal settling
    ///         inside its own window kept every approver locked at N x their
    ///         real share indefinitely. The collapse now runs inside
    ///         `executeProposal`, after the `requireApproveQuorum` gate.
    function test_executeProposal_collapsesReservationsImmediately() public {
        uint256 pid = _propose(govA, address(vaultA), agentA, 3 days);
        _openReview(govA, pid);
        _voteAllFour(govA, pid);
        _pastReview(govA, pid);

        // Every approver holds the FULL coverage right up to the execute call.
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "g1 holds full coverage pre-execute");
        assertEq(ledger.openExposureUsd(g4), COVERAGE_USD, "g4 holds full coverage pre-execute");

        vm.recordLogs();
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettled(logs, address(ledger)), 1, "execute collapses the cohort exactly once");
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 0, "no failure on the execute-time pass");

        assertEq(ledger.openExposureUsd(g1), SHARE_USD, "g1 collapsed at execute");
        assertEq(ledger.openExposureUsd(g2), SHARE_USD, "g2 collapsed at execute");
        assertEq(ledger.openExposureUsd(g3), SHARE_USD, "g3 collapsed at execute");
        assertEq(ledger.openExposureUsd(g4), SHARE_USD, "g4 collapsed at execute");
    }

    /// @notice The collapse must not cost the proposal any capital: a
    ///         fully-covered proposal keeps `MAX_CAPITAL` across it.
    ///
    /// @dev    NOT AN ORDERING CONTROL, DELIBERATELY LABELLED SO. Moving the
    ///         `settleCoverage` call ahead of `requireApproveQuorum` leaves this
    ///         test GREEN — verified by mutation, not assumed. At the shipped
    ///         `kNumerator == 1` a guardian's aggregate booking is capped at its
    ///         own slashable bond, so `slashable / liveTotal >= 1`,
    ///         `_sharedSlashableUsd` returns the booking unchanged, and the
    ///         cross-proposal haircut the ordering guards against cannot bite at
    ///         all. Collapse-first would only shave the gate's MARGIN (summing to
    ///         exactly `needUsd` rather than the A-fold aggregate), which this
    ///         fixture cannot distinguish.
    ///
    ///         A real ordering control needs `setKNumerator(2)` plus a guardian
    ///         over-committed across govA and govB — see SHE-225. Left unbuilt
    ///         rather than left here looking like proof it is not.
    function test_executeProposal_collapseDoesNotScaleDownCapital() public {
        uint256 pid = _propose(govA, address(vaultA), agentA, 3 days);
        _openReview(govA, pid);
        _voteAllFour(govA, pid);
        _pastReview(govA, pid);
        govA.executeProposal(pid);

        assertEq(
            govA.getProposal(pid).effectiveMaxCapital,
            MAX_CAPITAL,
            "fully-covered proposal keeps its full capital across the execute-time collapse"
        );
    }

    // ── 3.2 Proposer self-settle before executeBy: nothing left to collapse ──

    /// @notice PREVIOUSLY ASSERTED THE BUG. This test used to pin
    ///         "reservations untouched — the documented silent skip", which is
    ///         precisely SHE-225: a proposal settling inside its own window took
    ///         the silent-skip branch and left every approver locked at the full
    ///         coverage with only the proposer's own `reclaimProposerBond` able
    ///         to release it. The settlement-time trigger still skips here (that
    ///         part is unchanged and still worth pinning) — but the execute-time
    ///         collapse means there is nothing left for it to do.
    function test_settleProposal_beforeExecuteBy_proposerSelfSettle_skipsSilently() public {
        uint256 pid = _proposeApproveExecute(7 days);
        uint256 executeBy = govA.getProposal(pid).executeBy;

        vm.warp(govA.getProposal(pid).executedAt + 1 hours + 1);
        assertLe(block.timestamp, executeBy, "precondition: settling at/before executeBy");

        vm.recordLogs();
        vm.prank(agentA); // proposer self-settle
        govA.settleProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Settled));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 0, "no failed event on the documented skip");
        assertEq(
            _countCoverageSettled(logs, address(ledger)), 0, "settlement-time trigger still skips before executeBy"
        );

        // SHE-225: collapsed at execute, so the skip above costs nothing. Before
        // the fix these four read COVERAGE_USD — 4x the real share, on a
        // finished proposal, with no caller able to release it.
        assertEq(ledger.openExposureUsd(g1), SHARE_USD, "g1 collapsed at execute, not left at 4x");
        assertEq(ledger.openExposureUsd(g2), SHARE_USD, "g2 collapsed at execute, not left at 4x");
        assertEq(ledger.openExposureUsd(g3), SHARE_USD, "g3 collapsed at execute, not left at 4x");
        assertEq(ledger.openExposureUsd(g4), SHARE_USD, "g4 collapsed at execute, not left at 4x");
    }

    // ── 3.3 Failure isolation ──

    /// @notice Realistic ledger-side revert: WOOD price unset (`NoWoodPrice`)
    ///         at settlement time. Settlement still reaches `Settled`;
    ///         `CoverageSettleFailed` fires instead of reverting; reservations
    ///         stay exactly as they were (the reverted call rolled back any
    ///         ledger-side write).
    function test_settlementTrigger_failureIsolation_noWoodPrice() public {
        uint256 pid = _proposeApproveExecute(3 days);
        vm.prank(ledgerOwner);
        ledger.setWoodUsdPrice(0); // forces woodPriceX8() -> NoWoodPrice

        vm.warp(govA.getProposal(pid).executedAt + 3 days);
        assertGt(block.timestamp, govA.getProposal(pid).executeBy);

        vm.recordLogs();
        vm.prank(random);
        govA.settleProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Settled), "settlement not bricked");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 1, "CoverageSettleFailed emitted exactly once");
        assertEq(_countCoverageSettled(logs, address(ledger)), 0, "the ledger pass never completed");

        // Reservations untouched by the reverted pass. The baseline is the
        // execute-time collapse (SHE-225), not the full coverage: the price was
        // still readable at execute, so the cohort is already at its pro-rata
        // share before this settlement attempt fails.
        assertEq(ledger.openExposureUsd(g1), SHARE_USD);
        assertEq(ledger.openExposureUsd(g2), SHARE_USD);
    }

    /// @notice Same failure isolation, at the `reclaimProposerBond` call site:
    ///         the bond is still released even though the ledger reverts.
    function test_reclaimTrigger_failureIsolation_noWoodPrice() public {
        uint256 pid = _proposeApproveExecute(3 days);
        uint256 executedAt = govA.getProposal(pid).executedAt;
        vm.warp(executedAt + 3 days);
        vm.prank(random);
        govA.settleProposal(pid); // past executeBy: settlement-time trigger already ran & collapsed

        vm.prank(ledgerOwner);
        ledger.setWoodUsdPrice(0); // breaks the LEDGER for the reclaim-time pass

        vm.warp(executedAt + govA.getProposal(pid).strategyDuration + ledger.challengeWindow());
        uint256 agentBalBefore = wood.balanceOf(agentA);

        vm.recordLogs();
        govA.reclaimProposerBond(pid);

        assertEq(wood.balanceOf(agentA), agentBalBefore + BOND_WOOD, "bond released despite the ledger revert");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 1, "reclaim-time trigger failure surfaced");
    }

    /// @notice Generic (non-`NoWoodPrice`) revert from an arbitrary
    ///         `IExposureLedger`-shaped ledger: the bare catch is agnostic to
    ///         the revert reason. Uses govC / RevertingLedgerMock, which
    ///         needs no guardian approval to execute (quorumTierThreshold
    ///         set unreachable) and has no bond escrow wired.
    function test_settlementTrigger_failureIsolation_genericRevert() public {
        uint256 pid = _propose(govC, address(vaultC), agentC, 3 days);
        _openReview(govC, pid);
        _pastReview(govC, pid); // no approvers needed: quorum check is skipped
        govC.executeProposal(pid);
        assertEq(_state(govC, pid), uint256(ISyndicateGovernor.ProposalState.Executed));

        vm.warp(govC.getProposal(pid).executedAt + 3 days);
        assertGt(block.timestamp, govC.getProposal(pid).executeBy);

        vm.recordLogs();
        vm.prank(random);
        govC.settleProposal(pid);
        assertEq(_state(govC, pid), uint256(ISyndicateGovernor.ProposalState.Settled), "settlement not bricked");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govC)), 1, "generic revert surfaced as CoverageSettleFailed");
    }

    // ── 3.4 Emergency paths share _finishSettlement ──

    function test_unstick_pastExecuteBy_firesTrigger() public {
        uint256 pid = _proposeApproveExecute(3 days);
        vm.warp(govA.getProposal(pid).executedAt + 3 days + 1);
        assertGt(block.timestamp, govA.getProposal(pid).executeBy);

        vm.recordLogs();
        vm.prank(owner); // vault owner
        govA.unstick(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Settled));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 0);
        assertEq(_countCoverageSettled(logs, address(ledger)), 1, "unstick fires the trigger via _finishSettlement");
        assertEq(ledger.openExposureUsd(g1), 250e18);
    }

    function test_finalizeEmergencySettle_pastExecuteBy_firesTrigger() public {
        uint256 pid = _proposeApproveExecute(3 days);
        vm.warp(govA.getProposal(pid).executedAt + 3 days + 1);
        assertGt(block.timestamp, govA.getProposal(pid).executeBy);

        BatchExecutorLib.Call[] memory customCalls = _settleCalls();
        vm.prank(owner);
        govA.emergencySettleWithCalls(pid, customCalls);

        // No guardian block vote cast -> resolves unblocked once the review
        // period elapses.
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        vm.recordLogs();
        vm.prank(owner);
        govA.finalizeEmergencySettle(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Settled));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 0);
        assertEq(
            _countCoverageSettled(logs, address(ledger)),
            1,
            "finalizeEmergencySettle fires the trigger via _finishSettlement"
        );
        assertEq(ledger.openExposureUsd(g1), 250e18);
    }

    // ── 3.5 Reclaim after an early settlement: converges, no longer needed ──

    /// @notice ROLE CHANGE (SHE-225). This test previously asserted that reclaim
    ///         "collapses the reservations the early settle could not" — reclaim
    ///         was the ONLY backstop for a proposal that settled inside its own
    ///         window, and a proposer who never reclaimed left the whole cohort
    ///         locked at 4x indefinitely. The execute-time collapse removes that
    ///         dependency: there is nothing left uncollapsed by the time reclaim
    ///         runs, and the reclaim-time pass merely re-derives the same split.
    ///
    ///         Reclaim REMAINS the backstop for a proposal that expired
    ///         unexecuted, which has no execution to collapse at — pinned
    ///         separately by `test_reclaimProposerBond_expiredUnexecuted_firesTrigger`.
    function test_reclaimProposerBond_afterEarlySettlement_convergesOnExecuteTimeCollapse() public {
        uint256 pid = _proposeApproveExecute(7 days);
        uint256 executedAt = govA.getProposal(pid).executedAt;
        uint256 executeBy = govA.getProposal(pid).executeBy;

        // Proposer self-settles well before executeBy: the settlement-time
        // trigger still skips (3.2), but the cohort is already collapsed.
        vm.warp(executedAt + 1 hours + 1);
        assertLe(block.timestamp, executeBy);
        vm.prank(agentA);
        govA.settleProposal(pid);
        assertEq(ledger.openExposureUsd(g1), SHARE_USD, "already collapsed at execute, not by this settle");

        // Strategy term + challenge window pass -> reclaim is provably past
        // executeBy. The `+ strategyDuration` anchor (second-audit finding A)
        // only strengthens this guarantee: the hold now ends strictly later.
        vm.warp(executedAt + govA.getProposal(pid).strategyDuration + ledger.challengeWindow());
        assertGt(block.timestamp, executeBy, "structural guarantee (design D1): reclaim is past executeBy");

        vm.recordLogs();
        govA.reclaimProposerBond(pid);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 0);
        assertEq(_countCoverageSettled(logs, address(ledger)), 1, "reclaim fires the backstop trigger");

        assertEq(ledger.openExposureUsd(g1), SHARE_USD, "reclaim-time pass converges on the same split");
        assertEq(ledger.openExposureUsd(g2), SHARE_USD);
        assertEq(ledger.openExposureUsd(g3), SHARE_USD);
        assertEq(ledger.openExposureUsd(g4), SHARE_USD);
    }

    // ── 3.6 Idempotence / convergence ──

    function test_idempotence_externalThenSettleThenReclaim_convergesNoDoubleRelease() public {
        uint256 pid = _proposeApproveExecute(3 days);
        uint256 executedAt = govA.getProposal(pid).executedAt;

        // External permissionless call first, well after executeBy.
        vm.warp(executedAt + 3 days + 1);
        ledger.settleCoverage(address(govA), pid);
        assertEq(ledger.openExposureUsd(g1), 250e18, "external pass already collapsed it");

        uint256 agentBalBeforeSettle = wood.balanceOf(agentA);

        // Settlement trigger re-runs the same pass and converges (no change).
        vm.prank(random);
        govA.settleProposal(pid);
        assertEq(ledger.openExposureUsd(g1), 250e18, "settlement trigger converges, does not compound");

        // Reclaim trigger re-runs a third time and still converges.
        vm.warp(executedAt + govA.getProposal(pid).strategyDuration + ledger.challengeWindow());
        govA.reclaimProposerBond(pid);
        assertEq(ledger.openExposureUsd(g1), 250e18, "reclaim trigger converges too");
        assertEq(ledger.openExposureUsd(g2), 250e18);
        assertEq(ledger.openExposureUsd(g3), 250e18);
        assertEq(ledger.openExposureUsd(g4), 250e18);

        // No double-release: the bond moved exactly once, at reclaim.
        assertEq(wood.balanceOf(agentA), agentBalBeforeSettle + BOND_WOOD, "bond released exactly once");
        vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
        govA.reclaimProposerBond(pid);
    }

    // ── 3.7 Expired-unexecuted proposal with a bond ──

    function test_reclaimProposerBond_expiredUnexecuted_firesTrigger() public {
        uint256 pid = _propose(govA, address(vaultA), agentA, 7 days);
        _openReview(govA, pid);
        _voteAllFour(govA, pid); // approvers book exposure even though it never executes
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD);

        // Never executed: warp past executeBy and let it lazily expire.
        uint256 executeBy = govA.getProposal(pid).executeBy;
        vm.warp(executeBy + 1);
        govA.resolveProposalState(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Expired));

        vm.recordLogs();
        govA.reclaimProposerBond(pid); // executedAt == 0: no challenge-window gate to wait on
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCoverageSettleFailed(logs, address(govA)), 0);
        assertEq(_countCoverageSettled(logs, address(ledger)), 1, "Expired implies past executeBy (design D1)");

        assertEq(ledger.openExposureUsd(g1), 250e18, "never-executed cohort collapses on the live basis");
    }

    /// @notice Documented residual (design D1/tasks 3.7): with no bond escrow
    ///         wired, `reclaimProposerBond` reverts before ever reaching the
    ///         trigger — the surface is unreachable, not merely skipped. The
    ///         permissionless external `settleCoverage` remains the backstop.
    function test_reclaimProposerBond_noBondEscrow_triggerSurfaceUnreachable() public {
        uint256 pid = _propose(govC, address(vaultC), agentC, 3 days); // govC has no bond escrow wired
        _openReview(govC, pid);
        _pastReview(govC, pid);
        govC.executeProposal(pid);
        vm.warp(govC.getProposal(pid).executedAt + 3 days + 1);
        vm.prank(random);
        govC.settleProposal(pid); // succeeds; RevertingLedgerMock's settleCoverage reverts and is caught

        vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
        govC.reclaimProposerBond(pid); // no bond was ever locked -> reverts before the trigger tail
    }

    /// @notice Audit fix: a Draft proposal (collaborative, coProposers.length
    ///         > 0) that never reaches Pending has `executeBy == 0` forever
    ///         (only `_initPendingProposal`, on the non-collaborative branch,
    ///         ever writes it) -- but `_snapshotTierAndGate` still locks a
    ///         bond and pins `proposerBondLedger` unconditionally at propose.
    ///         The lead proposer cancels while still in Draft (a routine,
    ///         non-adversarial path -- no collaboration-window wait needed
    ///         since a single co-proposer's Draft is cancellable at any
    ///         point). `reclaimProposerBond` on the resulting Cancelled
    ///         proposal must hit the `proposal.executeBy == 0` disjunct of
    ///         the guard and skip SILENTLY: no ledger call, no
    ///         `CoverageSettleFailed` -- NOT a caught `ReviewNotClosed` for a
    ///         proposal that was never capable of a real trigger failure.
    function test_reclaimProposerBond_draftNeverPending_executeByZero_skipsSilently() public {
        address coAgentA = makeAddr("coAgentA");
        // Hoisted: `agentRegistry.mint(coAgentA)` in argument position would
        // consume the pending one-shot `vm.prank(owner)` before
        // `registerAgent` itself runs (repo gotcha).
        uint256 coAgentNftId = agentRegistry.mint(coAgentA);
        vm.prank(owner);
        vaultA.registerAgent(coAgentNftId, coAgentA);

        ISyndicateGovernor.CoProposer[] memory coProposers = new ISyndicateGovernor.CoProposer[](1);
        coProposers[0] = ISyndicateGovernor.CoProposer({agent: coAgentA, splitBps: 3000});

        BatchExecutorLib.Call[] memory exec = _execCalls();
        BatchExecutorLib.Call[] memory settle = _settleCalls();
        vm.prank(agentA);
        uint256 pid = govA.propose(
            address(vaultA),
            address(0),
            "ipfs://draft-never-pending",
            3 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            exec,
            GovEnvelope.defaultCaps(MAX_CAPITAL, exec.length),
            settle,
            GovEnvelope.defaultCaps(0, settle.length),
            coProposers
        );

        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Draft), "collaborative propose -> Draft");
        assertEq(govA.getProposal(pid).executeBy, 0, "executeBy never written on the Draft path");
        assertEq(govA.getProposal(pid).proposerBondWood, BOND_WOOD, "bond locked unconditionally at propose");
        assertTrue(govA.getProposal(pid).proposerBondLedger != address(0), "ledger pinned unconditionally too");

        // Lead cancels immediately -- a single co-proposer Draft (total == 1)
        // is cancellable at any point, no collaboration-window wait needed.
        vm.prank(agentA);
        govA.cancelProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Cancelled));
        assertEq(govA.getProposal(pid).executeBy, 0, "still zero -- Cancelled from Draft never touches it");

        uint256 agentBalBefore = wood.balanceOf(agentA);
        vm.recordLogs();
        govA.reclaimProposerBond(pid); // executedAt == 0 too -> no challenge-window gate to wait on
        assertEq(wood.balanceOf(agentA), agentBalBefore + BOND_WOOD, "bond released normally");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(
            _countCoverageSettleFailed(logs, address(govA)),
            0,
            "silent skip, NOT a caught ReviewNotClosed -- executeBy == 0 is a skip condition, not a failure"
        );
        assertEq(_countCoverageSettled(logs, address(ledger)), 0, "ledger was never called at all");
    }

    // ── 3.8 Gas snapshot (nice-to-have; not blocking) ──

    /// @dev Isolates the trigger's added gas by diffing `settleProposal`
    ///      against an identical proposal whose trigger skips (settled at
    ///      the same "past duration" instant but BEFORE executeBy, via a
    ///      strategyDuration shorter than executionWindow), so the only
    ///      difference between baseline and the 1/4-approver cases is
    ///      whether `_settleCoverageBestEffort` actually calls the ledger.
    ///      Bounds are generous sanity checks against design D3's
    ///      ~50-120k/approver + ~40-60k base envelope, not tight pins.
    function test_gasSnapshot_triggerCost_1And4Approvers() public {
        // Baseline: trigger SKIPS (settled at/before executeBy). Uses a
        // strategyDuration of 1 hours so the proposer's minimum self-settle
        // wait is also its full duration, landing well before executeBy
        // (executionWindow == 1 days).
        uint256 pidBaseline = _propose(govA, address(vaultA), agentA, 1 hours);
        _openReview(govA, pidBaseline);
        _vote(govA, pidBaseline, gGasBaseline);
        _pastReview(govA, pidBaseline);
        govA.executeProposal(pidBaseline);
        vm.warp(govA.getProposal(pidBaseline).executedAt + 1 hours + 1);
        assertLe(block.timestamp, govA.getProposal(pidBaseline).executeBy, "baseline settles before executeBy");
        vm.prank(agentA);
        govA.settleProposal(pidBaseline);
        uint256 gasBaseline = vm.lastCallGas().gasTotalUsed;
        // Baseline's reservation is never collapsed (trigger skipped, and
        // settling this early means the ledger's own gate would still
        // reject an external release too) — harmless, `gGasBaseline` is
        // dedicated to this one proposal and never reused.

        // 1 approver (a guardian dedicated to this case, so its reservation
        // never dilutes g1-g4's use in the 4-approver case below), trigger
        // FIRES.
        uint256 pid1 = _propose(govA, address(vaultA), agentA, 3 days);
        _openReview(govA, pid1);
        _vote(govA, pid1, gGas1);
        _pastReview(govA, pid1);
        govA.executeProposal(pid1);
        vm.warp(govA.getProposal(pid1).executedAt + 3 days);
        vm.prank(random);
        govA.settleProposal(pid1);
        uint256 gas1Approver = vm.lastCallGas().gasTotalUsed;

        // 4 approvers, trigger FIRES.
        uint256 pid4 = _proposeApproveExecute(3 days);
        vm.warp(govA.getProposal(pid4).executedAt + 3 days);
        vm.prank(random);
        govA.settleProposal(pid4);
        uint256 gas4Approvers = vm.lastCallGas().gasTotalUsed;

        uint256 delta1 = gas1Approver - gasBaseline;
        uint256 delta4 = gas4Approvers - gasBaseline;
        emit log_named_uint("gasBaseline (trigger skipped)", gasBaseline);
        emit log_named_uint("gas 1 approver (trigger fired)", gas1Approver);
        emit log_named_uint("gas 4 approvers (trigger fired)", gas4Approvers);
        emit log_named_uint("delta, 1 approver", delta1);
        emit log_named_uint("delta, 4 approvers", delta4);

        // Generous sanity bounds (design D3: ~40-60k base + ~50-120k/approver).
        assertLt(delta1, 400_000, "1-approver trigger cost within a generous envelope");
        assertLt(delta4, 900_000, "4-approver trigger cost within a generous envelope");
        assertGt(delta4, delta1, "cost grows with approver count, as design D3 predicts");
    }
}
