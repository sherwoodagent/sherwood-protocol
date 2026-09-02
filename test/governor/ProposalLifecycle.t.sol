// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockLedgerFullLocks} from "../mocks/MockLedgerFullLocks.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title ProposalLifecycle.t
/// @notice Tests the `ProposalLifecycle` seam through the governor's PUBLIC
///         surface only — `propose` / `vote` / `resolveProposalState` drive the
///         machine, `stateOf` reads it. No `vm.store` / `stdstore` fabrication:
///         every state under assertion was reached by a real transition.
///
///         The property under test is that `stateOf` is a TRUE view — it reports
///         Approved / Rejected / Expired the instant those are determinable,
///         with no "poke" transaction required first — and that the committing
///         path (`_commitState`) agrees with it, firing the registry's economic
///         commit on exactly the transitions where the guardian review actually
///         concluded (and never on a veto-rejection or a Draft expiry).
contract ProposalLifecycleTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GuardianRegistry public registry;
    StakedWood public swood;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public coAgent = makeAddr("coAgent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    // Five guardians × 20k = 100k cohort, comfortably above the registry's
    // 50k MIN_COHORT_STAKE_AT_OPEN floor so the review path actually runs.
    address public g1 = makeAddr("guardian1");
    address public g2 = makeAddr("guardian2");
    address public g3 = makeAddr("guardian3");
    address public g4 = makeAddr("guardian4");
    address public g5 = makeAddr("guardian5");

    address public factoryEoa; // test contract impersonates the factory

    uint256 public agentNftId;
    uint256 public coAgentNftId;

    /// @dev Repo convention: `GovEnvelope.permissive` performs an external
    ///      `totalAssets()` staticcall, so it must be HOISTED here in setUp and
    ///      never invoked inline at a `vm.prank` / `vm.expectRevert` site where
    ///      it would consume the armed cheatcode.
    ISyndicateGovernor.RiskEnvelope internal _env;

    // Governor params
    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant COLLABORATION_WINDOW = 48 hours;

    // Registry / sWOOD params
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%
    uint256 constant GUARDIAN_STAKE = 20_000e18;

    /// @dev Deterministic slash severity for the 60%-block scenario in
    ///      `test_stateOf_trueViewRejectedThenCommitAgrees`:
    ///        bBps = 60_000/100_000 = 6000; q = 3000; lo = 1000; hi = 9999
    ///        t = 3000e18/3667 ~ 0.818107e18 -> t^2 ~ 0.669299e18
    ///        severity = 1000 + floor(8999 * 0.669299) = 7023 bps
    uint256 constant EXPECTED_SEVERITY_BPS = 7023;

    bytes32 constant GUARDIAN_REVIEW_RESOLVED_SIG = keccak256("GuardianReviewResolved(uint256,bool)");

    function setUp() public {
        factoryEoa = address(this);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        agentNftId = agentRegistry.mint(agent);
        coAgentNftId = agentRegistry.mint(coAgent);

        // Vault
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
        vm.prank(owner);
        vault.registerAgent(coAgentNftId, coAgent);

        // sWOOD + Governor + Registry — three-way circular init dependency
        // resolved by predicting proxy addresses. From `baseNonce`:
        //   swoodImpl (+0), swoodProxy (+1), govImpl (+2), govProxy (+3),
        //   regImpl (+4), regProxy (+5).
        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        // Hoisted ABOVE the nonce snapshot: the governor's mandatory tier-registry
        // argument (pashov finding #1) is a DEPLOYMENT, so leaving it inline in the
        // `initialize` tuple would consume a nonce and slide every predicted address.
        address fixtureTierRegistry = address(deployTierRegistry(address(this)));
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 3);
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factoryEoa,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: 7 days,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                predictedRegistryProxy,
                address(_hoistedPC),
                address(this),
                fixtureTierRegistry, // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: COLLABORATION_WINDOW,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        // Per-vault governor: the vault resolves its governor via its factory
        // (this test contract). Mock governorOf(vault) -> the deployed governor.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        // The second arg is LOAD-BEARING: the emergency slash path resolves the
        // owner-bond target from `vaultOf[governor]`, so it must be the REAL
        // vault, never the test contract.
        vm.prank(registry.factory());
        registry.addGovernor(address(governor), address(vault));
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");
        require(registry.vaultOf(address(governor)) == address(vault), "vaultOf must be the real vault");

        // Resolve the registry <-> sWOOD circular dependency.
        vm.prank(owner);
        swood.setRegistry(address(registry));

        // Declared coverage locks: a review-path slash burns each approver's
        // LOCK, so an unwired ledger has nothing to burn and a blocked review
        // slashes nobody. Wire a ledger under which every approver locked its
        // whole stake (rate 10_000) — the pre-lock slash shape the severity
        // arithmetic below (`EXPECTED_SEVERITY_BPS` of the whole stake) pins.
        MockLedgerFullLocks fullLockLedger = new MockLedgerFullLocks();
        fullLockLedger.setGuardianRegistry(address(registry));
        vm.prank(owner);
        registry.setExposureLedger(address(fullLockLedger));

        // LPs deposit, then the block advances once — every proposal's
        // `snapshotTimestamp` (propose ts - 1) then sees the full supply.
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

        // Owner prepares + binds stake — staking lives in sWOOD post-split.
        wood.mint(owner, 100_000e18);
        vm.prank(owner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(owner);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.prank(factoryEoa);
        swood.bindOwnerStake(owner, address(vault));

        _stakeGuardian(g1, GUARDIAN_STAKE, 1);
        _stakeGuardian(g2, GUARDIAN_STAKE, 2);
        _stakeGuardian(g3, GUARDIAN_STAKE, 3);
        _stakeGuardian(g4, GUARDIAN_STAKE, 4);
        _stakeGuardian(g5, GUARDIAN_STAKE, 5);

        // Age-weighted voting: mature the cohort to par so the block-quorum
        // math below runs on full stake weight.
        skip(30 days);

        // Hoisted once, after the deposits that fix `totalAssets()`.
        _env = GovEnvelope.permissive(address(vault));
    }

    // ──────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────

    function _stakeGuardian(address who, uint256 amount, uint256 agentId) private {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(who);
        swood.stakeAsGuardian(amount, agentId);
    }

    function _emptyCoProposers() private pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _execCalls() private view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
    }

    function _settleCalls() private view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
    }

    /// @dev Non-collaborative propose — lands straight in Pending.
    function _propose() private returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://proposal-lifecycle",
            7 days,
            _env,
            _execCalls(),
            GovEnvelope.defaultCaps((_env).maxCapital, (_execCalls()).length),
            _settleCalls(),
            GovEnvelope.defaultCaps((_env).maxCapital, (_settleCalls()).length),
            _emptyCoProposers()
        );
    }

    /// @dev Collaborative propose — lands in Draft with a single co-proposer, so
    ///      one `approveCollaboration` completes the Draft -> Pending transition.
    function _proposeCollaborative() private returns (uint256 proposalId) {
        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](1);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: coAgent, splitBps: 3000});
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://proposal-lifecycle-collab",
            7 days,
            _env,
            _execCalls(),
            GovEnvelope.defaultCaps((_env).maxCapital, (_execCalls()).length),
            _settleCalls(),
            GovEnvelope.defaultCaps((_env).maxCapital, (_settleCalls()).length),
            coProps
        );
    }

    function _voteFor(uint256 pid) private {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
    }

    /// @dev lp1 holds 60% of supply — past the 40% veto threshold on its own.
    function _voteAgainst(uint256 pid) private {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
    }

    function _warpPast(uint256 timestamp) private {
        vm.warp(timestamp + 1);
    }

    function _proposal(uint256 pid) private view returns (ISyndicateGovernor.StrategyProposal memory) {
        return governor.getProposal(pid);
    }

    function _state(uint256 pid) private view returns (ISyndicateGovernor.ProposalState) {
        return governor.stateOf(pid);
    }

    function _assertState(uint256 pid, ISyndicateGovernor.ProposalState expected, string memory reason) private view {
        assertEq(uint256(_state(pid)), uint256(expected), reason);
    }

    /// @dev Opens the guardian review and casts `Block` votes from g3/g4/g5
    ///      (60k of a 100k cohort = 60% >= the 30% quorum) with g1/g2 approving,
    ///      so the review's determinable outcome is Blocked and g1/g2 are the
    ///      slashable approver set.
    function _reviewWithBlockQuorum(uint256 pid) private {
        registry.openReview(address(governor), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        vm.prank(g2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        vm.prank(g3);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max);
        vm.prank(g4);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max);
        vm.prank(g5);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max);
    }

    function _assertNoGuardianSlashing(string memory reason) private view {
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE, string.concat("g1 stake must be untouched: ", reason));
        assertEq(swood.guardianStake(g2), GUARDIAN_STAKE, string.concat("g2 stake must be untouched: ", reason));
        assertEq(swood.guardianStake(g3), GUARDIAN_STAKE, string.concat("g3 stake must be untouched: ", reason));
        assertEq(swood.guardianStake(g4), GUARDIAN_STAKE, string.concat("g4 stake must be untouched: ", reason));
        assertEq(swood.guardianStake(g5), GUARDIAN_STAKE, string.concat("g5 stake must be untouched: ", reason));
    }

    /// @dev Counts governor-emitted `GuardianReviewResolved(pid, ...)` logs and
    ///      returns the last decoded `blocked` payload.
    function _scanReviewResolved(Vm.Log[] memory logs, uint256 pid) private view returns (uint256 count, bool blocked) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(governor)) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != GUARDIAN_REVIEW_RESOLVED_SIG) continue;
            if (uint256(logs[i].topics[1]) != pid) continue;
            count++;
            blocked = abi.decode(logs[i].data, (bool));
        }
    }

    // ──────────────────────────────────────────────────────────────
    // 1. Pending during the voting window
    // ──────────────────────────────────────────────────────────────

    /// @notice Between propose and `voteEnd`, `stateOf` is Pending — the machine
    ///         does not resolve anything early.
    function test_stateOf_pendingDuringVote() public {
        uint256 pid = _propose();

        _assertState(pid, ISyndicateGovernor.ProposalState.Pending, "fresh proposal must be Pending");
        assertEq(governor.openProposalCount(), 1, "Pending proposal binds the vault");

        // Mid-window, and at exactly voteEnd: still Pending.
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD / 2);
        _assertState(pid, ISyndicateGovernor.ProposalState.Pending, "mid-vote must still be Pending");

        vm.warp(_proposal(pid).voteEnd);
        _assertState(pid, ISyndicateGovernor.ProposalState.Pending, "at exactly voteEnd the window is still open (<=)");
    }

    // ──────────────────────────────────────────────────────────────
    // 2. Veto rejection never fires the economic commit
    // ──────────────────────────────────────────────────────────────

    /// @notice The veto-never-slashes invariant. A proposal rejected at
    ///         `voteEnd` by AGAINST weight never traversed guardian review, so
    ///         committing it must NOT call `resolveReview`, must NOT slash any
    ///         guardian, and must NOT emit `GuardianReviewResolved`.
    function test_stateOf_vetoRejectsWithoutEconomicCommit() public {
        uint256 pid = _propose();
        _voteAgainst(pid);

        // Sanity: the AGAINST weight really is past the snapshot veto bar.
        ISyndicateGovernor.StrategyProposal memory p = _proposal(pid);
        uint256 vetoBar = (vault.getPastTotalSupply(p.snapshotTimestamp) * p.vetoThresholdBps) / 10_000;
        assertGe(p.votesAgainst, vetoBar, "AGAINST weight must clear the snapshot veto threshold");

        _warpPast(p.voteEnd);

        // TRUE view: Rejected the instant it is determinable, with no poke.
        _assertState(pid, ISyndicateGovernor.ProposalState.Rejected, "veto must read Rejected without a poke");

        // Now commit it and prove the economic path stayed closed.
        vm.recordLogs();
        governor.resolveProposalState(pid);
        (uint256 emitted,) = _scanReviewResolved(vm.getRecordedLogs(), pid);

        assertEq(emitted, 0, "veto-rejection must NOT emit GuardianReviewResolved");
        _assertNoGuardianSlashing("veto never traversed guardian review");

        // The review is CLOSED, not adjudicated. `assertFalse(resolved)` used to
        // stand in for "resolveReview was never called", which held only while
        // `resolveReview` was the sole writer of `resolved`. The terminal edge
        // now also closes the review via `cancelReview` so it cannot be opened
        // and slashed later, and that writes `resolved = true, blocked = false`
        // without touching a bond. The property under test is unchanged and is
        // asserted directly above and below: no `GuardianReviewResolved`, no
        // slash. What must never happen is the review resolving as BLOCKED.
        (, bool reviewResolved, bool reviewBlocked) = registry.getReviewState(address(governor), pid);
        assertTrue(reviewResolved, "a veto-rejected proposal's review must be closed, not left open to a keeper");
        assertFalse(reviewBlocked, "closing must never adjudicate the review as blocked");

        // The commit still released the vault binding.
        _assertState(pid, ISyndicateGovernor.ProposalState.Rejected, "state stays Rejected after commit");
        assertEq(governor.openProposalCount(), 0, "terminal veto releases the vault binding");
    }

    // ──────────────────────────────────────────────────────────────
    // 3. True-view Approved (pre-refactor this read GuardianReview)
    // ──────────────────────────────────────────────────────────────

    /// @notice Vote passes, guardians review without reaching block quorum, the
    ///         window elapses: `stateOf` reads Approved IMMEDIATELY. Pre-refactor
    ///         this lagged at GuardianReview until a mutating call resolved it.
    function test_stateOf_trueViewApprovedAfterReviewEnd() public {
        uint256 pid = _propose();
        _voteFor(pid);

        ISyndicateGovernor.StrategyProposal memory p = _proposal(pid);
        _warpPast(p.voteEnd);
        _assertState(
            pid, ISyndicateGovernor.ProposalState.GuardianReview, "inside the review window state is GuardianReview"
        );

        // Guardians review; nobody blocks.
        registry.openReview(address(governor), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        vm.prank(g2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);

        _warpPast(p.reviewEnd);

        // No mutating call has run: the registry review is still uncommitted...
        (, bool reviewResolved,) = registry.getReviewState(address(governor), pid);
        assertFalse(reviewResolved, "precondition: registry review must still be uncommitted");
        assertEq(
            uint256(registry.outcomeOf(address(governor), pid)),
            uint256(IGuardianRegistry.ReviewOutcome.Cleared),
            "outcome is determinable as Cleared past reviewEnd"
        );

        // ...yet the view already reports the determinable truth.
        _assertState(
            pid,
            ISyndicateGovernor.ProposalState.Approved,
            "stateOf must read Approved immediately past reviewEnd, with no poke tx"
        );
        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Approved),
            "getProposal must report the same resolved state as stateOf"
        );

        // And the commit agrees with the view.
        governor.resolveProposalState(pid);
        _assertState(pid, ISyndicateGovernor.ProposalState.Approved, "commit agrees with the view");
        _assertNoGuardianSlashing("cleared review slashes nobody");
    }

    // ──────────────────────────────────────────────────────────────
    // 4. True-view Rejected, then the commit agrees end-to-end
    // ──────────────────────────────────────────────────────────────

    /// @notice Guardians reach block quorum: `stateOf` reads Rejected with no
    ///         poke, and the subsequent commit fires the economic path exactly
    ///         once — `GuardianReviewResolved(pid, true)` plus a single slash of
    ///         the approver set — leaving the view unchanged.
    function test_stateOf_trueViewRejectedThenCommitAgrees() public {
        uint256 pid = _propose();
        _voteFor(pid);

        ISyndicateGovernor.StrategyProposal memory p = _proposal(pid);
        _warpPast(p.voteEnd);
        _reviewWithBlockQuorum(pid);
        _warpPast(p.reviewEnd);

        // Nothing has committed yet — no slashing, no registry resolution.
        (, bool reviewResolved,) = registry.getReviewState(address(governor), pid);
        assertFalse(reviewResolved, "precondition: registry review must still be uncommitted");
        _assertNoGuardianSlashing("no commit has run yet");

        // TRUE view: Rejected before any mutating call.
        _assertState(
            pid, ISyndicateGovernor.ProposalState.Rejected, "stateOf must read Rejected past reviewEnd, with no poke tx"
        );

        // Commit: fires resolveReview exactly once.
        vm.recordLogs();
        governor.resolveProposalState(pid);
        (uint256 emitted, bool blocked) = _scanReviewResolved(vm.getRecordedLogs(), pid);
        assertEq(emitted, 1, "commit must emit GuardianReviewResolved exactly once");
        assertTrue(blocked, "GuardianReviewResolved must report blocked = true");

        uint256 residue = GUARDIAN_STAKE - (GUARDIAN_STAKE * EXPECTED_SEVERITY_BPS) / 10_000;
        assertEq(swood.guardianStake(g1), residue, "approver g1 slashed once at the deterministic severity");
        assertEq(swood.guardianStake(g2), residue, "approver g2 slashed once at the deterministic severity");
        assertEq(swood.guardianStake(g3), GUARDIAN_STAKE, "blocker g3 untouched");
        assertEq(swood.guardianStake(g4), GUARDIAN_STAKE, "blocker g4 untouched");
        assertEq(swood.guardianStake(g5), GUARDIAN_STAKE, "blocker g5 untouched");

        // View and commit agree end-to-end, and re-committing is inert: no
        // second slash, no second event.
        _assertState(pid, ISyndicateGovernor.ProposalState.Rejected, "state stays Rejected after the commit");
        assertEq(governor.openProposalCount(), 0, "terminal rejection releases the vault binding");

        vm.recordLogs();
        governor.resolveProposalState(pid);
        (uint256 emittedAgain,) = _scanReviewResolved(vm.getRecordedLogs(), pid);
        assertEq(emittedAgain, 0, "re-commit must be a no-op - no second GuardianReviewResolved");
        assertEq(swood.guardianStake(g1), residue, "approver g1 must not be slashed twice");
        assertEq(swood.guardianStake(g2), residue, "approver g2 must not be slashed twice");
        _assertState(pid, ISyndicateGovernor.ProposalState.Rejected, "state still Rejected after the re-commit");
    }

    // ──────────────────────────────────────────────────────────────
    // 5. Expiry of an Approved proposal releases the vault
    // ──────────────────────────────────────────────────────────────

    /// @notice An Approved proposal that blows past `executeBy` reads Expired,
    ///         and committing that lazy transition releases the open-proposal
    ///         count so a fresh `propose()` succeeds.
    function test_stateOf_expiryReleasesVault() public {
        uint256 pid = _propose();
        _voteFor(pid);

        ISyndicateGovernor.StrategyProposal memory p = _proposal(pid);
        _warpPast(p.reviewEnd);

        // Commit the Approved state first, so the Expired edge below is a
        // genuine Approved -> Expired transition (which must NOT re-run the
        // economic commit — the review concluded on this call).
        governor.resolveProposalState(pid);
        _assertState(pid, ISyndicateGovernor.ProposalState.Approved, "proposal is Approved before executeBy");
        assertEq(governor.openProposalCount(), 1, "an Approved proposal still binds the vault");

        _warpPast(p.executeBy);

        // TRUE view: Expired with no poke, but the binding is still held.
        _assertState(pid, ISyndicateGovernor.ProposalState.Expired, "past executeBy must read Expired with no poke");
        assertEq(governor.openProposalCount(), 1, "the counter has not been flushed yet");

        // Negative control: the stale binding really does block a new proposal.
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.VaultHasOpenProposal.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://blocked-by-stale-binding",
            7 days,
            _env,
            _execCalls(),
            GovEnvelope.defaultCaps((_env).maxCapital, (_execCalls()).length),
            _settleCalls(),
            GovEnvelope.defaultCaps((_env).maxCapital, (_settleCalls()).length),
            _emptyCoProposers()
        );

        // Flush the lazy terminal transition. The Approved -> Expired edge must
        // NOT re-fire the economic commit.
        vm.recordLogs();
        governor.resolveProposalState(pid);
        (uint256 emitted,) = _scanReviewResolved(vm.getRecordedLogs(), pid);
        assertEq(emitted, 0, "Approved -> Expired must NOT re-run the review economic commit");
        assertEq(governor.openProposalCount(), 0, "expiry releases the vault binding");

        // The vault is free again.
        uint256 pid2 = _propose();
        assertGt(pid2, pid, "a fresh proposal id was minted");
        _assertState(pid2, ISyndicateGovernor.ProposalState.Pending, "the new proposal opens in Pending");
        assertEq(governor.openProposalCount(), 1, "the new proposal binds the vault");
    }

    // ──────────────────────────────────────────────────────────────
    // 6. Draft expiry
    // ──────────────────────────────────────────────────────────────

    /// @notice A collaborative Draft whose collaboration window lapses reads
    ///         Expired; committing it decrements the open count and emits
    ///         `CollaborationDeadlineExpired` — with no economic commit, since a
    ///         Draft never traversed guardian review.
    function test_stateOf_draftExpiry() public {
        uint256 pid = _proposeCollaborative();

        _assertState(pid, ISyndicateGovernor.ProposalState.Draft, "collaborative propose opens in Draft");
        assertEq(governor.openProposalCount(), 1, "Sherlock #8: a Draft binds the vault too");

        uint256 deadline = governor.collaborationDeadline(pid);
        assertEq(deadline, vm.getBlockTimestamp() + COLLABORATION_WINDOW, "deadline is propose + collaborationWindow");

        vm.warp(deadline);
        _assertState(pid, ISyndicateGovernor.ProposalState.Draft, "at exactly the deadline the Draft is still live");

        _warpPast(deadline);
        _assertState(pid, ISyndicateGovernor.ProposalState.Expired, "past the deadline the Draft reads Expired");
        assertEq(governor.openProposalCount(), 1, "the counter has not been flushed yet");

        vm.recordLogs();
        vm.expectEmit(true, false, false, false, address(governor));
        emit ISyndicateGovernor.CollaborationDeadlineExpired(pid);
        governor.resolveProposalState(pid);
        (uint256 emitted,) = _scanReviewResolved(vm.getRecordedLogs(), pid);

        assertEq(emitted, 0, "a Draft expiry must NOT run the review economic commit");
        assertEq(governor.openProposalCount(), 0, "Draft expiry releases the vault binding");
        _assertState(pid, ISyndicateGovernor.ProposalState.Expired, "state stays Expired after the commit");
        _assertNoGuardianSlashing("a Draft never traversed guardian review");
    }

    // ──────────────────────────────────────────────────────────────
    // 7. Review-window registration is pushed at the Pending transition
    // ──────────────────────────────────────────────────────────────

    /// @notice ZOMBIE REVIEWS. `registerReview` fires at the Draft -> Pending
    ///         transition, so EVERY terminal path out of Pending leaves a live,
    ///         open-able review behind unless it closes one. Only the
    ///         GuardianReview branch of `cancelProposal` did.
    ///
    ///         Left open, a dead proposal's review can still be opened at
    ///         `voteEnd`, voted on, and resolved — slashing guardians for
    ///         endorsing something that can never execute — and each approve
    ///         also books coverage that pins the approver's budget and blocks
    ///         `claimUnstakeGuardian` until the bucket expires.
    function test_cancelDuringPending_closesTheRegistryReview() public {
        uint256 pid = _propose();
        (uint64 ve,) = registry.reviewWindow(address(governor), pid);
        assertGt(uint256(ve), 0, "a Pending proposal has a registered review");

        vm.prank(agent);
        governor.cancelProposal(pid);

        (, bool resolved,) = registry.getReviewState(address(governor), pid);
        assertTrue(resolved, "cancelling out of Pending must close the review");

        // The proof that matters: it can never be opened afterwards.
        _warpPast(uint256(ve));
        registry.openReview(address(governor), pid); // idempotent no-op
        (bool opened,,) = registry.getReviewState(address(governor), pid);
        assertFalse(opened, "a cancelled proposal's review must never open");
    }

    /// @notice Same hazard on the owner's veto path.
    function test_vetoProposal_closesTheRegistryReview() public {
        uint256 pid = _propose();
        (uint64 ve,) = registry.reviewWindow(address(governor), pid);

        vm.prank(owner);
        governor.vetoProposal(pid);

        (, bool resolved,) = registry.getReviewState(address(governor), pid);
        assertTrue(resolved, "vetoing out of Pending must close the review");

        _warpPast(uint256(ve));
        registry.openReview(address(governor), pid);
        (bool opened,,) = registry.getReviewState(address(governor), pid);
        assertFalse(opened, "a vetoed proposal's review must never open");
    }

    /// @notice And on the LP veto-rejection edge, which `_computeState` resolves
    ///         passively with `reviewConcluded == false` — so nothing on the
    ///         registry side was ever told the proposal died.
    function test_lpVetoRejection_closesTheRegistryReview() public {
        uint256 pid = _propose();
        _voteAgainst(pid);
        ISyndicateGovernor.StrategyProposal memory p = _proposal(pid);
        _warpPast(p.voteEnd);

        governor.resolveProposalState(pid);
        _assertState(pid, ISyndicateGovernor.ProposalState.Rejected, "AGAINST weight rejects at voteEnd");

        (, bool resolved,) = registry.getReviewState(address(governor), pid);
        assertTrue(resolved, "a veto-rejected proposal must not leave an open review");

        registry.openReview(address(governor), pid);
        (bool opened,,) = registry.getReviewState(address(governor), pid);
        assertFalse(opened, "a veto-rejected proposal's review must never open");

        // The economic path stays closed exactly as before -- closing the review
        // must not become a slash.
        _assertNoGuardianSlashing("veto never traversed guardian review");
    }

    /// @notice The governor pushes `(voteEnd, reviewEnd)` to the registry at the
    ///         transition INTO Pending: at propose time for a plain proposal, and
    ///         only at the final `approveCollaboration` for a collaborative one
    ///         (whose window does not exist while it is a Draft).
    function test_registerReview_pushedAtPendingTransition() public {
        // ── Non-collaborative: registered at propose ──
        uint256 pid = _propose();
        ISyndicateGovernor.StrategyProposal memory p = _proposal(pid);

        (uint64 regVoteEnd, uint64 regReviewEnd) = registry.reviewWindow(address(governor), pid);
        assertEq(uint256(regVoteEnd), p.voteEnd, "registered voteEnd must equal the proposal's voteEnd");
        assertEq(uint256(regReviewEnd), p.reviewEnd, "registered reviewEnd must equal the proposal's reviewEnd");
        assertEq(p.reviewEnd, p.voteEnd + REVIEW_PERIOD, "reviewEnd is voteEnd + the registry review period");

        // Release the vault binding so the collaborative leg can propose.
        vm.prank(agent);
        governor.cancelProposal(pid);
        assertEq(governor.openProposalCount(), 0, "cancel releases the binding");

        // ── Collaborative: NOT registered while Draft ──
        uint256 cpid = _proposeCollaborative();
        _assertState(cpid, ISyndicateGovernor.ProposalState.Draft, "collaborative propose opens in Draft");

        (uint64 draftVoteEnd, uint64 draftReviewEnd) = registry.reviewWindow(address(governor), cpid);
        assertEq(uint256(draftVoteEnd), 0, "a Draft must not have a registered voteEnd yet");
        assertEq(uint256(draftReviewEnd), 0, "a Draft must not have a registered reviewEnd yet");
        assertEq(_proposal(cpid).voteEnd, 0, "a Draft has no voting window yet");

        // ── Registered at the Draft -> Pending transition ──
        vm.prank(coAgent);
        governor.approveCollaboration(cpid);
        _assertState(cpid, ISyndicateGovernor.ProposalState.Pending, "final approval moves the Draft to Pending");

        ISyndicateGovernor.StrategyProposal memory cp = _proposal(cpid);
        (uint64 cRegVoteEnd, uint64 cRegReviewEnd) = registry.reviewWindow(address(governor), cpid);
        assertEq(uint256(cRegVoteEnd), cp.voteEnd, "collaborative voteEnd registered at Draft -> Pending");
        assertEq(uint256(cRegReviewEnd), cp.reviewEnd, "collaborative reviewEnd registered at Draft -> Pending");
        assertEq(cp.voteEnd, vm.getBlockTimestamp() + VOTING_PERIOD, "voting opens at the transition, not at propose");
        assertEq(cp.reviewEnd, cp.voteEnd + REVIEW_PERIOD, "reviewEnd is voteEnd + the registry review period");
    }

    // ── A paused registry never makes the view lie ──
    //
    // `resolveReview` is `whenNotPaused`; `outcomeOf` is not. Reporting Approved
    // while the registry is paused hands callers a state that every path to act
    // on reverts against, with an opaque `ProtocolPaused` from a contract they
    // never called — and if the pause outlives `executeBy`, silently converts
    // that Approved into Expired. The governor holds the proposal at
    // GuardianReview for the duration instead, and resumes on unpause.
    function test_pausedRegistry_holdsGuardianReviewThenResolvesOnUnpause() public {
        uint256 pid = _propose();
        _voteFor(pid);
        _warpPast(_proposal(pid).voteEnd);

        registry.openReview(address(governor), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        _warpPast(_proposal(pid).reviewEnd);

        // Determinable as Cleared — but the registry cannot take the commit.
        _assertState(pid, ISyndicateGovernor.ProposalState.Approved, "resolvable while the registry is live");

        vm.prank(owner);
        registry.pause();

        _assertState(
            pid,
            ISyndicateGovernor.ProposalState.GuardianReview,
            "a paused registry must not report an Approved nobody can act on"
        );

        vm.prank(owner);
        registry.unpause();

        _assertState(pid, ISyndicateGovernor.ProposalState.Approved, "unpause resumes the normal outcome");

        governor.resolveProposalState(pid);
        _assertState(pid, ISyndicateGovernor.ProposalState.Approved, "commit agrees with the view after unpause");
        (, bool resolved,) = registry.getReviewState(address(governor), pid);
        assertTrue(resolved, "the economic commit lands once the registry is live again");
    }

    /// @dev The already-committed case must NOT be held back: when the registry
    ///      cached the resolution out-of-band before the pause, `_commitState`
    ///      skips `resolveReview` entirely, so a pause cannot strand it.
    function test_pausedRegistry_doesNotHoldAnAlreadyResolvedReview() public {
        uint256 pid = _propose();
        _voteFor(pid);
        _warpPast(_proposal(pid).voteEnd);

        registry.openReview(address(governor), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        _warpPast(_proposal(pid).reviewEnd);

        // Resolve out-of-band, THEN pause.
        registry.resolveReview(address(governor), pid);
        vm.prank(owner);
        registry.pause();

        _assertState(
            pid,
            ISyndicateGovernor.ProposalState.Approved,
            "an already-cached resolution needs no commit, so the pause is irrelevant"
        );
        governor.resolveProposalState(pid);
        _assertState(pid, ISyndicateGovernor.ProposalState.Approved, "commit succeeds through the pause");
    }

    // ── governor/registry disagreement fails CLOSED ──

    /// @dev Pins the security posture of the Unresolved branch in `_afterVote`.
    ///      The state is "governor believes a review window exists, registry
    ///      holds no record for it" — unreachable on a lockstep deployment, so
    ///      it is forced here by zeroing the registry's 4-slot `Review` for this
    ///      `(governor, proposalId)` (`_reviews` is slot 0). That disagreement
    ///      must NOT yield an executable proposal: answering Cleared would
    ///      approve a strategy no guardian ever reviewed. It must also stay
    ///      TERMINAL — holding at GuardianReview was the original strand this
    ///      fold fixed, pinning `_openProposalCount` and the vault with it.
    ///      Restore `Approved` on that branch and this test fails.
    function test_unregisteredWindowExpiresAndCannotExecute() public {
        uint256 pid = _propose();
        _voteFor(pid);

        bytes32 key = keccak256(abi.encode(address(governor), pid));
        bytes32 base = keccak256(abi.encode(key, uint256(0)));
        for (uint256 i = 0; i < 4; i++) {
            vm.store(address(registry), bytes32(uint256(base) + i), bytes32(0));
        }
        assertEq(
            uint8(registry.outcomeOf(address(governor), pid)),
            uint8(IGuardianRegistry.ReviewOutcome.Unresolved),
            "registry must hold no record for this proposal"
        );

        ISyndicateGovernor.StrategyProposal memory p = _proposal(pid);
        assertGt(p.reviewEnd, p.voteEnd, "governor still believes a review window exists");

        // Well inside `executeBy`: the old branch would have said Approved here.
        _warpPast(p.reviewEnd);
        assertLt(vm.getBlockTimestamp(), p.executeBy, "still inside the execution window");
        _assertState(pid, ISyndicateGovernor.ProposalState.Expired, "fails CLOSED, not open");

        // Terminal, so the vault binding is released rather than stranded.
        uint256 openBefore = governor.openProposalCount();
        governor.resolveProposalState(pid);
        _assertState(pid, ISyndicateGovernor.ProposalState.Expired, "terminal after commit");
        assertEq(governor.openProposalCount(), openBefore - 1, "Expired decrements the open count");
        assertEq(governor.getActiveProposal(), 0, "no active proposal binds the vault");
    }
}
