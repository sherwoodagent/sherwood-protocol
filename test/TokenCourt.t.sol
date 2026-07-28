// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ITokenCourt} from "../src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {MockStakedWood} from "./mocks/MockStakedWood.sol";

/// @dev Just enough game for the court: a settable challenge record, the
///      ledger pointer the court reads, and a `rule` recorder with a revert
///      toggle for the terminal-race test.
/// @dev `executedAt` is set directly on the challenge record (no separate
///      governor stub) — the court reads `ch.executedAt`, the game's own pin
///      (F10), never a live `ISyndicateGovernor.getProposal` call. There is
///      therefore nothing left for a `MockGovernorForCourt` to stand in for.
contract MockGameForCourt {
    mapping(uint256 => IChallengeGame.Challenge) internal _challenges;
    address public exposureLedger;
    bool public ruleReverts;
    uint256 public lastRuledChallenge;
    IChallengeGame.Verdict public lastVerdict;
    bool public ruled;

    function setExposureLedger(address l) external {
        exposureLedger = l;
    }

    function setRuleReverts(bool r) external {
        ruleReverts = r;
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
        if (ruleReverts) revert IChallengeGame.WrongStatus();
        ruled = true;
        lastRuledChallenge = challengeId;
        lastVerdict = verdict;
    }
}

contract MockLedgerForCourt {
    address[] internal _approvers;
    uint256[] internal _committed;

    function setApprovers(address[] memory a, uint256[] memory c) external {
        _approvers = a;
        _committed = c;
    }

    function approversOf(address, uint256) external view returns (address[] memory, uint256[] memory) {
        return (_approvers, _committed);
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

    function test_views_nonexistentCaseReturnDefaults() public view {
        ITokenCourt.Case memory cs = court.caseOf(999);
        assertEq(cs.challengeId, 0);
        assertEq(uint256(cs.phase), uint256(ITokenCourt.Phase.None));
        assertEq(court.accusedOf(999).length, 0);
        assertEq(court.caseOfChallenge(999), 0);
    }

    function test_setters_wiringEmitOldNew() public {
        address newGame = makeAddr("newGame");
        vm.expectEmit(true, true, false, true);
        emit ITokenCourt.ChallengeGameSet(address(game), newGame);
        vm.prank(owner);
        court.setChallengeGame(newGame);

        address newSwood = makeAddr("newSwood");
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
        assertEq(court.caseOfChallenge(CHALLENGE_ID), caseId);
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
        assertEq(court.caseOfChallenge(CHALLENGE_ID), firstCase);
        assertEq(court.caseOfChallenge(CHALLENGE_ID + 1), secondCase);
    }
}
