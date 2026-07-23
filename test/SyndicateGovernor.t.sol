// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "./mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../src/interfaces/IVaultWithdrawalQueue.sol";
import {MockStrategyAdapter} from "./mocks/MockStrategyAdapter.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {GovEnvelope} from "./helpers/GovEnvelope.sol";

contract SyndicateGovernorTest is Test {
    SyndicateGovernor public governor;

    /// @dev Widest legal risk envelope, computed once in setUp (see there).
    ISyndicateGovernor.RiskEnvelope internal permissiveEnv;
    ProtocolConfig public protocolConfig;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public agentEoa = makeAddr("agentEoa");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public random = makeAddr("random");

    uint256 public agentNftId;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant MAX_STRATEGY_DURATION = 30 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;

    ERC20Mock public targetToken;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        // Fees moved to ProtocolConfig (per-vault governor snapshots them at
        // propose). Match the legacy 1% protocol fee the settlement tests expect.
        vm.startPrank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);
        protocolConfig.setProtocolFeeBps(100);
        vm.stopPrank();
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

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault), // vault_: this test's vault (per-vault governor)
                address(guardianRegistry),
                address(protocolConfig),
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
        // Lane A off (no PriceRouter wired) — exercises the async (Lane B) paths.
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

        vm.warp(block.timestamp + 1);

        // Widest legal envelope at setUp TVL (finding 3 ceiling). Hoisted to a
        // state var: computing it inline made an external staticcall between
        // vm.prank/vm.expectRevert and propose(), consuming the cheatcode.
        permissiveEnv = GovEnvelope.permissive(address(vault));
    }

    // ==================== HELPERS ====================

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _simpleExecuteCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
        return calls;
    }

    function _simpleSettlementCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
        return calls;
    }

    function _createSimpleProposal(uint256 perfFeeBps, uint256 duration) internal returns (uint256 proposalId) {
        // Agent fee is now a vault-owner property read live at settlement; set
        // it to the test's intended rate so realized-fee assertions still hold.
        vm.prank(owner);
        vault.setAgentFeeBps(perfFeeBps);
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            duration,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
        vm.warp(block.timestamp + 1);
    }

    function _createApprovedProposal(uint256 perfFeeBps, uint256 duration) internal returns (uint256 proposalId) {
        proposalId = _createSimpleProposal(perfFeeBps, duration);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
    }

    function _createAndExecuteProposal(uint256 perfFeeBps, uint256 duration) internal returns (uint256 proposalId) {
        proposalId = _createApprovedProposal(perfFeeBps, duration);
        governor.executeProposal(proposalId);
        // MS-H3: proposer self-settle requires `MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE` (1h) elapsed.
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
    }

    /// @dev As `_createAndExecuteProposal` but pins a concrete `strategy` address on the proposal
    ///      (the default helpers use address(0) = Lane-B-only). Used by the H2/M4 opt-out tests,
    ///      which need a non-zero strategy whose `selfManagesFees()` the governor reads at settle.
    function _createAndExecuteProposalWithStrategy(uint256 perfFeeBps, uint256 duration, address strategy)
        internal
        returns (uint256 proposalId)
    {
        vm.prank(owner);
        vault.setAgentFeeBps(perfFeeBps);
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            strategy,
            "ipfs://test",
            duration,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
        vm.warp(block.timestamp + 1);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        governor.executeProposal(proposalId);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
    }

    // ==================== INITIALIZATION ====================

    function test_initialize() public view {
        ISyndicateGovernor.GovernorParams memory params = governor.getGovernorParams();
        assertEq(params.votingPeriod, VOTING_PERIOD);
        assertEq(params.executionWindow, EXECUTION_WINDOW);
        assertEq(params.vetoThresholdBps, VETO_THRESHOLD_BPS);
        assertEq(params.maxPerformanceFeeBps, MAX_PERF_FEE_BPS);
        assertEq(params.maxStrategyDuration, MAX_STRATEGY_DURATION);
        assertEq(params.cooldownPeriod, COOLDOWN_PERIOD);
        assertEq(governor.proposalCount(), 0);
        // isRegisteredVault removed in per-vault design - governor.vault() tracks the linked vault
        // assertTrue(governor.isRegisteredVault(address(vault)));
        assertEq(protocolConfig.protocolFeeBps(), 100);
        assertEq(protocolConfig.protocolFeeRecipient(), owner);
    }

    // ==================== PROPOSE ====================

    function test_propose() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        assertEq(proposalId, 1);
        assertEq(governor.proposalCount(), 1);

        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);
        assertEq(p.proposer, agent);
        assertEq(p.vault, address(vault));
        assertEq(p.performanceFeeBps, 1500, "snapshotted from vault at propose");
        assertEq(p.strategyDuration, 7 days);
        assertEq(uint256(p.state), uint256(ISyndicateGovernor.ProposalState.Pending));

        BatchExecutorLib.Call[] memory execCalls = governor.getExecuteCalls(proposalId);
        assertEq(execCalls.length, 1);
        BatchExecutorLib.Call[] memory settleCalls = governor.getSettlementCalls(proposalId);
        assertEq(settleCalls.length, 1);
    }

    function test_propose_notRegisteredAgent_reverts() public {
        vm.prank(random);
        vm.expectRevert(ISyndicateGovernor.NotRegisteredAgent.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
    }

    function test_propose_vaultNotRegistered_reverts() public {
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.VaultNotRegistered.selector);
        governor.propose(
            makeAddr("fakeVault"),
            address(0),
            "ipfs://test",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
    }

    function test_propose_strategyDurationTooLong_reverts() public {
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.StrategyDurationTooLong.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            MAX_STRATEGY_DURATION + 1,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
    }

    function test_propose_strategyDurationTooShort_reverts() public {
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.StrategyDurationTooShort.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            30 minutes,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
    }

    function test_propose_emptyExecuteCalls_reverts() public {
        BatchExecutorLib.Call[] memory empty = new BatchExecutorLib.Call[](0);
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.EmptyExecuteCalls.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            permissiveEnv,
            empty,
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
    }

    function test_propose_emptySettlementCalls_reverts() public {
        BatchExecutorLib.Call[] memory empty = new BatchExecutorLib.Call[](0);
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.EmptySettlementCalls.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            empty,
            _emptyCoProposers()
        );
    }

    /// @notice G-C1: propose() stamps snapshot at block.timestamp - 1 so any
    ///         delegation landing in the same block cannot be counted via
    ///         ERC20Votes.getPastVotes (which returns votes "at or before t").
    function test_propose_snapshotIsPriorTimestamp() public {
        uint256 tsBefore = block.timestamp;
        uint256 proposalId = governor.proposalCount() + 1;
        vm.prank(agent);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);
        assertEq(p.snapshotTimestamp, tsBefore - 1);
    }

    /// @notice G-C1: a delegation that lands in the same block as propose()
    ///         must NOT count toward voting weight. Exercises the full path
    ///         via governor.vote(): the voter holds shares but only delegates
    ///         in the propose block, so getPastVotes at snapshotTimestamp
    ///         (= block.timestamp - 1) returns 0 and the vote reverts as
    ///         NoVotingPower.
    function test_flashDelegate_sameBlock_notCounted() public {
        address flashVoter = makeAddr("flashVoter");

        // flashVoter receives shares via transfer so auto-delegation in
        // _deposit() does not fire -- delegates(flashVoter) stays at zero.
        vm.prank(lp1);
        vault.transfer(flashVoter, 10_000e6);

        // Same block: flashVoter delegates to self AND agent proposes.
        vm.prank(flashVoter);
        vault.delegate(flashVoter);

        vm.prank(agent);
        uint256 proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );

        // Snapshot is block.timestamp - 1; delegation checkpoint was written
        // at block.timestamp, so getPastVotes returns 0 and vote() reverts.
        vm.prank(flashVoter);
        vm.expectRevert(ISyndicateGovernor.NoVotingPower.selector);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
    }

    // ==================== VOTING ====================

    function test_vote() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.Against);

        assertTrue(governor.hasVoted(proposalId, lp1));
        assertTrue(governor.hasVoted(proposalId, lp2));
        assertFalse(governor.hasVoted(proposalId, random));

        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);
        assertEq(p.votesFor, vault.balanceOf(lp1));
        assertEq(p.votesAgainst, vault.balanceOf(lp2));
    }

    function test_vote_doubleVote_reverts() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp1);
        vm.expectRevert(ISyndicateGovernor.AlreadyVoted.selector);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
    }

    function test_vote_noShares_reverts() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(random);
        vm.expectRevert(ISyndicateGovernor.NoVotingPower.selector);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
    }

    function test_vote_afterVotingPeriod_reverts() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.prank(lp1);
        vm.expectRevert(ISyndicateGovernor.NotWithinVotingPeriod.selector);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
    }

    // ==================== PROPOSAL STATE RESOLUTION ====================

    function test_proposalState_approved() public {
        uint256 proposalId = _createApprovedProposal(1500, 7 days);
        assertEq(uint256(governor.getProposalState(proposalId)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    function test_proposal_passesWithNoVotes() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(governor.getProposalState(proposalId)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    function test_proposal_rejectedWhenVetoThresholdReached() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.Against);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.Against);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(governor.getProposalState(proposalId)), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    function test_proposalState_expired() public {
        uint256 proposalId = _createApprovedProposal(1500, 7 days);
        vm.warp(block.timestamp + EXECUTION_WINDOW + 1);
        assertEq(uint256(governor.getProposalState(proposalId)), uint256(ISyndicateGovernor.ProposalState.Expired));
    }

    // ==================== EXECUTE ====================

    function test_executeProposal() public {
        uint256 proposalId = _createApprovedProposal(1500, 7 days);
        governor.executeProposal(proposalId);

        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);
        assertEq(uint256(p.state), uint256(ISyndicateGovernor.ProposalState.Executed));
        assertEq(governor.getActiveProposal(), proposalId);
        assertTrue(vault.redemptionsLocked());
        assertEq(governor.getCapitalSnapshot(proposalId), 100_000e6);
    }

    function test_executeProposal_notApproved_reverts() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.Against);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.Against);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(proposalId);
    }

    /// @dev Post G-M1, `propose` reverts on `VaultHasOpenProposal` before
    ///      reaching the `StrategyAlreadyActive` guard inside `executeProposal`.
    ///      Belt-and-suspenders: the `executeProposal` guard stays as a safety
    ///      net, but the new primary defense is the propose-time check.
    function test_propose_blocksDuplicateWhileExecuted() public {
        _createAndExecuteProposal(1500, 7 days);
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.VaultHasOpenProposal.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://dup",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
    }

    function test_executeProposal_afterCooldown_succeeds() public {
        uint256 proposalId1 = _createAndExecuteProposal(1500, 7 days);
        vm.prank(agent);
        governor.settleProposal(proposalId1);
        vm.warp(block.timestamp + COOLDOWN_PERIOD + 1);
        uint256 proposalId2 = _createApprovedProposal(1500, 7 days);
        governor.executeProposal(proposalId2);
        assertEq(governor.getActiveProposal(), proposalId2);
    }

    // ==================== SETTLEMENT ====================

    function test_settleProposal_proposerSettlesEarly() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(proposalId);
        assertEq(uint256(p.state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(governor.getActiveProposal(), 0);
        assertFalse(vault.redemptionsLocked());
    }

    function test_settleProposal_nonProposerBeforeDuration_reverts() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.prank(random);
        vm.expectRevert(ISyndicateGovernor.StrategyDurationNotElapsed.selector);
        governor.settleProposal(proposalId);
    }

    function test_settleProposal_permissionless_afterDuration() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.warp(block.timestamp + 7 days);
        vm.prank(random);
        governor.settleProposal(proposalId);
        assertEq(uint256(governor.getProposal(proposalId).state), uint256(ISyndicateGovernor.ProposalState.Settled));
    }

    function test_settleProposal_notExecuted_reverts() public {
        uint256 proposalId = _createApprovedProposal(1500, 7 days);
        vm.expectRevert(ISyndicateGovernor.ProposalNotExecuted.selector);
        governor.settleProposal(proposalId);
    }

    // Legacy `emergencySettle(uint256, Call[])` is a revert stub as of Task 24.
    // See `test/governor/GovernorEmergency.t.sol` for the new 4-way lifecycle tests
    // (unstick / emergencySettleWithCalls / cancelEmergencySettle / finalizeEmergencySettle).

    // ==================== P&L CALCULATION ====================

    function test_settlement_noProfit_noFee() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        assertEq(usdc.balanceOf(agent), agentBalBefore);
    }

    function test_settlement_withProfit_agentAndManagementFee() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        usdc.mint(address(vault), 10_000e6);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        // Protocol fee: 1% of 10k = 100. Agent fee: 15% of 9900 = 1485. Mgmt: 0.5% of 8415 = 42.075
        assertEq(usdc.balanceOf(agent), agentBalBefore + 1_485e6);
        assertEq(usdc.balanceOf(owner), ownerBalBefore + 100e6 + 42_075000);
    }

    // ==================== H2/M4: self-managed-fee opt-out ====================

    /// @notice H2/M4: a strategy whose `selfManagesFees()` returns true opts out of ALL governor
    ///         settle-fees. Despite nonzero protocol (1%), performance (15%), and management (0.5%)
    ///         fees and a 10k profit, settle pays ZERO to protocol/agent/owner — the strategy already
    ///         crystallised its own fees. Prevents the custody-model double-charge where the governor's
    ///         float-delta PnL misreads net deposits as profit.
    function test_settlement_selfManagedStrategy_chargesZeroGovernorFees() public {
        MockStrategyAdapter strat = new MockStrategyAdapter();
        vm.mockCall(address(strat), abi.encodeWithSelector(IStrategy.selfManagesFees.selector), abi.encode(true));

        uint256 proposalId = _createAndExecuteProposalWithStrategy(1500, 7 days, address(strat));
        usdc.mint(address(vault), 10_000e6); // simulate profit (float delta)

        uint256 agentBalBefore = usdc.balanceOf(agent);
        uint256 ownerBalBefore = usdc.balanceOf(owner);

        vm.prank(agent);
        governor.settleProposal(proposalId);

        // Opt-out: agent (proposer perf fee) AND owner (protocol + mgmt fee) are unchanged by settle.
        assertEq(usdc.balanceOf(agent), agentBalBefore, "self-fee'd: agent perf fee skipped");
        assertEq(usdc.balanceOf(owner), ownerBalBefore, "self-fee'd: protocol + mgmt fee skipped");
    }

    /// @notice Control: a strategy with `selfManagesFees()==false` (the BaseStrategy default) still
    ///         has governor fees distributed normally — proving the opt-out is driven by the FLAG,
    ///         not merely by a non-zero `strategy` on the proposal. Same fee math as the address(0)
    ///         baseline `test_settlement_withProfit_agentAndManagementFee`.
    function test_settlement_nonSelfManagedStrategy_chargesNormalFees() public {
        MockStrategyAdapter strat = new MockStrategyAdapter(); // selfManagesFees() == false
        uint256 proposalId = _createAndExecuteProposalWithStrategy(1500, 7 days, address(strat));
        usdc.mint(address(vault), 10_000e6);

        uint256 agentBalBefore = usdc.balanceOf(agent);
        uint256 ownerBalBefore = usdc.balanceOf(owner);

        vm.prank(agent);
        governor.settleProposal(proposalId);

        // Identical to the baseline: protocol 1% of 10k = 100; agent 15% of 9900 = 1485; mgmt 42.075.
        assertEq(usdc.balanceOf(agent), agentBalBefore + 1_485e6, "non-self-fee'd: agent fee charged");
        assertEq(usdc.balanceOf(owner), ownerBalBefore + 100e6 + 42_075000, "non-self-fee'd: protocol + mgmt charged");
    }

    // ── PR #388 #2: selfManagesFees snapshotted at propose, read from storage at settle ──

    /// @notice Regression A (brick closed): the flag is snapshotted at propose, so a
    ///         strategy whose `selfManagesFees()` REVERTS after propose no longer bricks
    ///         settlement. Pre-fix `_finishSettlement` did a live call with `pnl > 0`,
    ///         so a settle-time revert stranded normal AND emergency settlement.
    function test_settlement_selfManagesFeesSnapshot_revertAfterProposeDoesNotBrickSettle() public {
        MockStrategyAdapter strat = new MockStrategyAdapter(); // selfFee=false at propose
        uint256 proposalId = _createAndExecuteProposalWithStrategy(1500, 7 days, address(strat));
        usdc.mint(address(vault), 10_000e6); // positive PnL (float delta)

        // Strategy breaks after propose — a live settle-time read would revert here.
        strat.setRevertOnSelfManagesFees(true);

        uint256 agentBalBefore = usdc.balanceOf(agent);
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        vm.prank(agent);
        governor.settleProposal(proposalId); // must NOT revert

        // Snapshot was false ⇒ normal fee distribution still runs.
        assertEq(usdc.balanceOf(agent), agentBalBefore + 1_485e6, "settle used snapshot; fees charged");
        assertEq(usdc.balanceOf(owner), ownerBalBefore + 100e6 + 42_075000, "protocol + mgmt charged");
    }

    /// @notice Regression B (TOCTOU closed): a non-pure strategy that reports `false` at
    ///         propose then flips to `true` before settle must not change the outcome —
    ///         settle reads the storage snapshot (`false`), so `_distributeFees` runs.
    function test_settlement_selfManagesFeesSnapshot_toctouFlipIgnored() public {
        MockStrategyAdapter strat = new MockStrategyAdapter(); // selfFee=false at propose
        uint256 proposalId = _createAndExecuteProposalWithStrategy(1500, 7 days, address(strat));
        assertEq(governor.getProposal(proposalId).selfManagesFees, false, "snapshot false at propose");
        usdc.mint(address(vault), 10_000e6);

        // Attacker flips the live value AFTER propose; a live read would skip all fees.
        strat.setSelfFee(true);
        assertTrue(strat.selfManagesFees(), "live value flipped to true");

        uint256 agentBalBefore = usdc.balanceOf(agent);
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        // Uses the false snapshot ⇒ normal fees, not the flipped opt-out.
        assertEq(usdc.balanceOf(agent), agentBalBefore + 1_485e6, "flip ignored; agent fee charged");
        assertEq(usdc.balanceOf(owner), ownerBalBefore + 100e6 + 42_075000, "flip ignored; protocol + mgmt charged");
    }

    /// @notice Regression C (fail-fast): proposing with an EOA / non-strategy address now
    ///         reverts at propose (the snapshot call has no code to return a bool), instead
    ///         of storing a junk address that would brick settle later.
    function test_propose_eoaStrategyRevertsAtPropose() public {
        ISyndicateGovernor.CoProposer[] memory empty = _emptyCoProposers();
        vm.prank(agent);
        vm.expectRevert();
        governor.propose(
            address(vault),
            address(0xBEEF), // EOA, no selfManagesFees()
            "ipfs://eoa",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            empty
        );
    }

    /// @notice H2: the snapshot is clamped to `maxPerformanceFeeBps` at propose,
    ///         so the recorded/emitted rate equals what settlement charges — a
    ///         vault fee above the cap is never shown to voters as higher.
    function test_settlement_agentFeeClampedToMax() public {
        // Protocol owner lowers the configured cap below the vault's fee.
        vm.prank(owner);
        governor.setMaxPerformanceFeeBps(1000); // 10%, under the vault's 15%
        // Vault owner sets 15% — above the 10% param; the snapshot clamps to 10%.
        uint256 proposalId = _createAndExecuteProposal(MAX_PERF_FEE_BPS, 7 days);
        assertEq(vault.agentFeeBps(), MAX_PERF_FEE_BPS, "vault stores the owner's 15%");
        assertEq(governor.getProposal(proposalId).performanceFeeBps, 1000, "snapshot clamped at propose");
        usdc.mint(address(vault), 10_000e6);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        // 10% of net, not 15%: protocol 1% of 10k = 100; agent 10% of 9900 = 990.
        assertEq(usdc.balanceOf(agent), agentBalBefore + 990e6, "agent fee clamped to 10%");
    }

    /// @notice C1: the fee is snapshotted at propose, so an owner who changes
    ///         the vault's agentFeeBps after the vote cannot alter what this
    ///         proposal charges. Settlement uses the snapshot, not the live fee.
    function test_settlement_usesProposeTimeSnapshot() public {
        // Snapshot 15% at propose (helper sets the vault fee, then proposes).
        uint256 proposalId = _createAndExecuteProposal(MAX_PERF_FEE_BPS, 7 days);
        // Owner drops the live vault fee to 5% AFTER the proposal is created.
        vm.prank(owner);
        vault.setAgentFeeBps(500);
        assertEq(vault.agentFeeBps(), 500, "live vault fee changed post-propose");
        usdc.mint(address(vault), 10_000e6);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        // Uses the 15% snapshot, not the live 5%: protocol 1% of 10k = 100;
        // agent 15% of 9900 = 1485 (a live read would have charged 5% = 495).
        assertEq(usdc.balanceOf(agent), agentBalBefore + 1_485e6, "uses propose-time snapshot");
    }

    /// @notice H2 belt-and-braces: if the protocol lowers maxPerformanceFeeBps
    ///         AFTER a proposal is created, settlement re-clamps the (higher)
    ///         snapshot to the new cap.
    function test_settlement_clampsOnMidFlightCapReduction() public {
        uint256 proposalId = _createAndExecuteProposal(MAX_PERF_FEE_BPS, 7 days);
        assertEq(governor.getProposal(proposalId).performanceFeeBps, MAX_PERF_FEE_BPS, "snapshot 15%");
        // Cap lowered to 10% after the proposal exists. Owner setters are
        // frozen while a proposal is open; use the freeze-exempt factory
        // rescue path (this test contract is the governor's factory).
        ISyndicateGovernor.GovernorParams memory gp = governor.getGovernorParams();
        gp.maxPerformanceFeeBps = 1000;
        governor.forceSetParams(gp);
        usdc.mint(address(vault), 10_000e6);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        // H1 (pass 3): the settle-time re-clamp must EMIT FeeClamped too, not
        // silently clamp — indexers/voters need the on-chain signal.
        vm.expectEmit(true, true, true, false, address(governor));
        emit ISyndicateGovernor.FeeClamped(proposalId, MAX_PERF_FEE_BPS, 1000);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        // Settle re-clamps the 15% snapshot to the new 10% cap: 10% of 9900 = 990.
        assertEq(usdc.balanceOf(agent), agentBalBefore + 990e6, "settle clamps to lowered cap");
    }

    /// @notice M5: the vault's hard cap must equal the governor's
    ///         MAX_PERFORMANCE_FEE_CAP. Catches a divergent hand-edit.
    function test_maxAgentFeeBps_equalsGovernorCap() public view {
        assertEq(vault.MAX_AGENT_FEE_BPS(), governor.MAX_PERFORMANCE_FEE_CAP(), "vault cap must mirror governor cap");
    }

    /// @notice H1: when the vault's snapshotted fee exceeds maxPerformanceFeeBps,
    ///         propose emits FeeClamped(pid, snapshotted, clamped) so voters can
    ///         detect the recorded fee was clamped below the owner's intent.
    function test_propose_emitsFeeClampedWhenAboveCap() public {
        vm.prank(owner);
        governor.setMaxPerformanceFeeBps(1000); // cap 10%
        vm.prank(owner);
        vault.setAgentFeeBps(MAX_PERF_FEE_BPS); // vault 15% > cap
        uint256 expectedId = governor.proposalCount() + 1;
        // All three params indexed → check topic1/2/3, no data.
        vm.expectEmit(true, true, true, false, address(governor));
        emit ISyndicateGovernor.FeeClamped(expectedId, MAX_PERF_FEE_BPS, 1000);
        vm.prank(agent);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://test",
            7 days,
            permissiveEnv,
            _simpleExecuteCalls(),
            _simpleSettlementCalls(),
            _emptyCoProposers()
        );
    }

    /// @notice H1: no clamp when the vault fee is at or below the cap — the
    ///         snapshot equals the set fee (so FeeClamped is not emitted).
    function test_propose_noClampWhenWithinCap() public {
        uint256 pid = _createSimpleProposal(500, 7 days); // vault 5% <= cap 15%
        assertEq(governor.getProposal(pid).performanceFeeBps, 500, "no clamp within cap");
    }

    function test_settlement_withLoss_noFees() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        usdc.burn(address(vault), 5_000e6);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        assertEq(usdc.balanceOf(agent), agentBalBefore);
    }

    // ==================== REDEMPTION LOCK ====================

    function test_redemptionLock_withdrawReverts() public {
        _createAndExecuteProposal(1500, 7 days);
        // While `redemptionsLocked()` is true the vault advertises
        // `maxWithdraw == 0`, so OZ's standard pre-check surfaces the
        // canonical EIP-4626 revert first. The inner `RedemptionsLocked`
        // guard remains as defence-in-depth.
        assertEq(vault.maxWithdraw(lp1), 0);
        vm.prank(lp1);
        vm.expectPartialRevert(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector);
        vault.withdraw(1_000e6, lp1, lp1);
    }

    function test_redemptionUnlocked_afterSettlement() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        uint256 balBefore = usdc.balanceOf(lp1);
        vm.prank(lp1);
        vault.withdraw(1_000e6, lp1, lp1);
        assertEq(usdc.balanceOf(lp1), balBefore + 1_000e6);
    }

    // ==================== CANCEL ====================

    function test_cancelProposal() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(agent);
        governor.cancelProposal(proposalId);
        assertEq(uint256(governor.getProposal(proposalId).state), uint256(ISyndicateGovernor.ProposalState.Cancelled));
    }

    function test_cancelProposal_clearsActiveProposal() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(agent);
        governor.cancelProposal(proposalId);
        assertEq(governor.getActiveProposal(), 0, "activeProposal should be cleared after cancel");
        // Vault should not be locked after cancellation
        assertFalse(vault.redemptionsLocked(), "vault should not be locked after cancel");
    }

    function test_cancelProposal_notProposer_reverts() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(random);
        vm.expectRevert(ISyndicateGovernor.NotProposer.selector);
        governor.cancelProposal(proposalId);
    }

    function test_emergencyCancel() public {
        // Task 25: emergencyCancel is narrowed to Draft/Pending only.
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(owner);
        governor.emergencyCancel(proposalId);
        assertEq(uint256(governor.getProposal(proposalId).state), uint256(ISyndicateGovernor.ProposalState.Cancelled));
    }

    function test_emergencyCancel_clearsActiveProposal() public {
        // Task 25: emergencyCancel is narrowed to Draft/Pending only.
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(owner);
        governor.emergencyCancel(proposalId);
        assertEq(governor.getActiveProposal(), 0, "activeProposal should be cleared after emergencyCancel");
        assertFalse(vault.redemptionsLocked(), "vault should not be locked after emergencyCancel");
    }

    function test_emergencyCancel_approved_reverts() public {
        // Task 25: once the vote passes the proposal enters GuardianReview (or Approved
        // when no registry is wired); owner can no longer unilaterally cancel.
        uint256 proposalId = _createApprovedProposal(1500, 7 days);
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ProposalNotCancellable.selector);
        governor.emergencyCancel(proposalId);
    }

    function test_emergencyCancel_executedProposal_reverts() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ProposalNotCancellable.selector);
        governor.emergencyCancel(proposalId);
    }

    // ==================== VETO ====================

    function test_vetoProposal_pending() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(owner);
        governor.vetoProposal(proposalId);
        assertEq(uint256(governor.getProposal(proposalId).state), uint256(ISyndicateGovernor.ProposalState.Rejected));
    }

    function test_vetoProposal_clearsActiveProposal() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(owner);
        governor.vetoProposal(proposalId);
        assertEq(governor.getActiveProposal(), 0, "activeProposal should be cleared after veto");
        assertFalse(vault.redemptionsLocked(), "vault should not be locked after veto");
    }

    function test_vetoProposal_approved_reverts() public {
        // Task 25: vetoProposal is narrowed to Pending only; approved/GuardianReview
        // proposals flow through the guardian-review path instead.
        uint256 proposalId = _createApprovedProposal(1500, 7 days);
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ProposalNotCancellable.selector);
        governor.vetoProposal(proposalId);
    }

    function test_vetoProposal_notVaultOwner_reverts() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.prank(random);
        vm.expectRevert(ISyndicateGovernor.NotVaultOwner.selector);
        governor.vetoProposal(proposalId);
    }

    function test_vetoProposal_emitsEvent() public {
        uint256 proposalId = _createSimpleProposal(1500, 7 days);
        vm.expectEmit(true, true, false, false);
        emit ISyndicateGovernor.ProposalVetoed(proposalId, owner);
        vm.prank(owner);
        governor.vetoProposal(proposalId);
    }

    // (Legacy `emergencySettle_notVaultOwner_reverts` deleted — Task 24 stub reverts unconditionally.)

    // ==================== PARAMETER SETTERS (TIMELOCK) ====================

    function test_setVotingPeriod_appliesImmediately() public {
        vm.prank(owner);
        governor.setVotingPeriod(2 days);
        assertEq(governor.getGovernorParams().votingPeriod, 2 days);
    }

    function test_setVotingPeriod_tooLow_reverts() public {
        // V1.5: setters apply immediately and bounds are validated at call time.
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidVotingPeriod.selector);
        governor.setVotingPeriod(30 minutes);
    }

    function test_setters_notOwner_reverts() public {
        vm.startPrank(random);
        vm.expectRevert();
        governor.setVotingPeriod(2 days);
        vm.expectRevert();
        governor.setExecutionWindow(2 days);
        vm.expectRevert();
        governor.setVetoThresholdBps(5000);
        vm.expectRevert();
        governor.setMaxPerformanceFeeBps(2000);
        vm.expectRevert();
        governor.setMaxStrategyDuration(20 days);
        vm.expectRevert();
        governor.setCooldownPeriod(2 days);
        vm.stopPrank();
    }

    // ==================== VAULT MANAGEMENT ====================

    function test_addVault() public {
        // G-M9: governor rejects EOAs via extcodesize probe, so use a
        // deployed contract address — the executorLib has bytecode and is
        // not already registered.
        address newVault = address(executorLib);
        // isRegisteredVault removed in per-vault governor design
    }

    /* test_addVault_duplicate_reverts — stubbed: references removed API in per-vault governor design */
    function test_addVault_duplicate_reverts() public {}

    /* test_removeVault — stubbed: references removed API in per-vault governor design */
    function test_removeVault() public {}

    /* test_addVault_fromFactory — stubbed: references removed API in per-vault governor design */
    function test_addVault_fromFactory() public {}

    /* test_addVault_unauthorizedCaller_reverts — stubbed: addVault removed in per-vault governor design */
    function test_addVault_unauthorizedCaller_reverts() public {}

    // ==================== GOVERNOR ON VAULT ====================

    /* test_governor_readFromFactory — stubbed: references removed API in per-vault governor design */
    function test_governor_readFromFactory() public {}

    function test_redemptionsLocked_duringActiveProposal() public {
        assertFalse(vault.redemptionsLocked());
        _createAndExecuteProposal(1500, 7 days);
        assertTrue(vault.redemptionsLocked());
    }

    function test_executeGovernorBatch_notGovernor_reverts() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](0);
        vm.prank(random);
        vm.expectRevert(ISyndicateVault.NotGovernor.selector);
        vault.executeGovernorBatch(calls, type(uint256).max);
    }

    // ==================== VETO ON EXECUTED PROPOSAL ====================

    function test_vetoProposal_executed_reverts() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ProposalNotCancellable.selector);
        governor.vetoProposal(proposalId);
    }

    // ==================== SETTLEMENT FEE EDGE CASES ====================

    function test_settlement_smallProfit_feeMath() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        // 1 unit of USDC profit (0.000001 USDC)
        usdc.mint(address(vault), 1);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        // Protocol fee: 2% of 1 = 0 (rounds down). Net profit = 1.
        // Agent fee: 15% of 1 = 0. Mgmt fee: 0.5% of 1 = 0.
        // All fees round to zero — no transfers.
        assertEq(usdc.balanceOf(agent), agentBalBefore);
        assertEq(usdc.balanceOf(owner), ownerBalBefore);
    }

    function test_settlement_zeroPerformanceFee_noAgentPayout() public {
        uint256 proposalId = _createAndExecuteProposal(0, 7 days);
        usdc.mint(address(vault), 10_000e6);
        uint256 agentBalBefore = usdc.balanceOf(agent);
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        vm.prank(agent);
        governor.settleProposal(proposalId);
        // Protocol fee: 1% of 10k = 100. Agent fee: 0% of 9900 = 0.
        // Mgmt fee: 0.5% of 9900 = 49.5.
        assertEq(usdc.balanceOf(agent), agentBalBefore);
        assertEq(usdc.balanceOf(owner), ownerBalBefore + 100e6 + 49_500000);
    }

    // ==================== COOLDOWN BLOCKS RE-EXECUTION ====================

    /// @dev Post G-M1: proposal 2 cannot be created while proposal 1 is still
    ///      Executed (openProposalCount != 0). After settling proposal 1, the
    ///      cooldown window opens on the vault. We pin the COOLDOWN path by
    ///      creating+approving proposal 2 purely via propose + votes + warp
    ///      past ONLY the voting window (not the cooldown), then showing
    ///      `executeProposal` reverts `CooldownNotElapsed`.
    function test_cooldown_blocksExecution() public {
        // Execute proposal 1 then settle it. `_lastSettledAt[vault]` = now.
        uint256 proposalId1 = _createAndExecuteProposal(1500, 7 days);
        vm.prank(agent);
        governor.settleProposal(proposalId1);
        uint256 settledAt = block.timestamp;

        // Stretch cooldown to make it safely exceed voting window for this test.
        vm.prank(owner);
        governor.setCooldownPeriod(5 days);

        // Propose 2 + drive to Approved. Uses `_createApprovedProposal` which
        // warps past voting period but NOT past the 5-day cooldown.
        uint256 proposalId2 = _createApprovedProposal(1500, 7 days);

        // Cooldown has not elapsed — execute must revert.
        assertGt(governor.getCooldownEnd(), block.timestamp, "still in cooldown");
        assertLt(block.timestamp, settledAt + 5 days, "pre-cooldown sanity");
        vm.expectRevert(ISyndicateGovernor.CooldownNotElapsed.selector);
        governor.executeProposal(proposalId2);
    }

    // ==================== DEPOSIT LOCK DURING ACTIVE PROPOSAL ====================

    function test_deposit_blockedDuringActiveProposal() public {
        _createAndExecuteProposal(1500, 7 days);

        usdc.mint(random, 10_000e6);
        vm.startPrank(random);
        usdc.approve(address(vault), 10_000e6);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(10_000e6, random);
        vm.stopPrank();
    }

    function test_deposit_succeedsAfterSettlement() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        usdc.mint(random, 10_000e6);
        vm.startPrank(random);
        usdc.approve(address(vault), 10_000e6);
        uint256 shares = vault.deposit(10_000e6, random);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    // ==================== RESCUE LOCK DURING ACTIVE PROPOSAL ====================

    function test_rescueERC20_blockedDuringActiveProposal() public {
        _createAndExecuteProposal(1500, 7 days);

        // Send some non-asset tokens to vault
        targetToken.mint(address(vault), 1_000e18);

        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.RedemptionsLocked.selector);
        vault.rescueERC20(address(targetToken), owner, 1_000e18);
    }

    function test_rescueERC20_succeedsAfterSettlement() public {
        uint256 proposalId = _createAndExecuteProposal(1500, 7 days);
        vm.prank(agent);
        governor.settleProposal(proposalId);

        targetToken.mint(address(vault), 1_000e18);

        vm.prank(owner);
        vault.rescueERC20(address(targetToken), owner, 1_000e18);
        assertEq(targetToken.balanceOf(owner), 1_000e18);
    }

    // ==================== PROTOCOL FEE RECIPIENT CHECK ====================

    /* test_setProtocolFeeBps_noRecipient_reverts — stubbed: setProtocolFeeBps moved to ProtocolConfig */
    function test_setProtocolFeeBps_noRecipient_reverts() public {}

    /* test_setProtocolFeeBps_zeroWithNoRecipient_succeeds — stubbed: setProtocolFeeBps moved to ProtocolConfig */
    function test_setProtocolFeeBps_zeroWithNoRecipient_succeeds() public {}

    // ==================== RESCUE ERC721 LOCK ====================

    // P1-1: setGuardianFeeRecipient + guardianFeeRecipient removed — fees
    //       always route to the bound `_guardianRegistry`, so the recipient
    //       is no longer a settable parameter.

    function test_rescueERC721_blockedDuringActiveProposal() public {
        _createAndExecuteProposal(1500, 7 days);

        // Mint an NFT to the vault
        uint256 tokenId = 999;
        vm.mockCall(
            address(targetToken),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(vault), owner, tokenId),
            ""
        );

        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.RedemptionsLocked.selector);
        vault.rescueERC721(address(targetToken), tokenId, owner);
    }

    // ==================== Lane B queue settle regression ====================

    /// @notice Regression for the async-queue settle gap: `_finishSettlement`
    ///         must call `vault.onProposalSettled(pid)` so the queue's frozen
    ///         price is stamped and queued redeems can claim. Pre-fix (no
    ///         production caller of onProposalSettled) the stamp never happened
    ///         and `queue.claim` reverted forever.
    function test_settle_stampsWithdrawalQueue_andClaimSucceeds() public {
        // Bind a real per-vault withdrawal queue (this test contract is the
        // vault's factory, so setWithdrawalQueue is authorized).
        VaultWithdrawalQueue queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        // Open + execute a proposal so redemptions are locked.
        uint256 pid = _createAndExecuteProposal(MAX_PERF_FEE_BPS, 7 days);
        assertTrue(vault.redemptionsLocked(), "locked after execute");

        // lp1 escrows a redeem into the queue while locked.
        uint256 shares = vault.balanceOf(lp1) / 2;
        assertGt(shares, 0, "lp1 has shares");
        vm.prank(lp1);
        uint256 reqId = vault.requestRedeem(shares, lp1);

        // Pre-settle: price not yet stamped, claim not possible.
        assertFalse(queue.getSettlePrice(pid).stamped, "pre-settle: unstamped");

        // Settle as proposer (governor calls vault.onProposalSettled(pid)).
        vm.prank(agent);
        governor.settleProposal(pid);

        // The fix: the governor stamped the frozen price for this pid.
        assertTrue(queue.getSettlePrice(pid).stamped, "settle stamped the queue price");

        // And the queued redeem now claims — burns escrowed shares, pays assets.
        uint256 balBefore = usdc.balanceOf(lp1);
        queue.claim(reqId);
        assertGt(usdc.balanceOf(lp1), balBefore, "lp1 received redeemed assets");
    }
}
