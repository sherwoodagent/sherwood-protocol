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
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @title GuardianReviewLifecycle.t
/// @notice End-to-end tests for the Task 25 guardian-review proposal lifecycle.
///         Drives propose → vote → GuardianReview → Approved/Rejected across a
///         real governor + registry with a staked guardian cohort.
contract GuardianReviewLifecycleTest is Test {
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
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public random = makeAddr("random");

    // Five guardians — each above the min-stake floor and together well above the
    // 50k MIN_COHORT_STAKE_AT_OPEN floor so the review path runs.
    address public g1 = makeAddr("guardian1");
    address public g2 = makeAddr("guardian2");
    address public g3 = makeAddr("guardian3");
    address public g4 = makeAddr("guardian4");
    address public g5 = makeAddr("guardian5");
    // Additional guardians used by block-quorum scenarios that need larger
    // cohorts (10 guardians × 10k = 100k stake at open).
    address public g6 = makeAddr("guardian6");
    address public g7 = makeAddr("guardian7");
    address public g8 = makeAddr("guardian8");
    address public g9 = makeAddr("guardian9");
    address public g10 = makeAddr("guardian10");
    address public factoryEoa; // test contract impersonates factory

    // Registry burn sink (matches GuardianRegistry.BURN_ADDRESS).
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public agentNftId;

    // Governor / registry params
    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%
    uint256 constant GUARDIAN_STAKE = 20_000e18; // 5 × 20k = 100k cohort

    function setUp() public {
        factoryEoa = address(this);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        agentNftId = agentRegistry.mint(agent);

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

        // sWOOD + Governor + Registry — three-way circular init dependency
        // resolved by predicting proxy addresses. From `baseNonce`:
        //   swoodImpl (+0), swoodProxy (+1), govImpl (+2), govProxy (+3),
        //   regImpl (+4), regProxy (+5).
        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 3);
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

        // sWOOD — sole WOOD custodian post-split.
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
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault), // vault_: this test's vault (per-vault governor)
                predictedRegistryProxy,
                address(_hoistedPC),
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
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        // Per-vault governor: the vault resolves its governor via its factory
        // (this test contract). Mock governorOf(vault) -> the deployed governor.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        // Registry — slimmed 6-arg initialize. factoryEoa = test contract so we
        // can bind owner stake. Must land at predictedRegistryProxy — `require`
        // below catches nonce drift.
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        // Authorize the per-vault governor on the composite-key registry
        // (replaces the removed governor.addVault wiring).
        vm.prank(registry.factory());
        registry.addGovernor(address(governor));
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");

        // Resolve the registry ↔ sWOOD circular dependency.
        vm.prank(owner);
        swood.setRegistry(address(registry));

        // LPs
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

        // Guardians stake — five × 20k = 100k (well above 50k MIN_COHORT_STAKE_AT_OPEN).
        _stakeGuardian(g1, GUARDIAN_STAKE, 1);
        _stakeGuardian(g2, GUARDIAN_STAKE, 2);
        _stakeGuardian(g3, GUARDIAN_STAKE, 3);
        _stakeGuardian(g4, GUARDIAN_STAKE, 4);
        _stakeGuardian(g5, GUARDIAN_STAKE, 5);

        // Age-weighted voting: mature the cohort to par so block-quorum math
        // below runs on full stake weight.
        skip(30 days);
    }

    // ──────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────

    function _stakeGuardian(address who, uint256 amount, uint256 agentId) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(who);
        swood.stakeAsGuardian(amount, agentId);
    }

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
    }

    function _propose() internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://review-lifecycle",
            7 days,
            GovEnvelope.permissive(),
            _execCalls(),
            _settleCalls(),
            _emptyCoProposers()
        );
    }

    function _voteFor(uint256 pid) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
    }

    // ──────────────────────────────────────────────────────────────
    // 25.9 Scenarios
    // ──────────────────────────────────────────────────────────────

    /// @notice Full lifecycle — post-vote → GuardianReview → Approved (no blocks)
    ///         → execute → settle. No slashing happens.
    function test_lifecycle_happyPath_survivesReview_executes_settles() public {
        uint256 pid = _propose();
        _voteFor(pid);

        // Vote ends → state is GuardianReview until the review window elapses.
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.GuardianReview),
            "state should be GuardianReview after voteEnd"
        );

        // Keeper opens the review.
        registry.openReview(address(governor), pid);

        // Optional Approve votes — don't matter for the outcome, but exercise the path.
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);

        // Review ends → state resolves to Approved (no blocks).
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.GuardianReview),
            "before resolveReview, the view path still sees GuardianReview"
        );

        // Execute drives `_resolveState` which calls `resolveReview`.
        governor.executeProposal(pid);
        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "executed after review resolves with no blocks"
        );

        // Approvers keep their stake — no slashing on the happy path.
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE);
        assertEq(swood.guardianStake(g2), GUARDIAN_STAKE);

        // Settle after duration.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
    }

    /// @notice Block quorum hit → proposal rejected and approvers slashed.
    function test_lifecycle_blockQuorum_rejects_slashesApprovers() public {
        uint256 pid = _propose();
        _voteFor(pid);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);

        // g1, g2 Approve; g3, g4, g5 Block.
        // Total stake at open = 100k. Block weight = 60k → 60% ≥ 30% quorum → BLOCKED.
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g3);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g4);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g5);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        // Resolve review directly on the registry (permissionless). This slashes
        // approvers and caches `blocked = true`.
        bool blocked = registry.resolveReview(address(governor), pid);
        assertTrue(blocked, "review resolved as blocked");

        // Deterministic severity (Part D) at 60% decisiveness:
        //   bBps = 60_000/100_000 = 6000; q = 3000; lo = 1000; hi = 9999
        //   t = 3000e18/3667 ≈ 0.818107e18 → t² ≈ 0.669299e18
        //   severity = 1000 + ⌊8999 × 0.669299⌋ = 7023 bps
        // 20_000e18 × 7023/10_000 = 14_046e18 → 5_954e18 residue per approver.
        uint256 residue = GUARDIAN_STAKE - (GUARDIAN_STAKE * 7023) / 10_000; // 5_954e18
        assertEq(swood.guardianStake(g1), residue, "g1 slashed at deterministic 7023 bps");
        assertEq(swood.guardianStake(g2), residue, "g2 slashed at deterministic 7023 bps");
        assertEq(swood.guardianStake(g3), GUARDIAN_STAKE, "g3 untouched");
        assertEq(swood.guardianStake(g4), GUARDIAN_STAKE, "g4 untouched");
        assertEq(swood.guardianStake(g5), GUARDIAN_STAKE, "g5 untouched");

        // Governor view now maps to Rejected via the cached registry resolution.
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "governor view reflects blocked review"
        );

        // executeProposal reverts because the proposal is Rejected, not Approved.
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(pid);
    }

    /// @notice When the guardian cohort is below MIN_COHORT_STAKE_AT_OPEN at
    ///         openReview time, the review auto-resolves to Approved with zero
    ///         slashing regardless of how any vote shakes out.
    function test_lifecycle_cohortTooSmall_autoApproves_noSlashing() public {
        // Drain the cohort below 50k: request unstake from 3 guardians so only
        // g1 + g2 remain active (40k < 50k).
        vm.prank(g3);
        swood.requestUnstakeGuardian();
        vm.prank(g4);
        swood.requestUnstakeGuardian();
        vm.prank(g5);
        swood.requestUnstakeGuardian();

        uint256 pid = _propose();
        _voteFor(pid);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);

        (,,, bool cohortTooSmall) = registry.getReviewState(address(governor), pid);
        assertTrue(cohortTooSmall, "cohort flagged as too small");

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        // No slashing — proposal should go straight to Approved then Executed.
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE, "g1 untouched");
        assertEq(swood.guardianStake(g2), GUARDIAN_STAKE, "g2 untouched");
    }

    /// @notice Owner cannot veto a proposal that has transitioned out of Pending.
    function test_vetoProposal_inGuardianReview_reverts() public {
        uint256 pid = _propose();
        _voteFor(pid);

        // Move into the GuardianReview window.
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.GuardianReview));

        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ProposalNotCancellable.selector);
        governor.vetoProposal(pid);
    }

    /// @notice Owner cannot emergencyCancel once the proposal is Approved.
    function test_emergencyCancel_inApproved_reverts() public {
        uint256 pid = _propose();
        _voteFor(pid);

        // Move past review → Approved.
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        // Drive the registry resolution via the mutating resolver on the governor
        // by calling a state-changing path. `vetoProposal` is cheap — attempt it
        // so the state is committed as Approved/Rejected; we expect it to revert.
        // Simpler: just read view and assert, then assert emergencyCancel reverts.
        // View path keeps state as GuardianReview until resolve; emergencyCancel
        // calls _resolveState which will resolve and return Approved.
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ProposalNotCancellable.selector);
        governor.emergencyCancel(pid);
    }

    // ──────────────────────────────────────────────────────────────
    // Task 27.A — block quorum × WOOD burn × approver slashing
    // ──────────────────────────────────────────────────────────────

    /// @notice Cross-contract proof: on block quorum, executeProposal reverts,
    ///         approvers are slashed, the burn address receives slashed WOOD,
    ///         and blockers accrue epoch block-weight for reward claims.
    ///         Mirrors spec §8 INV-2 and priority invariant #226 §8.
    function test_blockQuorum_rejectsProposal_slashesApprovers_burnsWood() public {
        // Scale up to 10 guardians × 10_000 WOOD so the block cohort drives
        // 50% of stake — cleanly above the 30% quorum with margin.
        _stakeGuardian(g6, MIN_GUARDIAN_STAKE, 6);
        _stakeGuardian(g7, MIN_GUARDIAN_STAKE, 7);
        _stakeGuardian(g8, MIN_GUARDIAN_STAKE, 8);
        _stakeGuardian(g9, MIN_GUARDIAN_STAKE, 9);
        _stakeGuardian(g10, MIN_GUARDIAN_STAKE, 10);

        // Age-weighted voting: mature the freshly staked blockers to par so
        // their block votes carry full weight against the raw denominator.
        skip(30 days);

        uint256 pid = _propose();
        _voteFor(pid);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);

        // 3 approvers × 10k + 5 blockers × 10k = 30k approve / 50k block out of
        // 100k + 50k = 150k... but g1..g5 staked 20k each above. Let me account
        // for that: g1..g5 = 20k (from setUp), g6..g10 = 10k (added here).
        // Total = 100k + 50k = 150k. Approve: g1..g3 (60k). Block: g6..g10 (50k).
        // Block = 50k/150k = 33.3% ≥ 30% → BLOCKED.
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);

        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g3);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g6);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g7);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g8);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g9);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g10);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        // Drive the registry resolution first so state transitions commit
        // (slashing + epoch attribution). The executeProposal call below then
        // reads the cached Rejected state via `_resolveStateView`.
        bool blocked = registry.resolveReview(address(governor), pid);
        assertTrue(blocked, "review resolved as blocked");

        // executeProposal reads `_resolveStateView` → Rejected → reverts.
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(pid);

        // Governor view now reflects Rejected via the cached registry resolution.
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "proposal rejected after block quorum"
        );

        // Deterministic severity (Part D) at 33.33% decisiveness:
        //   bBps = 50_000/150_000 = 3333; q = 3000; lo = 1000; hi = 9999
        //   t = 333e18/3667 ≈ 0.090810e18 → t² ≈ 0.008246e18
        //   severity = 1000 + ⌊8999 × 0.008246⌋ = 1074 bps
        // 20_000e18 × 1074/10_000 = 2_148e18 burned, 17_852e18 residue each.
        uint256 residue = GUARDIAN_STAKE - (GUARDIAN_STAKE * 1074) / 10_000; // 17_852e18
        assertEq(swood.guardianStake(g1), residue, "g1 (approver) slashed at deterministic 1074 bps");
        assertEq(swood.guardianStake(g2), residue, "g2 (approver) slashed at deterministic 1074 bps");
        assertEq(swood.guardianStake(g3), residue, "g3 (approver) slashed at deterministic 1074 bps");

        // Blockers untouched.
        assertEq(swood.guardianStake(g6), MIN_GUARDIAN_STAKE, "g6 (blocker) untouched");
        assertEq(swood.guardianStake(g10), MIN_GUARDIAN_STAKE, "g10 (blocker) untouched");

        // Burn sink received approver WOOD (× deterministic 1074/10_000).
        uint256 burnAfter = wood.balanceOf(BURN_ADDRESS);
        assertGt(burnAfter, burnBefore, "burn sink received slashed WOOD");
        uint256 expectedBurn = 3 * ((GUARDIAN_STAKE * 1074) / 10_000); // 3 × 2_148e18
        assertEq(burnAfter - burnBefore, expectedBurn, "burn == 3 * (20_000e18 * 1074/10_000)");

        // V1.5: blocker epoch attribution is emitted as `BlockerAttributed` and
        // attributed off-chain via Merkl. Event inspection is covered in
        // Phase 3 dedicated tests.
    }

    /// @notice Vote-change path: first-vote stake snapshot is preserved when a
    ///         guardian flips Approve → Block before the lockout window.
    function test_voteChange_fromApproveToBlock_survivesReviewEnd() public {
        uint256 pid = _propose();
        _voteFor(pid);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);

        // g1 initially approves.
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);

        // Still well before the 10% lockout window — flip to Block.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(g1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);

        // Four more guardians also block so the quorum is hit (5 × 20k = 100k,
        // well above 30% of 100k total).
        vm.prank(g2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g3);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g4);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(g5);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        bool blocked = registry.resolveReview(address(governor), pid);
        assertTrue(blocked, "review resolved as blocked");

        // g1's stake was preserved at first-vote value and counted on the
        // Block side at resolve time (no approvers to slash → all guardians
        // keep their stake).
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE, "g1 not slashed - ended as blocker");

        // V1.5: blocker attribution emitted via BlockerAttributed event, not
        // queryable on-chain. See Phase 3 event-inspection tests.
    }

    /// @notice No keeper ever calls `openReview`. After `reviewEnd`, anyone calls
    ///         `executeProposal`: `_resolveState` calls `resolveReview` which
    ///         short-circuits to `false` (since !opened) → Approved → executes.
    function test_reviewWithoutOpenReview_returnsFalse_cleanPath() public {
        uint256 pid = _propose();
        _voteFor(pid);

        // Skip openReview entirely; jump past reviewEnd.
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + REVIEW_PERIOD + 2);

        // Permissionless execute — anyone can trigger.
        vm.prank(random);
        governor.executeProposal(pid);

        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "proposal executes despite openReview being skipped"
        );

        // Registry review is now cached as resolved=true, blocked=false, opened=false.
        (bool opened, bool resolved, bool blocked, bool cohortTooSmall) =
            registry.getReviewState(address(governor), pid);
        assertFalse(opened, "review never opened");
        assertTrue(resolved, "review cached resolved");
        assertFalse(blocked, "review not blocked");
        assertFalse(cohortTooSmall, "cohortTooSmall flag stays unset when !opened");

        // No guardian slashing occurred.
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE, "g1 stake untouched");
        assertEq(swood.guardianStake(g5), GUARDIAN_STAKE, "g5 stake untouched");
    }
}
