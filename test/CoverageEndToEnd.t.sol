// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

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
import {TierRegistry} from "../src/TierRegistry.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

/// @dev Chainlink-shaped USD feed for the vault asset: fixed answer, `decimals`,
///      `updatedAt` stamped at construction.
contract MockFeed {
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
}

/// @dev A contract with real code (so `TierRegistry.certify` can snapshot its
///      EXTCODEHASH) whose only entrypoint moves no value — `poke()` is not one
///      of the four value-moving ERC20 selectors, so the vault's batch guard
///      lets it through without an adapter-allowlist entry.
contract NoopAdapter {
    uint256 public pokes;

    function poke() external {
        pokes++;
    }
}

/// @title CoverageEndToEndTest
/// @notice Task 13 — end-to-end coverage lifecycle plus the three adversarial
///         paths the guardian economic-security model (spec 2026-07-22 §3.3,
///         §3.3a, §3.7, §3.9) has to survive.
///
///         Unlike `GovernorCoverageGates.t.sol` (which mocks the approver source
///         so it can dial coverage directly), this suite runs the REAL approve
///         path: real `StakedWood`, a real UUPS `GuardianRegistry` proxy with a
///         real review window, and a real `ExposureLedger` wired BOTH ways
///         (`ledger.setGuardianRegistry(registry)` +
///         `registry.setExposureLedger(ledger)`). Every dollar of exposure here
///         is booked by an actual `GuardianRegistry.voteOnProposal(..., Approve)`
///         from an actual staked, matured guardian, and the execute-time quorum
///         reads that same registry's `getApproverWeights`.
///
/// @dev    Two full syndicates (vaultA/govA, vaultB/govB) share ONE sWOOD, ONE
///         registry and ONE ledger — that shared ledger is what makes the
///         batching test (§3.3 netting cap) meaningful: one guardian, two
///         independent drains, one aggregate budget.
///
/// @dev    Fixture scale (everything below derives from these):
///           - vault asset USDG, 6-dec, $1.00 feed → 1_000e6 maxCapital = $1,000
///           - no TierRegistry wired ⇒ tier 2, coverage == maxCapital ⇒ $1,000
///           - proposerBondBps 100 (1%) ⇒ $10 ⇒ 200 WOOD at the $0.05 haircut
///           - guardian bonds: 20_000 WOOD == $1,000, 30_000 WOOD == $1,500
contract CoverageEndToEndTest is Test {
    // ── Shared infrastructure ──
    ERC20Mock public usdg; // vault asset, 6-dec, $1.00
    ERC20Mock public wood; // stake + bond token, 18-dec
    ERC20Mock public targetToken; // inert execute/settle call target
    BatchExecutorLib public executorLib;
    MockAgentRegistry public agentRegistry;
    ProtocolConfig public protocolConfig;
    StakedWood public swood;
    GuardianRegistry public registry;
    ExposureLedger public ledger;
    MockFeed public feed;
    ProposerBondEscrow public escrow;
    TierRegistry public tierRegistry; // deployed; wired only by the tier-1 test
    NoopAdapter public adapter;

    // ── Two independent syndicates on the shared stack ──
    SyndicateVault public vaultA;
    SyndicateGovernor public govA;
    SyndicateVault public vaultB;
    SyndicateGovernor public govB;

    address public owner = makeAddr("owner");
    address public ledgerOwner = makeAddr("ledgerOwner");
    address public agentA = makeAddr("agentA");
    address public agentB = makeAddr("agentB");
    address public lp = makeAddr("lp");

    // Guardian cohort: 30k + 3 × 20k = 90k, comfortably over the registry's
    // 50k MIN_COHORT_STAKE_AT_OPEN floor.
    address public g1 = makeAddr("guardian1"); // 30_000 WOOD == $1,500 bond
    address public g2 = makeAddr("guardian2");
    address public g3 = makeAddr("guardian3");
    address public g4 = makeAddr("guardian4");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 45 days; // >= epochLength (28d) + challengeWindow (14d)
    uint256 constant EPOCH_LENGTH = 28 days;

    uint256 constant WHALE_STAKE = 30_000e18; // $1,500 at the $0.05 haircut
    uint256 constant FILLER_STAKE = 20_000e18; // $1,000
    uint256 constant DEPOSIT = 60_000e6;

    /// @dev maxCapital of every tier-2 proposal here. With no TierRegistry
    ///      wired, `_resolveTierAndCoverage` returns (2, maxCapital), so
    ///      requiredCoverage == this and coverageUsd == $1,000.
    uint256 constant MAX_CAPITAL = 1_000e6;
    uint256 constant COVERAGE_USD = 1_000e18;
    uint256 constant BOND_WOOD = 200e18; // $1,000 × 1% ÷ $0.05

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(owner);
        adapter = new NoopAdapter();
        tierRegistry = new TierRegistry(address(this));

        // ── sWOOD (sole WOOD custodian). Test contract is the factory.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: COOL_DOWN,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        // ── Guardian registry (real review window — no MockRegistryMinimal here).
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

        // ── Two syndicates on the shared registry.
        (govA, vaultA) = _deploySyndicate();
        (govB, vaultB) = _deploySyndicate();
        registry.addGovernor(address(govA), address(vaultA)); // test contract IS the registry factory
        registry.addGovernor(address(govB), address(vaultB));

        // Each vault resolves its governor through the factory (this contract).
        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vaultA)), abi.encode(address(govA))
        );
        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vaultB)), abi.encode(address(govB))
        );

        vm.startPrank(owner);
        vaultA.registerAgent(agentRegistry.mint(agentA), agentA);
        vaultB.registerAgent(agentRegistry.mint(agentB), agentB);
        vm.stopPrank();

        usdg.mint(lp, 4 * DEPOSIT);
        vm.startPrank(lp);
        usdg.approve(address(vaultA), DEPOSIT);
        vaultA.deposit(DEPOSIT, lp);
        usdg.approve(address(vaultB), DEPOSIT);
        vaultB.deposit(DEPOSIT, lp);
        vm.stopPrank();

        // ── Guardian cohort, then mature it to par (maturationPeriod 30d) so
        //    `getPastVotes` == raw stake and the cohort clears the 50k floor.
        _stakeGuardian(g1, WHALE_STAKE, 1);
        _stakeGuardian(g2, FILLER_STAKE, 2);
        _stakeGuardian(g3, FILLER_STAKE, 3);
        _stakeGuardian(g4, FILLER_STAKE, 4);
        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        // ── Ledger deployed AFTER the maturation warp so epoch genesis and feed
        //    freshness are current: approvals book into bucket 0 at a live price.
        ledger = new ExposureLedger(ledgerOwner, address(swood), EPOCH_LENGTH);
        feed = new MockFeed(1e8, 8); // $1.00, 8-dec
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.05e8); // conservative governance haircut
        // Generous staleness bound: the §3.3a quorum re-reads this feed at
        // EXECUTE time, a full voting + review window after propose. A tight
        // `maxDelay` would make every execution die `StalePrice` regardless of
        // coverage — that coupling is pinned deliberately by
        // `GovernorCoverageGates.test_execute_staleFeedBlocksQuorum` and must
        // not be allowed to confound the five behaviours under test here.
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(owner);
        registry.setExposureLedger(address(ledger));

        // ── Proposer-bond escrow authorized through the registry itself.
        escrow = new ProposerBondEscrow(address(wood), address(registry));

        // ── Wire both governors (test contract is their factory).
        govA.setExposureLedger(address(ledger));
        govA.setBondEscrow(address(escrow));
        govB.setExposureLedger(address(ledger));
        govB.setBondEscrow(address(escrow));

        wood.mint(agentA, 1_000_000e18);
        wood.mint(agentB, 1_000_000e18);
        vm.prank(agentA);
        wood.approve(address(escrow), type(uint256).max);
        vm.prank(agentB);
        wood.approve(address(escrow), type(uint256).max);

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Fixture helpers ───────────────────────────────────────────────────

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
                address(this), // factory (test contract) — may call the onlyFactory setters
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

    /// @dev Inert execute batch: an `approve` on a token the vault does not hold,
    ///      so net asset outflow is zero and the batch cannot fail the envelope.
    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(targetToken), data: abi.encodeCall(targetToken.approve, (address(usdg), 1)), value: 0
        });
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(usdg.approve, (address(targetToken), 0)), value: 0
        });
    }

    function _adapterCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.poke, ()), value: 0});
    }

    function _propose(SyndicateGovernor gov, address v, address as_) internal returns (uint256) {
        return _propose(gov, v, as_, _execCalls(), _settleCalls());
    }

    function _propose(
        SyndicateGovernor gov,
        address v,
        address as_,
        BatchExecutorLib.Call[] memory exec,
        BatchExecutorLib.Call[] memory settle
    ) internal returns (uint256) {
        vm.prank(as_);
        return gov.propose(
            v,
            address(0),
            "ipfs://coverage-e2e",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            exec,
            settle,
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @dev Warp to just past `voteEnd` and open the registry-side review — the
    ///      window in which guardians may cast (and therefore book exposure).
    function _openReview(SyndicateGovernor gov, uint256 pid) internal {
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
    }

    function _vote(SyndicateGovernor gov, uint256 pid, address guardian, IGuardianRegistry.GuardianVoteType support)
        internal
    {
        vm.prank(guardian);
        registry.voteOnProposal(address(gov), pid, support);
    }

    /// @dev Warp past `reviewEnd` (still inside the execution window). The
    ///      registry resolution itself is committed lazily by the governor's
    ///      `_resolveState`.
    function _pastReview(SyndicateGovernor gov, uint256 pid) internal {
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
    }

    function _state(SyndicateGovernor gov, uint256 pid) internal view returns (uint256) {
        return uint256(gov.getProposal(pid).state);
    }

    // ── 1. Full lifecycle: coverage accounting round-trips ────────────────

    /// @notice propose (bond locked, covered-TVL cap cleared) → guardian approves
    ///         (exposure booked, §3.3 cap checked) → execute (§3.3a quorum
    ///         covered by that same approver's LIVE bond) → settle →
    ///         `reclaimProposerBond` returns the WOOD → warp past
    ///         epoch + challengeWindow → `openExposureUsd` back to zero.
    ///
    ///         The one deliberate asymmetry pinned here: settling does NOT free
    ///         coverage. Exposure is released by TIME (bucket ageing), because
    ///         that epoch's challenge window is still open even after an early
    ///         settle — the conservative, spec-consistent behaviour listed under
    ///         the plan's "known deliberate gaps".
    function test_fullLifecycle_coverageAccountingRoundTrips() public {
        uint256 agentBalBefore = wood.balanceOf(agentA);

        // ── Propose: tier-2 pricing, covered-TVL cap cleared, bond pulled.
        uint256 pid = _propose(govA, address(vaultA), agentA);
        assertEq(govA.getProposal(pid).envelopeTier, 2, "no tier registry => tier 2");
        assertEq(govA.getProposal(pid).requiredCoverage, MAX_CAPITAL, "tier 2 => full notional");
        assertEq(ledger.coverageUsd(address(usdg), MAX_CAPITAL), COVERAGE_USD, "$1,000 of coverage");
        assertEq(govA.getProposal(pid).proposerBondWood, BOND_WOOD, "1% of $1,000 at $0.05/WOOD");
        assertEq(wood.balanceOf(address(escrow)), BOND_WOOD, "escrow holds the bond");
        assertEq(wood.balanceOf(agentA), agentBalBefore - BOND_WOOD, "proposer paid the bond");

        // ── Guardian approves through the REAL registry: exposure is booked on
        //    the ledger by `voteOnProposal`, and the §3.3 cap is checked there.
        _openReview(govA, pid);
        assertEq(ledger.openExposureUsd(g1), 0, "no exposure before the vote");
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "approve books the proposal's coverage");
        assertLe(ledger.openExposureUsd(g1), ledger.slashableBondUsd(g1), "booked within g1's slashable bond");

        // The registry is the quorum's approver source — one real approver.
        (address[] memory approvers,,) = registry.getApproverWeights(address(govA), pid);
        assertEq(approvers.length, 1);
        assertEq(approvers[0], g1);

        // ── Execute: §3.3a quorum reads g1's bond LIVE and finds it sufficient.
        _pastReview(govA, pid);
        assertGe(ledger.slashableBondUsd(g1), COVERAGE_USD, "approver covers the coverage in dollars");
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed), "executed");

        // ── Settle (the proposer may self-settle after MIN_STRATEGY_DURATION).
        vm.warp(govA.getProposal(pid).executedAt + 1 hours + 1);
        vm.prank(agentA);
        govA.settleProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Settled), "settled");

        // Settle does NOT recycle the budget — the challenge window is still open.
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "coverage stays booked through settle");

        // ── Bond returns in full: settlement is not a conviction.
        govA.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agentA), agentBalBefore, "bond refunded in full");
        assertEq(wood.balanceOf(address(escrow)), 0, "escrow drained");
        (, uint256 escrowed) = escrow.bondOf(address(govA), pid);
        assertEq(escrowed, 0);
        assertEq(govA.getProposal(pid).proposerBondWood, 0);

        // ── Budget recycles once the approval's bucket ages out: bucket `e`
        //    stops counting at genesis + (e+1)·L + W.
        vm.warp(vm.getBlockTimestamp() + EPOCH_LENGTH + ledger.challengeWindow() + 1);
        assertEq(ledger.openExposureUsd(g1), 0, "epoch + challenge window elapsed => budget recycled");
    }

    // ── 2. Batching attack: the netting cap blocks simultaneous exposure ──

    /// @notice Spec §3.3's core anti-batching property. ONE guardian, TWO
    ///         independent vaults/governors, two $1,000 drains. Either drain
    ///         ALONE fits inside g1's $1,500 slashable bond — the pair does not.
    ///
    ///         g1 backs a proposal with a SHARE of its free budget, so the
    ///         second approve is not rejected outright: it commits only the $500
    ///         still available. What the cap guarantees is that g1's TOTAL
    ///         committed exposure never exceeds its bond — so the second drain
    ///         is left under-covered and cannot clear the execute-time quorum.
    ///         The coalition can never get both drains executed against one bond.
    ///
    ///         Releasing the bookings (approve → block vote change) frees the
    ///         budget, and re-approving the second then covers it in full —
    ///         proving the shortfall was the shared budget and not a
    ///         per-proposal size check.
    function test_batchingAttack_cannotCoverTwoDrainsWithOneBond() public {
        uint256 pidA = _propose(govA, address(vaultA), agentA);
        uint256 pidB = _propose(govB, address(vaultB), agentB);

        // Precondition: each drain is individually coverable, the pair is not.
        assertLe(COVERAGE_USD, ledger.slashableBondUsd(g1), "drain #1 alone fits g1's bond");
        assertGt(2 * COVERAGE_USD, ledger.slashableBondUsd(g1), "but the two together do not");

        _openReview(govA, pidA);
        registry.openReview(address(govB), pidB); // same block: both reviews open

        // Drain #1 approved — coverage booked against g1's aggregate budget.
        _vote(govA, pidA, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD);

        // Drain #2 while #1 is still open: only the leftover budget is committed.
        _vote(govB, pidB, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(
            ledger.openExposureUsd(g1),
            ledger.slashableBondUsd(g1),
            "total committed exposure pinned at the bond, never 2x the drain"
        );

        // #1 stays covered; #2 is short and cannot clear the quorum.
        ledger.requireApproveQuorum(address(govA), pidA, address(usdg), MAX_CAPITAL);
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(govB), pidB, address(usdg), MAX_CAPITAL);

        // Control: the shortfall was the SHARED budget, not drain #2 itself.
        // Release both bookings, re-approve #2, and it covers in full.
        _vote(govA, pidA, g1, IGuardianRegistry.GuardianVoteType.Block);
        _vote(govB, pidB, g1, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposureUsd(g1), 0, "approve -> block releases both bookings");
        _vote(govB, pidB, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "drain #2 now fully covered");
        ledger.requireApproveQuorum(address(govB), pidB, address(usdg), MAX_CAPITAL);
    }

    // ── 3. Cold start: a thin cohort BLOCKS execution, it does not force it ──

    /// @notice Spec §3.3a cold-start. The guardian cohort collapses below the
    ///         registry's `MIN_COHORT_STAKE_AT_OPEN` before the review opens, so
    ///         the review auto-resolves NOT-blocked with ZERO approvers. The
    ///         optimistic path would happily execute that; the §3.3a quorum
    ///         refuses (`InsufficientApproveCoverage`) because there is no
    ///         identified, stake-backed signer to hold liable (R1). The proposal
    ///         then simply expires at `executeBy` and the proposer's bond comes
    ///         back — suppressing the cohort costs the attacker the execution,
    ///         it never forces one.
    function test_thinCohortCannotForceExecution() public {
        uint256 agentBalBefore = wood.balanceOf(agentA);
        uint256 pid = _propose(govA, address(vaultA), agentA);
        assertEq(govA.getProposal(pid).envelopeTier, 2, "tier 2 => quorum applies");
        assertGe(govA.getProposal(pid).envelopeTier, ledger.quorumTierThreshold());

        // Cohort collapses: three of four guardians exit, leaving 20k of votable
        // stake — under the registry's 50k floor.
        vm.prank(g1);
        swood.requestUnstakeGuardian();
        vm.prank(g2);
        swood.requestUnstakeGuardian();
        vm.prank(g3);
        swood.requestUnstakeGuardian();

        _openReview(govA, pid);
        assertEq(swood.getPastTotalVotes(vm.getBlockTimestamp() - 1), FILLER_STAKE, "only g4 left");
        assertLt(
            swood.getPastTotalVotes(vm.getBlockTimestamp() - 1),
            registry.MIN_COHORT_STAKE_AT_OPEN(),
            "cohort under the floor at open"
        );
        (,,, bool cohortTooSmall) = registry.getReviewState(address(govA), pid);
        assertTrue(cohortTooSmall, "review flagged cold-start");

        // Review closes with nobody having voted; it auto-resolves not-blocked.
        _pastReview(govA, pid);
        govA.resolveProposalState(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Approved), "not blocked => Approved");
        (bool opened, bool resolved, bool blocked,) = registry.getReviewState(address(govA), pid);
        assertTrue(opened, "review was opened");
        assertTrue(resolved, "review resolved");
        assertFalse(blocked, "and not blocked");
        (address[] memory approvers,,) = registry.getApproverWeights(address(govA), pid);
        assertEq(approvers.length, 0, "zero approvers");

        // Optimistic passage is NOT enough for a tier-2 proposal.
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        govA.executeProposal(pid);

        // It expires instead of executing, and the bond is not forfeited.
        vm.warp(govA.getProposal(pid).executeBy + 1);
        govA.resolveProposalState(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Expired), "expired unexecuted");
        govA.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agentA), agentBalBefore, "expiry returns the bond in full");
    }

    // ── 4. WOOD price crash between approve and execute ───────────────────

    /// @notice The §3.3a quorum re-reads approver bonds LIVE at execute, so
    ///         coverage must hold in DOLLARS at execution time — the v1a
    ///         approximation of F2's slash-time requirement. A guardian whose
    ///         $1,500 bond covered $1,000 at approve time covers only $150 after
    ///         a 10× WOOD drawdown, and the execution fails closed.
    function test_woodPriceCrashBetweenApproveAndExecute_blocksExecute() public {
        uint256 pid = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pid);
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertGe(ledger.slashableBondUsd(g1), COVERAGE_USD, "amply covered at approve time");
        _pastReview(govA, pid);

        // Commit the registry-side resolution up front. `executeProposal` would
        // do it lazily, but a revert inside execute rolls that write back too —
        // committing here makes the post-revert state assertion below read
        // Approved rather than a re-resolved GuardianReview.
        govA.resolveProposalState(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Approved), "review passed, executable");

        // Control: at the approve-time price this proposal DOES execute. Taken
        // on a snapshot so the crash below is the only difference between the
        // passing and the failing run.
        uint256 snap = vm.snapshotState();
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed), "executes at the old price");
        vm.revertToState(snap);

        // WOOD crashes 10×. Nothing about the proposal or the vote changed.
        vm.prank(ledgerOwner);
        ledger.setWoodUsdPrice(0.005e8);
        assertLt(ledger.slashableBondUsd(g1), COVERAGE_USD, "the same bond no longer covers the same dollars");
        assertEq(ledger.coverageUsd(address(usdg), MAX_CAPITAL), COVERAGE_USD, "the dollar need is unchanged");

        (address[] memory approvers,,) = registry.getApproverWeights(address(govA), pid);
        assertEq(approvers.length, 1, "the approver is still recorded");

        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Approved), "stays Approved, unexecuted");
    }

    // ── 5. The bounded (below-threshold) lane is genuinely preserved ───────

    /// @notice Spec §4 gate 2: the §3.10 ROE argument is only allowed to lower
    ///         `quorumTierThreshold` because the optimistic lane below it still
    ///         works. A tier-1-certified execute target therefore executes with
    ///         ZERO approvers — the quorum is never consulted — while the
    ///         propose-time gates (covered-TVL cap, risk-scaled bond) still run.
    function test_boundedTierFlowUnaffected() public {
        // Certify the (adapter, poke) pair at tier 1 with a 1% extractable bound.
        govA.setTierRegistry(address(tierRegistry)); // test contract is the factory
        tierRegistry.certify(address(adapter), adapter.poke.selector, 1, 100, address(0));

        uint256 pid = _propose(govA, address(vaultA), agentA, _adapterCalls(), _adapterCalls());
        assertEq(govA.getProposal(pid).envelopeTier, 1, "certified tier 1");
        assertLt(govA.getProposal(pid).envelopeTier, ledger.quorumTierThreshold(), "below the quorum threshold");
        // coverage = maxCapital × Σ(exec 100 bps + settle 100 bps) / 10_000.
        uint256 coverage = (MAX_CAPITAL * 200) / 10_000;
        assertEq(govA.getProposal(pid).requiredCoverage, coverage, "bounded coverage, not full notional");
        // The propose-time bond still applies, scaled to the smaller coverage.
        assertEq(
            govA.getProposal(pid).proposerBondWood,
            ledger.proposerBondWood(address(usdg), coverage),
            "risk-scaled bond still locked"
        );

        // Review runs with a healthy cohort and NOBODY approves.
        _openReview(govA, pid);
        _pastReview(govA, pid);
        (address[] memory approvers,,) = registry.getApproverWeights(address(govA), pid);
        assertEq(approvers.length, 0, "zero approvers");
        assertEq(ledger.openExposureUsd(g1), 0, "no exposure booked anywhere");

        // Optimistic passage survives below the threshold.
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed), "bounded lane still executes");
        assertEq(adapter.pokes(), 1, "the batch really ran");

        // The threshold is what did the work: the identical zero-approver shape
        // at tier 2 is exactly what `test_thinCohortCannotForceExecution` rejects.
        assertEq(ledger.quorumTierThreshold(), 2, "launch threshold unchanged");
    }
}
