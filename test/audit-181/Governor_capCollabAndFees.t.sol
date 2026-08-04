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

/// @title Governor_capCollabAndFees — audit issue #181 findings #9 / #16 / #17
/// @notice Three independent regressions against `SyndicateGovernor`, each
///         failing on pre-fix `main` and passing after this branch's fix:
///
///           (a) FINDING #9 — `executeProposal` re-checks `maxCapital`
///               against the LIVE `totalAssets() * maxCapitalBps / 10_000`
///               ceiling immediately before dispatch. A proposer can no
///               longer shrink the vault's float between propose and
///               execute (e.g. an honest LP redeeming mid-vote) and still
///               execute a batch capped at the STALE, propose-time ceiling.
///
///           (b) FINDING #16 — `rejectCollaboration`'s Draft -> Cancelled
///               transition is gated by the SAME near-quorum guard as
///               `cancelProposal`'s Draft branch, so a lead cannot dodge
///               `CancelNotAllowedNearQuorum` by calling the other
///               entrypoint.
///
///           (c) FINDING #17 — `_distributeAgentFee` honours the split
///               recorded at propose time. Removing a co-proposer
///               (`onlyOwner`, no lifecycle gate) before settle forfeits
///               that co-proposer's earned share back to the vault instead
///               of folding it into the lead's remainder.
contract Governor_capCollabAndFeesTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public leadAgent = makeAddr("leadAgent");
    address public coAgent1 = makeAddr("coAgent1");
    address public coAgent2 = makeAddr("coAgent2");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    uint256 public leadNftId;
    uint256 public coNftId1;
    uint256 public coNftId2;

    /// @dev Widest legal risk envelope, computed once in setUp against the
    ///      initial 100_000e6 TVL (finding #9's ceiling: `maxCapital ==
    ///      totalAssets()` at propose time, exactly at the bps=100% ceiling).
    ISyndicateGovernor.RiskEnvelope internal permissiveEnv;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant MAX_STRATEGY_DURATION = 30 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();

        leadNftId = agentRegistry.mint(leadAgent);
        coNftId1 = agentRegistry.mint(coAgent1);
        coNftId2 = agentRegistry.mint(coAgent2);

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
                    // Zeroed so settlement in test (c) isolates the
                    // performance-fee agent split (no management-fee noise
                    // mixed into the lead/co-proposer ratio being asserted).
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
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

        vm.startPrank(owner);
        vault.registerAgent(leadNftId, leadAgent);
        vault.registerAgent(coNftId1, coAgent1);
        vault.registerAgent(coNftId2, coAgent2);
        vault.setAgentFeeBps(1500);
        vm.stopPrank();

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

    // ==================== (a) FINDING #9 ====================

    /// @notice A proposer whose declared `maxCapital` was legal against
    ///         `totalAssets()` AT PROPOSE reverts at `executeProposal` if an
    ///         honest LP redemption during the vote shrinks the live vault
    ///         below the ratio `maxCapital` was priced against — even though
    ///         nothing about the PROPOSAL itself changed. Pre-fix `main`
    ///         re-checks only `TierRegressed`/`CoverageRegressed` at execute
    ///         and lets this through; the fix adds the live ceiling
    ///         re-check and reverts `MaxCapitalCeilingRegressed`.
    function test_executeProposal_liveCeilingShrunkByRedemption_reverts() public {
        vm.prank(leadAgent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://cap-regress",
            7 days,
            permissiveEnv, // maxCapital == totalAssets() == 100_000e6 at propose
            _execCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _execCalls().length),
            _settleCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _settleCalls().length),
            _emptyCoProposers()
        );
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));

        // Nothing blocks this: `redemptionsLocked()` only rises once
        // `executeProposal` sets `_activeProposal`, which hasn't happened
        // yet. An honest LP redeeming mid-vote shrinks totalAssets() below
        // the value `maxCapital` was priced against at propose.
        vm.prank(lp1);
        vault.withdraw(5_000e6, lp1, lp1);

        assertEq(
            (vault.totalAssets() * governor.maxCapitalBps()) / 10_000,
            95_000e6,
            "sanity: live ceiling now below the proposal's pinned maxCapital"
        );

        vm.expectRevert(ISyndicateGovernor.MaxCapitalCeilingRegressed.selector);
        governor.executeProposal(pid);

        // The proposal must not have partially advanced — state stays
        // Approved so a later, legally-sized batch can still execute (or
        // the proposal can be cancelled), not stuck half-transitioned.
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    /// @notice Negative control: with no redemption in between, the SAME
    ///         permissive (`maxCapital == totalAssets()`) proposal still
    ///         executes — the new live re-check does not turn into a
    ///         universal regression for the honest, unchanged-TVL path.
    function test_executeProposal_liveCeilingUnchanged_stillSucceeds() public {
        vm.prank(leadAgent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://cap-ok",
            7 days,
            permissiveEnv,
            _execCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _execCalls().length),
            _settleCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _settleCalls().length),
            _emptyCoProposers()
        );
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);

        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    // ==================== (b) FINDING #16 ====================

    /// @dev Draft with 2 co-proposers (lead + coAgent1 30% + coAgent2 10%),
    ///      only ONE of the two approves — "all but one" (1 of 2) is met,
    ///      so both abort entrypoints must refuse.
    function _draftNearQuorum() internal returns (uint256 pid) {
        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](2);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: coAgent1, splitBps: 3000});
        coProps[1] = ISyndicateGovernor.CoProposer({agent: coAgent2, splitBps: 1000});

        vm.prank(leadAgent);
        pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://near-quorum",
            7 days,
            permissiveEnv,
            _execCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _execCalls().length),
            _settleCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _settleCalls().length),
            coProps
        );
        vm.prank(coAgent1);
        governor.approveCollaboration(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Draft));
    }

    /// @notice `cancelProposal`'s existing Draft-branch guard: confirms the
    ///         near-quorum fixture actually trips it, so the sibling test
    ///         below is comparing against a guard that is live, not vacuous.
    function test_cancelProposal_draftNearQuorum_reverts() public {
        uint256 pid = _draftNearQuorum();
        vm.prank(leadAgent);
        vm.expectRevert(ISyndicateGovernor.CancelNotAllowedNearQuorum.selector);
        governor.cancelProposal(pid);
    }

    /// @notice THE FIX: `rejectCollaboration` must refuse in the identical
    ///         situation `cancelProposal` refuses in — same actor
    ///         (`proposal.proposer`), same Draft -> Cancelled transition.
    ///         Pre-fix `main` has no near-quorum guard on this entrypoint at
    ///         all, so the lead cancels for free here even though
    ///         `cancelProposal` would have refused, letting it dodge the
    ///         guard and burn co-proposers' approve gas at will.
    function test_rejectCollaboration_draftNearQuorum_reverts() public {
        uint256 pid = _draftNearQuorum();
        vm.prank(leadAgent);
        vm.expectRevert(ISyndicateGovernor.CancelNotAllowedNearQuorum.selector);
        governor.rejectCollaboration(pid);

        // Still Draft — the reject must not have gone through.
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Draft));
    }

    // ==================== (c) FINDING #17 ====================

    /// @notice Removing a co-proposer (owner action, no lifecycle gate)
    ///         AFTER a collaborative proposal executes but BEFORE it settles
    ///         must not enlarge the lead's payout beyond its own
    ///         propose-time split. Lead 60% / coAgent1 30% / coAgent2 10%:
    ///         with coAgent2 removed pre-settle, the lead must still receive
    ///         only ~60% of the agent fee pot (lead:coAgent1 ratio ~2:1),
    ///         NOT ~70% (folding coAgent2's forfeited 10% into the lead's
    ///         remainder, ratio ~2.33:1 — the pre-fix behavior). coAgent2
    ///         itself must not be paid either.
    function test_removeCoProposer_beforeSettle_doesNotInflateLeadShare() public {
        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](2);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: coAgent1, splitBps: 3000});
        coProps[1] = ISyndicateGovernor.CoProposer({agent: coAgent2, splitBps: 1000});

        vm.prank(leadAgent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://strip-coprop",
            7 days,
            permissiveEnv,
            _execCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _execCalls().length),
            _settleCalls(),
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, _settleCalls().length),
            coProps
        );
        vm.prank(coAgent1);
        governor.approveCollaboration(pid);
        vm.prank(coAgent2);
        governor.approveCollaboration(pid);
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);

        governor.executeProposal(pid);

        // The owner strips coAgent2 AFTER execute, BEFORE settle — exactly
        // the window the finding identifies. `removeAgent` is `onlyOwner`
        // with no lifecycle gate.
        vm.prank(owner);
        vault.removeAgent(coAgent2);

        // Profit so the performance fee (the agent pot under test — mgmt
        // fee is zeroed in setUp) is non-zero.
        usdc.mint(address(vault), 10_000e6);

        uint256 leadBefore = usdc.balanceOf(leadAgent);
        uint256 co1Before = usdc.balanceOf(coAgent1);
        uint256 co2Before = usdc.balanceOf(coAgent2);

        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE
        vm.prank(leadAgent);
        governor.settleProposal(pid);

        uint256 lead = usdc.balanceOf(leadAgent) - leadBefore;
        uint256 co1 = usdc.balanceOf(coAgent1) - co1Before;

        assertGt(lead, 0, "lead was paid");
        assertGt(co1, 0, "the still-active co-proposer was paid");
        assertEq(usdc.balanceOf(coAgent2), co2Before, "the removed co-proposer is not paid");

        // THE FIX: lead keeps exactly its own 60% split (lead:co1 == 2:1),
        // not 60%+10% folded together (which would read ~2.33:1). Tight
        // tolerance — the only slack is BPS floor-division dust on amounts
        // in the thousands-of-USDC range.
        assertApproxEqRel(lead, co1 * 2, 5e15, "lead's payout is its own split, not co1's plus the forfeited 10%");
    }
}
