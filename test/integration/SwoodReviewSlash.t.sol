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

/// @title SwoodReviewSlash.t
/// @notice End-to-end integration test for the sWOOD staking-split (Task 11.1).
///
///         Exercises the REAL cross-contract path with no mocks for the
///         staking / review machinery:
///
///           SyndicateGovernor → propose / vote / GuardianReview
///           GuardianRegistry  → openReview / voteOnProposal / resolveReview
///                               → _weightedMedianSlashBps → swood.slashGuardians
///           StakedWood (sWOOD)→ stakeAsGuardian / delegateStake
///                               → _slashOne (own stake + delegated pool)
///                               → _burnWood
///
///         A blocked proposal slashes the approver guardian at the
///         stake-weighted MEDIAN of the blockers' proposed `slashBps`. The
///         test deliberately picks UNEQUAL blocker stake weights so the
///         stake-weighted median is provably DISTINCT from the arithmetic
///         mean — a buggy mean implementation would compute a different
///         number and the assertions would fail. See the fixture comment
///         block for the hand-computed median derivation.
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
    // Three blocker guardians with VARYING stake weight AND proposed slashBps.
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

    // ── Fixture: stake-weighted MEDIAN must be provably ≠ arithmetic MEAN ──
    //
    // Blockers have UNEQUAL stake so the stake-weighted median diverges from
    // the (unweighted) arithmetic mean of the proposed slashBps. A buggy mean
    // implementation would compute 5000 bps and every assertion below would
    // fail — the test now genuinely distinguishes median from mean.
    //
    //   Blocker stake / proposed slashBps:
    //     gBlock1 = 10k stake, proposes 2000 bps
    //     gBlock2 = 20k stake, proposes 4000 bps
    //     gBlock3 = 50k stake, proposes 9000 bps
    //   Total blocker weight = 10k + 20k + 50k = 80k.
    //
    //   `_weightedMedianSlashBps` sorts ascending by slashBps then walks
    //   cumulative weight, picking the first pair where `cumulative*2 >=
    //   totalWeight`:
    //     sorted: (2000,10k) (4000,20k) (9000,50k)
    //     cumulative: 10k → 30k → 80k
    //     2*10k=20k  ≥ 80k? no
    //     2*30k=60k  ≥ 80k? no
    //     2*80k=160k ≥ 80k? yes  → MEDIAN = 9000 bps (90%)
    //
    //   Arithmetic MEAN of {2000,4000,9000} = 15000/3 = 5000 bps.
    //   MEDIAN (9000) ≠ MEAN (5000) — the key property of this fixture.
    //   9000 is inside the [minSlashBps=1000, maxSlashBps=9999] band so no
    //   clamp muddies the result.
    //
    //   Cohort own stake at open = 20k (approver) + 80k (blockers) = 100k.
    //   Denominator = 100k own + 400 delegated. Block weight = 80k.
    //   80k*10000 = 8e8  ≥  3000 * 100_400  = 3.012e8  → BLOCKED.
    //
    //   Slash @ median 9000 bps (90%):
    //     Approver own stake 20k → 90% = 18k burned, 2k remains.
    //     Approver delegated pool = 300 + 100 = 400 → 90% = 360 burned,
    //       40 remains. del1 300 → 30 remains, del2 100 → 10 remains.
    uint256 constant APPROVER_STAKE = 20_000e18;
    uint256 constant BLOCKER1_STAKE = 10_000e18;
    uint256 constant BLOCKER2_STAKE = 20_000e18;
    uint256 constant BLOCKER3_STAKE = 50_000e18;
    uint256 constant DEL1_AMOUNT = 300e18;
    uint256 constant DEL2_AMOUNT = 100e18;

    uint256 constant SLASH_BPS_LOW = 2000; // gBlock1 (10k weight)
    uint256 constant SLASH_BPS_MID = 4000; // gBlock2 (20k weight)
    uint256 constant SLASH_BPS_HIGH = 9000; // gBlock3 (50k weight)

    // Hand-computed stake-weighted median (see derivation above). This is the
    // slash factor the contract MUST apply — NOT the 5000 bps unweighted mean.
    uint256 constant EXPECTED_MEDIAN_BPS = 9000;

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
                    maxSlashBps: 9999
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
        // 100k own stake total. Unequal blocker weights make the stake-weighted
        // median (9000) provably distinct from the arithmetic mean (5000).
        _stakeGuardian(gApprove, APPROVER_STAKE, 1);
        _stakeGuardian(gBlock1, BLOCKER1_STAKE, 2);
        _stakeGuardian(gBlock2, BLOCKER2_STAKE, 3);
        _stakeGuardian(gBlock3, BLOCKER3_STAKE, 4);

        // Delegators delegate into the approver guardian's DPoS pool.
        _delegate(del1, gApprove, DEL1_AMOUNT);
        _delegate(del2, gApprove, DEL2_AMOUNT);
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
            _execCalls(),
            _settleCalls(),
            _emptyCoProposers()
        );
    }

    // ── The end-to-end test ──

    /// @notice Full sWOOD review→block→graduated-slash flow.
    ///
    ///   1. propose → vote For → GuardianReview window.
    ///   2. openReview on the registry (snapshots votable stake at openedAt-1).
    ///   3. gApprove votes Approve; gBlock1/2/3 vote Block with 2000/4000/9000
    ///      at UNEQUAL stake weights 10k/20k/50k.
    ///   4. resolveReview → block quorum hit → stake-weighted median 9000 bps
    ///      (NOT the 5000 bps mean) → slashGuardians.
    ///
    /// Asserts:
    ///   - the proposal resolves Rejected/blocked;
    ///   - the stake-weighted median (9000 bps) — and not the 5000 bps
    ///     arithmetic mean — was the slash factor applied;
    ///   - the approver's OWN stake was slashed pro-rata to the median;
    ///   - the approver's DELEGATED pool was slashed pro-rata, each delegator's
    ///     `delegationOf` diluted by the same share-factor;
    ///   - the slashed WOOD (18k own + 360 pool) was burned to BURN_ADDRESS;
    ///   - the GuardianRegistry holds no WOOD and no reward pool was funded —
    ///     the slash path does not touch reward-pool state.
    function test_review_blockQuorum_graduatedMedianSlash_endToEnd() public {
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

        // ── 3. guardian votes: 1 Approve, 3 Block with varying slashBps ──
        vm.prank(gApprove);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.prank(gBlock1);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block, SLASH_BPS_LOW); // 2000 @ 10k
        vm.prank(gBlock2);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block, SLASH_BPS_MID); // 4000 @ 20k
        vm.prank(gBlock3);
        registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block, SLASH_BPS_HIGH); // 9000 @ 50k

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

        // ── Assert: own stake slashed at the stake-weighted MEDIAN ──
        //
        // EXPECTED values below are HARDCODED LITERALS — deliberately NOT
        // re-derived from the contract's own `stake * bps / 10_000` formula —
        // so a contract-side formula or rounding bug cannot be silently
        // absorbed by a mirrored expression on the expected side.
        //
        // Arithmetic rationale (slash factor = stake-weighted median 9000 bps):
        //   own slash      = 20_000e18 * 9000 / 10_000 = 18_000e18  → 2_000e18 remains
        //   pool slash     =    400e18 * 9000 / 10_000 =    360e18  →    40e18 remains
        //   del1 remains   =    300e18 - (300e18 * 9000 / 10_000)   =    30e18
        //   del2 remains   =    100e18 - (100e18 * 9000 / 10_000)   =    10e18
        //   total burned   = 18_000e18 + 360e18                     = 18_360e18
        //   totalGuardianStake post = 100_000e18 - 18_000e18        = 82_000e18
        //
        // If the contract had (incorrectly) used the 5000 bps arithmetic mean,
        // own stake would be 10_000e18 and every literal below would mismatch —
        // that is the property this fixture proves.
        assertEq(swood.guardianStake(gApprove), 2_000e18, "approver own stake = 2k post-slash (90% of 20k burned)");
        // Self-documenting median≠mean guard: the slash factor actually applied
        // is the stake-weighted median (EXPECTED_MEDIAN_BPS = 9000), NOT the
        // 5000 bps arithmetic mean. Under the mean, own stake would be 10k.
        assertEq(EXPECTED_MEDIAN_BPS, 9000, "stake-weighted median is 9000 bps, not the 5000 bps mean");
        assertTrue(swood.guardianStake(gApprove) != 10_000e18, "slash used median (9000), not mean (5000)");
        // Cohort total stake dropped by exactly the approver's own 18k slash.
        assertEq(swood.totalGuardianStake(), 82_000e18, "totalGuardianStake = 100k - 18k own slash");

        // ── Assert: blockers untouched ──
        assertEq(swood.guardianStake(gBlock1), BLOCKER1_STAKE, "blocker1 untouched");
        assertEq(swood.guardianStake(gBlock2), BLOCKER2_STAKE, "blocker2 untouched");
        assertEq(swood.guardianStake(gBlock3), BLOCKER3_STAKE, "blocker3 untouched");

        // ── Assert: delegated pool slashed at the same median share-factor ──
        // pool 400 − (400 × 9000 / 10000) = 400 − 360 = 40.
        assertEq(swood.poolTokens(gApprove), 40e18, "pool slashed 90% -> 40");
        assertEq(swood.totalDelegatedStake(), 40e18, "totalDelegatedStake -> 40");

        // Each delegator's token-equivalent diluted by the SAME 90% share-factor
        // (no per-delegator loop — one poolTokens write dilutes the share rate).
        assertEq(swood.delegationOf(del1, gApprove), 30e18, "del1 diluted 90% -> 30");
        assertEq(swood.delegationOf(del2, gApprove), 10e18, "del2 diluted 90% -> 10");

        // ── Assert: slashed WOOD burned (own + delegated) ──
        // 18_000e18 own + 360e18 pool = 18_360e18 burned to the dead address.
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 18_360e18, "18k own + 360 pool burned to dead address");
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
