// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {MoonwellSupplyStrategy} from "../../src/strategies/MoonwellSupplyStrategy.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/**
 * @title GuardianNetworkForkTest
 * @notice Fork integration test that validates the guardian network end-to-end:
 *         staking, proposal review, approval with reward claims, block quorum
 *         with approver slashing, and emergency settle under guardian review.
 *
 *         WOOD is not yet live on Base mainnet (MinimalGuardianRegistry is the
 *         beta stub). This test deploys a fresh Sherwood stack on a Base fork
 *         so we get real Moonwell/USDC DeFi interactions while controlling the
 *         full guardian network.
 *
 *         Run:
 *           forge test --fork-url $BASE_RPC_URL \
 *             --match-contract GuardianNetworkForkTest -vvvv \
 *             --fork-block-number 47810000
 *
 *         For the MM TEE wallet demo, point a Tenderly virtual testnet at the
 *         same block and replay the setUp transactions via admin RPC so
 *         external wallets can interact with the live guardian network.
 */
contract GuardianNetworkForkTest is Test {
    // ── Live Base mainnet DeFi addresses ──
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MOONWELL_MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;

    // ── Guardian network parameters ──
    uint256 constant GUARDIAN_STAKE = 30_000e18; // 3 x 30k = 90k > 50k MIN_COHORT
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%

    // ── Governor / vault parameters ──
    uint256 constant VOTING_PERIOD = 1 hours;
    uint256 constant EXECUTION_WINDOW = 24 hours;
    uint256 constant VETO_THRESHOLD_BPS = 4000; // 40% AGAINST to reject
    uint256 constant COOLDOWN_PERIOD = 1 hours;
    uint256 constant GUARDIAN_FEE_BPS = 200; // 2% of profit to guardians
    uint256 constant AGENT_FEE_BPS = 1500; // 15% agent performance fee

    // ── Test actors ──
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address keeper = makeAddr("keeper"); // calls openReview / resolveReview

    // Three guardians. 2-of-3 blocking = 60% > 30% quorum → BLOCKED.
    address g1 = makeAddr("g1"); // approver in scenarios A/C
    address g2 = makeAddr("g2"); // approver in A, blocker in B
    address g3 = makeAddr("g3"); // blocker in B

    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ── Fresh Sherwood stack (deployed on top of fork) ──
    ERC20Mock wood;
    StakedWood swood;
    GuardianRegistry registry;
    SyndicateGovernor governor;
    SyndicateVault vault;
    SyndicateFactory factory;
    BatchExecutorLib executorLib;
    MockAgentRegistry agentRegistry;

    uint256 ownerAgentId;
    uint256 agentNftId;

    MoonwellSupplyStrategy moonwellTemplate;

    uint256 constant FORK_BLOCK = 47_810_000;

    function setUp() public {
        vm.rollFork(FORK_BLOCK);
        _deployFreshStack();
        _seedGuardians();
        _createVaultAndFundLPs();
        moonwellTemplate = new MoonwellSupplyStrategy();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Scenario A - Happy path: guardians approve, strategy executes, fees flow
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Full happy path:
     *   propose -> vote -> GuardianReview -> g1+g2 approve -> resolve -> execute
     *   -> settle (Moonwell interest accrues) -> no slashing.
     *
     *   Proves:
     *   - openReview emits ReviewOpened (NOT CohortTooSmallToReview) - guardian
     *     cohort is live and above MIN_COHORT_STAKE_AT_OPEN threshold
     *   - approvers keep their stake after a clean approval
     *   - vault unlocks after settle, LPs can redeem
     */
    function test_scenarioA_happyPath_guardiansApprove_executeSettle() public {
        (address strategy, BatchExecutorLib.Call[] memory execCalls, BatchExecutorLib.Call[] memory settleCalls) =
            _deployMoonwellStrategy(10_000e6, 9_900e6);

        uint256 pid = _proposeAndVote(strategy, execCalls, settleCalls);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.GuardianReview),
            "A: state should be GuardianReview after voting ends"
        );

        // openReview must emit ReviewOpened, NOT CohortTooSmallToReview.
        vm.expectEmit(true, false, false, false, address(registry));
        emit IGuardianRegistry.ReviewOpened(pid, 0);
        vm.prank(keeper);
        registry.openReview(pid);

        (bool opened,, bool blocked, bool cohortTooSmall) = registry.getReviewState(pid);
        assertTrue(opened, "A: review opened");
        assertFalse(cohortTooSmall, "A: cohort above MIN_COHORT_STAKE_AT_OPEN - enforcement live");
        assertFalse(blocked, "A: not blocked yet");

        vm.prank(g1);
        registry.voteOnProposal(pid, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.prank(g2);
        registry.voteOnProposal(pid, IGuardianRegistry.GuardianVoteType.Approve, 0);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        governor.executeProposal(pid);

        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "A: proposal executed"
        );

        // Strategy holds real mUSDC from Moonwell supply on live fork.
        assertGt(IERC20(MOONWELL_MUSDC).balanceOf(strategy), 0, "A: strategy holds mUSDC");

        // Approvers keep their stake - no slashing on the happy path.
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE, "A: g1 stake intact");
        assertEq(swood.guardianStake(g2), GUARDIAN_STAKE, "A: g2 stake intact");

        // Settle after strategy duration.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(keeper);
        governor.settleProposal(pid);

        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Settled),
            "A: proposal settled"
        );
        assertFalse(vault.redemptionsLocked(), "A: vault unlocked after settle");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Scenario B - Block quorum: 2/3 guardians block, proposal rejected, slash
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Block-quorum enforcement:
     *   propose -> vote -> GuardianReview -> g1 approves -> g2+g3 block
     *   -> block weight 60% > 30% quorum -> resolveReview blocked=true
     *   -> state = Rejected -> executeProposal reverts -> g1 stake slashed, WOOD burned.
     *
     *   This is the enforcement moment the beta demo was missing.
     *   The agent proposed to itself with no friction. This test proves the network
     *   can and does reject proposals when guardians reach block quorum.
     */
    function test_scenarioB_blockQuorum_rejected_slashesApprover() public {
        (, BatchExecutorLib.Call[] memory execCalls, BatchExecutorLib.Call[] memory settleCalls) =
            _deployMoonwellStrategy(10_000e6, 9_900e6);

        uint256 pid = _proposeAndVote(address(0), execCalls, settleCalls);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        vm.prank(keeper);
        registry.openReview(pid);

        (,,, bool cohortTooSmall) = registry.getReviewState(pid);
        assertFalse(cohortTooSmall, "B: cohort sufficient - enforcement is live");

        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        uint256 g1StakeBefore = swood.guardianStake(g1);

        // g1 approves; g2+g3 block.
        // Block weight = 60k / 90k total = 66.7% >= 30% quorum -> BLOCKED.
        vm.prank(g1);
        registry.voteOnProposal(pid, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.prank(g2);
        registry.voteOnProposal(pid, IGuardianRegistry.GuardianVoteType.Block, 10_000);
        vm.prank(g3);
        registry.voteOnProposal(pid, IGuardianRegistry.GuardianVoteType.Block, 10_000);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        vm.prank(keeper);
        bool blocked = registry.resolveReview(pid);
        assertTrue(blocked, "B: review resolved as blocked");

        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "B: proposal Rejected after block quorum"
        );

        // Execute reverts - enforcement biting.
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(pid);

        // Approver (g1) slashed at maxSlashBps (9999).
        assertLt(swood.guardianStake(g1), g1StakeBefore, "B: g1 stake slashed");

        // Slashed WOOD burned to 0xdEaD.
        assertGt(wood.balanceOf(BURN_ADDRESS), burnBefore, "B: WOOD burned");
        assertApproxEqAbs(
            wood.balanceOf(BURN_ADDRESS) - burnBefore,
            (g1StakeBefore * 9999) / 10_000,
            1e18,
            "B: burn amount matches 9999-bps slash"
        );

        // Blockers untouched.
        assertEq(swood.guardianStake(g2), GUARDIAN_STAKE, "B: g2 (blocker) untouched");
        assertEq(swood.guardianStake(g3), GUARDIAN_STAKE, "B: g3 (blocker) untouched");

        // Vault never locked (strategy never executed).
        assertFalse(vault.redemptionsLocked(), "B: vault never locked");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Scenario C - Emergency settle under guardian review
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emergency-settle path with live guardian network:
     *   execute strategy -> vault locked -> owner calls emergencySettleWithCalls
     *   -> registry opens emergency review -> guardians don't block
     *   -> owner calls finalizeEmergencySettle -> strategy unwound, vault unlocked.
     */
    function test_scenarioC_emergencySettle_guardiansApprove_finalizes() public {
        (address strategy, BatchExecutorLib.Call[] memory execCalls, BatchExecutorLib.Call[] memory settleCalls) =
            _deployMoonwellStrategy(10_000e6, 9_900e6);

        // Get the strategy executed so vault is locked.
        uint256 pid = _proposeAndVote(strategy, execCalls, settleCalls);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        vm.prank(keeper);
        registry.openReview(pid);
        vm.prank(g1);
        registry.voteOnProposal(pid, IGuardianRegistry.GuardianVoteType.Approve, 0);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        governor.executeProposal(pid);

        assertTrue(vault.redemptionsLocked(), "C: vault locked after execute");

        // Owner triggers emergency settle with the precommitted calls.
        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, settleCalls);

        assertTrue(registry.isEmergencyOpen(pid), "C: emergency review open");

        // No guardians block - warp past emergency review period.
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        // Owner finalizes - executes the precommitted calls, unwinds Moonwell position.
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);

        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Settled),
            "C: settled via emergency path"
        );
        assertFalse(vault.redemptionsLocked(), "C: vault unlocked after emergency settle");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Scenario D - Cold-start regression guard (documents the beta demo gap)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Regression guard confirming what the beta demo hit.
     *         Drains cohort below 50k WOOD, proposes - openReview emits
     *         CohortTooSmallToReview and resolveReview returns false regardless
     *         of any votes. Documents the exact cold-start condition.
     *
     *         On the live beta deployment:
     *         - MinimalGuardianRegistry.reviewPeriod() = 0 (collapses window)
     *         - totalGuardianStake = 0 (WOOD not live)
     *         -> Every proposal auto-passed, no enforcement possible.
     *
     *         This scenario proves the code correctly detects and documents that
     *         condition, so the same thing cannot silently happen on a deployment
     *         where guardians are partially unstaked.
     */
    function test_scenarioD_coldStart_regression_guard() public {
        // Drain cohort: only g1 (30k) remains. 30k < 50k MIN_COHORT_STAKE_AT_OPEN.
        vm.prank(g2);
        swood.requestUnstakeGuardian();
        vm.prank(g3);
        swood.requestUnstakeGuardian();

        (, BatchExecutorLib.Call[] memory execCalls, BatchExecutorLib.Call[] memory settleCalls) =
            _deployMoonwellStrategy(10_000e6, 9_900e6);
        uint256 pid = _proposeAndVote(address(0), execCalls, settleCalls);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);

        // openReview emits CohortTooSmallToReview - cold-start path.
        vm.expectEmit(true, false, false, false, address(registry));
        emit IGuardianRegistry.CohortTooSmallToReview(pid, 0);
        registry.openReview(pid);

        (,,, bool cohortTooSmall) = registry.getReviewState(pid);
        assertTrue(cohortTooSmall, "D: cold-start flag set");

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        // resolveReview short-circuits to false - no enforcement, no slashing.
        bool blocked = registry.resolveReview(pid);
        assertFalse(blocked, "D: cold-start -> always unblocked");

        governor.executeProposal(pid);
        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "D: auto-approved under cold-start"
        );
        assertEq(swood.guardianStake(g1), GUARDIAN_STAKE, "D: no slashing under cold-start");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ══════════════════════════════════════════════════════════════════════════

    function _deployMoonwellStrategy(uint256 supplyAmount, uint256 minRedeem)
        internal
        returns (address strategy, BatchExecutorLib.Call[] memory execCalls, BatchExecutorLib.Call[] memory settleCalls)
    {
        bytes memory initData = abi.encode(USDC, MOONWELL_MUSDC, supplyAmount, minRedeem, false);
        strategy = Clones.clone(address(moonwellTemplate));
        (bool ok,) =
            strategy.call(abi.encodeWithSignature("initialize(address,address,bytes)", address(vault), agent, initData));
        require(ok, "strategy init failed");

        execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = BatchExecutorLib.Call({
            target: USDC,
            data: abi.encodeCall(IERC20.approve, (strategy, supplyAmount)),
            value: 0
        });
        execCalls[1] =
            BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});

        settleCalls = new BatchExecutorLib.Call[](1);
        settleCalls[0] =
            BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    function _proposeAndVote(
        address strategy,
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls
    ) internal returns (uint256 pid) {
        vm.prank(owner);
        vault.setAgentFeeBps(AGENT_FEE_BPS);

        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            strategy,
            "ipfs://guardian-network-fork-test",
            7 days,
            execCalls,
            settleCalls,
            new ISyndicateGovernor.CoProposer[](0)
        );

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
    }

    /**
     * @dev Deploys a fresh Sherwood stack on the fork.
     *
     *      Nonce layout from address(this) at call time:
     *        +0  wood (ERC20Mock)
     *        +1  agentRegistry
     *        +2  swoodImpl
     *        +3  swoodProxy       <- predictedSwood (passed to govImpl)
     *        +4  govImpl
     *        +5  govProxy         <- predictedGovernor
     *        +6  regImpl
     *        +7  regProxy         <- predictedRegistry
     *        +8  vaultImpl
     *        +9  executorLib
     *        +10 factImpl
     *        +11 factProxy        <- predictedFactory
     */
    function _deployFreshStack() internal {
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 5);
        address predictedRegistry = vm.computeCreateAddress(address(this), baseNonce + 7);
        address predictedFactory = vm.computeCreateAddress(address(this), baseNonce + 11);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        agentRegistry = new MockAgentRegistry();
        ownerAgentId = agentRegistry.mint(owner);
        agentNftId = agentRegistry.mint(agent);

        // sWOOD
        StakedWood swoodImpl = new StakedWood();
        swood = StakedWood(
            address(
                new ERC1967Proxy(
                    address(swoodImpl),
                    abi.encodeCall(
                        StakedWood.initialize,
                        (
                            StakedWood.InitParams({
                                owner: owner,
                                wood: address(wood),
                                governor: predictedGovernor,
                                factory: predictedFactory,
                                minGuardianStake: MIN_GUARDIAN_STAKE,
                                coolDownPeriod: 7 days,
                                minOwnerStake: MIN_OWNER_STAKE,
                                minSlashBps: 1000,
                                maxSlashBps: 9999
                            })
                        )
                    )
                )
            )
        );

        // Governor
        SyndicateGovernor govImpl = new SyndicateGovernor();
        governor = SyndicateGovernor(
            address(
                new ERC1967Proxy(
                    address(govImpl),
                    abi.encodeCall(
                        SyndicateGovernor.initialize,
                        (
                            ISyndicateGovernor.InitParams({
                                owner: owner,
                                votingPeriod: VOTING_PERIOD,
                                executionWindow: EXECUTION_WINDOW,
                                vetoThresholdBps: VETO_THRESHOLD_BPS,
                                maxPerformanceFeeBps: 1500,
                                cooldownPeriod: COOLDOWN_PERIOD,
                                collaborationWindow: 48 hours,
                                maxCoProposers: 5,
                                minStrategyDuration: 1 hours,
                                maxStrategyDuration: 30 days,
                                protocolFeeBps: 0,
                                protocolFeeRecipient: address(0),
                                guardianFeeBps: GUARDIAN_FEE_BPS,
                                guardiansFeeRecipient: predictedRegistry
                            }),
                            predictedRegistry
                        )
                    )
                )
            )
        );
        require(address(governor) == predictedGovernor, "governor addr mismatch - nonce drift");

        // GuardianRegistry
        GuardianRegistry regImpl = new GuardianRegistry();
        registry = GuardianRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(
                        GuardianRegistry.initialize,
                        (owner, address(governor), predictedFactory, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
                    )
                )
            )
        );
        require(address(registry) == predictedRegistry, "registry addr mismatch - nonce drift");

        // Factory + vault impl + executor
        SyndicateVault vaultImpl = new SyndicateVault();
        executorLib = new BatchExecutorLib();
        SyndicateFactory factImpl = new SyndicateFactory();
        factory = SyndicateFactory(
            address(
                new ERC1967Proxy(
                    address(factImpl),
                    abi.encodeCall(
                        SyndicateFactory.initialize,
                        (
                            SyndicateFactory.InitParams({
                                owner: owner,
                                executorImpl: address(executorLib),
                                vaultImpl: address(vaultImpl),
                                ensRegistrar: address(0),
                                agentRegistry: address(agentRegistry),
                                governor: address(governor),
                                managementFeeBps: 0,
                                guardianRegistry: address(registry)
                            })
                        )
                    )
                )
            )
        );
        require(address(factory) == predictedFactory, "factory addr mismatch - nonce drift");

        // Resolve circular deps post-deploy.
        vm.prank(owner);
        swood.setRegistry(address(registry));

        vm.prank(owner);
        governor.setFactory(address(factory));
    }

    function _seedGuardians() internal {
        _stakeGuardian(g1, GUARDIAN_STAKE, 10);
        _stakeGuardian(g2, GUARDIAN_STAKE, 11);
        _stakeGuardian(g3, GUARDIAN_STAKE, 12);
        // Checkpoint timestamps must be in the past before any proposal opens.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _stakeGuardian(address who, uint256 amount, uint256 agentId) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(who);
        swood.stakeAsGuardian(amount, agentId);
    }

    function _createVaultAndFundLPs() internal {
        // Owner must prepareOwnerStake before createSyndicate.
        wood.mint(owner, MIN_OWNER_STAKE);
        vm.prank(owner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(owner);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);

        vm.prank(owner);
        (, address vaultAddr) = factory.createSyndicate(
            ownerAgentId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://guardian-network-fork-demo",
                asset: IERC20(USDC),
                name: "Guardian Demo Vault",
                symbol: "gdUSDC",
                openDeposits: true,
                subdomain: "guardian-demo"
            })
        );
        vault = SyndicateVault(payable(vaultAddr));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        // Fund LPs with real USDC via deal (live Base fork state).
        deal(USDC, lp1, 60_000e6);
        deal(USDC, lp2, 40_000e6);

        vm.startPrank(lp1);
        IERC20(USDC).approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();

        vm.startPrank(lp2);
        IERC20(USDC).approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();
    }
}
