// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ITokenCourt} from "../src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {MockStakedWood} from "./mocks/MockStakedWood.sol";

/// @dev Just enough game for the court: a settable challenge record, the
///      ledger pointer the court reads, and a `rule` recorder with several
///      revert toggles — one per class `finalize`'s selector-filtered catch
///      must tell apart: the ONE swallowed terminal-race cause
///      (`WrongStatus`), and the transient failures that must bubble instead
///      (`NotCourt`, B2 — the game was re-pointed away but the challenge is
///      still rulable; and a stand-in `ZeroAddress`), plus a gas floor
///      standing in for `InsufficientSlashGas` (the under-gas verdict-burning
///      PoC).
/// @dev `executedAt` is set directly on the challenge record (no separate
///      governor stub) — the court reads `ch.executedAt`, the game's own pin
///      (F10), never a live `ISyndicateGovernor.getProposal` call. There is
///      therefore nothing left for a `MockGovernorForCourt` to stand in for.
contract MockGameForCourt {
    mapping(uint256 => IChallengeGame.Challenge) internal _challenges;
    address public exposureLedger;
    bool public ruleReverts; // reverts WrongStatus - swallowed (terminal race)
    bool public ruleRevertsNotCourt; // reverts NotCourt - bubbles (re-pointed court, still rulable, B2)
    bool public ruleRevertsOther; // reverts ZeroAddress - must bubble (transient stand-in)
    uint256 public ruleGasFloor; // 0 disables; else reverts InsufficientSlashGas under it
    uint256 public lastRuledChallenge;
    IChallengeGame.Verdict public lastVerdict;
    bool public ruled;

    /// @dev Mirrors the real `ChallengeGame`'s defaults (7-day
    ///      `autoSlashDelay`, 30-day `disputeTimeout`) — `TokenCourt.setVoteWindow`
    ///      now reads both live off the wired game to enforce the B3
    ///      cross-contract window invariant, so a mock without them would
    ///      revert every `setVoteWindow` call once this game is wired in
    ///      `setUp`.
    uint256 public autoSlashDelay = 7 days;
    uint256 public disputeTimeout = 30 days;

    function setExposureLedger(address l) external {
        exposureLedger = l;
    }

    function setAutoSlashDelay(uint256 d) external {
        autoSlashDelay = d;
    }

    function setDisputeTimeout(uint256 t) external {
        disputeTimeout = t;
    }

    function setRuleReverts(bool r) external {
        ruleReverts = r;
    }

    function setRuleRevertsNotCourt(bool r) external {
        ruleRevertsNotCourt = r;
    }

    function setRuleRevertsOther(bool r) external {
        ruleRevertsOther = r;
    }

    function setRuleGasFloor(uint256 g) external {
        ruleGasFloor = g;
    }

    function setChallenge(
        uint256 id,
        address governor,
        uint256 proposalId,
        IChallengeGame.Status status,
        uint256 filedAt,
        uint256 disputeTimeoutAtFiling,
        uint256 executedAt
    ) external {
        IChallengeGame.Challenge storage c = _challenges[id];
        c.governor = governor;
        c.proposalId = proposalId;
        c.status = status;
        c.filedAt = filedAt;
        c.disputeTimeoutAtFiling = disputeTimeoutAtFiling;
        c.executedAt = executedAt;
    }

    function challengeOf(uint256 id) external view returns (IChallengeGame.Challenge memory) {
        return _challenges[id];
    }

    function rule(uint256 challengeId, IChallengeGame.Verdict verdict) external {
        if (ruleGasFloor != 0 && gasleft() < ruleGasFloor) revert IChallengeGame.InsufficientSlashGas();
        if (ruleReverts) revert IChallengeGame.WrongStatus();
        if (ruleRevertsNotCourt) revert IChallengeGame.NotCourt();
        if (ruleRevertsOther) revert IChallengeGame.ZeroAddress();
        ruled = true;
        lastRuledChallenge = challengeId;
        lastVerdict = verdict;
    }
}

/// @dev Mirrors the real ledger's TWO numbers per approver, because #83 is
///      about the gap between them. `recordApproval` writes the pledge and the
///      live booking equal, so `setApprovers` does too; `settleCoverage` moves
///      only the booking, so `setCommittedOnly` is this mock's stand-in for a
///      settlement pass and is what lets a test drive the booking to zero while
///      the pledge stands.
contract MockLedgerForCourt {
    address[] internal _approvers;
    uint256[] internal _committed;
    uint256[] internal _pledged;

    function setApprovers(address[] memory a, uint256[] memory c) external {
        _approvers = a;
        _committed = c;
        _pledged = c;
    }

    /// @dev A settlement pass: rewrites the LIVE BOOKING for one approver and
    ///      leaves the pledge alone, exactly as `_rebook` does.
    function setCommittedOnly(address guardian, uint256 usd) external {
        for (uint256 i; i < _approvers.length; ++i) {
            if (_approvers[i] == guardian) {
                _committed[i] = usd;
                return;
            }
        }
        revert("not an approver");
    }

    function approversOf(address, uint256) external view returns (address[] memory, uint256[] memory) {
        return (_approvers, _committed);
    }

    function pledgedOf(address, uint256) external view returns (address[] memory, uint256[] memory) {
        return (_approvers, _pledged);
    }
}

