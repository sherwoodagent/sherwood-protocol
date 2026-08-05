// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenCourtTest} from "../TokenCourt.t.sol";
import {ITokenCourt} from "../../src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";

/// @dev Stands in for `ProposerBondEscrow`, answering only the selector
///      `TokenCourt.refer` reads. Real code, because the probe is a raw
///      staticcall and a codeless address is treated as "cannot answer".
contract StubBondEscrow {
    address public proposer;
    uint256 public amount;

    constructor(address proposer_, uint256 amount_) {
        proposer = proposer_;
        amount = amount_;
    }

    function bondOf(address, uint256) external view returns (address, uint256) {
        return (proposer, amount);
    }
}

/// @dev An escrow that answers with the WRONG SHAPE — one word instead of two.
///      The probe must treat this as unanswerable rather than decoding garbage.
contract StubBondEscrowShortReturn {
    function bondOf(address, uint256) external pure returns (uint256) {
        return 1;
    }
}

/// @title TokenCourt — the proposer may not vote on its own case
/// @notice `vote` barred three verdict-payees — the accused guardians, the
///         challenger, and counter-bond contributors — and missed the largest
///         one. `ChallengeGame._settle` confiscates the proposer's ENTIRE
///         `proposerBondWood` on `Guilty` (`ProposerBondEscrow.forfeitBond`:
///         "NO PARTIAL FORFEIT"), and every other outcome returns it intact.
///
///         `isAccused` cannot reach it: that set is `pledgedOf(governor,
///         proposalId)` — approving GUARDIANS — while the proposer is the vault
///         AGENT, a disjoint role. And nothing stops an agent also staking as a
///         guardian; `StakedWood.stakeAsGuardian` has no allowlist.
///
///         Two levers, not one. `finalize` requires `guiltyVotes >
///         notGuiltyVotes` for `Guilty`, so the proposer need only MATCH the
///         guilty tally; and its ballot also enters `turnout`, converting a
///         re-armable `Inconclusive` into a terminal `NotGuilty` that forecloses
///         re-challenge and forfeits the honest challenger's bond.
contract PashovFinalProposerBarTest is TokenCourtTest {
    address internal proposer = makeAddr("proposalProposer");

    /// @dev The fixture the counter-bond bar test uses, plus a bond escrow that
    ///      names `proposer` — i.e. an ordinary filing against an ordinary
    ///      bonded proposal.
    function _disputedWithBond(uint256 bondAmount) internal returns (uint256 caseId) {
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        game.setProposerBondEscrow(CHALLENGE_ID, address(new StubBondEscrow(proposer, bondAmount)));

        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);

        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(accusedG, snap, 500e18);
        // The proposer ALSO staked as a guardian — the move that makes it an
        // eligible voter. Nothing in the protocol forbids this.
        swood.setPastStake(proposer, snap, 900e18);
        swood.setPastVotes(proposer, snap, 900e18);

        caseId = court.refer(CHALLENGE_ID);
    }

    /// @notice THE PIN. Revert the fix and this vote succeeds.
    function test_finding1_proposerCannotVoteItsOwnAcquittal() public {
        uint256 caseId = _disputedWithBond(1_000e18);

        // Neither existing bar sees it: the proposer never approved (so it is
        // not accused), it did not file, and it funded no counter-bond.
        assertFalse(court.isAccused(caseId, proposer), "fixture: the proposer is not in the accused set");
        assertTrue(proposer != court.caseOf(caseId).challenger, "fixture: the proposer is not the challenger");

        vm.prank(proposer);
        vm.expectRevert(ITokenCourt.ProposerCannotVote.selector);
        court.vote(caseId, false);
    }

    /// @notice The bar is on the PROPOSER specifically, not on everyone. An
    ///         unrelated holder with the same weight still votes — without this
    ///         the test above would pass against a court that barred all voting.
    function test_finding1_unrelatedVoterIsUnaffected() public {
        uint256 caseId = _disputedWithBond(1_000e18);

        uint256 snap = vm.getBlockTimestamp() - 1 days - 1;
        swood.setPastStake(voterA, snap, 900e18);
        swood.setPastVotes(voterA, snap, 900e18);
        swood.setVotes(voterA, 900e18);

        vm.prank(voterA);
        court.vote(caseId, false);
        assertTrue(court.voteOf(caseId, voterA) != ITokenCourt.Ruling.None, "an unrelated holder still votes");
    }

    /// @notice The bar covers a `Guilty` ballot too. The pin is on the CONFLICT
    ///         — a party with a payout riding on the verdict — not on the
    ///         direction it happens to favour, so a proposer cannot launder its
    ///         participation by voting against itself to lift turnout.
    function test_finding1_proposerCannotVoteGuiltyEither() public {
        uint256 caseId = _disputedWithBond(1_000e18);

        vm.prank(proposer);
        vm.expectRevert(ITokenCourt.ProposerCannotVote.selector);
        court.vote(caseId, true);
    }

    /// @notice NO BOND, NO BAR. A zero `amount` means the proposal locked
    ///         nothing, so there is no verdict-contingent payout to this party
    ///         and nothing for the bar to protect — the stated failure decision.
    ///         Pinned so it stays a decision rather than drifting into an
    ///         accidental hole.
    function test_finding1_zeroBondLeavesTheProposerUnbarred() public {
        uint256 caseId = _disputedWithBond(0);

        assertEq(court.caseOf(caseId).proposer, address(0), "no bond locked: nothing pinned");

        swood.setVotes(proposer, 900e18);
        vm.prank(proposer);
        court.vote(caseId, false);
        assertTrue(court.voteOf(caseId, proposer) != ITokenCourt.Ruling.None, "no payout at stake, no conflict");
    }

    /// @notice An escrow with no code cannot be probed, and `refer` must still
    ///         open the case rather than reverting — `ch.proposerBondEscrow` is
    ///         documented as zero-when-no-bond, and the settle path treats an
    ///         unreachable escrow as nothing-to-forfeit rather than an error.
    function test_finding1_codelessEscrowStillRefers() public {
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        game.setProposerBondEscrow(CHALLENGE_ID, makeAddr("escrowWithNoCode"));

        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        swood.setPastStake(accusedG, vm.getBlockTimestamp() - 1 days - 1, 500e18);

        uint256 caseId = court.refer(CHALLENGE_ID);
        assertEq(court.caseOf(caseId).proposer, address(0), "unanswerable escrow pins nothing");
    }

    /// @notice A malformed answer (one word where two are expected) is treated
    ///         as unanswerable, not decoded. The explicit `ret.length == 64`
    ///         check is what makes this a stated decision instead of an
    ///         undecodable revert inside `refer`.
    function test_finding1_shortReturnEscrowStillRefers() public {
        game.setChallenge(
            CHALLENGE_ID,
            governor,
            PROPOSAL_ID,
            IChallengeGame.Status.Disputed,
            vm.getBlockTimestamp(),
            30 days,
            vm.getBlockTimestamp() - 1 days
        );
        game.setProposerBondEscrow(CHALLENGE_ID, address(new StubBondEscrowShortReturn()));

        address[] memory a = new address[](1);
        uint256[] memory cm = new uint256[](1);
        a[0] = accusedG;
        cm[0] = 100e18;
        ledger.setApprovers(a, cm);
        swood.setPastStake(accusedG, vm.getBlockTimestamp() - 1 days - 1, 500e18);

        uint256 caseId = court.refer(CHALLENGE_ID);
        assertEq(court.caseOf(caseId).proposer, address(0), "a wrong-shaped answer must not be decoded");
    }

    /// @notice The pin is taken at `refer` and does not re-read afterwards —
    ///         matching `challenger`. A verdict can land a full `disputeTimeout`
    ///         after filing, and `releaseBond`/`forfeitBond` DELETE the record,
    ///         so a live read would go blind exactly when it matters most.
    function test_finding1_pinSurvivesTheEscrowRecordBeingCleared() public {
        uint256 caseId = _disputedWithBond(1_000e18);
        assertEq(court.caseOf(caseId).proposer, proposer, "pinned at refer");

        // The bond is released/forfeited and the record cleared.
        game.setProposerBondEscrow(CHALLENGE_ID, address(new StubBondEscrow(address(0), 0)));

        vm.prank(proposer);
        vm.expectRevert(ITokenCourt.ProposerCannotVote.selector);
        court.vote(caseId, false);
    }
}
