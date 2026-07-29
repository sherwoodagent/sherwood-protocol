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
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

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
///         both sides of that call (aged weight for the electorate, raw stake
///         for the slash). These five arcs are that proof.
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
    CompensationEscrow public escrow;
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
    /// @dev maxCapital x (exec 15,000 bps + settle 5,000 bps) / 10,000 -- see
    ///      `ChallengeEndToEndTest`'s identical constant for the full derivation.
    uint256 constant REQUIRED_COVERAGE = 1_000e6;
    uint256 constant COVERAGE_USD = 1_000e18;
    uint256 constant CHALLENGER_BOND = 1_000e18; // $1,000 x 5% / $0.05

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
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.05e8); // conservative governance haircut
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(owner);
        registry.setExposureLedger(address(ledger));

        bondEscrow = new ProposerBondEscrow(address(wood), address(registry));
        escrow = new CompensationEscrow(owner, address(wood));

        // ── The game and the court, then their roles.
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));
        court = new TokenCourt(owner);
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(game));
        tierRegistry.setAuthorizedDemoter(address(game));
        vm.startPrank(owner);
        swood.setAuthorizedSlasher(address(game));
        swood.setCompensationEscrow(address(escrow));
        escrow.setAuthorizedFunder(address(swood));
        escrow.setBackstop(backstop);
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
        tierRegistry.certify(address(adapter), adapter.poke.selector, 1, CERTIFIED_BOUND_BPS, address(0));

        // ── WOOD for the proposer's bond, both challengers' bonds, and g1's
        //    counter-bond pool contributions (sized generously: some arcs have
        //    g1 fund TWO pools in the same test).
        wood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        wood.approve(address(bondEscrow), type(uint256).max);
        wood.mint(challenger, CHALLENGER_BOND * 5);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
        wood.mint(challengerB, CHALLENGER_BOND * 5);
        vm.prank(challengerB);
        wood.approve(address(game), type(uint256).max);
        wood.mint(g1, CHALLENGER_BOND * 5);
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
                address(this), // factory
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
            _settleCalls(),
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
        // g4 stakes AFTER the proposal already executed -- on the far side of
        // the instant `snapshotTs` (`executedAt - 1`) pins the electorate to.
        _stakeGuardian(g4, FILLER_STAKE, 4);
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 expectedBps = _g1SlashBpsFor(pid);
        // PINNED LITERAL (not derived from the same function under test): g1
        // committed $1,000 of coverage against $1,500 of slashable bond
        // ($0.05 x 30,000 WOOD), so its liability prices at
        // ceil(1_000 * 10_000 / 1_500) = 6,667 bps. This is what actually
        // catches a wrong rate -- a mutated `slashBpsFor` that returns a
        // different number fails HERE, not only downstream where it would
        // otherwise agree with itself.
        assertEq(
            expectedBps, 6667, "$1,000 of coverage against $1,500 of slashable bond ($0.05 x 30,000 WOOD), rounded up"
        );

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
        uint256 caseId = court.caseOfChallenge(cid);
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
        court.finalize(caseId);

        // ── The verdict landed on the REAL game.
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled");
        assertEq(uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.Guilty));

        // ── The accused's REAL staked WOOD was really slashed, at exactly what
        //    the ledger priced its liability at.
        assertEq(swood.guardianStake(g1), G1_STAKE - (G1_STAKE * expectedBps) / 10_000, "g1 paid exactly what it owed");

        // ── The challenger is repaid bond + the whole forfeited pool
        //    (escalated settle: no burn -- see `_settle`'s `escalated` branch).
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(wood.balanceOf(challenger), challengerBalBefore + c.counterBondWood, "bond back plus the whole pool");

        // ── The named adapter lost its certification (D7).
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 2, "demoted to the arbitrary-calldata default");
        assertEq(boundAfter, 10_000, "and to full notional");

        // ── A real compensation case opened in the escrow.
        assertEq(escrow.caseCount(), 1, "the slash reached the compensation escrow");
        (,, uint256 proceeds,,,,) = escrow.caseOf(1);
        assertEq(proceeds, (G1_STAKE * expectedBps) / 10_000, "the whole slash reached the case");

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
        uint256 caseId = court.caseOfChallenge(cid);
        assertTrue(caseId != 0);

        vm.prank(g2);
        court.vote(caseId, false); // not guilty

        _warpPastVoteWindow(caseId);
        court.finalize(caseId);

        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Failed), "Failed");
        assertEq(uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.NotGuilty));

        // ── The challenger's bond is gone outright -- no refund on a failed challenge.
        assertEq(wood.balanceOf(challenger), challengerBalBefore - CHALLENGER_BOND, "the bond forfeited");

        // ── g1 funded the whole pool alone, so `claimContribution` gives it
        //    its stake back plus its whole (burn-adjusted) pro-rata slice.
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        // PINNED, not merely "greater than zero": at the default 20%
        // `forfeitBurnBps`, g1's payout is exactly 80% of the bond. A
        // zeroed-out burn rate would still clear `assertGt(..., 0)`, so the
        // literal is what actually pins the rate rather than merely its sign.
        assertEq(c.forfeitPayoutWood, (CHALLENGER_BOND * 8_000) / 10_000, "80% of the bond, net of the 20% burn");
        uint256 expectedClaim = c.counterBondWood + c.forfeitPayoutWood;
        assertEq(game.claimableContribution(cid, g1), expectedClaim);
        uint256 g1BalBeforeClaim = wood.balanceOf(g1);
        vm.prank(g1);
        uint256 got = game.claimContribution(cid);
        assertEq(got, expectedClaim);
        assertEq(wood.balanceOf(g1), g1BalBeforeClaim + expectedClaim, "the WOOD actually moved");

        // ── The accused was NEVER slashed -- an acquittal marks nothing.
        assertEq(swood.guardianStake(g1), G1_STAKE, "g1's stake is untouched");
        assertEq(escrow.caseCount(), 0, "no compensation case was ever opened");
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
        uint256 caseId = court.caseOfChallenge(cid);
        assertTrue(caseId != 0);

        // Nobody votes: turnout is zero, which `finalize` reads as
        // `Inconclusive` unconditionally, regardless of the floor's value.
        _warpPastVoteWindow(caseId);
        court.finalize(caseId);

        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Inconclusive), "Inconclusive");
        assertEq(uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.Inconclusive));

        // ── The challenger's bond returns WHOLE -- no settle-path burn slice,
        //    because an unwind is not a correct filing being rewarded.
        assertEq(wood.balanceOf(challenger), challengerBalBefore, "the whole bond came back");

        // ── g1 collects EXACTLY its stake back -- no winnings, nothing was won.
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(game.claimableContribution(cid, g1), c.counterBondWood, "stake only, no forfeit to split");
        uint256 g1BalBeforeClaim = wood.balanceOf(g1);
        vm.prank(g1);
        uint256 got = game.claimContribution(cid);
        assertEq(got, c.counterBondWood);
        assertEq(wood.balanceOf(g1), g1BalBeforeClaim + c.counterBondWood);

        // ── Coverage unfroze, and NO conviction mark was left anywhere.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen");
        assertEq(swood.guardianStake(g1), G1_STAKE, "never slashed");
        assertEq(escrow.caseCount(), 0, "no compensation case was ever opened");

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
        uint256 caseIdA = court.caseOfChallenge(cidA);
        assertTrue(caseIdA != 0);

        vm.prank(g2);
        court.vote(caseIdA, false); // not guilty -- keeps g1's stake intact for (b)
        _warpPastVoteWindow(caseIdA);
        court.finalize(caseIdA);
        assertEq(uint256(game.challengeOf(cidA).status), uint256(IChallengeGame.Status.Failed), "the ruling landed");

        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(cidA); // nothing left for the timeout to do

        // ── (b): the challenge's own clock beats a late `finalize`.
        vm.prank(owner);
        game.setCourt(address(0)); // suppress auto-referral -- the referral instant below is chosen by hand
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
        game.setCourt(address(court)); // re-wire just before the manual referral
        uint256 caseIdB = court.refer(cidB); // the last legal instant, per test_refer_clockCheckBoundary
        assertEq(court.caseOf(caseIdB).referredAt, lastLegal);

        vm.prank(g3);
        court.vote(caseIdB, true); // the tally is moot -- the timeout wins this race regardless

        vm.warp(filedAtB + disputeTimeoutAtFilingB); // exactly the challenge's own (pinned) timeout
        game.resolve(cidB); // Disputed, clock elapsed -> _fail
        assertEq(uint256(game.challengeOf(cidB).status), uint256(IChallengeGame.Status.Failed), "timeout won the race");

        vm.expectEmit(true, true, false, false);
        emit ITokenCourt.ChallengeAlreadyTerminal(caseIdB, cidB);
        court.finalize(caseIdB); // must not revert: WrongStatus from `rule` is swallowed
        assertEq(uint256(court.caseOf(caseIdB).phase), uint256(ITokenCourt.Phase.Resolved), "the case still closes");

        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
    }

    // ── 5. A failed auto-referral leaves no poison, and anyone can refer later ──

    /// @notice THE PROPERTY TASK 8'S WHOLE AUTO-REFERRAL DESIGN RESTS ON, and
    ///         until this test asserted only in `dispute`'s own comments and
    ///         proven by nothing: `refer` claims `caseCount++` and
    ///         `caseOfChallenge[id] = caseId` BEFORE its clock check runs, so a
    ///         revert inside that check must discard those writes along with
    ///         everything else in the reverted call frame -- not merely leave
    ///         them unassigned to anything meaningful. This is arranged
    ///         against a REAL, reachable revert reason (`InsufficientClock`)
    ///         on the real court, reached through `dispute`'s own broad,
    ///         deliberately un-narrowed catch (see `dispute`'s natspec for why
    ///         that catch must stay broad rather than selector-filtered).
    /// @dev    THE "RECONFIGURE THE SAME CHALLENGE AND RE-REFER IT" HALF OF
    ///         THIS TASK'S SPEC IS STRUCTURALLY IMPOSSIBLE, and that limitation
    ///         is worth recording plainly rather than working around it:
    ///         `disputeTimeoutAtFiling` is PINNED at filing (review F5)
    ///         precisely so the owner cannot move a live challenge's clock,
    ///         and a challenge's remaining clock only ever shrinks as time
    ///         passes -- raising the LIVE `disputeTimeout` afterwards changes
    ///         nothing about a challenge already filed under the old value
    ///         (asserted below directly). So this test proves the no-poison
    ///         half on the SAME (tight-clocked) challenge, and the
    ///         stranger-can-refer half on a SECOND, generously-clocked one --
    ///         exactly the two-challenge structure the task itself anticipates
    ///         for this reason.
    function test_failedAutoReferral_leavesNoPoisonAndAnyoneCanReferLater() public {
        vm.prank(owner);
        game.setDisputeTimeout(8 days); // > autoSlashDelay (7d): a tight but legal timeout

        uint256 pid = _proposeApproveExecute();

        vm.prank(challenger);
        uint256 cidA = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/tight-clock"
        );
        uint256 filedAtA = game.challengeOf(cidA).filedAt;

        // Complete the pool 6.5 days in -- still inside the 7-day
        // `autoSlashDelay` dispute window, but only 1.5 days remain of the
        // pinned 8-day timeout: short of the 6 days (`voteWindow` 5d +
        // `FINALIZE_BUFFER` 1d) `refer`'s own clock check requires.
        vm.warp(filedAtA + 6 days + 12 hours);
        vm.expectEmit(true, false, false, false);
        emit IChallengeGame.AutoReferFailed(cidA);
        vm.prank(g1);
        game.dispute(cidA, type(uint256).max);

        // ── THE ANSWER: the reverted child frame left NOTHING behind.
        assertEq(court.caseOfChallenge(cidA), 0, "no case was ever recorded for the failed referral");
        assertEq(court.caseCount(), 0, "the reverted refer()'s caseCount++ was discarded, not merely unassigned");

        // Reconfiguring the LIVE parameter cannot rescue cidA -- its own pin
        // stays exactly what it was at filing.
        vm.prank(owner);
        game.setDisputeTimeout(30 days);
        assertEq(game.challengeOf(cidA).disputeTimeoutAtFiling, 8 days, "the pin is immune to the reconfigure");

        // ── So the stranger-can-refer half is proven on a SECOND, fresh
        //    challenge, filed under the now-generous 30-day timeout.
        vm.prank(owner);
        game.setCourt(address(0)); // suppress auto-referral again -- the manual refer below is what's under test
        vm.prank(challengerB);
        uint256 cidB = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/generous-clock"
        );
        vm.prank(g1);
        game.dispute(cidB, type(uint256).max); // pool completes; no auto-referral while court == 0

        vm.prank(owner);
        game.setCourt(address(court));
        vm.prank(stranger); // ANYONE may call `refer` -- the recovery path `dispute`'s natspec promises
        uint256 caseId = court.refer(cidB);
        assertEq(caseId, 1, "the first case ever opened -- the failed attempt above minted none");
        assertEq(court.caseOfChallenge(cidB), 1);

        assertEq(wood.balanceOf(address(court)), 0, "court custody is zero, always");
    }
}
