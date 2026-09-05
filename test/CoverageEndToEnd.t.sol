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
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {GovEnvelope} from "./helpers/GovEnvelope.sol";
import {deployTierRegistry} from "./helpers/TierRegistryFixture.sol";

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

    /// @dev Re-stamps `updatedAt`. Needed by any test that warps to real chain
    ///      time, which otherwise leaves this fixture's feed stale.
    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
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
///           - uncertified calls ⇒ tier 2 at full notional, and only the exec
///             leg declares a cap ⇒ coverage == maxCapital ⇒ $1,000
///           - proposerBondBps 100 (1%) ⇒ $10 ⇒ 200 WOOD at the $0.05 haircut
///           - guardian bonds: 20_000 WOOD == $1,000, 30_000 WOOD == $1,500
contract CoverageEndToEndTest is Test {
    /// @dev Two tests wire THIS contract as the ledger's coverage freezer;
    ///      since SHE-214 a freezer must answer `challengeWindow()` to wire.
    function challengeWindow() external view returns (uint256) {
        return ledger.challengeWindow();
    }

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
    MockAggregatorV3 public woodFeed;
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

    /// @dev maxCapital of every tier-2 proposal here. Uncertified calls resolve
    ///      to tier 2 at full notional and only the exec leg declares a cap, so
    ///      requiredCoverage == this and coverageUsd == $1,000. (Before pashov
    ///      finding #1 made the registry mandatory at init, the same figure came
    ///      out of the registry-LESS flat default instead.)
    uint256 constant MAX_CAPITAL = 1_000e6;
    uint256 constant COVERAGE_USD = 1_000e18;
    /// @dev The WOOD lock every approve in this file DECLARES: $1,000 of
    ///      coverage at the $0.05 WOOD price. Under declared coverage locks a
    ///      guardian names the WOOD it puts behind a proposal and the ledger
    ///      clamps it to `kNumerator x stake - openExposure`; declaring exactly
    ///      the need keeps every dollar figure below identical to the USD
    ///      reservation it replaced (one WOOD-18 unit == $0.05, so
    ///      `COVERAGE_WOOD == COVERAGE_USD x 20`).
    uint256 constant COVERAGE_WOOD = 20_000e18;
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
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
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
        _bondVaultOwner(address(vaultA));
        _bondVaultOwner(address(vaultB));

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
        // Design revision 2: `woodUsdPriceX8` is a CAP, never a price. WOOD is
        // valued from the WOOD/USD feed at $0.05, with the cap 2x ABOVE it and
        // therefore NOT binding — the configuration production ships. Every
        // dollar figure in this suite is unchanged; only the reason it holds is.
        woodFeed = new MockAggregatorV3(8, 0.05e8);
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8);
        // The mock publishes one round at construction and these suites warp far
        // past it; staleness is exercised in test/ExposureLedger.t.sol.
        ledger.setWoodFeed(address(woodFeed), type(uint64).max);
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
        escrow = new ProposerBondEscrow(address(wood), address(registry), address(ledger));

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
                address(this),
                address(deployTierRegistry(address(this))), // factory (test contract) — may call the onlyFactory setters
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
            GovEnvelope.defaultCaps(
                (ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000})).maxCapital,
                (exec).length
            ),
            settle,
            GovEnvelope.defaultCaps(
                (ISyndicateGovernor.RiskEnvelope({maxCapital: 0, maxDrawdownBps: 10_000})).maxCapital, (settle).length
            ),
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
        _voteLock(gov, pid, guardian, support, COVERAGE_WOOD);
    }

    /// @dev `_vote` with an explicit declaration; `type(uint256).max` locks the
    ///      guardian's whole free budget.
    function _voteLock(
        SyndicateGovernor gov,
        uint256 pid,
        address guardian,
        IGuardianRegistry.GuardianVoteType support,
        uint256 lockWood
    ) internal {
        vm.prank(guardian);
        registry.voteOnProposal(address(gov), pid, support, lockWood);
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

    /// @dev First instant at which a vote CHANGE is refused — the registry's
    ///      anti-sniping window, `reviewEnd - (reviewWindow * 10%)`. The C1
    ///      attack depended on flipping one second before this.
    function _lockoutStart(SyndicateGovernor gov, uint256 pid) internal view returns (uint256) {
        ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
        uint256 window = p.reviewEnd - p.voteEnd;
        return p.reviewEnd - (window * registry.LATE_VOTE_LOCKOUT_BPS()) / 10_000;
    }

    /// @notice n3 — wiring a ledger onto a governor that already has live
    ///         proposals would brick them: they were created before coverage
    ///         existed, so nobody could have booked any, and `executeProposal`
    ///         starts demanding it the moment the ledger is wired.
    ///
    ///         The M3 change made this worse rather than better — the approve
    ///         hook now books nothing instead of reverting, so the failure moved
    ///         from loud at vote time to silent until execute. Refusing the
    ///         wiring is the last point it is visible.
    function test_n3_cannotWireTheLedgerWhileProposalsAreOpen() public {
        uint256 pid = _propose(govA, address(vaultA), agentA);
        assertGt(govA.openProposalCount(), 0, "a proposal is in flight");

        vm.expectRevert(ISyndicateGovernor.ParamsFrozenDuringProposal.selector);
        govA.setExposureLedger(address(ledger));

        // Un-wiring stays legal: it can only relax the execute gate.
        govA.setExposureLedger(address(0));

        // Once nothing is open, wiring is allowed again.
        _openReview(govA, pid);
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);
        _pastReview(govA, pid);
        govA.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + 8 days); // strategy must run its course
        vm.prank(agentA);
        govA.settleProposal(pid);
        assertEq(govA.openProposalCount(), 0, "nothing in flight");
        govA.setExposureLedger(address(ledger));
    }

    /// @notice N11 — the COLLABORATIVE propose path runs the same coverage-horizon
    ///         gate as the solo path. A co-proposed strategy sits in Draft with
    ///         `executeBy == 0` until `approveCollaboration`, so the gate cannot
    ///         read a real deadline; it computes the worst-case deadline instead
    ///         (`collaborationWindow + votingPeriod + reviewPeriod + executionWindow`)
    ///         and checks that against the horizon.
    ///
    ///         The over-horizon REVERT case is no longer constructible: with
    ///         `ABSOLUTE_MAX_STRATEGY_DURATION` pinned at 30 days, the worst-case
    ///         lifecycle (≤ 7d collab + 3d vote + 3d review + 7d execution = 20d,
    ///         plus a 30d run = 50d) can never exceed `MAX_COVERAGE_HORIZON` (60d).
    ///         The 30-day duration cap is now the real protection — over-horizon
    ///         proposals are impossible at the source, so the horizon gate is a
    ///         pure backstop. This test therefore proves the collaborative path
    ///         PROPOSES CLEANLY within horizon; the gate's rejection arithmetic is
    ///         still unit-tested directly in `ExposureLedger.t.sol`
    ///         (`test_requireWithinCoverageHorizon_zeroDeadlineIsNotAFreePass`).
    ///
    ///         `vm.warp` is load-bearing: at Foundry's default `t = 1` the
    ///         deadline math is trivially satisfied and a regression would hide.
    function test_n11_collaborativeProposalRunsTheHorizonGate() public {
        vm.warp(1_800_000_000);
        feed.set(1e8); // re-stamp updatedAt: the warp made the fixture feed stale

        // Max legal duration: exercises the horizon gate at its tightest point
        // while staying within the 30-day cap.
        vm.prank(owner);
        govA.setMaxStrategyDuration(30 days);

        // A co-proposer must be an agent registered on THIS vault; agentB is
        // vaultB's.
        address coAgent = makeAddr("coAgentA");
        // Hoisted: `mint` in argument position would consume the prank and the
        // registerAgent would run unpranked.
        uint256 coAgentId = agentRegistry.mint(coAgent);
        vm.prank(owner);
        vaultA.registerAgent(coAgentId, coAgent);

        ISyndicateGovernor.CoProposer[] memory cps = new ISyndicateGovernor.CoProposer[](1);
        cps[0] = ISyndicateGovernor.CoProposer({agent: coAgent, splitBps: 1_000});

        // A max-duration collaborative proposal passes the horizon gate on the
        // Draft path (worst-case deadline + 30d run stays under the 60d horizon).
        vm.prank(agentA);
        govA.propose(
            address(vaultA),
            address(0),
            "ipfs://n11-ok",
            30 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            _execCalls(),
            GovEnvelope.defaultCaps(
                (ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000})).maxCapital,
                (_execCalls()).length
            ),
            _settleCalls(),
            GovEnvelope.defaultCaps(
                (ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000})).maxCapital,
                (_settleCalls()).length
            ),
            cps
        );
    }

    // ── N1: budget exhaustion must not silence the approve side ───────────

    /// @notice N1 (re-review) — a guardian whose budget went on an earlier
    ///         proposal can still CAST an approve vote on the next one. It
    ///         books nothing, so the batching cap is untouched, but the vote
    ///         itself lands.
    ///
    ///         Before this, `recordApproval` reverted `ExposureCapExceeded` and
    ///         took `voteOnProposal` down with it. That is what let the C1 veto
    ///         survive in a second form: an attacker who front-runs while the
    ///         cohort is busy still bricks the proposal, because the guardians
    ///         who would have covered it cannot participate at all.
    function test_n1_spentBudgetStillVotesAndDoesNotBreakTheReview() public {
        // Warm-up on syndicate B consumes g3's budget entirely.
        uint256 pidB = _propose(govB, address(vaultB), agentB);
        _openReview(govB, pidB);
        _voteLock(govB, pidB, g3, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        assertEq(ledger.openExposure(g3), FILLER_STAKE, "g3 locked its whole stake on B");

        // Target proposal on syndicate A, same epoch.
        uint256 pidA = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pidA);

        // g3 has nothing left to pledge -- and votes anyway.
        _vote(govA, pidA, g3, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.lockOf(address(govA), pidA, g3), 0, "locks nothing: the cap still binds");

        (address[] memory approvers,,) = registry.getApproverWeights(address(govA), pidA);
        assertEq(approvers.length, 1, "but the review counted the vote");
        assertEq(approvers[0], g3);

        // g1 still has budget, so the proposal is genuinely coverable.
        _vote(govA, pidA, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertGt(ledger.openExposure(g1), 0);

        _pastReview(govA, pidA);
        govA.executeProposal(pidA);
        assertEq(_state(govA, pidA), uint256(ISyndicateGovernor.ProposalState.Executed), "executes on real coverage");
    }

    // ── Exit gating (ADR 2026-07-26) ──────────────────────────────────────

    /// @notice A guardian who is currently insuring a proposal cannot pull
    ///         their stake, however long they wait. The cooldown alone could
    ///         not enforce this: it ships at 7 days against obligations running
    ///         ~42, which is why the deploy pre-flight refuses to deploy.
    ///
    ///         REQUESTING stays open — it marks them inactive immediately, so
    ///         they take on no new commitments while the existing one runs
    ///         down. Only the release waits.
    function test_exitGate_blocksClaimWhileCoverageIsOpen() public {
        vm.startPrank(owner);
        swood.setExposureLedger(address(ledger));
        // Drop the cooldown to the value production actually ships (7 days).
        // The fixture's 45d already outlasts this fixture's ~42d of coverage,
        // so the timer would mask the gate and the test would prove nothing.
        // A short cooldown is the case the gate exists for — and the case
        // `DeployPlanB`'s pre-flight currently refuses to deploy.
        swood.setCooldownPeriod(7 days);
        vm.stopPrank();

        uint256 pid = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pid);
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertGt(ledger.openExposure(g1), 0, "g1 is on the hook");

        vm.prank(g1);
        swood.requestUnstakeGuardian(); // allowed: stops them taking on more

        // Past the cooldown but INSIDE the coverage window — the interval the
        // timer alone cannot police, and the whole reason the gate exists.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        assertGt(ledger.openExposure(g1), 0, "precondition: cooldown elapsed, coverage still open");

        vm.prank(g1);
        vm.expectRevert(StakedWood.CoverageStillOpen.selector);
        swood.claimUnstakeGuardian();
    }

    /// @notice ...and released once the coverage genuinely expires. The gate is
    ///         a condition, not a longer timer.
    function test_exitGate_releasesOnceCoverageExpires() public {
        vm.prank(owner);
        swood.setExposureLedger(address(ledger));

        uint256 pid = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pid);
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);

        vm.prank(g1);
        swood.requestUnstakeGuardian();

        // Past the bucket covering settlement plus its challenge window.
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(ledger.openExposure(g1), 0, "coverage has expired");

        uint256 balBefore = wood.balanceOf(g1);
        vm.prank(g1);
        swood.claimUnstakeGuardian();
        assertGt(wood.balanceOf(g1), balBefore, "stake released once nothing is owed");
    }

    /// @notice PR #25 review F2/F6: expiry alone is NOT the exit condition while
    ///         an accusation is live. `openExposure` sums epoch buckets on
    ///         pure wall-clock, so coverage ages out on a timer that does not
    ///         pause for a challenge — and the challenge game's disputed tail
    ///         (up to `disputeTimeout`, 30d) outlives it by design. The accused
    ///         could therefore request at execution, wait, and walk the whole
    ///         bond out before the challenge could resolve; the conviction then
    ///         priced maximum guilt (`live == 0` saturates `slashBpsFor` at
    ///         10,000 bps) and recovered nothing, silently.
    ///
    ///         The freeze is what closes it — and closing it is also what makes
    ///         the freeze load-bearing at all (F6): before this its only reader
    ///         was `releaseApproval`, whose sole caller is unreachable in every
    ///         state a freeze can exist in.
    function test_exitGate_frozenCoverageOutlivesBucketExpiry() public {
        vm.prank(owner);
        swood.setExposureLedger(address(ledger));
        // This test contract stands in for the challenge game.
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(this));

        uint256 pid = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pid);
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);

        // A challenge lands against the proposal g1 covered.
        ledger.freezeCoverage(address(govA), pid, block.timestamp + 30 days);
        assertTrue(ledger.hasFrozenCoverage(g1), "g1 is named by a frozen proposal");

        vm.prank(g1);
        swood.requestUnstakeGuardian();

        // Far past every bucket clock — exactly the window that used to release
        // the bond out from under a live accusation.
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(ledger.openExposure(g1), 0, "the buckets have expired, as they always did");

        vm.prank(g1);
        vm.expectRevert(StakedWood.CoverageStillOpen.selector);
        swood.claimUnstakeGuardian();

        // Once the challenge resolves, the exit opens on the same terms as before.
        ledger.unfreezeCoverage(address(govA), pid);
        assertFalse(ledger.hasFrozenCoverage(g1), "nothing pins g1 any more");

        uint256 balBefore = wood.balanceOf(g1);
        vm.prank(g1);
        swood.claimUnstakeGuardian();
        assertGt(wood.balanceOf(g1), balBefore, "the gate is a condition, not a longer timer");
    }

    /// @notice The frozen-commitment count is per guardian and exact: a second
    ///         frozen proposal naming the same guardian must not be released by
    ///         the first one unfreezing, and a repeated unfreeze must not
    ///         underflow it into a permanent lock.
    function test_exitGate_frozenCoverageCountsEveryLiveAccusation() public {
        vm.prank(owner);
        swood.setExposureLedger(address(ledger));
        // This test contract stands in for the challenge game.
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(this));

        // Two syndicates, so g1 carries two independent commitments at once.
        uint256 pidA = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pidA);
        _vote(govA, pidA, g1, IGuardianRegistry.GuardianVoteType.Approve);
        uint256 pidB = _propose(govB, address(vaultB), agentB);
        _openReview(govB, pidB);
        _vote(govB, pidB, g1, IGuardianRegistry.GuardianVoteType.Approve);

        ledger.freezeCoverage(address(govA), pidA, block.timestamp + 30 days);
        ledger.freezeCoverage(address(govB), pidB, block.timestamp + 30 days);
        assertTrue(ledger.hasFrozenCoverage(g1));

        ledger.unfreezeCoverage(address(govA), pidA);
        assertTrue(ledger.hasFrozenCoverage(g1), "the second accusation still pins the guardian");

        ledger.unfreezeCoverage(address(govB), pidB);
        assertFalse(ledger.hasFrozenCoverage(g1), "released only when the last one clears");

        ledger.unfreezeCoverage(address(govB), pidB);
        assertFalse(ledger.hasFrozenCoverage(g1), "a repeated unfreeze cannot underflow the count");
    }

    /// @notice FAIL-OPEN with no ledger wired. There is necessarily a window at
    ///         deploy — and again on a UUPS upgrade — where the pointer is
    ///         zero, and bricking withdrawals over a missed configuration step
    ///         would be worse than the hole. `DeployPlanB` asserts the wiring
    ///         instead, so the failure surfaces as a refused deploy.
    function test_exitGate_failsOpenWhenNoLedgerIsWired() public {
        assertEq(swood.exposureLedger(), address(0), "fixture leaves it unwired");

        uint256 pid = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pid);
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertGt(ledger.openExposure(g1), 0, "genuinely on the hook...");

        vm.prank(g1);
        swood.requestUnstakeGuardian();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(g1);
        swood.claimUnstakeGuardian(); // ...and still allowed out: no gate wired
    }

    // ── C1 regression, end to end ─────────────────────────────────────────

    /// @notice C1 — the free-rider veto, reconstructed against the REAL stack
    ///         rather than mocks, because the attack composed three contracts:
    ///         the ledger's booking rule, the registry's release-on-flip, and
    ///         the registry's late-vote lockout. A unit test over the ledger
    ///         alone proves only the first third.
    ///
    ///         The attack: g2 holds 20k of 90k staked WOOD — 2,222 bps, well
    ///         under the 3,000 bps block quorum, so it cannot legitimately veto
    ///         anything. Under first-come booking it approved first and absorbed
    ///         the entire $1,000 of coverage; g3's approve then booked $0 and
    ///         left it off the ledger's approver list; g2 flipped to Block one
    ///         second before the lockout, releasing everything. Coverage $0, g3
    ///         unable to re-register, review NOT blocked (g2 never reached
    ///         quorum) — so the proposal resolved Approved and then reverted
    ///         `InsufficientApproveCoverage` on execute, forever, at a cost of
    ///         gas and with no conviction to slash.
    ///
    ///         With per-approver reservations there is nothing to absorb, so
    ///         every step below still happens and the proposal executes anyway.
    function test_poc_freeRiderVetoIsClosed() public {
        uint256 pid = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pid);

        // 1. The attacker gets in first. It reserves the full coverage — but a
        //    reservation is an upper bound on liability, not a claim on the book.
        _vote(govA, pid, g2, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposure(g2), COVERAGE_WOOD, "attacker locks the coverage");

        // 2. THE FIX. The honest approver is no longer free-ridden into a zero
        //    commitment, and is on the ledger's approver list. This assertion is
        //    the exact line that read `0` before.
        _vote(govA, pid, g3, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposure(g3), COVERAGE_WOOD, "honest approver locks its own declaration");
        assertGe(ledger.slashableBondUsd(g3), COVERAGE_USD, "and could carry the proposal alone");

        // Both locked the full coverage. NOTHING IS SPLIT: there is no cohort
        // cap, so each lock stands in full and the proposal is simply
        // over-subscribed 2x - every guardian's lock is exactly what it loses
        // on conviction, whoever else is in.
        assertEq(ledger.lockOf(address(govA), pid, g2), COVERAGE_WOOD, "attacker's lock stands in full");
        assertEq(ledger.lockOf(address(govA), pid, g3), COVERAGE_WOOD, "and so does the honest approver's");
        assertEq(ledger.coverageUsdOf(address(govA), pid, g3), COVERAGE_USD, "priced at the whole lock, uncapped");
        assertEq(ledger.liabilityUsd(address(govA), pid), COVERAGE_USD, "recoverable liability capped at the need");

        // 3. The attacker flips to Block at the last permitted instant, which
        //    releases its reservation at zero cost. Exactly as before.
        vm.warp(_lockoutStart(govA, pid) - 1);
        _vote(govA, pid, g2, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposure(g2), 0, "attacker walks away paying nothing");

        // 4. ...but the survivor's lock is untouched - it never depended on
        //    who else was in - so the coverage does not collapse to zero.
        assertEq(ledger.lockOf(address(govA), pid, g3), COVERAGE_WOOD, "g3's lock is exactly what it declared");
        assertEq(ledger.coverageUsdOf(address(govA), pid, g3), COVERAGE_USD, "and still prices the full coverage");
        assertEq(ledger.lockOf(address(govA), pid, g2), 0, "a released approver carries nothing");

        // 5. The lockout still binds — g3 genuinely cannot re-register, which is
        //    what made the original veto permanent. It no longer needs to.
        vm.warp(_lockoutStart(govA, pid) + 1);
        vm.prank(g3);
        vm.expectRevert(IGuardianRegistry.VoteChangeLockedOut.selector);
        registry.voteOnProposal(address(govA), pid, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max);

        // 6. The review resolves Approved (g2 never reached block quorum) — and
        //    this time the proposal EXECUTES rather than being bricked.
        _pastReview(govA, pid);
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed), "the veto no longer lands");
    }

    // ── 1. Full lifecycle: coverage accounting round-trips ────────────────

    /// @notice propose (bond locked, covered-TVL cap cleared) → guardian approves
    ///         (exposure booked, §3.3 cap checked) → execute (§3.3a quorum
    ///         covered by that same approver's LIVE bond) → settle →
    ///         `reclaimProposerBond` returns the WOOD → warp past
    ///         epoch + challengeWindow → `openExposure` back to zero.
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
        assertEq(ledger.openExposure(g1), 0, "no exposure before the vote");
        _vote(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposure(g1), COVERAGE_WOOD, "approve locks the declared coverage");
        assertLe(ledger.openExposure(g1), swood.guardianStake(g1), "locked within g1's stake");

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
        assertEq(ledger.openExposure(g1), COVERAGE_WOOD, "coverage stays locked through settle");

        // ── But not YET: the proposer self-settled an hour in, and an executed
        //    proposal holds its bond until nothing can still convict it. The
        //    bond is the one thing an early self-settle must not accelerate.
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        govA.reclaimProposerBond(pid);

        // ── Bond returns in full once the challenge window has run out from
        //    execution: settlement is not a conviction, it just is not proof of
        //    innocence on the hour either.
        // `+ strategyDuration` (second-audit finding A): the hold runs from the
        // end of the strategy's TERM, not from execution.
        vm.warp(govA.getProposal(pid).executedAt + govA.getProposal(pid).strategyDuration + ledger.challengeWindow());
        govA.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agentA), agentBalBefore, "bond refunded in full");
        assertEq(wood.balanceOf(address(escrow)), 0, "escrow drained");
        (, uint256 escrowed) = escrow.bondOf(address(govA), pid);
        assertEq(escrowed, 0);
        assertEq(govA.getProposal(pid).proposerBondWood, 0);

        // ── Budget recycles once the approval's bucket ages out: bucket `e`
        //    stops counting at genesis + (e+1)·L + W.
        vm.warp(vm.getBlockTimestamp() + EPOCH_LENGTH + ledger.challengeWindow() + 1);
        assertEq(ledger.openExposure(g1), 0, "epoch + challenge window elapsed => budget recycled");
    }

    /// @notice Issue #35, end-to-end: an accused approver cannot use a
    ///         post-execution top-up to restore the filing-bond basis a WOOD
    ///         price crash took away. Drives a REAL proposal through the real
    ///         governor, registry, and sWOOD stack -- no coverage-path mocks.
    ///
    ///         g1 approves with a $1,500 bond against a $1,000 need (reserves
    ///         the full $1,000). WOOD then crashes 2.5x ($0.05 -> $0.02),
    ///         dropping g1's LIVE bond to $600 -- below its reservation. g1
    ///         tops up post-execution by exactly enough WOOD to restore its
    ///         live bond to $1,000 at the crashed price. Under the OLD
    ///         (pre-issue-#35, always-live) basis that top-up would have fully
    ///         restored `liabilityUsd` to $1,000 -- capital the verdict slash,
    ///         anchored at `executedAt`, can never reach. The fix prices g1 at
    ///         its pre-top-up WOOD snapshot even at the crashed rate, so
    ///         `liabilityUsd` -- and the filing bond `ChallengeGame.file`
    ///         sizes from it -- stays at the pre-top-up figure.
    function test_n35_postExecutionTopUpCannotPriceUpItsOwnProsecution() public {
        uint256 pid = _propose(govA, address(vaultA), agentA);
        _openReview(govA, pid);
        // g1 locks its WHOLE stake (30,000 WOOD, $1,500), not merely the
        // $1,000 need: the lock is the first bound on what a conviction can
        // take, and a lock below the stake would make the anchor moot here
        // (`min(lock, basis)` would be the lock either side of the top-up).
        // The anchor is pinned on its own in `ExposureLedger.t.sol`.
        _voteLock(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        assertEq(ledger.openExposure(g1), WHALE_STAKE, "g1 locks its whole stake behind the proposal");

        _pastReview(govA, pid);
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed), "executed");

        // Advance time past the execute instant. Checkpoints are
        // timestamp-keyed: a top-up landing in the SAME timestamp as
        // `executedAt` would merge into that checkpoint instead of creating
        // a strictly-later one (same-second lookups are intentional
        // elsewhere in this codebase too), so the top-up below must be
        // pushed at a genuinely later instant to test the anchor at all.
        skip(1 hours);

        // WOOD crashes 2.5x: $0.05 -> $0.02. g1's live bond falls from $1,500
        // to $600 -- below its $1,000 reservation.
        woodFeed.setAnswer(0.02e8);
        assertEq(ledger.slashableBondUsd(g1), 600e18, "live bond crashed with the price");
        uint256 liabilityAfterCrash = ledger.liabilityUsd(address(govA), pid);
        assertEq(liabilityAfterCrash, 600e18, "filing-bond basis drops with the price");

        // g1 (the accused approver) tops up post-execution: at the crashed
        // price this exactly restores its LIVE bond to the $1,000 reservation.
        wood.mint(g1, 20_000e18);
        vm.startPrank(g1);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(20_000e18, 1);
        vm.stopPrank();
        assertEq(ledger.slashableBondUsd(g1), 1_000e18, "sanity: live bond IS fully restored by the top-up");

        // `liabilityUsd` is UNMOVED: the lock is 30,000 WOOD and the basis is
        // anchored at `executedAt`, so `min(lock, basis)` is the pre-top-up
        // 30,000 WOOD at the crashed price whichever bound is read - the
        // verdict slash can never reach the top-up tranche.
        assertEq(
            ledger.liabilityUsd(address(govA), pid),
            liabilityAfterCrash,
            "post-execution top-up cannot price up g1's own prosecution"
        );
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
        assertEq(ledger.openExposure(g1), COVERAGE_WOOD);

        // Drain #2 while #1 is still open: g1 declares the same 20,000 WOOD
        // again, and the ledger clamps it to the 10,000 of budget left.
        _vote(govB, pidB, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(
            ledger.openExposure(g1),
            swood.guardianStake(g1),
            "total locked exposure pinned at the stake, never 2x the drain"
        );
        assertEq(ledger.lockOf(address(govB), pidB, g1), WHALE_STAKE - COVERAGE_WOOD, "drain #2 got only the remainder");

        // #1 stays fully covered; #2 is short of the requirement — a nonzero
        // shortfall now SIZES (issue #27) rather than reverting outright, so
        // it returns the raised/required pair reflecting only the leftover
        // $500 of budget g1 had left to commit.
        ledger.requireApproveQuorum(address(govA), pidA, address(usdg), MAX_CAPITAL);
        (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd) =
            ledger.requireApproveQuorum(address(govB), pidB, address(usdg), MAX_CAPITAL);
        assertEq(coverageRaisedUsd, 500e18, "only g1's leftover budget backs drain #2");
        assertEq(requiredCoverageUsd, COVERAGE_USD);

        // Control: the shortfall was the SHARED budget, not drain #2 itself.
        // Release both bookings, re-approve #2, and it covers in full.
        _vote(govA, pidA, g1, IGuardianRegistry.GuardianVoteType.Block);
        _vote(govB, pidB, g1, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposure(g1), 0, "approve -> block releases both locks");
        _vote(govB, pidB, g1, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposure(g1), COVERAGE_WOOD, "drain #2 now fully covered");
        ledger.requireApproveQuorum(address(govB), pidB, address(usdg), MAX_CAPITAL);
    }

    // ── 3. Cold start: a thin cohort BLOCKS execution, it does not force it ──

    /// @notice Spec §3.3a cold-start. The guardian cohort collapses to a single
    ///         member before the review opens and nobody votes, so the review
    ///         auto-resolves NOT-blocked with ZERO approvers. The
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

        // Review closes with nobody having voted; it auto-resolves not-blocked.
        _pastReview(govA, pid);
        govA.resolveProposalState(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Approved), "not blocked => Approved");
        (bool opened, bool resolved, bool blocked) = registry.getReviewState(address(govA), pid);
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
        // Whole stake locked, so the coverage g1 raises IS its bond at the
        // live price - the quantity the crash below moves.
        _voteLock(govA, pid, g1, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
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

        // issue #27: the crashed-but-nonzero bond no longer blocks execution
        // outright — it SIZES it. $150 of $1,000 required is 15%, so the
        // proposal executes at 15% of its declared size rather than reverting.
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed), "executes at the scaled size");
        assertEq(govA.getEffectiveMaxCapital(pid), 150e6, "scaled to the crashed bond's $150 of $1,000 coverage");
    }

    // ── 5. The bounded (below-threshold) lane is genuinely preserved ───────

    /// @dev Certifies (adapter, poke) at tier 1 with a 1% extractable bound and
    ///      proposes against it. Returns the proposal id, asserting the tier-1
    ///      SIZING that both tests below share — sizing is unchanged by the ADR.
    function _proposeBoundedTier1() internal returns (uint256 pid) {
        govA.setTierRegistry(address(tierRegistry)); // test contract is the factory
        // Two-step certification (design.md / tasks.md 2.1): the test contract
        // IS the registry owner, so no prank is needed — propose, warp past
        // the pinned `readyAt` (`vm.getBlockTimestamp()`, never a cached
        // `block.timestamp` local — the optimizer CSEs it across `vm.warp`),
        // execute. `_propose` and every later window below reads live state
        // relative to this new baseline, so the forward shift is safe.
        // issue #166 (target-based batch callee gate, landed after this fixture
        // was written): the vault's outer callee check requires the adapter be
        // allowlisted independently of certification, or the batch never
        // reaches the tier-1 poke call at all.
        tierRegistry.setAdapterAllowed(address(adapter), true);
        tierRegistry.proposeCertification(
            address(adapter), adapter.poke.selector, 1, 100, address(0), address(adapter).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(address(adapter), adapter.poke.selector);
        // issue #166: certifying a (target, selector) prices it for tiering
        // but does NOT make `target` batch-callable at all — that is the
        // SEPARATE `isAdapterAllowed` allowlist `SyndicateVault._guardBatchCalls`
        // PART 2a now enforces on every batch callee. `adapter` (`NoopAdapter`)
        // is a benign, fund-neutral fixture, not an attacker probe — allowlist
        // it or `executeProposal` below is refused with `DisallowedBatchCallee`
        // before the bounded-tier coverage mechanics under test ever run.
        tierRegistry.setAdapterAllowed(address(adapter), true);

        pid = _propose(govA, address(vaultA), agentA, _adapterCalls(), _adapterCalls());
        assertEq(govA.getProposal(pid).envelopeTier, 1, "certified tier 1");
        // coverage = Σ(cap_i × bound_i) / 10_000. Only the exec leg declares a
        // cap here — the settle leg's is zero (see `_settleCalls`) — so the
        // certified 100 bps bites once, not twice.
        uint256 coverage = (MAX_CAPITAL * 100) / 10_000;
        assertEq(govA.getProposal(pid).requiredCoverage, coverage, "bounded coverage, not full notional");
        // The propose-time bond still applies, scaled to the smaller coverage.
        assertEq(
            govA.getProposal(pid).proposerBondWood,
            ledger.proposerBondWood(address(usdg), coverage),
            "risk-scaled bond still locked"
        );
    }

    /// @notice ADR 2026-07-27 REVERSED this test's original conclusion, and the
    ///         reversal is the whole point of the ADR. It used to assert that a
    ///         tier-1 proposal executes with ZERO approvers — the optimistic
    ///         lane below `quorumTierThreshold`, which the §4 gate-2 argument
    ///         leaned on. The ROE validation resolved that gate the other way:
    ///         the threshold is now 0, tier 1 is no longer below it, and the
    ///         quorum IS consulted.
    ///
    ///         Coverage SIZING is unchanged and still bounded (asserted in the
    ///         helper) — sizing was never the gap. ENFORCEMENT was: this exact
    ///         shape, a bounded-tier proposal with no covering approver, is what
    ///         used to execute unbacked.
    function test_boundedTierNowRequiresCoverage() public {
        uint256 pid = _proposeBoundedTier1();
        assertEq(ledger.quorumTierThreshold(), 0, "ADR 2026-07-27: every tier fail-closed");

        // Review runs with a healthy cohort and NOBODY approves.
        _openReview(govA, pid);
        _pastReview(govA, pid);
        (address[] memory approvers,,) = registry.getApproverWeights(address(govA), pid);
        assertEq(approvers.length, 0, "zero approvers");
        assertEq(ledger.openExposure(g1), 0, "no exposure booked anywhere");

        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Approved), "stays Approved, unexecuted");
        assertEq(adapter.pokes(), 0, "the batch never ran");
    }

    /// @notice The optimistic lane still EXISTS as a mechanism — it is simply no
    ///         longer reachable at the launch threshold. Raising the threshold
    ///         back above the proposal's tier restores it, which is what proves
    ///         the `>=` comparison is doing the work rather than the tier alone.
    ///         Kept so a future re-admission (v2, per the ADR) has a live test of
    ///         the knob rather than a re-derivation.
    function test_boundedTierExecutesOptimisticallyWhenThresholdRaised() public {
        uint256 pid = _proposeBoundedTier1();
        vm.prank(ledgerOwner);
        ledger.setQuorumTierThreshold(2); // the pre-ADR launch value

        _openReview(govA, pid);
        _pastReview(govA, pid);
        (address[] memory approvers,,) = registry.getApproverWeights(address(govA), pid);
        assertEq(approvers.length, 0, "zero approvers");

        govA.executeProposal(pid);
        assertEq(_state(govA, pid), uint256(ISyndicateGovernor.ProposalState.Executed), "bounded lane still executes");
        assertEq(adapter.pokes(), 1, "the batch really ran");
    }

    // ── 6. Declared coverage locks on the REVIEW path ─────────────────────

    /// @dev `GuardianRegistry._severityBps`, replicated: the quadratic ramp of
    ///      block-side decisiveness from the at-open quorum (floor) to the
    ///      supermajority (ceiling), in the same integer arithmetic.
    function _severity(uint256 bBps, uint256 qBps, uint256 lo, uint256 hi) internal pure returns (uint256) {
        uint256 supermajority = 6_667;
        if (qBps >= supermajority || bBps >= supermajority) return hi;
        if (bBps <= qBps) return lo;
        uint256 t = ((bBps - qBps) * 1e18) / (supermajority - qBps);
        return lo + ((hi - lo) * ((t * t) / 1e18)) / 1e18;
    }

    /// @dev Drives a review on `gov`/`pid` in which g1 approves with `lockWood`
    ///      and g2 + g3 block (40,000 of the 90,000 cohort: 4,444 bps, past the
    ///      3,000-bps quorum and short of the supermajority, so the severity
    ///      ramp lands strictly between the floor and the ceiling). Returns the
    ///      severity the registry will apply.
    function _blockedReview(SyndicateGovernor gov, uint256 pid, uint256 lockWood) internal returns (uint256 sev) {
        _openReview(gov, pid);
        uint256 openedAt = vm.getBlockTimestamp() - 1;
        _voteLock(gov, pid, g1, IGuardianRegistry.GuardianVoteType.Approve, lockWood);
        _vote(gov, pid, g2, IGuardianRegistry.GuardianVoteType.Block);
        _vote(gov, pid, g3, IGuardianRegistry.GuardianVoteType.Block);
        uint256 blockWeight = swood.getPastVotes(g2, openedAt) + swood.getPastVotes(g3, openedAt);
        uint256 total = swood.getPastTotalVotes(openedAt);
        uint256 bBps = (blockWeight * 10_000) / total;
        assertGe(bBps, BLOCK_QUORUM_BPS, "fixture: the block reaches quorum");
        assertLt(bBps, 6_667, "fixture: and stays under the supermajority");
        // The envelope the review is judged under is the one in force at open.
        sev = _severity(bBps, BLOCK_QUORUM_BPS, swood.minSlashBps(), swood.maxSlashBps());
        assertGt(sev, swood.minSlashBps(), "fixture: severity is strictly inside the envelope");
        assertLt(sev, swood.maxSlashBps());
    }

    /// @notice Task 6.4, review path: the block-decisiveness severity MULTIPLIES
    ///         the lock rate. g1 locks half its 30,000 stake (5,000 bps); a
    ///         mid-decisiveness block resolves at a severity strictly inside the
    ///         envelope; the burn is `stake x ceil(5,000 x severity / 10,000)`
    ///         — less than the lock (the severity discounts it) and more than
    ///         the floor (the envelope does not bind), so neither bound could
    ///         have produced the number on its own.
    function test_reviewSlash_severityMultipliesTheLockRate() public {
        uint256 pid = _propose(govA, address(vaultA), agentA);
        uint256 lock = WHALE_STAKE / 2; // 15,000 WOOD: 5,000 bps of the 30,000 stake
        uint256 sev = _blockedReview(govA, pid, lock);
        assertEq(ledger.lockOf(address(govA), pid, g1), lock, "g1 locked half its stake");

        _pastReview(govA, pid);
        assertTrue(registry.resolveReview(address(govA), pid), "blocked");

        uint256 lockBps = 5_000;
        uint256 bps = (lockBps * sev + 10_000 - 1) / 10_000; // ceil, as the registry does
        bps = bps < swood.minSlashBps() ? swood.minSlashBps() : bps;
        uint256 burn = (WHALE_STAKE * bps) / 10_000;
        assertEq(swood.guardianStake(g1), WHALE_STAKE - burn, "burned lock rate x severity of the at-open basis");
        assertLt(burn, lock, "the severity discounts the lock: less than the whole lock burns...");
        assertGt(burn, (WHALE_STAKE * swood.minSlashBps()) / 10_000, "...and more than the bare floor");
        assertEq(swood.guardianStake(g2), FILLER_STAKE, "blockers untouched");
        assertEq(swood.guardianStake(g3), FILLER_STAKE);
    }

    /// @notice Spec scenarios "Negligible declaration still pays the floor" and
    ///         "Owner cannot raise the floor on a decided review". g1 locks ONE
    ///         WEI: its lock rate rounds up to 1 bps, the severity leaves it at
    ///         1 bps, and the envelope floors it at the `minSlashBps` in force
    ///         AT OPEN — 1,000 bps of the whole bond, a real penalty for a token
    ///         declaration. The owner raising the floor to 5,000 after the
    ///         review opened changes nothing about it; a review opened after the
    ///         raise is floored at 5,000.
    function test_reviewSlash_tokenLockPaysTheAtOpenFloor_ownerCannotRaiseItMidReview() public {
        uint256 pid = _propose(govA, address(vaultA), agentA);
        _blockedReview(govA, pid, 1);
        assertEq(ledger.lockOf(address(govA), pid, g1), 1, "a 1-wei lock");
        (, uint256[] memory rate) = ledger.slashBpsFor(address(govA), pid);
        assertEq(rate[0], 1, "which rounds up to 1 bps");

        // The owner raises the floor AFTER the review opened and the votes are in.
        assertEq(swood.minSlashBps(), 1_000, "fixture floor at open");
        vm.prank(owner);
        swood.setMinSlashBps(5_000);

        _pastReview(govA, pid);
        assertTrue(registry.resolveReview(address(govA), pid), "blocked");
        uint256 atOpenFloorBurn = (WHALE_STAKE * 1_000) / 10_000;
        assertEq(swood.guardianStake(g1), WHALE_STAKE - atOpenFloorBurn, "floored at the AT-OPEN 1,000 bps, not 5,000");
        assertEq(atOpenFloorBurn, 3_000e18, "a token lock still costs 10% of the whole bond");

        // Control: a review opened AFTER the raise is judged under the new floor.
        uint256 stakeNow = swood.guardianStake(g1);
        uint256 pidB = _propose(govB, address(vaultB), agentB);
        _blockedReview(govB, pidB, 1);
        _pastReview(govB, pidB);
        assertTrue(registry.resolveReview(address(govB), pidB), "blocked");
        assertEq(
            swood.guardianStake(g1),
            stakeNow - (stakeNow * 5_000) / 10_000,
            "the raise applies to reviews opened afterwards"
        );
    }

    /// @dev SHE-215: `SyndicateGovernor.propose` / `executeProposal` now refuse
    ///      a vault whose owner-stake slot is unbound, claimed, slashed, or
    ///      exiting. `SyndicateFactory.createSyndicate` ALWAYS binds that slot,
    ///      so a hand-built syndicate that skips it models a vault the real
    ///      factory cannot produce. Binding here restores the fixture to a
    ///      state the protocol can actually reach.
    function _bondVaultOwner(address vault_) internal {
        uint256 bond = swood.minOwnerStake();
        wood.mint(owner, bond);
        vm.startPrank(owner);
        wood.approve(address(swood), bond);
        swood.prepareOwnerStake(bond);
        vm.stopPrank();
        // The test contract is sWOOD's factory.
        swood.bindOwnerStake(owner, vault_);
    }
}
