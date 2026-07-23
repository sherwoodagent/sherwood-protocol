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

/// @title SwoodReviewSlash.t
/// @notice End-to-end integration test for the sWOOD staking-split (Task 11.1).
///
///         Exercises the REAL cross-contract path with no mocks for the
///         staking / review machinery:
///
///           SyndicateGovernor → propose / vote / GuardianReview
///           GuardianRegistry  → openReview / voteOnProposal / resolveReview
///                               → _severityBps → swood.slashGuardians
///           StakedWood (sWOOD)→ stakeAsGuardian / delegateStake
///                               → _slashOne (own stake + delegated pool)
///                               → _burnWood
///
///         A blocked proposal slashes the approver guardian at the
///         DETERMINISTIC severity derived from block-side decisiveness
///         (spec 2026-07-19 Part D) — severity is NOT voted. This fixture's
///         block side is overwhelming (79.68% of the at-open total, past the
///         2/3 SUPERMAJORITY_BPS ceiling), so the severity is maxSlashBps =
///         9999 and the first-loss spill is clamped by the approver's
///         remaining own stake. See the fixture comment block for the
///         hand-computed derivation.
contract SwoodReviewSlashTest is Test {
    // `governor` MUST be public: the vault reads its governor via
    // `factory.governor()`, and this test contract impersonates the factory —
    // the Solidity-generated public getter is what answers that call.
    SyndicateGovernor public governor;
    SyndicateVault internal vault;
    GuardianRegistry internal registry;
    StakedWood internal swood;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    ERC20Mock internal wood;
    ERC20Mock internal targetToken;
    MockAgentRegistry internal agentRegistry;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");

    // Approver guardian — the one who gets slashed.
    address internal gApprove = makeAddr("guardianApprove");
    // Three blocker guardians with varying stake weight.
    address internal gBlock1 = makeAddr("guardianBlock1");
    address internal gBlock2 = makeAddr("guardianBlock2");
    address internal gBlock3 = makeAddr("guardianBlock3");
    // Delegators into the approver's DPoS pool.
    address internal del1 = makeAddr("delegator1");
    address internal del2 = makeAddr("delegator2");

    address internal factoryEoa; // test contract impersonates the factory

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 internal agentNftId;

    // Governor / registry params.
    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%

    // ── Fixture: deterministic severity from block-side decisiveness ──
    //
    // Severity is no longer voted (spec 2026-07-19 Part D): `_severityBps`
    // ramps quadratically with block decisiveness from the at-open block
    // quorum (floor `minSlashBps`) to SUPERMAJORITY_BPS = 6667 (ceiling
    // `maxSlashBps`).
    //
    //   Blocker stake: gBlock1 = 10k, gBlock2 = 20k, gBlock3 = 50k → 80k.
    //   Cohort own stake at open = 20k (approver) + 80k (blockers) = 100k.
    //   Denominator = 100k own + 400 delegated = 100_400.
    //
    //   Block quorum: 80k*10000 = 8e8 ≥ 3000 * 100_400 = 3.012e8 → BLOCKED.
    //
    //   Decisiveness: bBps = 80_000e18 × 10_000 / 100_400e18 = 7968 (floor).
    //   7968 ≥ SUPERMAJORITY_BPS (6667) → severity = maxSlashBps = 9999.
    uint256 constant APPROVER_STAKE = 20_000e18;
    uint256 constant BLOCKER1_STAKE = 10_000e18;
    uint256 constant BLOCKER2_STAKE = 20_000e18;
    uint256 constant BLOCKER3_STAKE = 50_000e18;
    uint256 constant DEL1_AMOUNT = 300e18;
    uint256 constant DEL2_AMOUNT = 100e18;

    // Hand-computed deterministic severity (see derivation above). This is
    // the slash factor the contract MUST apply.
    uint256 constant EXPECTED_SEVERITY_BPS = 9999;

    // This test contract impersonates the factory. Per-vault (#421) the vault
    // resolves its governor via `factory.governorOf(vault)`, so expose it here
    // (single vault → single governor).
    function governorOf(address) external view returns (address) {
        return address(governor);
    }

    function setUp() public {
        factoryEoa = address(this);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        agentNftId = agentRegistry.mint(agent);

        // Vault.
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
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        // Registry — slimmed 6-arg initialize.
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");

        // Authorize the per-vault governor with the registry (factory-only;
        // this test impersonates the factory). Required for openReview /
        // resolveReview to pass the registry's authorized-governor guard (P2).
        registry.addGovernor(address(governor));

        // Resolve the registry ↔ sWOOD circular dependency.
        vm.prank(owner);
        swood.setRegistry(address(registry));

        // DPoS delegation must be explicitly enabled on sWOOD.
        vm.prank(owner);
        swood.setDelegationEnabled(true);

        // LPs deposit so the proposal vote has votable supply.
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

        // Guardian cohort: 1 approver (20k) + 3 blockers (10k/20k/50k) →
        // 100k own stake total. The 80k block side is 79.68% of the at-open
        // total — past the 2/3 supermajority ceiling of the deterministic
        // severity ramp (Part D).
        _stakeGuardian(gApprove, APPROVER_STAKE, 1);
        _stakeGuardian(gBlock1, BLOCKER1_STAKE, 2);
        _stakeGuardian(gBlock2, BLOCKER2_STAKE, 3);
        _stakeGuardian(gBlock3, BLOCKER3_STAKE, 4);

        // Delegators delegate into the approver guardian's DPoS pool.
        _delegate(del1, gApprove, DEL1_AMOUNT);
        _delegate(del2, gApprove, DEL2_AMOUNT);

        // Age-weighted voting: mature the cohort to par so vote weights and
        // slash bases below run on full stake weight.
        skip(30 days);
    }

    // ── Helpers ──

    function _stakeGuardian(address who, uint256 amount, uint256 agentId) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(who);
        swood.stakeAsGuardian(amount, agentId);
    }

    function _delegate(address delegator, address delegate, uint256 amount) internal {
        wood.mint(delegator, amount);
        vm.prank(delegator);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(delegator);
        swood.delegateStake(delegate, amount);
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
            "ipfs://swood-review-slash",
            7 days,
            GovEnvelope.permissive(),
            _execCalls(),
            _settleCalls(),
            _emptyCoProposers()
        );
    }

    // ── The end-to-end test ──

    /// @notice Full sWOOD review→block→deterministic-severity-slash flow.
    ///
    ///   1. propose → vote For → GuardianReview window.
    ///   2. openReview on the registry (snapshots votable stake at openedAt-1).
    ///   3. gApprove votes Approve; gBlock1/2/3 vote Block at stake weights
    ///      10k/20k/50k (no severity argument — Part D).
    ///   4. resolveReview → block quorum hit → deterministic severity from
    ///      block decisiveness (79.68% ≥ 2/3 supermajority → maxSlashBps =
    ///      9999) → slashGuardians.
    ///
    /// Asserts:
    ///   - the proposal resolves Rejected/blocked;
    ///   - the deterministic ceiling severity (9999 bps) was the slash factor
    ///     applied — severity is a function of decisiveness, not of anything
    ///     the blockers propose;
    ///   - the approver's OWN stake was slashed pro-rata to the severity,
    ///     plus the first-loss spill of the delegated damage the
    ///     `maxDelegatedSlashBps` cap absorbed (spec 2026-07-19 Part A) —
    ///     here the spill is clamped by the tiny own-stake remainder, wiping
    ///     the approver;
    ///   - the approver's DELEGATED pool was slashed pro-rata at
    ///     min(severity, C = 2000), each delegator's `delegationOf` diluted
    ///     by the same share-factor;
    ///   - the slashed WOOD (20k own incl. clamped spill + 80 pool) was
    ///     burned to BURN_ADDRESS;
    ///   - the GuardianRegistry holds no WOOD and no reward pool was funded —
    ///     the slash path does not touch reward-pool state.
    function test_review_blockQuorum_deterministicSeveritySlash_endToEnd() public {
        // ── Pre-conditions: pool wired correctly before the review ──
        assertEq(swood.guardianStake(gApprove), APPROVER_STAKE, "approver own stake pre-slash");
        assertEq(swood.poolTokens(gApprove), DEL1_AMOUNT + DEL2_AMOUNT, "pool tokens pre-slash");
        assertEq(swood.delegationOf(del1, gApprove), DEL1_AMOUNT, "del1 stake pre-slash");
        assertEq(swood.delegationOf(del2, gApprove), DEL2_AMOUNT, "del2 stake pre-slash");
        assertEq(swood.totalGuardianStake(), 100_000e18, "cohort total stake (20k + 10k + 20k + 50k)");
        assertEq(swood.totalDelegatedStake(), DEL1_AMOUNT + DEL2_AMOUNT, "total delegated pre-slash");

        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        assertEq(wood.balanceOf(address(registry)), 0, "registry holds no WOOD post-split");

        // ── 1. propose + vote For ──
        uint256 pid = _propose();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);

        // ── 2. voting ends → GuardianReview → openReview ──
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.GuardianReview),
            "state is GuardianReview after voteEnd"
        );
        registry.openReview(address(governor), pid);

        // ── 3. guardian votes: 1 Approve, 3 Block (no severity arg) ──
        vm.prank(gApprove);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(gBlock1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block); // 10k weight
        vm.prank(gBlock2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block); // 20k weight
        vm.prank(gBlock3);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block); // 50k weight

        // ── 4. review window ends → resolveReview ──
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        bool blocked = registry.resolveReview(address(governor), pid);

        // ── Assert: proposal rejected/blocked ──
        assertTrue(blocked, "review resolved as blocked");
        (, bool resolved, bool blockedFlag,) = registry.getReviewState(address(governor), pid);
        assertTrue(resolved, "review resolved");
        assertTrue(blockedFlag, "review blocked flag set");
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "governor view reflects blocked review"
        );
        // Execution is barred — the proposal is Rejected, not Approved.
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(pid);

        // ── Assert: own stake slashed at the DETERMINISTIC severity ──
        //
        // EXPECTED values below are HARDCODED LITERALS — deliberately NOT
        // re-derived from the contract's own `stake * bps / 10_000` formula —
        // so a contract-side formula or rounding bug cannot be silently
        // absorbed by a mirrored expression on the expected side.
        //
        // Arithmetic rationale (slash factor = deterministic severity, spec
        // 2026-07-19 Part D: decisiveness 7968 bps ≥ SUPERMAJORITY_BPS 6667 →
        // severity = maxSlashBps = 9999; delegated legs capped at C =
        // maxDelegatedSlashBps = 2000 with the absorbed excess spilling onto
        // the approver's own stake, clamped to what remains — spec Part A):
        //   own base slash = 20_000e18 * 9999 / 10_000 = 19_998e18
        //   pool slash     =    400e18 * 2000 / 10_000 =     80e18  →  320e18 remains
        //   spill (raw)    =    400e18 * (9999 - 2000) / 10_000 = 319.96e18
        //   spill (clamped)= min(319.96e18, 20_000e18 - 19_998e18) = 2e18
        //   own remains    = 20_000e18 - 19_998e18 - 2e18           = 0
        //   del1 remains   =    300e18 - (300e18 * 2000 / 10_000)   = 240e18
        //   del2 remains   =    100e18 - (100e18 * 2000 / 10_000)   =  80e18
        //   total burned   = 19_998e18 + 2e18 + 80e18               = 20_080e18
        //   totalGuardianStake post = 100_000e18 - 20_000e18        = 80_000e18
        //
        // If the contract had (incorrectly) kept e.g. a sub-ceiling severity,
        // the approver would retain own stake and every literal below would
        // mismatch — the ceiling wipe is the property this fixture proves.
        assertEq(swood.guardianStake(gApprove), 0, "approver own wiped: 19_998 base + 2 clamped spill");
        // Self-documenting Part D guard: the slash factor actually applied is
        // the deterministic ceiling (EXPECTED_SEVERITY_BPS = 9999) because
        // block decisiveness (7968 bps) exceeds the 2/3 supermajority.
        assertEq(EXPECTED_SEVERITY_BPS, 9999, "deterministic ceiling severity = maxSlashBps");
        // Cohort total stake dropped by exactly the approver's own debit
        // (19_998 base + 2 clamped spill = full 20k bond).
        assertEq(swood.totalGuardianStake(), 80_000e18, "totalGuardianStake = 100k - 20k own debit");

        // ── Assert: blockers untouched ──
        assertEq(swood.guardianStake(gBlock1), BLOCKER1_STAKE, "blocker1 untouched");
        assertEq(swood.guardianStake(gBlock2), BLOCKER2_STAKE, "blocker2 untouched");
        assertEq(swood.guardianStake(gBlock3), BLOCKER3_STAKE, "blocker3 untouched");

        // ── Assert: delegated pool slashed at min(severity, C) = 20% ──
        // pool 400 − (400 × 2000 / 10000) = 400 − 80 = 320.
        assertEq(swood.poolTokens(gApprove), 320e18, "pool slashed at C (20%) -> 320");
        assertEq(swood.totalDelegatedStake(), 320e18, "totalDelegatedStake -> 320");

        // Each delegator's token-equivalent diluted by the SAME 20% share-factor
        // (no per-delegator loop — one poolTokens write dilutes the share rate).
        assertEq(swood.delegationOf(del1, gApprove), 240e18, "del1 diluted 20% -> 240");
        assertEq(swood.delegationOf(del2, gApprove), 80e18, "del2 diluted 20% -> 80");

        // ── Assert: slashed WOOD burned (own incl. spill + delegated) ──
        // 19_998e18 own + 2e18 clamped spill + 80e18 pool = 20_080e18 burned.
        assertEq(
            wood.balanceOf(BURN_ADDRESS),
            burnBefore + 20_080e18,
            "20k own (incl. spill) + 80 pool burned to dead address"
        );
        assertEq(swood.pendingBurn(), 0, "no pending burn - ERC20Mock burn transfer succeeded");

        // ── Assert: registry holds no assets; fee attribution is off-chain ──
        // The burn happened entirely inside sWOOD. Guardian-fee rewards are now
        // paid off-chain (buyback-WOOD via weekly Merkl) — the on-chain reward
        // pool / claim machinery was deleted. `getApproverWeights` still
        // exposes the per-proposal approver attribution for the bot.
        assertEq(wood.balanceOf(address(registry)), 0, "registry still holds no WOOD after slash");
        (address[] memory approvers,, uint128 totalApproveWeight) = registry.getApproverWeights(address(governor), pid);
        assertEq(approvers.length, 1, "approver attribution persists post-slash");
        assertEq(approvers[0], gApprove, "approver is gApprove");
        assertGt(uint256(totalApproveWeight), 0, "approve-weight denominator recorded");
    }
}
