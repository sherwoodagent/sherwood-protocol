// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ITokenCourt} from "../src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {MockStakedWood} from "./mocks/MockStakedWood.sol";

/// @dev Just enough game for the court: a settable challenge record, the
///      ledger pointer the court reads, and a `rule` recorder with several
///      revert toggles — one per class `finalize`'s selector-filtered catch
///      must tell apart: the two swallowed terminal-race causes
///      (`WrongStatus`, `NotCourt`) and a stand-in transient failure
///      (`ZeroAddress`) that must bubble instead, plus a gas floor standing in
///      for `InsufficientSlashGas` (the under-gas verdict-burning PoC).
/// @dev `executedAt` is set directly on the challenge record (no separate
///      governor stub) — the court reads `ch.executedAt`, the game's own pin
///      (F10), never a live `ISyndicateGovernor.getProposal` call. There is
///      therefore nothing left for a `MockGovernorForCourt` to stand in for.
contract MockGameForCourt {
    mapping(uint256 => IChallengeGame.Challenge) internal _challenges;
    address public exposureLedger;
    bool public ruleReverts; // reverts WrongStatus - swallowed (terminal race)
    bool public ruleRevertsNotCourt; // reverts NotCourt - swallowed (re-pointed court)
    bool public ruleRevertsOther; // reverts ZeroAddress - must bubble (transient stand-in)
    uint256 public ruleGasFloor; // 0 disables; else reverts InsufficientSlashGas under it
    uint256 public lastRuledChallenge;
    IChallengeGame.Verdict public lastVerdict;
    bool public ruled;

    function setExposureLedger(address l) external {
        exposureLedger = l;
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
    ///      `WrongStatus`/`NotCourt`) must bubble out of `finalize` whole,
    ///      exactly like the gas-floor case above, so the case survives for a
    ///      retry once the underlying condition clears.
    function test_finalize_transientRevert_bubblesAndLeavesCaseVoting() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        game.setRuleRevertsOther(true); // stand-in: reverts ZeroAddress, not WrongStatus/NotCourt
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
    ///      landed) is the SECOND swallowed cause, alongside `WrongStatus`.
    function test_finalize_notCourt_swallowed() public {
        uint256 id = _referredCase();
        vm.prank(voterA);
        court.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);

        game.setRuleRevertsNotCourt(true);
        vm.expectEmit(true, true, false, false);
        emit ITokenCourt.ChallengeAlreadyTerminal(id, CHALLENGE_ID);
        court.finalize(id);

        assertEq(uint256(court.caseOf(id).phase), uint256(ITokenCourt.Phase.Resolved), "case closed anyway");
        assertFalse(game.ruled(), "verdict never landed");
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
}
