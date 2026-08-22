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
import {TierRegistry} from "../src/TierRegistry.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ITokenCourt} from "../src/interfaces/ITokenCourt.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockWoodTwapOracle} from "./mocks/MockWoodTwapOracle.sol";
import {GovEnvelope} from "./helpers/GovEnvelope.sol";
import {deployTierRegistry} from "./helpers/TierRegistryFixture.sol";

/// @dev Chainlink-shaped USD feed for the vault asset. Mirrors
///      `ChallengeEndToEndTest`'s own `ChallengeE2EFeed`.
contract TCE2EFeed {
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

/// @dev A real adapter with two entrypoints, neither a value-moving ERC20
///      selector, so the exec batch clears `_guardBatchCalls` without an
///      adapter allowlist entry -- mirrors `ChallengeE2EAdapter`.
contract TCE2EAdapter {
    uint256 public pokes;
    uint256 public bumps;

    function poke() external {
        pokes++;
    }

    function bump() external {
        bumps++;
    }
}

/// @title TokenCourtEndToEndTest
/// @notice Task 9 -- the whole `ChallengeGame` + `TokenCourt` PAIR proven
///         TOGETHER on the real stack. `ChallengeGame.t.sol` and
///         `TokenCourt.t.sol` each cover their own side thoroughly against
///         mocks; neither ever exercises the seam where `dispute`'s
///         auto-referral actually calls into a real `TokenCourt`, a real
///         `TokenCourt.finalize` actually calls back into a real
///         `ChallengeGame.rule`, and a real `StakedWood` supplies the votes on
///         both sides of that call. These five arcs are that proof.
/// @dev    WHAT THIS FILE DELIBERATELY DOES NOT PROVE: that the electorate is
///         weighed on AGED stake while the accused sum uses RAW stake (review
///         F17). `setUp` matures the whole cohort to par, so the two bases are
///         numerically identical here and no assertion can separate them --
///         swapping `getPastStake` for `getPastVotes` in `_recordAccused`
///         survives every arc below. Separating them would need a partially
///         matured accused plus turnout tuned into the narrow band between the
///         two resulting floors, a knife-edge fixture that arcs 1-3 all depend
///         on and would each have to be re-tuned around. It is left to
///         `TokenCourt.t.sol`, where four tests kill that mutation against
///         `MockStakedWood`. Recorded rather than chased, so the gap is a
///         decision and not a discovery.
/// @dev    Fixture arithmetic mirrors `ChallengeEndToEndTest` exactly -- same
///         proposal, same tier pricing, same coverage and bond sizing --
///         because reusing a proven fixture keeps this file about the
///         game/court seam rather than re-litigating proposal economics.
///         Two deliberate simplifications relative to that fixture:
///           - Only ONE LP deposit, not two-plus-a-buyer. It exists solely to
///             keep `CompensationEscrow.openCase`'s `EmptySnapshot` guard from
///             firing (a case cannot open against a zero-supply snapshot);
///             the pre/post-drain LP split itself is `ChallengeEndToEndTest`'s
///             territory (§3.8), not this file's.
///           - Two more guardians, `g2` and `g3`, staked but never approving
///             THIS proposal. They are the court's non-accused electorate --
///             `g1` is the sole accused, so a single non-accused vote already
///             clears `participationFloorBps`'s default 10% floor
///             (`(70k - 30k) * 10% == 4k`, against `g2`'s 20k of aged weight).
contract TokenCourtEndToEndTest is Test {
    // ── Real stack ──
    ERC20Mock public usdg; // vault asset, 6-dec, $1.00
    ERC20Mock public wood; // stake + bond token, 18-dec
    BatchExecutorLib public executorLib;
    MockAgentRegistry public agentRegistry;
    ProtocolConfig public protocolConfig;
    TCE2EFeed public feed;
    TCE2EAdapter public adapter;

    StakedWood public swood;
    GuardianRegistry public registry;
    ExposureLedger public ledger;
    TierRegistry public tierRegistry;
    ProposerBondEscrow public bondEscrow;
    ChallengeGame public game;
    TokenCourt public court;

    SyndicateVault public vault;
    SyndicateGovernor public gov;

    address public owner = makeAddr("owner");
    address public ledgerOwner = makeAddr("ledgerOwner");
    address public backstop = makeAddr("backstop");
    address public agent = makeAddr("agent");
    address public challenger = makeAddr("challenger");
    address public challengerB = makeAddr("challengerB");
    address public stranger = makeAddr("stranger");

    address public g1 = makeAddr("guardian1"); // the covering approver -- the court's sole accused
    address public g2 = makeAddr("guardian2"); // non-accused voter
    address public g3 = makeAddr("guardian3"); // non-accused voter
    address public g4 = makeAddr("guardian4"); // stakes AFTER execution -- must carry zero weight at the snapshot

    address public lp1 = makeAddr("lp1"); // keeps the escrow's pre-drain snapshot non-empty

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 45 days;
    uint256 constant EPOCH_LENGTH = 28 days;
    uint256 constant MATURATION = 30 days;

    uint256 constant G1_STAKE = 30_000e18; // $1,500 of slashable bond
    uint256 constant FILLER_STAKE = 20_000e18; // g2/g3, over MIN_GUARDIAN_STAKE and enough to clear the court's floor

    uint256 constant LP1_ASSETS = 70_000e6;

    uint256 constant MAX_CAPITAL = 500e6;
    /// @dev Issue #43 per-call caps: `_execCalls()` has 2 calls (`poke`
    ///      certified at CERTIFIED_BOUND_BPS, `bump` uncertified) and the
    ///      test-fixture default (`GovEnvelope.defaultCaps`) caps only the
    ///      FIRST call — `poke` gets `maxCapital`, `bump` gets 0 (a zero cap
    ///      is a legal declaration at every tier: "this call moves no vault
    ///      asset"). `requiredCoverage` = (maxCapital * 5_000/10_000) [exec
    ///      poke] + 0 [exec bump, zero cap] + (maxCapital * 5_000/10_000)
    ///      [settle poke, default cap = maxCapital] = maxCapital = 500e6 —
    ///      see `ChallengeEndToEndTest`'s identical constant for the full
    ///      derivation.
    uint256 constant REQUIRED_COVERAGE = 500e6;
    uint256 constant COVERAGE_USD = 500e18;

    uint16 constant CERTIFIED_BOUND_BPS = 5_000;

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(owner);
        adapter = new TCE2EAdapter();
        tierRegistry = new TierRegistry(address(this));

        // ── sWOOD (sole WOOD custodian). The test contract is the factory.
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
                    maxSlashBps: 10_000,
                    ageFloorBps: 2500,
                    maturationPeriod: MATURATION
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        // ── Real guardian registry with a real review window.
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

        // ── Real vault + real governor; the test contract is their factory.
        _deploySyndicate();
        registry.addGovernor(address(gov), address(vault));
        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vault)), abi.encode(address(gov))
        );
        uint256 agentId = agentRegistry.mint(agent);
        vm.prank(owner);
        vault.registerAgent(agentId, agent);

        // ── Guardian cohort: g1 the eventual approver/accused, g2/g3 the
        //    court's non-accused electorate. All matured to par.
        _stakeGuardian(g1, G1_STAKE, 1);
        _stakeGuardian(g2, FILLER_STAKE, 2);
        _stakeGuardian(g3, FILLER_STAKE, 3);
        skip(MATURATION);
        vm.warp(vm.getBlockTimestamp() + 1);

        // ── Ledger deployed after maturation so epoch genesis and feed
        //    freshness are current.
        ledger = new ExposureLedger(ledgerOwner, address(swood), EPOCH_LENGTH);
        feed = new TCE2EFeed(1e8, 8); // $1.00, 8-dec
        // Design revision 2: `woodUsdPriceX8` is a CAP, never a price. WOOD is
        // valued from the TWAP oracle at $0.05, with the cap 2x ABOVE it and
        // therefore NOT binding — the configuration production ships.
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

        bondEscrow = new ProposerBondEscrow(address(wood), address(registry), address(ledger));

        // ── The game and the court, then their roles.
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));
        court = new TokenCourt(owner);
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(game));
        tierRegistry.setAuthorizedDemoter(address(game));
        vm.startPrank(owner);
        swood.setAuthorizedSlasher(address(game));
        game.setStakedWood(address(swood));
        court.setChallengeGame(address(game));
        court.setStakedWood(address(swood));
        game.setCourt(address(court));
        vm.stopPrank();

        // ── Governor wiring (the test contract is the factory).
        gov.setExposureLedger(address(ledger));
        gov.setBondEscrow(address(bondEscrow));
        gov.setTierRegistry(address(tierRegistry));

        // Certification a passed challenge will revoke; `bump` stays
        // uncertified so the exec batch as a whole is still tier 2.
        //
        // Two-step certification (design.md / tasks.md 2.1): the test contract
        // IS the registry owner, so no prank is needed — propose, warp past
        // the pinned `readyAt` (`vm.getBlockTimestamp()`, never a cached
        // `block.timestamp` local — the optimizer CSEs it across `vm.warp`),
        // execute. Every later warp in this suite reads live state
        // (`vm.getBlockTimestamp() + X` or a value computed from
        // in-test-live `filedAt`/`referredAt`), so this setUp-time shift is safe.
        tierRegistry.proposeCertification(
            address(adapter), adapter.poke.selector, 1, CERTIFIED_BOUND_BPS, address(0), address(adapter).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(address(adapter), adapter.poke.selector);
        // issue #166: certifying a (target, selector) prices it for tiering
        // but does NOT make `target` batch-callable at all — that is a
        // SEPARATE allowlist (`isAdapterAllowed`) `SyndicateVault._guardBatchCalls`
        // PART 2a now enforces on every batch callee. `adapter` is this
        // suite's real, benign (fund-neutral) production-shaped adapter, not
        // an attacker probe — it must be explicitly allowlisted here or every
        // proposal touching it (execute AND settlement calls) is refused with
        // `DisallowedBatchCallee` before any challenge/court mechanics run.
        tierRegistry.setAdapterAllowed(address(adapter), true);

        // ── WOOD for the proposer's bond, both challengers' bonds, and g1's
        //    counter-bond pool contributions (sized generously: some arcs have
        //    g1 fund TWO pools in the same test).
        wood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        wood.approve(address(bondEscrow), type(uint256).max);
        wood.mint(challenger, _challengerBond() * 5);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
        wood.mint(challengerB, _challengerBond() * 5);
        vm.prank(challengerB);
        wood.approve(address(game), type(uint256).max);
        wood.mint(g1, _challengerBond() * 5);
        vm.prank(g1);
        wood.approve(address(game), type(uint256).max);

        // ── One LP, so the escrow's pre-drain snapshot is never empty.
        _deposit(lp1, LP1_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    // ── Fixture helpers ───────────────────────────────────────────────────

    function _deploySyndicate() internal {
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
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(registry),
                address(protocolConfig),
                address(this),
                address(deployTierRegistry(address(this))), // factory
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

    function _deposit(address who, uint256 assets) internal {
        usdg.mint(who, assets);
        vm.startPrank(who);
        usdg.approve(address(vault), assets);
        vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// @dev Mirrors `ChallengeGame.file`'s bond formula exactly, and reads
    ///      `challengerBondBps` LIVE off the contract rather than hardcoding
    ///      it — audit #181 finding 18a moved it from 500 to 150. Mirrors
    ///      `ChallengeGame.t.sol`'s own `_expectedBondWood` / `_standardBondWood`
    ///      helpers and `ChallengeEndToEndTest`'s identical `_challengerBond`.
    function _challengerBond() internal view returns (uint256) {
        return (((COVERAGE_USD * game.challengerBondBps()) / 10_000) * 1e8) / 0.05e8;
    }

    /// @dev Exec batch: the certified adapter call plus an uncertified one, so
    ///      the envelope resolves to tier 2 and the coverage quorum engages.
    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.poke, ()), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.bump, ()), value: 0});
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.poke, ()), value: 0});
    }

    function _propose() internal returns (uint256) {
        vm.prank(agent);
        return gov.propose(
            address(vault),
            address(0),
            "ipfs://token-court-e2e",
            7 days,
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
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @dev propose -> review opens -> g1 approves (coverage committed) ->
    ///      execute. The identical real lifecycle `ChallengeEndToEndTest` uses;
    ///      every arc below starts from a freshly executed proposal this
    ///      produces.
    function _proposeApproveExecute() internal returns (uint256 pid) {
        pid = _propose();
        assertEq(gov.getProposal(pid).envelopeTier, 2, "uncertified call in the batch => tier 2");
        assertEq(gov.getProposal(pid).requiredCoverage, REQUIRED_COVERAGE, "half-notional + full-notional + settle");

        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "g1 backs the whole coverage");

        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
        assertEq(gov.getProposal(pid).executedAt, vm.getBlockTimestamp(), "executedAt stamped now");
    }

    /// @dev g1 is the sole accused approver, so it alone can complete the
    ///      counter-bond pool. With the court wired, completing the pool also
    ///      fires the pool-completing auto-referral (Task 8) in this same call.
    function _disputeFull(uint256 challengeId) internal {
        vm.prank(g1);
        game.dispute(challengeId, type(uint256).max);
    }

    function _warpPastVoteWindow(uint256 caseId) internal {
        ITokenCourt.Case memory c = court.caseOf(caseId);
        vm.warp(c.referredAt + c.voteWindowAtReferral + 1);
    }

    /// @dev The bps g1 is actually priced at by the REAL ledger right now.
    ///      THIS IS A CROSS-CHECK, NOT A SUBSTITUTE for a pinned literal: arc 1
    ///      also asserts `expectedBps == 6667` directly, and THAT literal is
    ///      what catches a wrong rate (a mutated `slashBpsFor` that, say,
    ///      halves its output would still satisfy every assertion phrased only
    ///      in terms of this helper's own live return value -- reading the
    ///      answer from the same function under test proves nothing about
    ///      whether that answer is correct). The live read's job is narrower:
    ///      it keeps the literal in step with the fixture if the coverage or
    ///      the haircut price ever changes, so this helper and the pinned
    ///      constant are re-derived from the same real contract call rather
    ///      than drifting apart silently.
    function _g1SlashBpsFor(uint256 pid) internal view returns (uint256) {
        (address[] memory approvers, uint256[] memory bps) = ledger.slashBpsFor(address(gov), pid);
        for (uint256 i = 0; i < approvers.length; i++) {
            if (approvers[i] == g1) return bps[i];
        }
        return 0;
    }

    // ── 1. Guilty: the accused is slashed, the challenger is paid, the adapter demoted ──

    /// @notice The court's `Guilty` ruling must reach every one of the same
    ///         consequences the silence verdict already proves in
    ///         `ChallengeEndToEndTest` -- a real slash, a real bond-plus-pool
    ///         payout, a real adapter demotion, a real compensation case -- but
    ///         reached through the DISPUTED path instead: a real counter-bond
    ///         pool completing (which auto-refers to a real `TokenCourt`), a
    ///         real snapshot-weighted vote, and `finalize` delivering the
    ///         verdict back to the game through `rule`. Nothing on either side
    ///         of that call is a mock.
    function test_arc_guiltyVerdict_slashesAndPaysChallenger() public {
        uint256 pid = _proposeApproveExecute();
        // sWOOD's OWN balance, not the burn address: the burn address also
        // receives challenger-bond burns (settle/forfeit/inconclusive), so a
        // delta measured there conflates two sinks. Only a slash moves WOOD out
        // of the custodian.
        uint256 swoodBalBefore = wood.balanceOf(address(swood));
        // g4 stakes AFTER the proposal already executed -- on the far side of
        // the instant `snapshotTs` (`executedAt - 1`) pins the electorate to.
        //
        _stakeGuardian(g4, FILLER_STAKE, 4);
        // THE WARP IS LOAD-BEARING, and its POSITION is the whole point. g4
        // stakes on the same second the proposal executed; the warp then
        // separates that instant from the referral. That puts g4's stake
        // BETWEEN the two candidate snapshots: `executedAt - 1` (correct --
        // g4 is weightless) and `block.timestamp - 1` read at referral time
        // (wrong -- g4 would count). Without the separation both formulas
        // land on the same second, g4 reads as weightless under either, and
        // the assertions below pass for the wrong reason -- verified by
        // mutation: anchoring the snapshot at the referral survives this arc
        // when the warp precedes the stake, and dies when it follows it.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 expectedBps = _g1SlashBpsFor(pid);
        // PINNED LITERAL (not derived from the same function under test): the
        // rate is PUNITIVE, so a committed approver prices at the ceiling
        // whatever it underwrote. This used to read 6,667 — g1's $1,000 of
        // coverage against a $1,500 slashable bond, ceil(1_000 * 10_000 /
        // 1_500) — and that arithmetic is precisely what the burn retired. The
        // literal still does the real work: a mutated `slashBpsFor` returning
        // anything else fails HERE, not only downstream where it would agree
        // with itself.
        assertEq(expectedBps, 10_000, "punitive: the severity ceiling, not a share of the loss");

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/guilty"
        );

        _disputeFull(cid); // g1 funds the whole pool -> Disputed -> auto-refers
        uint256 caseId = court.caseOfChallenge(address(game), cid);
        assertTrue(caseId != 0, "the pool-completing auto-referral landed a real case");
        assertEq(uint256(court.caseOf(caseId).phase), uint256(ITokenCourt.Phase.Voting));

        // D2, proven on the real stack rather than only against
        // MockStakedWood (see TokenCourt.t.sol): g4's stake exists only AFTER
        // `executedAt`, strictly after the pinned `snapshotTs` -- so it must
        // carry zero weight and must not be able to vote at all.
        assertEq(
            swood.getPastVotes(g4, court.caseOf(caseId).snapshotTs),
            0,
            "stake acquired after the drain carries no weight"
        );
        vm.prank(g4);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(caseId, true);

        vm.prank(g2);
        court.vote(caseId, true); // guilty; g2 alone clears the participation floor

        _warpPastVoteWindow(caseId);
        // Captured HERE, not at the top of the test: g4 staked `FILLER_STAKE`
        // into sWOOD partway through, so an earlier baseline would net that
        // inflow against the slash and understate it.
        uint256 swoodBalPreSlash = wood.balanceOf(address(swood));
        // Read while the bond is still escrowed: conviction forfeits it, and
        // the prosecutor's fee is a slice of exactly this amount.
        (, uint256 proposerBond) = bondEscrow.bondOf(address(gov), pid);
        court.finalize(caseId);

        // ── The verdict landed on the REAL game.
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled");
        assertEq(uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.Guilty));

        // ── The accused's REAL staked WOOD was really slashed, at exactly what
        //    the ledger priced its liability at.
        uint256 slashedGross = (G1_STAKE * expectedBps) / 10_000;
        assertEq(swood.guardianStake(g1), G1_STAKE - slashedGross, "g1 paid exactly what it owed");

        // ── The challenger is repaid its bond plus the forfeited pool NET OF
        //    the settle-slice burn (issue #181 finding 18b), plus the
        //    prosecutor's fee. THE SLASH ITSELF PAYS NO ONE: every wei of it
        //    burns. The fee comes from the convicted proposer's forfeited bond
        //    instead, which is the one pot a prosecutor cannot fund for itself
        //    — so even an escalated win here is paid by the accused proposer,
        //    never out of the guardians' slash.
        //
        //    THE POOL DOES NOT RETURN AT ALL: `dispute` is open to anyone, so a
        //    challenger who also funds the counter-bond pool (directly, or via a
        //    second address) used to round-trip its whole stake on exactly this
        //    branch, forfeiting nothing. Burning a `settleBurnBpsAtFiling` slice
        //    of the pool made that a ~5% deposit rather than a cost; the pool is
        //    now destroyed in full, so the round trip loses it outright.
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        uint256 prosecutorFee = (proposerBond * game.prosecutorFeeBps()) / 10_000;
        assertGt(prosecutorFee, 0, "the fee is live in this fixture");
        // The slice comes off the CHALLENGER'S BOND on both settle branches now,
        // not off the pool -- an identical amount while a complete pool equals
        // the bond, but a different pot, and the pot is what this test is about.
        uint256 settleBurned = (c.bondWood * c.settleBurnBpsAtFiling) / 10_000;
        assertGt(settleBurned, 0, "sanity: the default settleBurnBps actually burns something on this branch now");
        // BURN MODEL (pashov 2026-08 finding #10). The counter-bond pool no
        // longer forfeits TO the challenger on conviction -- it is burned. The
        // challenger recovers its own bond net of the settle slice, plus the
        // prosecutor's cut of the proposer bond, and nothing from the pool.
        //
        // The self-dealing round trip this comment block is about is closed
        // HARDER by that, not softer: funding your own pool through a second
        // address now loses the pool outright instead of returning it net of a
        // slice. See test_rule_selfFilingCohortRecoversNothingFromTheBurnedPool.
        //
        // `challengerBalBefore` IS READ BEFORE `file`, so the bond OUTFLOW is
        // inside this measurement and the bond's return cancels it exactly.
        // What is left over the starting balance is therefore the fee less the
        // slice -- adding `c.bondWood` here counts the bond a second time and
        // was what made this assertion expect 912.5 against an actual 762.5.
        assertEq(
            wood.balanceOf(challenger),
            challengerBalBefore - settleBurned + prosecutorFee,
            "own bond net of the settle-slice burn, plus the prosecutor's cut -- the pool is burned, not paid out"
        );

        // ── The named adapter lost its certification (D7).
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 2, "demoted to the arbitrary-calldata default");
        assertEq(boundAfter, 10_000, "and to full notional");

        // ── A real compensation case opened in the escrow, funded with the
        //    slash NET of the conviction bounty paid out above (spec 2026-07-29
        //    §2: the bounty comes off the top before the escrow ever sees the
        //    proceeds, so victims' claimable total is smaller by exactly what
        //    the challenger was just paid).
        assertEq(
            swoodBalPreSlash - wood.balanceOf(address(swood)),
            slashedGross,
            "the whole slash left the custodian: bounty to the challenger, remainder burned"
        );
        assertEq(swood.pendingBurn(), 0, "and the burn transfer landed rather than parking");

        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
    }

    // ── 2. Not guilty: the challenger's bond forfeits to the defenders it bought ──

    /// @notice The mirror of arc 1: the electorate acquits, so the court's
    ///         `NotGuilty` ruling routes into the SAME path the game's own
    ///         `disputeTimeout` takes (`_fail`) -- the challenger's bond is
    ///         forfeited, the burn slice is taken off the top at the pinned
    ///         rate, and the remainder reaches the funder that actually bought
    ///         the defence through the real pull-payment accounting
    ///         (`claimableContribution`/`claimContribution`). The accused is
    ///         never touched: an acquittal, real or by timeout, leaves no mark.
    /// @dev    WHAT THIS ARC DOES NOT PROVE: contribution-keyed splitting
    ///         (PR #50 -- forfeit follows what each accused approver actually
    ///         paid into the pool, not its coverage share) is untestable here,
    ///         because this fixture's court electorate design makes g1 the
    ///         SOLE approver of the challenged proposal, so it is necessarily
    ///         also the sole possible contributor: its contribution share and
    ///         its coverage share are numerically identical, and no amount of
    ///         arithmetic on a single-contributor pool can tell the two keying
    ///         schemes apart. Restructuring this fixture to add a second
    ///         approver would collide with the court's own electorate design
    ///         (a second approver is also an accused non-voter, which changes
    ///         `accusedWeight` and the participation floor arc 1/3 depend on),
    ///         so this arc instead proves what IS available on the real stack
    ///         -- the forfeit reaches the real funder through the real pull
    ///         path, at the pinned burn rate, and the accounting balances to
    ///         the wei -- and leaves the free-rider/sybil-split distinction to
    ///         `test/ChallengeGame.t.sol`'s `test_resolve_forfeitIsProRataToContributionAndLeavesNoDust`,
    ///         `test_resolve_honestSoleDefenderKeepsEightyPercentOfTheForfeit`,
    ///         `test_selfChallenge_roundTripCostsExactlyTheBurn` and
    ///         `test_selfChallenge_twoAddressOperatorPaysTheSameBurn`, which
    ///         exercise multi-contributor pools directly against the game.
    function test_arc_notGuilty_forfeitsToDefenders() public {
        uint256 pid = _proposeApproveExecute();
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        // sWOOD's OWN balance, not the burn address: the burn address also
        // receives challenger-bond burns (settle/forfeit/inconclusive), so a
        // delta measured there conflates two sinks. Only a slash moves WOOD out
        // of the custodian.
        uint256 swoodBalBefore = wood.balanceOf(address(swood));

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.ProposerLinkedOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/not-guilty"
        );

        _disputeFull(cid);
        uint256 caseId = court.caseOfChallenge(address(game), cid);
        assertTrue(caseId != 0);

        vm.prank(g2);
        court.vote(caseId, false); // not guilty

        _warpPastVoteWindow(caseId);
        court.finalize(caseId);

        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Failed), "Failed");
        assertEq(uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.NotGuilty));

        // ── The challenger's bond is gone outright -- no refund on a failed challenge.
        assertEq(wood.balanceOf(challenger), challengerBalBefore - _challengerBond(), "the bond forfeited");

        // ── g1 funded the whole pool alone, so `claimContribution` gives it
        //    its stake back plus its whole (burn-adjusted) pro-rata slice.
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        // PINNED, not merely "greater than zero": at the default 20%
        // `forfeitBurnBps`, g1's payout is exactly 80% of the bond. A
        // zeroed-out burn rate would still clear `assertGt(..., 0)`, so the
        // literal is what actually pins the rate rather than merely its sign.
        assertEq(c.forfeitPayoutWood, (_challengerBond() * 8_000) / 10_000, "80% of the bond, net of the 20% burn");
        uint256 expectedClaim = c.counterBondWood + c.forfeitPayoutWood;
        assertEq(game.claimableContribution(cid, g1), expectedClaim);
        uint256 g1BalBeforeClaim = wood.balanceOf(g1);
        vm.prank(g1);
        uint256 got = game.claimContribution(cid);
        assertEq(got, expectedClaim);
        assertEq(wood.balanceOf(g1), g1BalBeforeClaim + expectedClaim, "the WOOD actually moved");

        // ── The accused was NEVER slashed -- an acquittal marks nothing.
        assertEq(swood.guardianStake(g1), G1_STAKE, "g1's stake is untouched");
        assertEq(wood.balanceOf(address(swood)), swoodBalBefore, "and no WOOD left the custodian");
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 1, "the adapter keeps its certification");
        assertEq(boundAfter, CERTIFIED_BOUND_BPS);

        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
    }

    // ── 3. Inconclusive: a thin vote unwinds both sides and marks nobody ──

    /// @notice D6's anti-capture participation floor doing its job: turnout
    ///         that never clears it -- here, turnout of exactly ZERO -- must
    ///         not be read as an answer in either direction. Both sides unwind
    ///         whole and no conviction is recorded. The property that actually
    ///         distinguishes this from an acquittal is proved directly, not
    ///         inferred: the SAME proposal stays challengeable, because
    ///         nothing here ever collected its one liability.
    function test_arc_inconclusive_unwindsAndAllowsRefiling() public {
        uint256 pid = _proposeApproveExecute();
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        // sWOOD's OWN balance, not the burn address: the burn address also
        // receives challenger-bond burns (settle/forfeit/inconclusive), so a
        // delta measured there conflates two sinks. Only a slash moves WOOD out
        // of the custodian.
        uint256 swoodBalBefore = wood.balanceOf(address(swood));

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.DrawdownBreach,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/inconclusive"
        );

        _disputeFull(cid);
        uint256 caseId = court.caseOfChallenge(address(game), cid);
        assertTrue(caseId != 0);

        // Nobody votes: turnout is zero, which `finalize` reads as
        // `Inconclusive` unconditionally, regardless of the floor's value.
        _warpPastVoteWindow(caseId);
        court.finalize(caseId);

        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Inconclusive), "Inconclusive");
        assertEq(uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.Inconclusive));

        // ── The challenger's bond returns minus the round-1 ENTRY-TIER burn
        //    on THIS filing specifically (issue #181 finding 19, superseding
        //    the 2026-07-30 "round 1 is free" decision): it is this
        //    proposal's first-ever challenge, and round 1 of the escalating
        //    schedule is now priced at `INCONCLUSIVE_BURN_ROUND1_BPS` (250
        //    bps) rather than 0 -- a free first unwind let anyone pin every
        //    accused approver's stake for free, repeatably, so no attempt is
        //    ever free anymore. A SECOND Inconclusive round against the SAME
        //    proposal would escalate further (see `ChallengeGame.t.sol`'s
        //    `test_inconclusive_escalationSchedule` for the full ladder);
        //    this arc test covers the single-round happy path only. The burn
        //    is derived from the challenge's own pinned rate rather than
        //    hardcoded, so this survives a future schedule change.
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(c.inconclusiveBurnBpsAtFiling, 250, "round 1 against a fresh proposal pins the entry tier");
        uint256 round1Burned = (c.bondWood * c.inconclusiveBurnBpsAtFiling) / 10_000;
        assertEq(
            wood.balanceOf(challenger),
            challengerBalBefore - round1Burned,
            "the bond came back minus the round-1 entry-tier burn"
        );

        // ── g1 collects EXACTLY its stake back -- no winnings, nothing was won.
        assertEq(game.claimableContribution(cid, g1), c.counterBondWood, "stake only, no forfeit to split");
        uint256 g1BalBeforeClaim = wood.balanceOf(g1);
        vm.prank(g1);
        uint256 got = game.claimContribution(cid);
        assertEq(got, c.counterBondWood);
        assertEq(wood.balanceOf(g1), g1BalBeforeClaim + c.counterBondWood);

        // ── Coverage unfroze, and NO conviction mark was left anywhere.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen");
        assertEq(swood.guardianStake(g1), G1_STAKE, "never slashed");
        assertEq(wood.balanceOf(address(swood)), swoodBalBefore, "and no WOOD left the custodian");

        // ── The proof that nothing was marked: the SAME challenger can file a
        //    FRESH challenge against the SAME proposal, and it is accepted.
        vm.prank(challenger);
        uint256 cid2 = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.DrawdownBreach,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/refiled"
        );
        assertEq(cid2, 2, "a fresh challenge id, not a revert");
        assertEq(game.liveChallengeOf(address(gov), pid), cid2, "and it is the live one");

        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
    }

    // ── 4. The E1 timeout race, both directions ──

    /// @notice Review finding E1, proven in both directions on the real
    ///         contracts. A disputed challenge has TWO independent clocks
    ///         racing to end it -- the court's vote/finalize path, and the
    ///         game's own permissionless `disputeTimeout` -- and the pair must
    ///         agree on a single winner regardless of which one gets there
    ///         first.
    /// @dev    (a) THE COURT WINS: once `finalize` has delivered a verdict,
    ///         the challenge is terminal, and the game's own `resolve` must
    ///         find nothing left to do (`WrongStatus`) rather than re-resolve
    ///         an already-decided case.
    /// @dev    (b) THE CLOCK WINS: `refer`'s clock check (see
    ///         `test_refer_clockCheckBoundary`, test/TokenCourt.t.sol, for the
    ///         identical arithmetic) only guarantees a newly-opened case CAN
    ///         finish before `disputeTimeout` if `finalize` is called
    ///         promptly -- it is not a guarantee that `finalize` actually runs
    ///         before the timeout regardless of when it is called. A case
    ///         referred at the very last legal instant still loses that race
    ///         if nobody calls `finalize` until after the game's own timeout
    ///         has already resolved the challenge by itself. `finalize` must
    ///         survive that without reverting: the selector-filtered catch on
    ///         `rule`'s `WrongStatus` closes the case anyway
    ///         (`ChallengeAlreadyTerminal`) instead of bubbling.
    function test_arc_timeoutRace_bothOrderings() public {
        uint256 pid = _proposeApproveExecute();

        // ── (a): the court rules first.
        vm.prank(challenger);
        uint256 cidA = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/race-a"
        );
        _disputeFull(cidA); // court wired throughout -> auto-refers immediately
        uint256 caseIdA = court.caseOfChallenge(address(game), cidA);
        assertTrue(caseIdA != 0);

        vm.prank(g2);
        court.vote(caseIdA, false); // not guilty -- keeps g1's stake intact for (b)
        _warpPastVoteWindow(caseIdA);
        court.finalize(caseIdA);
        assertEq(uint256(game.challengeOf(cidA).status), uint256(IChallengeGame.Status.Failed), "the ruling landed");

        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(cidA); // nothing left for the timeout to do

        // ── (b): the challenge's own clock beats a late `finalize`, and lands
        //    a NON-VERDICT, not an acquittal (issue #181 finding 20). The
        //    court is unwired BEFORE this filing, so `courtAtFiling` pins to
        //    `address(0)` for this challenge -- permanently, regardless of
        //    the later re-wire below. That is the exact shape `resolve`'s
        //    `_refundAll` branch exists for ("no adjudicator was ever
        //    guaranteed reachable"), so THIS challenge's timeout resolves
        //    `Inconclusive` even though a real case does go on to open and
        //    even collect a vote -- `resolve` reads the pin taken at filing,
        //    not that later history. A wired court whose adjudicator simply
        //    never rules in time takes the identical non-verdict path via
        //    `_fail`'s `unadjudicatedTimeout` re-arm; only a court's genuine
        //    `NotGuilty` ruling (arc (a) above) is a real acquittal that
        //    forfeits the challenger's bond.
        vm.prank(owner);
        game.setCourt(address(0)); // suppress auto-referral -- the referral instant below is chosen by hand
        uint256 challengerBBalBeforeFile = wood.balanceOf(challengerB);
        vm.prank(challengerB);
        uint256 cidB = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.RogueAllowance,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/race-b"
        );
        uint256 filedAtB = game.challengeOf(cidB).filedAt;
        vm.prank(g1);
        game.dispute(cidB, type(uint256).max); // pool completes; no auto-referral while court == 0

        // THE PIN, NOT THE LIVE PARAMETER: this arc's whole point is that the
        // challenge's own `disputeTimeoutAtFiling` -- not whatever
        // `game.disputeTimeout()` happens to read at the time -- is the clock
        // that ultimately wins the race below. Reading the live parameter here
        // would still pass today (nothing re-points it mid-arc), but it would
        // silently stop meaning what this comment says the moment that
        // stopped being true.
        uint256 disputeTimeoutAtFilingB = game.challengeOf(cidB).disputeTimeoutAtFiling;
        uint256 lastLegal = filedAtB + disputeTimeoutAtFilingB - court.voteWindow() - court.FINALIZE_BUFFER();
        vm.warp(lastLegal);
        vm.prank(owner);
        game.setCourt(address(court)); // re-wire just before the manual referral -- courtAtFiling stays pinned at 0
        // REFUSED AT THE DOOR NOW (pashov review finding #6). This arc used to
        // open a case here and even collect a vote, then watch the game's own
        // clock discard the whole thing. That WAS the defect: `rule`
        // authorises against `courtAtFiling`, pinned at 0 for this challenge
        // forever, so the case could never be adjudicated -- `finalize`
        // re-raises everything except `WrongStatus`, so `rule`'s `NotCourt`
        // would roll back the `Resolved` write and wedge the case in `Voting`.
        // `refer` now rejects that shape outright: no case id burned, no voter
        // paying gas for a verdict that cannot be delivered. The arc's actual
        // subject is unchanged -- the timeout below still reads the pin and
        // lands a NON-VERDICT.
        vm.expectRevert(ITokenCourt.ChallengeNotRulable.selector);
        court.refer(cidB);

        assertEq(wood.balanceOf(challengerB), challengerBBalBeforeFile - _challengerBond(), "the bond is out on loan");
        vm.warp(filedAtB + disputeTimeoutAtFilingB); // exactly the challenge's own (pinned) timeout
        game.resolve(cidB); // Disputed, clock elapsed, courtAtFiling == 0 -> _refundAll
        assertEq(
            uint256(game.challengeOf(cidB).status),
            uint256(IChallengeGame.Status.Inconclusive),
            "the game's own clock resolved this challenge first, as a non-verdict, not an acquittal"
        );

        // ── BOTH SIDES UNWIND WHOLE, proven in WOOD rather than inferred
        //    from the status alone. The challenger gets its bond back minus
        //    only the small, escalating anti-grinding burn (never forfeited
        //    to the defence, unlike arc (a)'s real acquittal), and g1 -- the
        //    pool's sole funder -- gets its whole counter-bond contribution
        //    back with no burn on that side at all. Derived from the
        //    challenge's own pinned rate, not hardcoded, so this survives a
        //    future schedule change.
        IChallengeGame.Challenge memory cb = game.challengeOf(cidB);
        uint256 inconclusiveBurnedB = (cb.bondWood * cb.inconclusiveBurnBpsAtFiling) / 10_000;
        assertEq(
            wood.balanceOf(challengerB),
            challengerBBalBeforeFile - inconclusiveBurnedB,
            "the challenger's bond came back whole, less only the anti-grinding burn"
        );
        assertEq(game.claimableContribution(cidB, g1), cb.counterBondWood, "g1's pool contribution, stake only");
        uint256 g1BalBeforeClaim = wood.balanceOf(g1);
        vm.prank(g1);
        uint256 gotB = game.claimContribution(cidB);
        assertEq(gotB, cb.counterBondWood);
        assertEq(wood.balanceOf(g1), g1BalBeforeClaim + cb.counterBondWood, "g1's whole defence contribution returned");

        // No case was ever opened for this challenge — `refer` refused the
        // zero-pin shape above (pashov review finding #6) — so there is no
        // `finalize` to drive here and nothing to observe closing. The
        // `ChallengeAlreadyTerminal` swallow-path that used to be exercised
        // here is still covered by arc (a) and by
        // `test_finalize_terminalRace_caseClosesViaCatch` in
        // test/TokenCourt.t.sol, both of which reach it on a challenge that
        // DID pin an adjudicator — the only shape that could ever get there.
        assertEq(court.caseOfChallenge(address(game), cidB), 0, "no case id was burned on an unrulable challenge");

        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
    }

    // ── 5. A reverting `refer` leaves no poison, and anyone can refer a fresh challenge later ──

    /// @notice THE FINDING THIS TASK'S OWN WINDOW INVARIANT PRODUCED, worth
    ///         recording here because it changes what this test can even
    ///         reach: with `ChallengeGame._requireWindowFits` /
    ///         `TokenCourt.setVoteWindow`'s cross-contract check enforced (B3),
    ///         `refer`'s clock check can NEVER fail through ordinary
    ///         auto-referral again. Proof: the latest a counter-bond pool can
    ///         complete is `filedAt + autoSlashDelay`, so the remaining clock
    ///         at that instant is AT LEAST `disputeTimeout - autoSlashDelay`,
    ///         and the invariant guarantees `disputeTimeout - autoSlashDelay
    ///         >= voteWindow + FINALIZE_BUFFER` -- exactly what `refer`
    ///         requires. THE OLD VERSION of this test reached its failure by
    ///         calling `game.setDisputeTimeout(8 days)`, a state Part A's
    ///         `_requireWindowFits` now REJECTS outright
    ///         (`WindowInvariantViolated`) at the default 7-day
    ///         `autoSlashDelay` / 5-day `voteWindow` / 1-day
    ///         `FINALIZE_BUFFER` (7 + 5 + 1 = 13 > 8). So the window invariant
    ///         didn't break this test -- it made the test's premise
    ///         unreachable by configuration, a strengthening worth recording
    ///         rather than working around.
    /// @dev    THE PROPERTY STILL WORTH PINNING, reached a different way:
    ///         `refer` claims `caseCount++` and `caseOfChallenge[game][id] =
    ///         caseId` BEFORE its `InsufficientClock` check runs, so a revert there
    ///         must discard those writes along with everything else in the
    ///         reverted call frame -- not merely leave them unassigned to
    ///         anything meaningful. Auto-referral can no longer manufacture
    ///         that revert (see above), so this test reaches the SAME
    ///         reverting path DELIBERATELY instead: unwire the court so
    ///         `dispute` never attempts a referral (its auto-refer is itself
    ///         gated on `court != address(0)`), let the pool complete and the
    ///         clock run down past `refer`'s own boundary, then re-wire the
    ///         court and call `refer` BY HAND, expecting `InsufficientClock`
    ///         to revert exactly as it always could -- this path is
    ///         independent of the window invariant, which bounds the
    ///         PARAMETERS, not how late a caller chooses to call `refer`.
    /// @dev    THE "RECONFIGURE THE SAME CHALLENGE AND RE-REFER IT" HALF OF
    ///         THIS TASK'S SPEC IS STRUCTURALLY IMPOSSIBLE, and that limitation
    ///         is worth recording plainly rather than working around it:
    ///         `disputeTimeoutAtFiling` is PINNED at filing (review F5)
    ///         precisely so the owner cannot move a live challenge's clock,
    ///         and a challenge's remaining clock only ever shrinks as time
    ///         passes. So this test proves the no-poison half on the SAME
    ///         (clock-starved) challenge, and the stranger-can-refer half on a
    ///         SECOND, generously-clocked one -- exactly the two-challenge
    ///         structure the task itself anticipates for this reason.
    function test_revertingRefer_leavesNoPoisonAndAnyoneCanReferAFreshChallenge() public {
        uint256 pid = _proposeApproveExecute();

        // BOTH CHALLENGES ARE FILED UP FRONT, seconds apart, against the SAME
        // proposal -- g1 is the sole accused approver on both, so it funds
        // both pools (this file's own top-level comment anticipates exactly
        // this: "some arcs have g1 fund TWO pools in the same test"). Filing
        // both now, before any warp, is what keeps cidB's own clock fresh AND
        // keeps `pid`'s 14-day `challengeWindow` from ever being in play --
        // a SECOND filing timed after the large warp cidA's scenario needs
        // would revert `WindowClosed` (`pid` aged out) or, filed against a
        // fresh proposal instead, `VaultHasOpenProposal` (this vault's one
        // proposal at a time gate, unrelated to the challenge system and
        // still open because `pid` hasn't been settled).
        vm.prank(challenger);
        uint256 cidA = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/reverting-refer"
        );
        uint256 filedAtA = game.challengeOf(cidA).filedAt;
        uint256 disputeTimeoutAtFilingA = game.challengeOf(cidA).disputeTimeoutAtFiling;

        vm.prank(challengerB);
        uint256 cidB = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.RogueAllowance,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/generous-clock"
        );

        // Unwire the court FIRST: `dispute`'s auto-referral is gated on
        // `court != address(0)` (see its own natspec), so completing either
        // pool below attempts nothing -- no case opened, no poison possible
        // yet.
        vm.prank(owner);
        game.setCourt(address(0));
        // ONE contribution answers BOTH filings now (pashov 2026-08 finding
        // #10): the counter-bond pool is keyed per PROPOSAL, not per challenge,
        // so completing it through cidA leaves cidB Disputed as well. A second
        // `dispute` on the same key therefore reverts `WrongStatus` -- cidB is
        // no longer `Filed`. That is the fix working; before it, the accused
        // had to fund a separate pool per filing, which is exactly the N-fold
        // cost the finding is about.
        vm.prank(g1);
        game.dispute(cidA, type(uint256).max);
        assertEq(
            uint8(game.challengeOf(cidB).status),
            uint8(IChallengeGame.Status.Disputed),
            "the shared pool answers the sibling filing too"
        );

        // ── The stranger-can-refer half, proven FIRST, while cidB's own
        //    clock is still fresh (filed only seconds after cidA, under the
        //    same defaults). Proving it AFTER the big warp below would fail
        //    it too, for the identical reason cidA is about to.
        vm.prank(owner);
        game.setCourt(address(court));
        vm.prank(stranger); // ANYONE may call `refer` -- the recovery path `dispute`'s natspec promises
        uint256 caseId = court.refer(cidB);
        assertEq(caseId, 1, "the first case ever opened");
        assertEq(court.caseOfChallenge(address(game), cidB), 1);

        // ── Now exhaust cidA's OWN clock and reach the reverting path.
        // Run the clock down past `refer`'s own boundary (identical
        // arithmetic to `test_refer_clockCheckBoundary`, test/TokenCourt.t.sol):
        // one second past the last instant that leaves `voteWindow +
        // FINALIZE_BUFFER` of runway before cidA's own pinned timeout.
        uint256 lastLegal = filedAtA + disputeTimeoutAtFilingA - court.voteWindow() - court.FINALIZE_BUFFER();
        vm.warp(lastLegal + 1);

        // Call `refer` BY HAND -- the deliberate trigger the vanished
        // auto-referral race used to provide for free (the court is already
        // wired from cidB's referral above; `dispute` never runs again for
        // cidA, so there is nothing left to auto-refer through anyway).
        vm.expectRevert(ITokenCourt.InsufficientClock.selector);
        court.refer(cidA);

        // ── THE ANSWER: the reverted child frame left NOTHING behind for
        //    cidA -- `caseCount` staying at 1 (cidB's real, earlier case)
        //    rather than advancing to 2 is exactly what proves it: a
        //    poisoned `caseCount++` would show up here as 2, not silently as
        //    0, since a real case already exists.
        assertEq(court.caseOfChallenge(address(game), cidA), 0, "no case was ever recorded for the reverted referral");
        assertEq(court.caseCount(), 1, "the reverted refer()'s caseCount++ was discarded, not merely unassigned");

        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
    }

    // ── 6. Present-holdings gate (B4): requesting to unstake mid-cooldown blocks a vote ──

    /// @notice The whole premise of the present-holdings gate -- historic
    ///         weight surviving while present holdings are gone -- was
    ///         previously asserted only through `MockStakedWood`'s settable
    ///         storage (`TokenCourt.t.sol`). This arc proves it on the real
    ///         `StakedWood` stack: g3's RAW stake checkpoint at the snapshot
    ///         (`getPastStake`) is genuinely immutable across
    ///         `requestUnstakeGuardian` -- checkpoints are append-only.
    ///         `getPastVotes(snapshotTs)` is a subtler read: it re-derives
    ///         the age factor from the guardian's CURRENT (mutable)
    ///         `stakedAt` every call (review F17's own basis mismatch), so
    ///         once `requestUnstakeGuardian` re-anchors `stakedAt` to now,
    ///         a later call to `getPastVotes(g3, snapshotTs)` recomputes at
    ///         `ageFloorBps` too -- it does NOT freeze at its pre-request
    ///         value. That is not a hole in the gate: `getPastVotes` STAYS
    ///         NONZERO (floored, never zeroed), which is exactly the
    ///         "still votes at 25% of historic weight" shape B4 describes --
    ///         the gate has to be the present-holdings check, because the
    ///         historic weight alone can never reach zero here. Present
    ///         holdings, meanwhile, are zeroed from the REQUEST instant --
    ///         before `claimUnstakeGuardian` ever runs, and long before
    ///         `coolDownPeriod` (45 days here) could elapse. The attack
    ///         this closes dies at the vote, not at the claim.
    function test_arc_requestedUnstakeMidCooldown_blocksVote() public {
        uint256 pid = _proposeApproveExecute();

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.ProposerLinkedOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/mid-cooldown"
        );

        _disputeFull(cid);
        uint256 caseId = court.caseOfChallenge(address(game), cid);
        assertTrue(caseId != 0);
        uint256 snapshotTs = court.caseOf(caseId).snapshotTs;

        vm.prank(g2);
        court.vote(caseId, true); // g2 alone clears the participation floor

        assertTrue(swood.getPastVotes(g3, snapshotTs) != 0, "g3 held weight at the snapshot");
        uint256 g3RawStakeAtSnapshot = swood.getPastStake(g3, snapshotTs);
        assertTrue(g3RawStakeAtSnapshot != 0, "g3's raw checkpoint at the snapshot is nonzero");

        // g3 requests to unstake. Still mid-cooldown -- nothing claimed,
        // WOOD still locked in `swood` -- but present holdings are already
        // gone.
        vm.prank(g3);
        swood.requestUnstakeGuardian();

        assertEq(
            swood.getPastStake(g3, snapshotTs), g3RawStakeAtSnapshot, "the RAW checkpoint at the snapshot is immutable"
        );
        assertTrue(
            swood.getPastVotes(g3, snapshotTs) != 0,
            "historic AGED weight still nonzero (floored, never zeroed) -- the gate must be present-holdings, not history"
        );
        assertEq(swood.getVotes(g3), 0, "present holdings zeroed from the REQUEST instant, not the claim");

        vm.prank(g3);
        vm.expectRevert(ITokenCourt.NoPresentHoldings.selector);
        court.vote(caseId, true);

        _warpPastVoteWindow(caseId);
        court.finalize(caseId);
        assertEq(
            uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.Guilty), "g2 alone still convicts"
        );
    }

    // ── 6. Issue #83: a concurrent conviction must not lift the voting bar ──

    /// @dev TWO covering approvers, not the fixture's usual one. The arc below
    ///      needs `settleCoverage` to actually REACH `_rebook` for g1, and with
    ///      g1 alone on the key its emptied bond makes `_effectiveReservedTotal`
    ///      zero — which `settleCoverage` early-returns on before rebooking
    ///      anything. g2 keeps the cohort's effective total non-zero, so the
    ///      pass runs and books g1 at zero: the state the whole issue turns on.
    ///      g2 is consequently accused here too; nothing below depends on the
    ///      size of the accused set, only on whether g1 is in it.
    function _proposeApproveExecuteTwoApprovers() internal returns (uint256 pid) {
        pid = _propose();
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g2);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "g1 reserved the whole coverage");
        assertEq(ledger.openExposureUsd(g2), COVERAGE_USD, "g2 reserved the whole coverage");

        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
        assertEq(gov.getProposal(pid).executedAt, vm.getBlockTimestamp(), "executedAt stamped now");
    }

    /// @notice ISSUE #83, the whole chain on the real stack: an approver
    ///         convicted on a SEPARATE, CONCURRENT challenge must still be
    ///         barred from voting on THIS one, even though a permissionless
    ///         `settleCoverage` has since booked its coverage at zero.
    ///
    /// @dev    Every step is either ordinary protocol operation or a call
    ///         anyone may make — no attacker capital and no privileged role:
    ///
    ///           1. g1 approves P; P executes at `executedAt`. `refer` will
    ///              snapshot the electorate at `executedAt - 1`.
    ///           2. A challenge is filed against P. Coverage freezes.
    ///           3. g1 is convicted on a DIFFERENT challenge. `maxSlashBps` is
    ///              10,000 (the Plan B pre-flight requires it), so `_slashOne`
    ///              takes the whole live balance and `guardianStake(g1)` lands
    ///              on exactly zero rather than on dust.
    ///           4. A stranger calls `settleCoverage` on P's key. g1's
    ///              slashable bond is now zero, so `_rebook` writes its live
    ///              booking down to zero. The PLEDGE is untouched.
    ///           5. `refer` runs. This is the step the fix changes: reading the
    ///              booking, g1 fell out of the accused set entirely.
    ///           6. g1 votes. Its ballot weighs `getPastVotes(g1, executedAt-1)`
    ///              — the FULL PRE-SLASH amount, because checkpoints are
    ///              append-only and a later slash cannot reach back past a
    ///              stored timestamp. The accused judged its own case at full
    ///              strength, which is exactly what `AccusedCannotVote` exists
    ///              to prevent.
    ///
    ///         Step 3 runs as a direct `slashVerdict` from the authorized
    ///         slasher under a DIFFERENT `caseKey`, which is precisely what a
    ///         concurrent challenge's `_settle` does. Standing up a second full
    ///         proposal-and-challenge lifecycle reaches the identical state
    ///         (`stakedAmount == 0`) through much more fixture and proves
    ///         nothing extra about the court.
    function test_arc_convictedElsewhereThenSettledToZero_isStillAccused() public {
        uint256 pid = _proposeApproveExecuteTwoApprovers();
        uint256 executedAt = gov.getProposal(pid).executedAt;

        // 2. The filing. Sized off the live bookings, which are still intact.
        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/issue-83"
        );

        // Settlement is gated strictly past `executeBy`; the proposal executed
        // one second into its review close, so this is roughly a day — well
        // inside the 7-day `autoSlashDelay` the dispute below has to land in.
        vm.warp(gov.getProposal(pid).executeBy + 1);

        // 3. The concurrent conviction, under a case key that has nothing to do
        //    with the challenge filed above.
        assertEq(swood.guardianStake(g1), G1_STAKE, "fixture: g1 is fully staked going in");
        address[] memory convicted = new address[](1);
        convicted[0] = g1;
        uint256[] memory fullRate = new uint256[](1);
        fullRate[0] = 10_000;
        vm.prank(address(game));
        swood.slashVerdict(keccak256("issue-83.concurrent-challenge"), executedAt - 1, convicted, fullRate);
        assertEq(swood.guardianStake(g1), 0, "a 100% conviction lands on exactly zero, not on dust");

        // 4. Anyone settles. g1's slashable bond is gone, so its booking goes
        //    to zero; g2's live bond keeps the cohort's effective total
        //    non-zero, so the pass actually runs rather than early-returning.
        vm.prank(stranger);
        ledger.settleCoverage(address(gov), pid);
        (address[] memory bookedWho, uint256[] memory bookedUsd) = ledger.approversOf(address(gov), pid);
        (address[] memory pledgedWho, uint256[] memory pledgedUsd) = ledger.pledgedOf(address(gov), pid);
        assertEq(_usdFor(bookedWho, bookedUsd, g1), 0, "the live booking was written down to nothing");
        assertEq(
            _usdFor(pledgedWho, pledgedUsd, g1),
            COVERAGE_USD,
            "the pledge is untouched: g1 did underwrite this proposal"
        );

        // 5. Refer. Before the fix, `_recordAccused` read the booking above and
        //    dropped g1 here.
        _disputeFull(cid);
        uint256 caseId = court.caseOfChallenge(address(game), cid);
        assertTrue(caseId != 0, "the pool-completing auto-referral landed a real case");
        assertTrue(court.isAccused(caseId, g1), "ISSUE #83: a settled-to-zero booking is not an acquittal");

        // Its stake is also back in `accusedWeight`, which the participation
        // floor's base subtracts. This half of the harm needs nothing further
        // from g1 at all — it lands the moment the accused set is built.
        assertTrue(court.caseOf(caseId).accusedWeight >= G1_STAKE, "g1's stake counts against the floor again");

        // 6. And the bar bites. The weight read is what makes this a
        //    vulnerability rather than a cosmetic set-membership question: g1
        //    holds nothing right now, yet its ballot is weighed at a checkpoint
        //    the slash cannot reach back to.
        uint256 snapshotTs = court.caseOf(caseId).snapshotTs;
        assertEq(snapshotTs, executedAt - 1, "the electorate is snapshotted before the drain");
        assertEq(
            swood.getPastVotes(g1, snapshotTs),
            G1_STAKE,
            "the ballot g1 is about to cast carries its FULL pre-slash weight"
        );

        // `vote` has a SECOND, independent gate — present holdings — and a
        // guardian slashed to nothing trips it before the accused bar could
        // ever be tested. That gate is cheap to step over: `StakedWood`'s own
        // natspec records the residual, and `minGuardianStake` is its whole
        // price. Paying it here is what makes this arc prove the ACCUSED bar
        // rather than accidentally re-proving the holdings one.
        wood.mint(g1, MIN_GUARDIAN_STAKE);
        vm.startPrank(g1);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(MIN_GUARDIAN_STAKE, 1);
        vm.stopPrank();
        assertTrue(swood.getVotes(g1) != 0, "present holdings restored: the other gate no longer bites");
        assertTrue(swood.getPastVotes(g1, snapshotTs) != 0, "and the historic weight is still there to be cast");

        vm.prank(g1);
        vm.expectRevert(ITokenCourt.AccusedCannotVote.selector);
        court.vote(caseId, false);

        // The unaccused electorate is unaffected: g3 never approved, votes
        // normally, and the case still reaches a verdict.
        vm.prank(g3);
        court.vote(caseId, true);
        _warpPastVoteWindow(caseId);
        court.finalize(caseId);
        assertEq(
            uint256(court.caseOf(caseId).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "barring the accused did not brick the case"
        );
    }

    /// @dev Positional lookup over one of the ledger's paired return arrays.
    ///      Reverts rather than returning zero for an address that is not
    ///      listed at all — "absent" and "listed at zero" are exactly the two
    ///      states this arc exists to tell apart.
    function _usdFor(address[] memory who, uint256[] memory usd, address guardian) internal pure returns (uint256) {
        for (uint256 i = 0; i < who.length; i++) {
            if (who[i] == guardian) return usd[i];
        }
        revert("guardian is not a listed approver");
    }
}