contract TokenCourtTest is Test {
    TokenCourt internal court;
    MockGameForCourt internal game;
    MockLedgerForCourt internal ledger;
    MockStakedWood internal swood;

    address internal owner = makeAddr("owner");
    address internal voterA = makeAddr("voterA");
    address internal voterB = makeAddr("voterB");
    address internal accusedG = makeAddr("accusedG");
    // Not a contract: the court no longer calls anything on `ch.governor`
    // (`refer` reads `ch.executedAt`, the game's own pin), so a plain address
    // is enough to stand in for the identity the ledger is keyed by.
    address internal governor = makeAddr("governor");
    uint256 internal constant CHALLENGE_ID = 7;
    uint256 internal constant PROPOSAL_ID = 42;

    function setUp() public {
        vm.warp(365 days); // keep executedAt/filedAt well away from the genesis timestamp
        court = new TokenCourt(owner);
        game = new MockGameForCourt();
        ledger = new MockLedgerForCourt();
        swood = new MockStakedWood();
        game.setExposureLedger(address(ledger));
        vm.prank(owner);
        court.setChallengeGame(address(game));
        vm.prank(owner);
        court.setStakedWood(address(swood));
    }

    function test_constructor_defaults() public view {
        assertEq(court.voteWindow(), 5 days);
        assertEq(court.participationFloorBps(), 1_000);
        assertEq(court.FINALIZE_BUFFER(), 1 days);
        assertEq(court.MAX_VOTE_WINDOW(), 14 days);
    }

    function test_setters_boundsAndValues() public {
        vm.startPrank(owner);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setVoteWindow(0);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setVoteWindow(14 days + 1);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setParticipationFloorBps(0);
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.setParticipationFloorBps(10_001);
        vm.expectRevert(ITokenCourt.ZeroAddress.selector);
        court.setChallengeGame(address(0));
        vm.expectRevert(ITokenCourt.ZeroAddress.selector);
        court.setStakedWood(address(0));
        court.setVoteWindow(7 days);
        assertEq(court.voteWindow(), 7 days);
        vm.stopPrank();
    }

    function test_setters_onlyOwner() public {
        vm.prank(voterA);
        vm.expectRevert();
        court.setVoteWindow(7 days);
    }

    function test_setVoteWindow_emitsOldNew() public {
        vm.expectEmit(false, false, false, true);
        emit ITokenCourt.VoteWindowSet(5 days, 7 days);
        vm.prank(owner);
        court.setVoteWindow(7 days);
    }

    /// @notice Part A / B3, the court-side mirror of `ChallengeGame`'s window
    ///         invariant: `setVoteWindow` must not accept a window the wired
    ///         game's own LIVE `autoSlashDelay`/`disputeTimeout` cannot fit.
    ///         Tightening the game's `disputeTimeout` to 20 days is enough to
    ///         make `MAX_VOTE_WINDOW` (14d) no longer fit against the default
    ///         7-day `autoSlashDelay` + 1-day `FINALIZE_BUFFER`
    ///         (7 + 14 + 1 = 22 > 20).
    function test_setVoteWindow_revertsWindowInvariantViolated_whenGameNumbersCannotFit() public {
        game.setDisputeTimeout(20 days);
        vm.prank(owner);
        vm.expectRevert(ITokenCourt.WindowInvariantViolated.selector);
        court.setVoteWindow(14 days);
    }

    /// @notice The invariant is VACUOUS with no game wired — there is no
    ///         referral clock to fit yet.
    function test_setVoteWindow_vacuousWithNoGameWired() public {
        TokenCourt freshCourt = new TokenCourt(owner);
        vm.prank(owner);
        freshCourt.setVoteWindow(14 days); // no game wired: would violate the invariant if one were
        assertEq(freshCourt.voteWindow(), 14 days);
    }

    /// @notice BLOCKER (review 2026-07-29 audit, item 1): wiring to a NEW game
    ///         is itself a setter that can break the window invariant, and it
    ///         was completely unguarded. A game whose own `disputeTimeout`
    ///         cannot fit this court's CURRENT `voteWindow` must be refused at
    ///         the door.
    function test_setChallengeGame_revertsWindowInvariantViolated_whenNewGameCannotFit() public {
        MockGameForCourt tooTight = new MockGameForCourt();
        tooTight.setDisputeTimeout(8 days); // 7d autoSlashDelay + 5d court voteWindow + 1d buffer = 13d > 8d
        vm.prank(owner);
        vm.expectRevert(ITokenCourt.WindowInvariantViolated.selector);
        court.setChallengeGame(address(tooTight));
    }

    /// @notice THE INVERTED 3-STEP BYPASS (review 2026-07-29 audit, item 1
    ///         BLOCKER), as a single test: a FRESH court's `setVoteWindow` can
    ///         raise its window while unwired (vacuous — no game to check
    ///         against yet), and `setChallengeGame` must re-validate that
    ///         raised window against whatever game it is THEN pointed at,
    ///         rather than trusting the vacuous pass to mean the window is
    ///         fine. Mirrors `ChallengeGame`'s own `setCourt` bypass test
    ///         exactly, with the guarded/unguarded setters swapped.
    function test_setChallengeGame_bypassClosed_wiringAfterVacuousVoteWindowRaiseReverts() public {
        MockGameForCourt tight = new MockGameForCourt();
        tight.setDisputeTimeout(8 days); // pre-configured, tight clock — nothing to do with wiring yet
        TokenCourt freshCourt = new TokenCourt(owner);
        vm.startPrank(owner);
        freshCourt.setVoteWindow(14 days); // legal while vacuous: would violate against `tight` (7+14+1=22>8)
        vm.expectRevert(ITokenCourt.WindowInvariantViolated.selector);
        freshCourt.setChallengeGame(address(tight)); // wiring must catch what the vacuous branch let through
        vm.stopPrank();
    }

    /// @notice Issue #84, option 1: `setParticipationFloorBps` must not accept
    ///         a value that meets or exceeds the wired sWOOD's LIVE
    ///         `ageFloorBps()` (setUp's `MockStakedWood` defaults to 2_500).
    ///         Both the boundary (equality) and above it revert — see the
    ///         design's D2 for why equality is already the violating case:
    ///         `finalize` needs `turnout >= floor`, turnout is aged weight
    ///         bounded below by `ageFloorBps/10_000` of raw stake, so at
    ///         `participationFloorBps == ageFloorBps` the raw-turnout fraction
    ///         needed to clear is exactly 100% — every un-accused staked wei
    ///         voting at age zero, not a liveness guarantee anyone can stand
    ///         on, and exactly what the deploy pre-flight already rejects.
    function test_setParticipationFloorBps_revertsFloorInvariantViolated_atOrAboveWiredAgeFloor() public {
        assertEq(swood.ageFloorBps(), 2_500, "fixture assumption");
        vm.startPrank(owner);
        vm.expectRevert(ITokenCourt.FloorInvariantViolated.selector);
        court.setParticipationFloorBps(2_500); // equality: violates
        vm.expectRevert(ITokenCourt.FloorInvariantViolated.selector);
        court.setParticipationFloorBps(2_501); // above: violates
        vm.stopPrank();
    }

    /// @notice The mirror: strictly below the wired age floor succeeds,
    ///         emits, and lands in storage — the guard has a live path, not
    ///         only a revert path.
    function test_setParticipationFloorBps_acceptsStrictlyBelowWiredAgeFloor() public {
        vm.expectEmit(false, false, false, true);
        emit ITokenCourt.ParticipationFloorBpsSet(1_000, 2_499);
        vm.prank(owner);
        court.setParticipationFloorBps(2_499);
        assertEq(court.participationFloorBps(), 2_499);
    }

    /// @notice The invariant is VACUOUS with no electorate wired — there is
    ///         no age floor to compare against yet (mirrors
    ///         `test_setVoteWindow_vacuousWithNoGameWired`). The bypass this
    ///         opens is closed at the other end: wiring an electorate whose
    ///         age floor the raised value now meets or exceeds must revert.
    function test_setParticipationFloorBps_vacuousWithNoStakedWoodWired_bypassClosedAtWiring() public {
        TokenCourt freshCourt = new TokenCourt(owner);
        vm.startPrank(owner);
        freshCourt.setParticipationFloorBps(9_999); // no sWOOD wired: would violate against any real electorate
        assertEq(freshCourt.participationFloorBps(), 9_999);

        MockStakedWood freshSwood = new MockStakedWood(); // default ageFloorBps 2_500
        vm.expectRevert(ITokenCourt.FloorInvariantViolated.selector);
        freshCourt.setStakedWood(address(freshSwood)); // wiring must catch what the vacuous branch let through
        vm.stopPrank();
    }

    /// @notice `setStakedWood` validates unconditionally against the NEW
    ///         sWOOD's `ageFloorBps()` — no vacuous branch, every call
    ///         validates (design D4). Equality is refused; strictly above the
    ///         current floor is accepted.
    function test_setStakedWood_revertsFloorInvariantViolated_whenNewAgeFloorAtOrBelowCurrentFloor() public {
        assertEq(court.participationFloorBps(), 1_000, "fixture assumption");
        MockStakedWood tooLow = new MockStakedWood();
        tooLow.setAgeFloorBps(1_000); // equals the current floor: violates
        vm.prank(owner);
        vm.expectRevert(ITokenCourt.FloorInvariantViolated.selector);
        court.setStakedWood(address(tooLow));

        MockStakedWood justAbove = new MockStakedWood();
        justAbove.setAgeFloorBps(1_001); // strictly above: accepted
        vm.prank(owner);
        court.setStakedWood(address(justAbove));
        assertEq(court.stakedWood(), address(justAbove));
    }

    /// @notice Behavioural end-to-end sanity for the documented residual
    ///         (design D5): lowering `ageFloorBps` on the STAKING side is the
    ///         one lever this change deliberately does not guard, because
    ///         sWOOD holds no pointer back to the court. Proves (a) that
    ///         lowering it is legal and immediately visible to the court's
    ///         live read, (b) a subsequent `setParticipationFloorBps` at or
    ///         above the new (lower) age floor now correctly reverts, and (c)
    ///         the ALREADY-SET floor keeps operating — no retroactive wedge.
    function test_ageFloorLoweredOnStakedWoodSide_isLegalAndVisibleButNotGuardedHere() public {
        vm.prank(owner);
        court.setParticipationFloorBps(2_000); // legal: 2_000 < 2_500 (wired mock's default)
        assertEq(court.participationFloorBps(), 2_000);

        swood.setAgeFloorBps(2_000); // sWOOD-side lever: LEGAL, not guarded here — the documented residual
        assertEq(swood.ageFloorBps(), 2_000);

        vm.prank(owner);
        vm.expectRevert(ITokenCourt.FloorInvariantViolated.selector);
        court.setParticipationFloorBps(2_000); // now equals the LOWERED age floor: the court's guard catches it live

        assertEq(court.participationFloorBps(), 2_000, "no retroactive wedge: the already-set floor is untouched");
    }

    function test_views_nonexistentCaseReturnDefaults() public view {
        ITokenCourt.Case memory cs = court.caseOf(999);
        assertEq(cs.challengeId, 0);
        assertEq(uint256(cs.phase), uint256(ITokenCourt.Phase.None));
        assertEq(court.accusedOf(999).length, 0);
        assertEq(court.caseOfChallenge(address(game), 999), 0);
    }

    function test_setters_wiringEmitOldNew() public {
        // A REAL `IChallengeGame` STAND-IN, not a bare address (review
        // 2026-07-29 audit, item 1): `setChallengeGame` now calls the new
        // game's own `autoSlashDelay()`/`disputeTimeout()` to re-validate the
        // window invariant, which a code-less `makeAddr` has no answer for.
        // `MockGameForCourt`'s defaults (7d/30d) fit the court's current
        // 5-day `voteWindow` (7+5+1=13<=30).
        address newGame = address(new MockGameForCourt());
        vm.expectEmit(true, true, false, true);
        emit ITokenCourt.ChallengeGameSet(address(game), newGame);
        vm.prank(owner);
        court.setChallengeGame(newGame);

        // A REAL `IStakedWood`-shaped stand-in, not a bare address (issue
        // #84): `setStakedWood` now reads the new sWOOD's own `ageFloorBps()`
        // to enforce the floor invariant, which a code-less `makeAddr` has no
        // answer for. Hoisted before `vm.prank` — a call in argument position
        // would evaluate first and eat the one-shot prank. `MockStakedWood`'s
        // default `ageFloorBps` (2_500) comfortably clears the floor this
        // test raises to (2_000) below.
        address newSwood = address(new MockStakedWood());
        vm.expectEmit(true, true, false, true);
        emit ITokenCourt.StakedWoodSet(address(swood), newSwood);
        vm.prank(owner);
        court.setStakedWood(newSwood);

        vm.expectEmit(false, false, false, true);
        emit ITokenCourt.ParticipationFloorBpsSet(1_000, 2_000);
        vm.prank(owner);
        court.setParticipationFloorBps(2_000);
    }

    /// @dev Disputed challenge with sane clocks: filed now, 30d timeout,
    ///      proposal executed 1d ago. CHALLENGE_ID becomes referable.
    function _disputedChallenge() internal {
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
    }

    function test_refer_recordsSnapshotAndAccused() public {
        _disputedChallenge();
        address[] memory a = new address[](2);
        uint256[] memory c = new uint256[](2);
        a[0] = accusedG;
        c[0] = 100e18;
        a[1] = makeAddr("released");
        c[1] = 0; // released before filing: not accused
        ledger.setApprovers(a, c);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);

        vm.expectEmit(true, true, true, true);
        emit ITokenCourt.CaseReferred(1, CHALLENGE_ID, governor, PROPOSAL_ID, snap);
        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.AccusedSetRecorded(1, 1, 500e18);
        uint256 caseId = court.refer(CHALLENGE_ID);

        ITokenCourt.Case memory cs = court.caseOf(caseId);
        assertEq(cs.snapshotTs, snap, "executedAt - 1");
        assertEq(cs.voteWindowAtReferral, 5 days, "window pinned");
        assertEq(cs.accusedWeight, 500e18, "raw getPastStake sum");
        assertEq(uint256(cs.phase), uint256(ITokenCourt.Phase.Voting));
        assertTrue(court.isAccused(caseId, accusedG));
        assertFalse(court.isAccused(caseId, a[1]), "released is not accused");
        assertEq(court.caseOfChallenge(address(game), CHALLENGE_ID), caseId);
        assertEq(court.accusedOf(caseId).length, 1);
    }

    function test_refer_accusedWeight_sumsMultiple() public {
        _disputedChallenge();
        address accusedH = makeAddr("accusedH");
        address[] memory a = new address[](2);
        uint256[] memory c = new uint256[](2);
        a[0] = accusedG;
        c[0] = 100e18;
        a[1] = accusedH;
        c[1] = 250e18;
        ledger.setApprovers(a, c);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);
        swood.setPastStake(accusedH, snap, 300e18);

        uint256 caseId = court.refer(CHALLENGE_ID);

        ITokenCourt.Case memory cs = court.caseOf(caseId);
        assertEq(cs.accusedWeight, 800e18, "sums both accused stakes");
        assertEq(court.accusedOf(caseId).length, 2);
        assertTrue(court.isAccused(caseId, accusedG));
        assertTrue(court.isAccused(caseId, accusedH));
    }

    function test_refer_dedupesRepeatedApprover() public {
        _disputedChallenge();
        // The ledger names `accusedG` twice — `refer` must count its weight once.
        address[] memory a = new address[](2);
        uint256[] memory c = new uint256[](2);
        a[0] = accusedG;
        c[0] = 100e18;
        a[1] = accusedG;
        c[1] = 100e18;
        ledger.setApprovers(a, c);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);

        uint256 caseId = court.refer(CHALLENGE_ID);

        assertEq(court.accusedOf(caseId).length, 1, "counted once despite duplicate ledger entry");
        ITokenCourt.Case memory cs = court.caseOf(caseId);
        assertEq(cs.accusedWeight, 500e18, "weight counted once, not doubled");
    }

    /// @notice Issue #69: the exposure ledger the accused set was derived from
    ///         is PINNED into `Case` at `refer` — the last case input that used
    ///         to be resolved live inside `_recordAccused`.
    function test_ledgerPinnedAtRefer() public {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory c = new uint256[](1);
        a[0] = accusedG;
        c[0] = 100e18;
        ledger.setApprovers(a, c);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);

        uint256 caseId = court.refer(CHALLENGE_ID);

        ITokenCourt.Case memory cs = court.caseOf(caseId);
        assertEq(cs.ledger, address(ledger), "ledger the accused set came from is pinned");
        assertEq(cs.accusedWeight, 500e18, "accused weight derived from that same ledger");
    }

    /// @notice Issue #69 regression: an owner re-point of the game's exposure
    ///         ledger AFTER `refer` must not reach back into a live case.
    ///         Numbers mirror `test_finalize_accusedWeightLowersFloor`: floor =
    ///         10% of (1000e18 - 600e18) = 40e18, which a 45e18 turnout clears.
    ///         Had the re-point emptied the case's accused set, `accusedWeight`
    ///         would fall to zero, the floor would rise to 100e18, and the
    ///         verdict would flip to `Inconclusive` — so the finalize path is
    ///         itself an assertion that the pin held.
    function test_repointAfterReferDoesNotDisturbCase() public {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 600e18);

        uint256 id = court.refer(CHALLENGE_ID);
        uint256 accusedCountBefore = court.accusedOf(id).length;

        // The owner re-points the game at a ledger that names nobody.
        MockLedgerForCourt emptyLedger = new MockLedgerForCourt();
        game.setExposureLedger(address(emptyLedger));

        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(c.ledger, address(ledger), "pinned ledger survives the re-point");
        assertEq(c.accusedWeight, 600e18, "accused weight survives the re-point");
        assertTrue(court.isAccused(id, accusedG), "accused set survives the re-point");
        assertEq(court.accusedOf(id).length, accusedCountBefore, "accused list unchanged");

        swood.setPastTotalVotes(snap, 1_000e18);
        swood.setPastVotes(voterA, snap, 45e18);
        vm.prank(voterA);
        court.vote(id, true);

        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Guilty, 45e18, 0, 40e18);
        court.finalize(id);
        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "floor still computed off the pinned accused weight"
        );
    }

    /// @notice Issue #69's "check when doing it": pinning the ledger without
    ///         its derived weight would leave half the property. The stored
    ///         `accusedWeight` must be exactly the `getPastStake` sum over the
    ///         PINNED ledger's still-committed approvers at the PINNED
    ///         `snapshotTs` — recomputed here from `Case` alone.
    function test_ledgerAndWeightPinnedTogether() public {
        _disputedChallenge();
        address accusedH = makeAddr("accusedH");
        address[] memory a = new address[](3);
        uint256[] memory cm = new uint256[](3);
        a[0] = accusedG;
        cm[0] = 100e18;
        a[1] = accusedH;
        cm[1] = 250e18;
        a[2] = makeAddr("released");
        cm[2] = 0; // released before the filing: backs nothing, not accused
        ledger.setApprovers(a, cm);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);
        swood.setPastStake(accusedH, snap, 300e18);
        swood.setPastStake(a[2], snap, 900e18); // must never enter the sum

        uint256 id = court.refer(CHALLENGE_ID);

        ITokenCourt.Case memory c = court.caseOf(id);
        (address[] memory approvers, uint256[] memory committed) =
            MockLedgerForCourt(c.ledger).approversOf(governor, PROPOSAL_ID);
        uint256 expected;
        for (uint256 i; i < approvers.length; ++i) {
            if (committed[i] == 0) continue;
            expected += swood.getPastStake(approvers[i], c.snapshotTs);
        }
        assertEq(expected, 800e18, "fixture sanity: the recompute sees both live approvers");
        assertEq(c.accusedWeight, expected, "weight is the pinned ledger's sum at the pinned snapshot");

        // The identity holds after a re-point too: both halves moved together
        // or neither did.
        game.setExposureLedger(address(new MockLedgerForCourt()));
        ITokenCourt.Case memory pinned = court.caseOf(id);
        assertEq(pinned.ledger, address(ledger), "ledger half still pinned");
        assertEq(pinned.accusedWeight, expected, "weight half still pinned");
    }

    function test_refer_guards() public {
        // Unwired court refuses (review E4 closed structurally).
        TokenCourt fresh = new TokenCourt(owner);
        vm.expectRevert(ITokenCourt.ZeroAddress.selector);
        fresh.refer(CHALLENGE_ID);

        // Wired game but zero stakedWood also refuses.
        TokenCourt halfWired = new TokenCourt(owner);
        vm.prank(owner);
        halfWired.setChallengeGame(address(game));
        vm.expectRevert(ITokenCourt.ZeroAddress.selector);
        halfWired.refer(CHALLENGE_ID);

        // Not disputed.
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Filed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        vm.expectRevert(ITokenCourt.ChallengeNotDisputed.selector);
        court.refer(CHALLENGE_ID);

        // Unexecuted proposal fails closed.
        game.setChallenge(
            CHALLENGE_ID, governor, PROPOSAL_ID, IChallengeGame.Status.Disputed, vm.getBlockTimestamp(), 30 days, 0
        );
        vm.expectRevert(ITokenCourt.InvalidParameter.selector);
        court.refer(CHALLENGE_ID);

        // Double referral.
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        court.refer(CHALLENGE_ID);
        vm.expectRevert(ITokenCourt.AlreadyReferred.selector);
        court.refer(CHALLENGE_ID);
    }

    function test_refer_clockCheckBoundary() public {
        // remaining == voteWindow + FINALIZE_BUFFER passes; one second less refuses.
        uint256 filedAt = vm.getBlockTimestamp();
        game.setChallenge(
            CHALLENGE_ID, governor, PROPOSAL_ID, IChallengeGame.Status.Disputed, filedAt, 30 days, filedAt - 1 days
        );

        uint256 exactLatest = filedAt + 30 days - (5 days + 1 days);
        vm.warp(exactLatest);
        uint256 caseId = court.refer(CHALLENGE_ID); // boundary passes
        assertEq(caseId, 1);

        game.setChallenge(
            CHALLENGE_ID + 1, governor, PROPOSAL_ID, IChallengeGame.Status.Disputed, filedAt, 30 days, filedAt - 1 days
        );
        vm.warp(exactLatest + 1);
        vm.expectRevert(ITokenCourt.InsufficientClock.selector);
        court.refer(CHALLENGE_ID + 1);
    }

    function test_refer_secondChallengeOnSameProposal_distinctCase() public {
        // Two challenges can name the same (governor, proposalId) pair —
        // e.g. a failed challenge followed by a fresh one — and each gets
        // its own case.
        _disputedChallenge();
        uint256 firstCase = court.refer(CHALLENGE_ID);

        game.setChallenge(
            CHALLENGE_ID + 1,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        uint256 secondCase = court.refer(CHALLENGE_ID + 1);

        assertTrue(secondCase != firstCase, "distinct case ids");
        assertEq(court.caseOfChallenge(address(game), CHALLENGE_ID), firstCase);
        assertEq(court.caseOfChallenge(address(game), CHALLENGE_ID + 1), secondCase);
    }

    /// @notice B1: `ChallengeGame` is non-upgradeable, so redeploying it IS
    ///         the migration path (`setChallengeGame` exists to serve it) —
    ///         but a fresh game's `challengeCount` restarts at 0, so its
    ///         challenge ids collide with every id the old game ever minted.
    ///         Single-keyed by challenge id alone, this collision made BOTH
    ///         the auto-referral and the permissionless manual `refer`
    ///         fallback revert `AlreadyReferred` forever on the new game's
    ///         colliding ids, with no exit but `disputeTimeout` auto-acquitting
    ///         the accused. Namespacing `caseOfChallenge` by (game, challenge)
    ///         closes it: the same numeric challenge id on two different
    ///         games gets two independent cases.
    function test_refer_afterGameMigration_doesNotCollideOnChallengeId() public {
        _disputedChallenge();
        uint256 firstCase = court.refer(CHALLENGE_ID);
        assertEq(firstCase, 1);

        // Migrate to a second game; its ids restart from the same numbers.
        MockGameForCourt game2 = new MockGameForCourt();
        game2.setExposureLedger(address(ledger));
        vm.prank(owner);
        court.setChallengeGame(address(game2));

        // `setChallengeGame` now RE-VALIDATES the window invariant against the
        // new game's own clocks (review 2026-07-29 audit, item 1): game2's
        // defaults (7d autoSlashDelay / 30d disputeTimeout) fit the court's
        // current 5-day voteWindow (7+5+1=13<=30), so that check above already
        // passed and no extra wiring is needed here.
        game2.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );

        uint256 secondCase = court.refer(CHALLENGE_ID); // MUST NOT revert AlreadyReferred
        assertEq(secondCase, 2, "the new game's challenge gets its own case");
        assertEq(court.caseOfChallenge(address(game2), CHALLENGE_ID), secondCase);
        assertEq(court.caseOfChallenge(address(game), CHALLENGE_ID), firstCase, "the old mapping is intact");
    }

    /// @notice ISSUE #83, the seam in one assertion: the accused set is derived
    ///         from the PLEDGE, so a settlement pass that wrote a guardian's
    ///         LIVE BOOKING down to zero cannot lift the bar off it.
    /// @dev    `setCommittedOnly` is what `ExposureLedger._rebook` does to an
    ///         approver whose own slashable bond has been emptied by a
    ///         concurrent conviction — the booking goes to zero, the pledge is
    ///         untouched. Before the fix `_recordAccused` read the booking,
    ///         saw zero, and `continue`d: `accusedG` came out unaccused, with
    ///         its stake missing from `accusedWeight`, free to vote at full
    ///         pre-slash weight on the case its own approval caused.
    ///
    ///         `released` is the control. It really did release, so BOTH its
    ///         numbers are zero and it must stay out of the set — the
    ///         behaviour the zero-filter was written for, unchanged.
    function test_refer_accusedByPledgeNotBySettledBooking() public {
        _disputedChallenge();
        address released = makeAddr("released");
        address[] memory a = new address[](2);
        uint256[] memory cm = new uint256[](2);
        a[0] = accusedG;
        cm[0] = 100e18;
        a[1] = released;
        cm[1] = 0;
        ledger.setApprovers(a, cm);
        // Step 4 of the chain: anyone calls `settleCoverage`, and the approver
        // a concurrent conviction already emptied is booked at zero.
        ledger.setCommittedOnly(accusedG, 0);
        (, uint256[] memory bookedNow) = ledger.approversOf(governor, PROPOSAL_ID);
        (, uint256[] memory pledgedNow) = ledger.pledgedOf(governor, PROPOSAL_ID);
        assertEq(bookedNow[0], 0, "fixture: the live booking really is zero");
        assertEq(pledgedNow[0], 100e18, "fixture: the pledge is untouched by settlement");

        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);
        swood.setPastStake(released, snap, 900e18); // must never enter the sum

        uint256 caseId = court.refer(CHALLENGE_ID);

        assertTrue(court.isAccused(caseId, accusedG), "a zeroed BOOKING does not clear the accusation");
        assertFalse(court.isAccused(caseId, released), "a real release still is not accused");
        assertEq(court.accusedOf(caseId).length, 1);
        assertEq(court.caseOf(caseId).accusedWeight, 500e18, "its stake still counts against the floor");

        // Step 6, the inversion itself: the bar must actually bite.
        swood.setPastVotes(accusedG, snap, 500e18); // full PRE-slash weight, as `getPastVotes` reports it
        vm.prank(accusedG);
        vm.expectRevert(ITokenCourt.AccusedCannotVote.selector);
        court.vote(caseId, false);
    }

    /// @notice The set and the weight are FROZEN at `refer`. Nothing the ledger
    ///         does afterwards — a further settlement pass in either direction,
    ///         or a release — may reach back into a live case.
    /// @dev    Complements `test_repointAfterReferDoesNotDisturbCase`, which
    ///         pins WHICH ledger the case reads (#69). This pins WHAT that
    ///         ledger said (#83): the accused set is written into storage once
    ///         and never re-derived, so a post-`refer` mutation of either
    ///         number is inert.
    function test_referSnapshotsTheAccusedSet_laterLedgerMovesAreInert() public {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);

        uint256 caseId = court.refer(CHALLENGE_ID);
        assertTrue(court.isAccused(caseId, accusedG));
        assertEq(court.caseOf(caseId).accusedWeight, 500e18);

        // A later settlement pass writes the booking down to nothing...
        ledger.setCommittedOnly(accusedG, 0);
        assertTrue(court.isAccused(caseId, accusedG), "still accused");
        assertEq(court.caseOf(caseId).accusedWeight, 500e18, "weight unmoved");

        // ...and a wholesale rewrite of the ledger's content, pledge included,
        // is equally inert. Even the raw stake read moving cannot shift it.
        address[] memory empty = new address[](0);
        ledger.setApprovers(empty, new uint256[](0));
        swood.setPastStake(accusedG, snap, 1e18);
        assertTrue(court.isAccused(caseId, accusedG), "the flag is storage, not a live re-read");
        assertEq(court.accusedOf(caseId).length, 1, "the list is storage too");
        assertEq(court.caseOf(caseId).accusedWeight, 500e18, "and so is the weight");

        vm.prank(accusedG);
        vm.expectRevert(ITokenCourt.AccusedCannotVote.selector);
        court.vote(caseId, true);
    }

    /// @notice THE ORDINARY CASE MUST NOT REGRESS: an approver whose booking
    ///         legitimately reads non-zero at `refer` is accused and barred,
    ///         exactly as before #83. Widening the predicate from the booking
    ///         to the pledge may only ADD to the set, never remove from it.
    function test_vote_accusedCannotVote_ordinaryNonZeroBooking() public {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18; // never settled: booking and pledge agree, both non-zero
        ledger.setApprovers(a, cm);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);

        uint256 caseId = court.refer(CHALLENGE_ID);
        (, uint256[] memory booked) = ledger.approversOf(governor, PROPOSAL_ID);
        assertEq(booked[0], 100e18, "fixture: this is the un-settled, non-zero-booking case");
        assertTrue(court.isAccused(caseId, accusedG));

        swood.setPastVotes(accusedG, snap, 500e18);
        vm.prank(accusedG);
        vm.expectRevert(ITokenCourt.AccusedCannotVote.selector);
        court.vote(caseId, true);

        // And an unrelated holder is still perfectly able to vote — the bar is
        // aimed at the accused, not at the electorate.
        swood.setPastVotes(voterA, snap, 300e18);
        swood.setPastTotalVotes(snap, 1_000e18);
        vm.prank(voterA);
        court.vote(caseId, true);
        assertEq(court.caseOf(caseId).guiltyVotes, 300e18);
    }

    function _referredCase() internal returns (uint256 caseId) {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        caseId = court.refer(CHALLENGE_ID);
        uint256 snap = court.caseOf(caseId).snapshotTs;
        swood.setPastVotes(voterA, snap, 300e18);
        swood.setPastVotes(voterB, snap, 200e18);
        swood.setPastTotalVotes(snap, 1_000e18);
    }

    /// @dev Exercises the issue #82 growth-gated min's BOOTSTRAP FALLBACK, not
    ///      the clamp: `_referredCase` never sets a lookback total
    ///      (`getPastTotalVotes(snap - FLOOR_LOOKBACK)` reads the mock's
    ///      default 0), so the gate's `&& getPastTotalVotes(lookbackTs) != 0`
    ///      conjunct is false and the recorded weight is the unclamped
    ///      `getPastVotes(voter, snap)` — bit-identical to pre-#82 behaviour.
    function test_vote_tallies_agedWeight() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.prank(voterB);
        court.vote(id, false);
        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(c.guiltyVotes, 300e18);
        assertEq(c.notGuiltyVotes, 200e18);
        assertEq(uint256(court.voteOf(id, voterA)), uint256(ITokenCourt.Ruling.Guilty));
        assertEq(uint256(court.voteOf(id, voterB)), uint256(ITokenCourt.Ruling.NotGuilty));
    }

    function test_vote_emitsWeight() public {
        uint256 id = _referredCase();
        vm.expectEmit(true, true, false, true);
        emit ITokenCourt.VoteCast(id, voterA, true, 300e18);
        vm.prank(voterA);
        court.vote(id, true);
    }

    function test_vote_guards() public {
        uint256 id = _referredCase();

        // Nonexistent case: phase None.
        vm.prank(voterA);
        vm.expectRevert(ITokenCourt.WrongPhase.selector);
        court.vote(999, true);

        vm.prank(voterA);
        court.vote(id, true);
        vm.prank(voterA);
        vm.expectRevert(ITokenCourt.AlreadyVoted.selector);
        court.vote(id, false);

        vm.prank(accusedG);
        vm.expectRevert(ITokenCourt.AccusedCannotVote.selector);
        court.vote(id, false);

        address dust = makeAddr("noWeight");
        vm.prank(dust);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(id, true);

        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.prank(voterB);
        vm.expectRevert(ITokenCourt.WindowClosed.selector);
        court.vote(id, false);
    }

    function test_vote_refusesAFullyExitedHolder() public {
        uint256 id = _referredCase();
        uint256 snap = court.caseOf(id).snapshotTs;
        address exited = makeAddr("exited");
        swood.setPastVotes(exited, snap, 400e18); // historic weight survives the exit
        swood.setVotes(exited, 0); // present holdings: none
        vm.prank(exited);
        vm.expectRevert(ITokenCourt.NoPresentHoldings.selector);
        court.vote(id, false);
    }

    /// @dev The mock's `getVotes` can't distinguish "claimed and gone" from
    ///      "requested, cooling down, WOOD still locked in the contract" —
    ///      both collapse to present votes == 0 the instant
    ///      `requestUnstakeGuardian` re-anchors `stakedAt` and zeros the
    ///      checkpoint (real contract; see `StakedWood.requestUnstakeGuardian`).
    ///      That is the point: the gate is binary on present holdings, so a
    ///      guardian mid-cooldown is refused exactly like one who already
    ///      claimed out — there is no partial credit for "technically still
    ///      recoverable". The REAL request -> vote-reverts arc, on a real
    ///      `StakedWood` stack, is proven end-to-end in
    ///      `TokenCourtEndToEnd.t.sol`'s `test_arc_requestedUnstakeMidCooldown_blocksVote`.
    function test_vote_refusesAGuardianMidCooldown() public {
        uint256 id = _referredCase();
        uint256 snap = court.caseOf(id).snapshotTs;
        address cooling = makeAddr("cooling");
        swood.setPastVotes(cooling, snap, 250e18); // historic weight, staked before the drain
        swood.setVotes(cooling, 0); // requested unstake: present votes already zeroed, WOOD still locked
        vm.prank(cooling);
        vm.expectRevert(ITokenCourt.NoPresentHoldings.selector);
        court.vote(id, true);
    }

    /// @dev Also exercises the bootstrap-fallback branch (issue #82): no
    ///      lookback total is set on `_referredCase`'s fixture, so the gate's
    ///      total conjunct is false and the recorded weight below is the
    ///      unclamped snapshot read, same as before the growth gate existed.
    function test_vote_acceptsACurrentHolderWithHistoricWeight() public {
        uint256 id = _referredCase();
        swood.setVotes(voterA, 42); // present stake distinguishable from the mock's default-1
        vm.prank(voterA);
        court.vote(id, true);
        assertEq(court.caseOf(id).guiltyVotes, 300e18, "weight is still the SNAPSHOT figure, not the present one");
    }

    /// @dev The latecomer has NO snapshot weight, so the pre-existing
    ///      `weight == 0` check (`NoVotingPower`) fires before the
    ///      present-holdings gate (`NoPresentHoldings`) is ever reached —
    ///      mutation-confirmed: deleting the B4 gate does not fail this test.
    ///      Kept anyway because it pins that ordering explicitly.
    /// @dev The latecomer has present holdings but NO snapshot weight, so it
    ///      fails only the pre-existing `weight == 0` check -- it never even
    ///      reaches the present-holdings gate. This does NOT pin the two
    ///      checks' ORDERING: an address failing just one check gets the same
    ///      error regardless of which check runs first. See
    ///      `test_vote_bothChecksFail_getsNoVotingPowerNotNoPresentHoldings`
    ///      for the test that actually is ordering-sensitive.
    function test_vote_presentHolderWithoutSnapshotWeightRevertsNoVotingPower() public {
        uint256 id = _referredCase();
        address latecomer = makeAddr("latecomer");
        swood.setVotes(latecomer, 5_000e18); // bought in after the drain
        vm.prank(latecomer);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(id, true);
    }

    /// @dev An address failing BOTH checks must get `NoVotingPower` ("no
    ///      remedy — never had snapshot weight"), not `NoPresentHoldings`
    ///      ("re-stake and you're fine" — false here, re-staking cannot
    ///      manufacture weight at a past snapshot). This IS ordering-
    ///      sensitive: swap the two checks in `vote` and this test starts
    ///      failing, because the present-holdings check would then fire
    ///      first and revert `NoPresentHoldings` instead.
    function test_vote_bothChecksFail_getsNoVotingPowerNotNoPresentHoldings() public {
        uint256 id = _referredCase();
        address neither = makeAddr("neither"); // no setPastVotes, no setVotes: zero on both axes
        vm.prank(neither);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(id, true);
    }

    function test_vote_windowIsThePinnedOne() public {
        // Owner shortening voteWindow after referral must NOT close a live case early.
        uint256 id = _referredCase();
        vm.prank(owner);
        court.setVoteWindow(1 days);
        vm.warp(vm.getBlockTimestamp() + 2 days); // past the NEW window, inside the pinned 5d
        vm.prank(voterA);
        court.vote(id, true); // must succeed
        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(c.guiltyVotes, 300e18);
    }

    function test_vote_windowLengtheningDoesNotExtendLiveCase() public {
        // Owner lengthening voteWindow after referral must NOT extend a live case's clock either.
        uint256 id = _referredCase();
        vm.prank(owner);
        court.setVoteWindow(10 days);
        vm.warp(vm.getBlockTimestamp() + 5 days); // the case's PINNED window has closed
        vm.prank(voterA);
        vm.expectRevert(ITokenCourt.WindowClosed.selector);
        court.vote(id, true);
        court.finalize(id); // pinned window is genuinely closed at this instant
        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Resolved));
    }

    // ── issue #82: the growth-gated ballot min ──

    /// @dev Opens a bare referable case recording NO fixture weight — each
    ///      growth-gate test below wires `voterA`'s (or an attacker's)
    ///      raw/aged state itself, explicitly via `setPastStake`, to decouple
    ///      raw from aged weight (the mock's `getPastStake` otherwise
    ///      defaults to the `getPastVotes` fixture, coupling the two).
    function _openGateCase() internal returns (uint256 caseId, uint256 snap, uint256 lookbackTs) {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        caseId = court.refer(CHALLENGE_ID);
        snap = court.caseOf(caseId).snapshotTs;
        lookbackTs = snap - court.FLOOR_LOOKBACK();
    }

    /// @dev (a) Steady-mature regression: equal raw AND equal aged weight at
    ///      both instants -> gate false -> tally and `VoteCast` equal
    ///      `getPastVotes(snap)` bit-exactly.
    function test_vote_growthGate_steadyMatureRegression_tallyBitIdenticalToSnapshotRead() public {
        (uint256 id, uint256 snap, uint256 lookbackTs) = _openGateCase();
        swood.setPastTotalVotes(lookbackTs, 1_000e18);
        swood.setPastStake(voterA, snap, 500e18);
        swood.setPastStake(voterA, lookbackTs, 500e18);
        swood.setPastVotes(voterA, snap, 500e18);
        swood.setPastVotes(voterA, lookbackTs, 500e18);

        vm.expectEmit(true, true, false, true);
        emit ITokenCourt.VoteCast(id, voterA, true, 500e18);
        vm.prank(voterA);
        court.vote(id, true);
        assertEq(court.caseOf(id).guiltyVotes, 500e18);
    }

    /// @dev (b) YOUNG STEADY STAKER AT PAR — the 2b headline test, kills 2a's
    ///      unconditional min and any weight-gated variant. Equal raw at both
    ///      instants (steady position, gate must be false) but the aged
    ///      weight at the lookback is LOWER than at the snapshot (still
    ///      maturing) -> tally equals the UNCLAMPED `weightNow`, never the
    ///      smaller historical figure.
    function test_vote_growthGate_youngSteadyStakerVotesAtParUnclamped() public {
        (uint256 id, uint256 snap, uint256 lookbackTs) = _openGateCase();
        swood.setPastTotalVotes(lookbackTs, 1_000e18);
        swood.setPastStake(voterA, snap, 500e18);
        swood.setPastStake(voterA, lookbackTs, 500e18); // steady raw: gate must stay false
        swood.setPastVotes(voterA, snap, 500e18); // matured to par by the snapshot
        swood.setPastVotes(voterA, lookbackTs, 125e18); // still at the age floor a month ago

        vm.prank(voterA);
        court.vote(id, true);
        assertEq(court.caseOf(id).guiltyVotes, 500e18, "steady raw must never clamp to the lookback figure");
    }

    /// @dev (c) Top-up bound: `rawNow > rawThen > 0`, `weightThen` non-zero ->
    ///      tally is exactly `weightThen`, unreduced by any snapshot-side
    ///      factor (kills a live-anchor-style implementation that would let
    ///      the top-up's re-anchor drag the historical side down too).
    function test_vote_growthGate_topUpBoundsTallyAtLookbackWeight() public {
        (uint256 id, uint256 snap, uint256 lookbackTs) = _openGateCase();
        swood.setPastTotalVotes(lookbackTs, 1_000e18);
        swood.setPastStake(voterA, lookbackTs, 400e18);
        swood.setPastStake(voterA, snap, 900e18); // topped up inside the window
        swood.setPastVotes(voterA, lookbackTs, 380e18); // the base's aged worth a month ago
        swood.setPastVotes(voterA, snap, 900e18); // full re-anchored weight, near par

        vm.prank(voterA);
        court.vote(id, true);
        assertEq(
            court.caseOf(id).guiltyVotes, 380e18, "top-up must not raise the ballot above the base's month-ago worth"
        );
    }

    /// @dev (d) Gate-true, weight-fell coherence (design §1.1): raw grew
    ///      (gate true) but the aged weight at the snapshot is SMALLER than
    ///      at the lookback (a re-anchoring sequence) -> tally is
    ///      `weightNow`, the smaller side: a gated voter never collects the
    ///      larger historical figure either.
    function test_vote_growthGate_weightFellOnGrowthPath_tallyIsTheSmallerCurrentWeight() public {
        (uint256 id, uint256 snap, uint256 lookbackTs) = _openGateCase();
        swood.setPastTotalVotes(lookbackTs, 1_000e18);
        swood.setPastStake(voterA, lookbackTs, 100e18);
        swood.setPastStake(voterA, snap, 200e18); // raw grew: gate true
        swood.setPastVotes(voterA, lookbackTs, 150e18); // aged weight was HIGHER back then
        swood.setPastVotes(voterA, snap, 90e18); // re-anchor knocked current weight down

        vm.prank(voterA);
        court.vote(id, true);
        assertEq(court.caseOf(id).guiltyVotes, 90e18, "min must never hand a gated voter the larger historical figure");
    }

    /// @dev (e) Shrink: `rawNow < rawThen` -> gate false -> tally is
    ///      `weightNow`, never the larger historical figure, even though
    ///      `weightThen > weightNow` here (kills `>=`-gating and any rule
    ///      handing a shrinker the historical figure).
    function test_vote_growthGate_shrunkPositionNeverGetsTheHistoricalFigure() public {
        (uint256 id, uint256 snap, uint256 lookbackTs) = _openGateCase();
        swood.setPastTotalVotes(lookbackTs, 1_000e18);
        swood.setPastStake(voterA, lookbackTs, 500e18);
        swood.setPastStake(voterA, snap, 200e18); // raw shrank
        swood.setPastVotes(voterA, lookbackTs, 500e18); // larger historical weight
        swood.setPastVotes(voterA, snap, 200e18); // current (smaller) weight

        vm.prank(voterA);
        court.vote(id, true);
        assertEq(
            court.caseOf(id).guiltyVotes, 200e18, "a shrunk position must never be rewarded with its historical figure"
        );
    }

    /// @dev (f) Fresh-address attack regression (issue #82): `rawThen == 0`,
    ///      non-zero snapshot weight, non-zero lookback total ->
    ///      `NoVotingPower`, mutation-killing a revert back to the bare
    ///      single-instant read. This is the issue's worked trace: WOOD
    ///      staked one second before a drain, previously voting at
    ///      `ageFloorBps` of raw.
    function test_vote_growthGate_freshAddressAttackClosed() public {
        (uint256 id, uint256 snap, uint256 lookbackTs) = _openGateCase();
        swood.setPastTotalVotes(lookbackTs, 1_000e18); // a real electorate existed a lookback ago
        address attacker = makeAddr("freshWhale");
        swood.setPastStake(attacker, snap, 1_200_000e18); // staked one second before the drain
        swood.setPastStake(attacker, lookbackTs, 0); // nothing a lookback ago
        swood.setPastVotes(attacker, snap, 300_000e18); // ageFloorBps (25%) of raw

        vm.prank(attacker);
        vm.expectRevert(ITokenCourt.NoVotingPower.selector);
        court.vote(id, true);
    }

    /// @dev (g) Partial-position attacker (design §3.1): `rawThen = P > 0`,
    ///      topped up at drain time by any amount -> tally is exactly the
    ///      base's month-ago worth, unmoved by the increment's size.
    function test_vote_growthGate_partialPositionTopUpBuysNothingBeyondMonthAgoWorth() public {
        (uint256 id, uint256 snap, uint256 lookbackTs) = _openGateCase();
        swood.setPastTotalVotes(lookbackTs, 1_000e18);
        swood.setPastStake(voterA, lookbackTs, 100e18); // pre-existing base P = 100e18
        swood.setPastStake(voterA, snap, 100e18 + 1_000_000e18); // drain-time top-up of any size
        swood.setPastVotes(voterA, lookbackTs, 25e18); // P's aged worth (ageFloorBps) a month ago
        swood.setPastVotes(voterA, snap, 1_000_100e18); // full re-anchored weight, near par on the huge base

        vm.prank(voterA);
        court.vote(id, true);
        assertEq(court.caseOf(id).guiltyVotes, 25e18, "the top-up must buy nothing beyond the base's month-ago worth");
    }

    /// @dev (h) Bootstrap: no lookback total is ever recorded (mock default
    ///      0) -> the fallback fires regardless of what the raw comparison
    ///      would have been -> weight unclamped.
    function test_vote_growthGate_bootstrapSkipsTheClampEvenWhenGateWouldBeTrue() public {
        (uint256 id, uint256 snap,) = _openGateCase();
        // Deliberately no setPastTotalVotes at the lookback: mock default 0.
        swood.setPastStake(voterA, snap, 500e18);
        swood.setPastVotes(voterA, snap, 500e18);

        vm.prank(voterA);
        court.vote(id, true);
        assertEq(court.caseOf(id).guiltyVotes, 500e18, "bootstrap must leave the ballot unclamped");
    }

    // ── finalize ──

    function test_finalize_verdictMatrix_guiltyMajority() public {
        uint256 id = _referredCase(); // floor = 10% of 1000e18 = 100e18
        vm.prank(voterA);
        court.vote(id, true); // 300e18
        vm.prank(voterB);
        court.vote(id, false); // 200e18 -> turnout 500e18 >= floor
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(uint256(c.verdict), uint256(IChallengeGame.Verdict.Guilty));
        assertEq(uint256(c.phase), uint256(ITokenCourt.Phase.Resolved));
        assertEq(c.finalizedAt, vm.getBlockTimestamp());
        assertEq(uint256(game.lastVerdict()), uint256(IChallengeGame.Verdict.Guilty));
        assertEq(game.lastRuledChallenge(), CHALLENGE_ID);
    }

    function test_finalize_tieAcquits() public {
        uint256 id = _referredCase();
        uint256 snap = court.caseOf(id).snapshotTs;
        swood.setPastVotes(voterB, snap, 300e18); // equalize
        vm.prank(voterA);
        court.vote(id, true);
        vm.prank(voterB);
        court.vote(id, false);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).verdict), uint256(IChallengeGame.Verdict.NotGuilty), "tie -> fail-safe");
    }

    function test_finalize_belowFloorInconclusive_andZeroTurnout() public {
        uint256 id = _referredCase();
        uint256 snap = court.caseOf(id).snapshotTs;
        address dust = makeAddr("dustVoter");
        swood.setPastVotes(dust, snap, 1e18); // << 100e18 floor
        vm.prank(dust);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).verdict), uint256(IChallengeGame.Verdict.Inconclusive));

        // Zero turnout, second case (same proposal, generous clock).
        game.setChallenge(
            CHALLENGE_ID + 1,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        uint256 id2 = court.refer(CHALLENGE_ID + 1);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id2);
        assertEq(uint256(court.caseOf(id2).verdict), uint256(IChallengeGame.Verdict.Inconclusive));
    }

    function test_finalize_accusedWeightLowersFloor() public {
        // floor = 10% of (1000e18 - 600e18) = 40e18; a 45e18 aged turnout clears it.
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18; // committed USD, nonzero so accusedG is in the accused set
        ledger.setApprovers(a, cm);
        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 600e18);

        uint256 id = court.refer(CHALLENGE_ID);
        assertEq(court.caseOf(id).accusedWeight, 600e18, "accused raw stake recorded");

        swood.setPastTotalVotes(snap, 1_000e18);
        swood.setPastVotes(voterA, snap, 45e18);

        vm.prank(voterA);
        court.vote(id, true);

        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);

        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(uint256(c.verdict), uint256(IChallengeGame.Verdict.Guilty), "cleared the lowered floor");
    }

    function test_finalize_terminalRace_caseClosesViaCatch() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        game.setRuleReverts(true); // challenge already terminal on the game side
        vm.expectEmit(true, true, false, false);
        emit ITokenCourt.ChallengeAlreadyTerminal(id, CHALLENGE_ID);
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Resolved), "case closed anyway");
        assertFalse(game.ruled(), "verdict never landed");
    }

    /// @dev THE VERDICT-BURNING REGRESSION. A bare `catch` in `finalize` would
    ///      let an under-gassed call trip `rule`'s own `InsufficientSlashGas`
    ///      gas floor while the OUTER `finalize` call still has plenty of gas
    ///      to complete on the refund — writing `Resolved` and silently
    ///      dropping a `Guilty` verdict forever. The fix bubbles that revert
    ///      instead: the under-gassed call must revert the WHOLE `finalize`,
    ///      leaving the case `Voting` for an honest, adequately-gassed retry.
    function test_finalize_underGassedCall_revertsAndLeavesCaseVoting() public {
        uint256 id = _referredCase(); // floor = 100e18
        vm.prank(voterA);
        court.vote(id, true); // 300e18 guilty, clears the floor alone
        vm.warp(vm.getBlockTimestamp() + 5 days);

        // STRUCTURAL, not gas-tuned: set the floor EQUAL to the outer cap
        // (200_000). EIP-150 forwards at most 63/64 of the gas available at
        // the CALL, so the child can receive at most 200_000 * 63/64 ==
        // 196_875 < 200_000 -- `rule`'s own gasleft() < ruleGasFloor check
        // trips no matter how the parent's pre-CALL cost (SLOADs, the swood
        // staticcall, event emission -- measured ~30.7k here, leaving ~5.5x
        // headroom to reach the CALL) moves with compiler or optimizer
        // settings, because the 1/64th withheld alone already exceeds it.
        game.setRuleGasFloor(200_000);

        vm.expectRevert(IChallengeGame.InsufficientSlashGas.selector);
        court.finalize{gas: 200_000}(id);

        ITokenCourt.Case memory c = court.caseOf(id);
        assertEq(uint256(c.phase), uint256(ITokenCourt.Phase.Voting), "under-gassed call must not resolve the case");
        assertFalse(game.ruled(), "verdict never landed on the under-gassed attempt");

        // Control: a plain (adequately gassed) retry lands the verdict.
        court.finalize(id);
        c = court.caseOf(id);
        assertEq(uint256(c.phase), uint256(ITokenCourt.Phase.Resolved), "honest retry resolves the case");
        assertTrue(game.ruled(), "verdict landed on the honest retry");
        assertEq(uint256(game.lastVerdict()), uint256(IChallengeGame.Verdict.Guilty));
    }

    /// @dev A TRANSIENT, NON-TERMINAL revert (anything other than
    ///      `WrongStatus`) must bubble out of `finalize` whole, exactly like
    ///      the gas-floor case above, so the case survives for a retry once
    ///      the underlying condition clears.
    function test_finalize_transientRevert_bubblesAndLeavesCaseVoting() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        game.setRuleRevertsOther(true); // stand-in: reverts ZeroAddress, not WrongStatus
        vm.expectRevert(IChallengeGame.ZeroAddress.selector);
        court.finalize(id);
        assertEq(
            uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Voting), "transient revert must not resolve"
        );

        game.setRuleRevertsOther(false); // condition cleared
        court.finalize(id);
        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Resolved), "retry resolves once cleared");
        assertTrue(game.ruled());
    }

    /// @dev `NotCourt` (the game's `court` re-pointed away before `rule`
    ///      landed, e.g. an owner `setCourt(address(0))` emergency lever)
    ///      does NOT mean "nothing left to rule" (B2) - the challenge is
    ///      still `Disputed` and fully rulable, unlike `WrongStatus`'s
    ///      terminal race. Swallowing it would close the case with a verdict
    ///      recorded and undelivered, and re-wiring could not redeliver it
    ///      (`refer` reverts `AlreadyReferred`) - the same verdict-burning
    ///      outcome this catch exists to prevent, reached by an owner action
    ///      instead of a gas dial. It is transient and retryable, so it must
    ///      bubble like every other non-`WrongStatus` revert.
    function test_finalize_notCourt_bubblesAndLeavesCaseVoting() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        game.setRuleRevertsNotCourt(true); // the game no longer recognises this court
        vm.expectRevert(IChallengeGame.NotCourt.selector);
        court.finalize(id);

        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Voting), "case stays retryable");
        assertFalse(game.ruled(), "nothing delivered");

        // Re-wire and the verdict lands for real - the whole point of bubbling.
        game.setRuleRevertsNotCourt(false);
        court.finalize(id);
        assertEq(uint256(game.lastVerdict()), uint256(IChallengeGame.Verdict.Guilty));
        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Resolved));
    }

    /// @dev `Case.game` PINS the game a case rules on at `refer` time. A
    ///      `setChallengeGame` re-wire in between must not redirect an
    ///      in-flight case's `finalize` to the newly-wired game.
    function test_finalize_rulesThePinnedGameNotTheLiveOne() public {
        uint256 id = _referredCase(); // referred against `game`, pinned into the case
        MockGameForCourt game2 = new MockGameForCourt();

        vm.prank(owner);
        court.setChallengeGame(address(game2)); // re-wire the LIVE pointer after referral

        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);

        assertTrue(game.ruled(), "verdict landed on the pinned game, not the live one");
        assertEq(uint256(game.lastVerdict()), uint256(IChallengeGame.Verdict.Guilty));
        assertEq(game.lastRuledChallenge(), CHALLENGE_ID);
        assertFalse(game2.ruled(), "the re-pointed live game must never be touched by this case");
    }

    function test_finalize_guards() public {
        uint256 id = _referredCase();
        vm.expectRevert(ITokenCourt.WindowOpen.selector);
        court.finalize(id);
        vm.expectRevert(ITokenCourt.WrongPhase.selector);
        court.finalize(999); // nonexistent
        vm.warp(vm.getBlockTimestamp() + 5 days);
        court.finalize(id);
        vm.expectRevert(ITokenCourt.WrongPhase.selector);
        court.finalize(id); // already resolved
    }

    function test_finalize_emitsCaseFinalized() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Guilty, 300e18, 0, 100e18);
        court.finalize(id);
    }

    // ── B2: the participation floor's denominator (the lookback min) ──

    /// @dev Opens a referable case whose electorate is described at BOTH
    ///      instants the floor now reads: `snapshotTs` and `snapshotTs -
    ///      FLOOR_LOOKBACK`. The accused set is exercised (accusedG is a
    ///      covering approver) but carries no stake, so `accusedWeight` is 0
    ///      and the floor is a clean `participationFloorBps` of the base.
    ///      Voters A (300e18) and B (200e18) hold snapshot weight, for a
    ///      maximum achievable turnout of 500e18.
    /// @param totalAtSnapshot     `getPastTotalVotes(snapshotTs)`.
    /// @param totalAtLookback     `getPastTotalVotes(snapshotTs - FLOOR_LOOKBACK)`,
    ///                            or 0 to model an electorate with no history
    ///                            that far back.
    function _caseWithElectorate(uint256 totalAtSnapshot, uint256 totalAtLookback)
        internal
        returns (uint256 caseId, uint256 snap)
    {
        _disputedChallenge();
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);

        caseId = court.refer(CHALLENGE_ID);
        snap = court.caseOf(caseId).snapshotTs;
        assertEq(court.caseOf(caseId).accusedWeight, 0, "fixture assumes a zero-stake accused set");

        swood.setPastTotalVotes(snap, totalAtSnapshot);
        swood.setPastVotes(voterA, snap, 300e18);
        swood.setPastVotes(voterB, snap, 200e18);
        // Issue #82: model MATURE STEADY voters, not fresh ones. Without this,
        // the mock's `getPastStake` default (falls back to the `getPastVotes`
        // fixture when no explicit `setPastStake` was recorded) reads
        // rawThen = 0 at the lookback while rawNow = 300e18/200e18 at the
        // snapshot — the growth gate fires on every one of these voters and
        // `NoVotingPower` reverts, even though this fixture means to describe
        // an electorate that was already there a lookback ago. Setting equal
        // `getPastVotes` at the lookback makes the mock's defaulted raw equal
        // at both instants too, so the gate reads false and the clamp never
        // evaluates — bit-identical weights, per design §3.3/§8.
        if (totalAtLookback != 0) {
            swood.setPastTotalVotes(snap - court.FLOOR_LOOKBACK(), totalAtLookback);
            swood.setPastVotes(voterA, snap - court.FLOOR_LOOKBACK(), 300e18);
            swood.setPastVotes(voterB, snap - court.FLOOR_LOOKBACK(), 200e18);
        }
    }

    /// @dev Casts the full achievable turnout (500e18, both voters, guilty)
    ///      and closes the window, stopping SHORT of `finalize` so a caller
    ///      can arm `vm.expectEmit` on `CaseFinalized` without the two
    ///      `VoteCast` emissions consuming it first. After this returns,
    ///      `Guilty` out of `finalize` means the floor was cleared and
    ///      `Inconclusive` means it was not.
    function _castFullTurnoutAndCloseWindow(uint256 caseId) internal {
        vm.prank(voterA);
        court.vote(caseId, true);
        vm.prank(voterB);
        court.vote(caseId, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
    }

    /// @notice B2 (BLOCKING, review of PR #56), AS A REGRESSION TEST: THE
    ///         DENIAL-OF-QUORUM ATTACK ON THE FLOOR'S DENOMINATOR.
    ///
    ///         D2 defends the NUMERATOR — weight is read at `executedAt - 1`,
    ///         so post-drain buyers and flash loans count for nothing. The
    ///         DENOMINATOR had the opposite exposure: it is RAISED by anyone
    ///         staked before `executedAt`, and the attacker is exactly the
    ///         party who knows when `executedAt` will be, because it is their
    ///         own drain.
    ///
    ///         The attack, verbatim: stake large from an address that NEVER
    ///         APPROVES ANYTHING, immediately before executing the malicious
    ///         proposal. `stakeAsGuardian` is permissionless, and
    ///         `_recordAccused` subtracts only ledger approvers, so the stake
    ///         is never subtracted back out. Here the honest electorate is
    ///         1_000e18 with 500e18 of achievable turnout; the attacker adds
    ///         9_000e18, taking the pre-fix floor to 10% of 10_000e18 =
    ///         1_000e18 — beyond ANY achievable turnout. The case would
    ///         finalize `Inconclusive`: no slash, no `_convicted` mark, no
    ///         adapter demotion, counter-bond returned whole, coverage freeze
    ///         released — with the attacker never voting, never coordinating,
    ///         never slashable, and recovering its capital after cooldown.
    ///
    ///         MUTATION-CHECKED: reverting `_participationFloor` to the single
    ///         `getPastTotalVotes(snapshotTs)` read fails this test with
    ///         `Inconclusive != Guilty`.
    function test_finalize_floorIgnoresAPreDrainStakeSurge_denialOfQuorumClosed() public {
        // 10_000e18 at the snapshot (1_000e18 honest + 9_000e18 attacker),
        // but only the honest 1_000e18 a lookback earlier: the attacker's
        // stake landed inside the window and cannot raise the base.
        (uint256 id,) = _caseWithElectorate(10_000e18, 1_000e18);
        _castFullTurnoutAndCloseWindow(id);

        vm.expectEmit(true, false, false, true);
        // floor = 10% of min(10_000e18, 1_000e18) = 100e18, NOT 1_000e18.
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Guilty, 500e18, 0, 100e18);
        court.finalize(id);

        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "a pre-drain stake surge must not deny the case a real verdict"
        );
        assertTrue(game.ruled(), "the verdict reached the game");
    }

    /// @notice THE PROPERTY IS PRESERVED, NOT DELETED (half 1): a legitimate
    ///         electorate that did not move over the lookback window still
    ///         produces exactly the floor it always did, and real turnout
    ///         still clears it. The min is a no-op when the two reads agree.
    function test_finalize_floorUnchangedWhenElectorateStable() public {
        (uint256 id,) = _caseWithElectorate(1_000e18, 1_000e18);
        _castFullTurnoutAndCloseWindow(id);

        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Guilty, 500e18, 0, 100e18);
        court.finalize(id);

        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "stable electorate, ordinary verdict"
        );
    }

    /// @notice THE PROPERTY IS PRESERVED, NOT DELETED (half 2): honest turnout
    ///         BELOW the floor still resolves `Inconclusive`. The lookback
    ///         lowers the base when stake is young; it does not remove the D6
    ///         floor. Here both reads agree at 10_000e18 — a genuinely large,
    ///         long-standing electorate — so 500e18 of turnout against a
    ///         1_000e18 floor is exactly the thin vote D6 refuses to read as
    ///         an answer.
    function test_finalize_belowFloorStillInconclusive_withBothCheckpointsSet() public {
        (uint256 id,) = _caseWithElectorate(10_000e18, 10_000e18);
        _castFullTurnoutAndCloseWindow(id);

        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Inconclusive, 500e18, 0, 1_000e18);
        court.finalize(id);

        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Inconclusive),
            "thin turnout is still no answer"
        );
    }

    /// @notice THE RESIDUAL, PINNED DELIBERATELY RATHER THAN LEFT IMPLICIT.
    ///         The lookback does not make the attack impossible — it prices
    ///         it. An attacker who commits the same 9_000e18 a FULL
    ///         `FLOOR_LOOKBACK` before the drain is present at both reads, so
    ///         the min does not exclude it and the case still lands
    ///         `Inconclusive`. What changed is the cost: the capital must sit
    ///         on-chain, idle and publicly visible, for a month before the
    ///         drain it exists to protect, rather than being staked in the
    ///         block before `executedAt` for free. The live
    ///         `participationFloorBps` read (D6) is the operational
    ///         counter-lever if such a stake is spotted mid-case — proven by
    ///         the second half of this test.
    function test_finalize_floorStillInflatableByAMonthOldStake_knownResidual() public {
        (uint256 id,) = _caseWithElectorate(10_000e18, 10_000e18);

        vm.prank(voterA);
        court.vote(id, true);
        vm.prank(voterB);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        // Snapshot the state, prove the residual, then rewind to prove the lever.
        uint256 snapshotId = vm.snapshotState();
        court.finalize(id);
        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Inconclusive),
            "a lookback-old stake still inflates the base: the residual"
        );

        vm.revertToState(snapshotId);
        vm.prank(owner);
        court.setParticipationFloorBps(100); // 1%: floor 100e18, cleared by 500e18
        court.finalize(id);
        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "the live floor read is the counter-lever against an observed inflating stake"
        );
    }

    /// @notice NO UNDERFLOW WHEN `snapshotTs < FLOOR_LOOKBACK`. A proposal
    ///         that executed in the chain's first month makes
    ///         `snapshotTs - FLOOR_LOOKBACK` a subtraction below zero; the
    ///         clamp keeps it at 0, where the trace is empty by definition,
    ///         and the `earlier == 0` fallback stands the snapshot total up
    ///         instead. `executedAt` is set to one hour past genesis directly
    ///         on the game record rather than warping the chain backwards —
    ///         `vm.warp` backwards is a no-op, and `snapshotTs` is derived
    ///         from the game's pinned `executedAt`, not from `block.timestamp`.
    function test_finalize_floorDoesNotUnderflowWhenSnapshotPrecedesLookback() public {
        assertLt(1 hours, court.FLOOR_LOOKBACK(), "fixture must actually exercise the clamp");
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            1 hours // executedAt: one hour into the chain's life
        );
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);

        uint256 id = court.refer(CHALLENGE_ID);
        uint256 snap = court.caseOf(id).snapshotTs;
        assertEq(snap, 1 hours - 1, "snapshotTs is well below FLOOR_LOOKBACK");

        swood.setPastTotalVotes(snap, 1_000e18);
        swood.setPastVotes(voterA, snap, 300e18);
        swood.setPastVotes(voterB, snap, 200e18);

        _castFullTurnoutAndCloseWindow(id);
        vm.expectEmit(true, false, false, true);
        // The clamped read is empty, so the snapshot total stands: floor = 100e18.
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Guilty, 500e18, 0, 100e18);
        court.finalize(id);
        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "no revert, no underflow, floor intact"
        );
    }

    /// @notice THE BOOTSTRAP FALLBACK, ASSERTED IN THE DIRECTION IT MATTERS.
    ///         With no electorate at all a lookback before the snapshot
    ///         (`getPastTotalVotes` reads zero before a trace's first entry),
    ///         the base falls back to the SNAPSHOT TOTAL, not to zero. A zero
    ///         base would disable the D6 anti-capture floor outright for the
    ///         protocol's first `FLOOR_LOOKBACK` of staking history, letting a
    ///         single dust-weight guardian carry a case alone — and a wrongful
    ///         `Guilty` destroys an honest guardian's whole stake, strictly
    ///         worse than the forced `Inconclusive` the fallback leaves
    ///         possible. So the floor here is the pre-fix 10% of 10_000e18,
    ///         and 500e18 of turnout does NOT clear it.
    function test_finalize_floorFallsBackToSnapshotTotalWhenNoEarlierElectorateExists() public {
        (uint256 id,) = _caseWithElectorate(10_000e18, 0); // nothing staked a lookback ago
        _castFullTurnoutAndCloseWindow(id);

        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Inconclusive, 500e18, 0, 1_000e18);
        court.finalize(id);

        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Inconclusive),
            "an empty lookback must not zero the floor, only decline to lower it"
        );
    }

    /// @notice The floor is monotone against the pre-fix formula: the lookback
    ///         can only ever LOWER the base, never raise it. Proven on the
    ///         asymmetric case the min exists for — an electorate that SHRANK
    ///         over the window, where reading the lookback instant ALONE
    ///         (rather than the min) would have raised the floor from 100e18
    ///         to 1_000e18 and denied the verdict.
    function test_finalize_floorTakesTheMinNotTheEarlierReadAlone() public {
        (uint256 id,) = _caseWithElectorate(1_000e18, 10_000e18); // electorate shrank 10x
        _castFullTurnoutAndCloseWindow(id);

        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Guilty, 500e18, 0, 100e18);
        court.finalize(id);

        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "a shrunken electorate must not raise the floor"
        );
    }

    /// @notice `FLOOR_LOOKBACK` is a constant, not an owner parameter: there
    ///         is no setter to shrink it to zero before a drain, and being
    ///         immutable it satisfies the D2 "pinned at `refer`" discipline
    ///         more strongly than any stored field could. Its value matches
    ///         `StakedWood`'s deployed `maturationPeriod`, the horizon the
    ///         NUMERATOR already ages stake over.
    function test_floorLookback_isAThirtyDayConstant() public view {
        assertEq(court.FLOOR_LOOKBACK(), 30 days);
    }

    // ── issue #96: the accused subtraction clamps at zero ──

    /// @dev Opens a referable case whose ONLY accused approver carries
    ///      `accusedStake` of raw own stake at the snapshot, against a fixed
    ///      1_000e18 electorate base. Nothing is staked a `FLOOR_LOOKBACK`
    ///      earlier, so the `earlier == 0` fallback stands the snapshot total
    ///      up and the base is a clean 1_000e18 — the whole floor then turns
    ///      on the accused subtraction alone, which is the subject here.
    ///      Takes an explicit `challengeId` so several cases can be referred
    ///      at the SAME timestamp (hence the same `snapshotTs`) and compared
    ///      against each other with nothing else varying.
    /// @param challengeId  A challenge id not yet referred on `game`.
    /// @param accused      The sole covering approver, recorded as accused.
    /// @param accusedStake Its raw `getPastStake` at `snapshotTs`, i.e. the
    ///                     case's `accusedWeight`.
    function _caseWithAccusedWeight(uint256 challengeId, address accused, uint256 accusedStake)
        internal
        returns (uint256 caseId, uint256 snap)
    {
        game.setChallenge(
            challengeId,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accused;
        cm[0] = 100e18; // committed USD, nonzero so `accused` is in the accused set
        ledger.setApprovers(a, cm);

        snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accused, snap, accusedStake);

        caseId = court.refer(challengeId);
        assertEq(court.caseOf(caseId).snapshotTs, snap, "snapshotTs is executedAt - 1");
        assertEq(court.caseOf(caseId).accusedWeight, accusedStake, "accused raw stake recorded");

        swood.setPastTotalVotes(snap, 1_000e18);
    }

    /// @dev Finalizes and returns the floor the case actually resolved
    ///      against, read off `CaseFinalized` rather than recomputed — the
    ///      floor is not stored on the `Case`, and recomputing it in the test
    ///      would just restate the implementation instead of pinning it.
    function _finalizeAndReadFloor(uint256 caseId) internal returns (uint256 floor, IChallengeGame.Verdict verdict) {
        vm.recordLogs();
        court.finalize(caseId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(court)) continue;
            if (logs[i].topics[0] != ITokenCourt.CaseFinalized.selector) continue;
            if (uint256(logs[i].topics[1]) != caseId) continue;
            (uint8 v,,, uint256 f) = abi.decode(logs[i].data, (uint8, uint256, uint256, uint256));
            return (f, IChallengeGame.Verdict(v));
        }
        revert("CaseFinalized was not emitted for this case");
    }

    /// @notice ISSUE #96, AS A REGRESSION TEST: THE FLOOR MUST NOT JUMP UP
    ///         WHEN `accusedWeight` CROSSES THE ELECTORATE BASE.
    ///
    ///         Pre-fix, `_participationFloor` skipped the subtraction entirely
    ///         when `accusedWeight >= base` and used the FULL unreduced base
    ///         instead, so the floor was non-monotone: it shrank toward zero
    ///         as the accused cohort approached the base, then snapped to its
    ///         maximum at the crossing. The adversary is the accused set
    ///         itself, which controls `accusedWeight` by staking more before
    ///         its own drain (inside `FLOOR_LOOKBACK`, so the lookback min can
    ///         hold the base down while `accusedWeight` climbs past it): one
    ///         extra wei of stake bought a floor beyond any achievable turnout
    ///         and a forced `Inconclusive` — no slash, no `_convicted` mark,
    ///         no adapter demotion, counter-bond returned whole.
    ///
    ///         Three otherwise identical cases, referred in the same block so
    ///         they share a `snapshotTs` and a 1_000e18 base, differing only
    ///         in `accusedWeight`: 999e18 (below), 1_000e18 (exactly at), and
    ///         1_001e18 (above).
    ///
    ///         MUTATION-CHECKED: restoring the `: base` fallback finalizes the
    ///         last two against a 100e18 floor instead of 0, failing both the
    ///         exact-value and the non-increasing assertions.
    function test_finalize_floorIsMonotoneAcrossTheAccusedWeightBoundary() public {
        (uint256 below,) = _caseWithAccusedWeight(CHALLENGE_ID, makeAddr("accusedBelowBase"), 999e18);
        (uint256 atBase,) = _caseWithAccusedWeight(CHALLENGE_ID + 1, makeAddr("accusedAtBase"), 1_000e18);
        (uint256 above,) = _caseWithAccusedWeight(CHALLENGE_ID + 2, makeAddr("accusedAboveBase"), 1_001e18);

        vm.warp(vm.getBlockTimestamp() + 5 days);

        (uint256 floorBelow,) = _finalizeAndReadFloor(below);
        (uint256 floorAtBase,) = _finalizeAndReadFloor(atBase);
        (uint256 floorAbove,) = _finalizeAndReadFloor(above);

        assertEq(floorBelow, 0.1e18, "10% of (1_000e18 - 999e18)");
        assertEq(floorAtBase, 0, "clamped to zero at the crossing, not fallen back to the unreduced base");
        assertEq(floorAbove, 0, "still clamped one whole WOOD past the crossing");

        assertLe(floorAtBase, floorBelow, "the floor must not jump up as accusedWeight reaches the base");
        assertLe(floorAbove, floorAtBase, "nor as it passes the base");
    }

    /// @notice ISSUE #96: THE DENIAL LEVER IS CLOSED. With the accused cohort
    ///         at or above the whole electorate base the floor is zero, so a
    ///         single unaccused voter — 1e18 of aged weight, dust against the
    ///         100e18 floor the pre-fix fallback would have imposed — carries
    ///         the case to a verdict on the merits. That is the correct
    ///         continuous limit of the subtraction (at `accusedWeight = base -
    ///         1` the floor is already dust) and the right answer when the
    ///         accused cohort IS the electorate: whoever is left unaccused is
    ///         the jury. Pre-fix this same fixture returned `Inconclusive`,
    ///         which is precisely what the accused was buying.
    function test_finalize_accusedOutweighingTheElectorateCannotDenyAVerdict() public {
        (uint256 id, uint256 snap) = _caseWithAccusedWeight(CHALLENGE_ID, makeAddr("accusedWhale"), 1_000e18);

        address dust = makeAddr("dustVoter");
        swood.setPastVotes(dust, snap, 1e18);
        vm.prank(dust);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Guilty, 1e18, 0, 0);
        court.finalize(id);

        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Guilty),
            "an accused cohort outweighing the base must not buy a denial"
        );
        assertTrue(game.ruled(), "the verdict reached the game");
    }

    /// @notice ISSUE #96: A ZERO FLOOR NEVER RESOLVES AN EMPTY VOTE. The
    ///         clamp does not weaken the anti-capture property it looks like
    ///         it might, because the floor was never the guard against a
    ///         silent electorate: `finalize`'s `turnout == 0` check sits ahead
    ///         of the `turnout < floor` comparison and forces `Inconclusive`
    ///         regardless. Same fixture as the test above, no ballots cast —
    ///         `0 < 0` is false, so the verdict here is carried by the guard
    ///         alone, and the emitted floor of 0 shows which branch fired.
    function test_finalize_zeroFloorStillInconclusiveOnAnEmptyVote() public {
        (uint256 id,) = _caseWithAccusedWeight(CHALLENGE_ID, makeAddr("accusedWhale"), 1_000e18);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        vm.expectEmit(true, false, false, true);
        emit ITokenCourt.CaseFinalized(id, IChallengeGame.Verdict.Inconclusive, 0, 0, 0);
        court.finalize(id);

        assertEq(
            uint256(court.caseOf(id).verdict),
            uint256(IChallengeGame.Verdict.Inconclusive),
            "the turnout == 0 guard, not the floor, carries the empty vote"
        );
    }

    /// @notice AUDIT FINDING (PR #120, confidence 92): THE `: 0` CLAMP ALONE
    ///         COLLAPSES THE FLOOR TO ZERO UNDER ORDINARY ELECTORATE GROWTH —
    ///         NO ATTACKER REQUIRED. THIS IS THE REGRESSION FOR THE FIX, NOT
    ///         FOR THE ORIGINAL BUG.
    ///
    ///         Every test above shares one property the audit caught: `earlier`
    ///         is never set, so `getPastTotalVotes(lookbackTs)` reads its
    ///         zero-checkpoint default and every one of them resolves through
    ///         the `earlier == 0` fallback (`base = total`). None of them
    ///         exercises `earlier != 0 && earlier < total` — the regime the
    ///         production formula actually lands in whenever the protocol has
    ///         grown over the lookback window, which is the common case, not
    ///         an edge case.
    ///
    ///         The bug the audit found: an EARLIER buggy revision subtracted
    ///         `accusedWeight` from `min(earlier, total)` — mixing an
    ///         `accusedWeight` measured NOW against an electorate measured a
    ///         month ago. In a growing protocol, "the accused today" routinely
    ///         exceeds "the whole electorate a month ago" with zero attacker
    ///         action, so that formula read `base <= accusedWeight` and
    ///         returned a floor of ZERO while a large, honest, unaccused
    ///         electorate stood by unable to move it — worse than the original
    ///         bug, because a `NotGuilty` bought this way is terminal (the
    ///         forfeited bond routes to the accused's own counter-bond
    ///         funders and the proposal becomes permanently unchallengeable),
    ///         where the original bug's `Inconclusive` was merely recoverable.
    ///
    ///         The fix: reduce `total` by `accusedWeight` FIRST (same
    ///         instant), THEN take the lookback min. Reproduces the audit's
    ///         own worked numbers: earlier=60,000, total=560,000,
    ///         accused=300,000. `reduced = 560,000 - 300,000 = 260,000`;
    ///         `base = min(60,000, 260,000) = 60,000` (earlier is the binding
    ///         constraint here, not the subtraction) — a real, sizeable floor,
    ///         not zero, with 260,000 WOOD of honest electorate correctly
    ///         still counted as available to clear it.
    ///
    ///         MUTATION-CHECKED: reducing against `min(earlier, total)`
    ///         instead of against `total` alone (i.e. reverting to
    ///         `base = base > accusedWeight ? base - accusedWeight : 0` where
    ///         `base` was already `min(earlier, total)`) computes
    ///         `60,000 > 300,000? false -> 0` and fails this test's nonzero
    ///         assertion.
    function test_finalize_floorSurvivesElectorateGrowthPastTheLookback() public {
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        address accused = makeAddr("growingProtocolAccused");
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accused;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);

        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        uint256 lookbackTs = snap - court.FLOOR_LOOKBACK();

        // The audit's own worked example: the protocol grew ~9x over the
        // lookback window, and the accused cohort (300k) sits between
        // `earlier` (60k) and `total` (560k) — the untested regime.
        swood.setPastStake(accused, snap, 300_000e18);
        swood.setPastTotalVotes(lookbackTs, 60_000e18);
        swood.setPastTotalVotes(snap, 560_000e18);

        uint256 caseId = court.refer(CHALLENGE_ID);
        assertEq(court.caseOf(caseId).accusedWeight, 300_000e18, "accused raw stake recorded");

        vm.warp(vm.getBlockTimestamp() + 5 days);

        (uint256 floor,) = _finalizeAndReadFloor(caseId);

        assertEq(floor, 6_000e18, "10% of min(60_000e18, 560_000e18 - 300_000e18) = 10% of 60_000e18");
        assertGt(floor, 0, "electorate growth past the lookback must not collapse the floor to zero");
    }

    /// @notice RE-AUDIT FINDING (PR #120 round 2): THE PRIOR REGRESSION TEST
    ///         DOES NOT PIN THE FIX, BECAUSE `earlier` BINDS IN IT.
    ///
    ///         `test_finalize_floorSurvivesElectorateGrowthPastTheLookback`
    ///         uses earlier=60k < reduced=260k, so `earlier` is the binding
    ///         term and `accusedWeight` never actually reaches the min
    ///         comparison. A mutant that compares the lookback read against
    ///         the UNREDUCED `total` instead of `reduced` —
    ///         `base = (earlier != 0 && earlier < total) ? earlier : reduced`
    ///         — is byte-equivalent to the real formula on every existing
    ///         fixture, this one included, because none of them has
    ///         `accusedWeight > 0` together with `earlier > 0` in the regime
    ///         where `reduced`, not `earlier`, is the smaller term.
    ///
    ///         This fixture closes that gap: earlier=500k, total=560k,
    ///         accused=300k, so `reduced = 260k < earlier = 500k` and
    ///         `reduced` binds. The mutant above would instead take the
    ///         `earlier < total` branch (500k < 560k is true) and return
    ///         `earlier` = 500k — a floor of 50,000e18, more than 8x the
    ///         real 26,000e18, wide open to the #96 bug class (an
    ///         unclearable floor) the moment `accusedWeight` is large enough
    ///         to make `reduced` the smaller term.
    ///
    ///         MUTATION-CHECKED: comparing against `total` instead of
    ///         `reduced` in the lookback condition computes floor=50,000e18
    ///         here instead of 26,000e18, failing the exact-value assertion.
    function test_finalize_floorPinsTheReducedTermWhenItBindsBeforeTheLookback() public {
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        address accused = makeAddr("reducedBindsAccused");
        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accused;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);

        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        uint256 lookbackTs = snap - court.FLOOR_LOOKBACK();

        // reduced = 560k - 300k = 260k, which is LESS than earlier (500k),
        // so `reduced` is the binding term — the regime no prior fixture
        // reaches with a nonzero `accusedWeight`.
        swood.setPastStake(accused, snap, 300_000e18);
        swood.setPastTotalVotes(lookbackTs, 500_000e18);
        swood.setPastTotalVotes(snap, 560_000e18);

        uint256 caseId = court.refer(CHALLENGE_ID);
        assertEq(court.caseOf(caseId).accusedWeight, 300_000e18, "accused raw stake recorded");

        vm.warp(vm.getBlockTimestamp() + 5 days);

        (uint256 floor,) = _finalizeAndReadFloor(caseId);

        assertEq(floor, 26_000e18, "10% of min(500_000e18, 560_000e18 - 300_000e18) = 10% of 260_000e18");
    }

    // ── ownership ──

    /// @notice An ownerless court is unrecoverable: it is non-upgradeable, so
    ///         `setChallengeGame` / `setStakedWood` (the rescue path for a
    ///         compromised or redeployed dependency) and
    ///         `setParticipationFloorBps` (the counter-lever the B2 residual
    ///         above leans on) would be gone permanently. Refused for
    ///         everyone, the owner included.
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ITokenCourt.OwnershipCannotBeRenounced.selector);
        court.renounceOwnership();

        vm.prank(voterA);
        vm.expectRevert(ITokenCourt.OwnershipCannotBeRenounced.selector);
        court.renounceOwnership();

        assertEq(court.owner(), owner, "owner survives both attempts");
    }
}
