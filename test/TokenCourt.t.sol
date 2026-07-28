// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ITokenCourt} from "../src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {MockStakedWood} from "./mocks/MockStakedWood.sol";

/// @dev Just enough game for the court: a settable challenge record, the
///      ledger pointer the court reads, and a `rule` recorder with a revert
///      toggle for the terminal-race test.
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
        uint256 disputeTimeoutAtFiling
    ) external {
        IChallengeGame.Challenge storage c = _challenges[id];
        c.governor = governor;
        c.proposalId = proposalId;
        c.status = status;
        c.filedAt = filedAt;
        c.disputeTimeoutAtFiling = disputeTimeoutAtFiling;
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

/// @dev Governor stub. The court reads exactly one field off `getProposal`:
///      `executedAt`, from which D2's snapshot instant (`executedAt - 1`) is
///      derived once, at referral. `setExecuted` is deliberately re-callable so
///      a test can MOVE the proposal after referral and prove the case kept the
///      snapshot it stored rather than re-deriving it. Shape recovered from the
///      deleted panel court's `MockCourtGovernor`
///      (`git show 222ae21^:test/Court.t.sol`).
contract MockGovernorForCourt {
    mapping(uint256 proposalId => ISyndicateGovernor.StrategyProposal) internal _proposals;

    function setExecuted(uint256 proposalId, uint256 executedAt) external {
        _proposals[proposalId].executedAt = executedAt;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
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
    MockGovernorForCourt internal governor;
    MockLedgerForCourt internal ledger;
    MockStakedWood internal swood;

    address internal owner = makeAddr("owner");
    address internal voterA = makeAddr("voterA");
    address internal voterB = makeAddr("voterB");
    address internal accusedG = makeAddr("accusedG");
    uint256 internal constant CHALLENGE_ID = 7;
    uint256 internal constant PROPOSAL_ID = 42;

    function setUp() public {
        court = new TokenCourt(owner);
        game = new MockGameForCourt();
        governor = new MockGovernorForCourt();
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
}
