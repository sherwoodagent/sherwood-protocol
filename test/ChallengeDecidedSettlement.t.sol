// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChallengeEndToEndBase} from "./ChallengeEndToEnd.t.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {IGuardianRegistry} from "src/interfaces/IGuardianRegistry.sol";

/// @notice A challenge settles before its window only once the convict side is decided.
contract ChallengeDecidedSettlementTest is ChallengeEndToEndBase {
    address internal whale = makeAddr("freshWhale");
    address internal sock = makeAddr("sockFiler");

    /// @dev g1 (30k) approves and is accused; g2/g3 hold 20k each; a fresh 30k
    ///      whale stakes after execution. Total 100k, votable 70k.
    function _proposeExecuteAndStakeWhale() internal returns (uint256 pid) {
        pid = _proposeApproveExecute();
        _stakeGuardian(whale, 30_000e18, 9);
        vm.warp(vm.getBlockTimestamp() + 1);
        _fundSock();
    }

    function _fundSock() internal {
        wood.mint(sock, _challengerBond());
        vm.prank(sock);
        wood.approve(address(game), type(uint256).max);
    }

    function _status(uint256 cid) internal view returns (uint8) {
        return uint8(game.challengeOf(cid).status);
    }

    function _windowEnd(uint256 cid) internal view returns (uint256) {
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        return c.filedAt + c.voteWindowAtFiling;
    }

    /// @notice A 30% convict bloc meets quorum but cannot settle while the 40k it has not yet heard can still acquit.
    function test_quorumMinorityCannotSettleBeforeTheRestCanVote() public {
        uint256 pid = _proposeExecuteAndStakeWhale();
        uint256 swoodBefore = wood.balanceOf(address(swood));
        (uint8 tierBefore,) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);

        uint256 cid = _file(sock, pid, "ipfs://frivolous");
        assertEq(game.challengeOf(cid).votableAtFiling, 70_000e18, "votable excludes the accused g1");
        vm.prank(whale);
        game.voteOnChallenge(cid, true);
        (uint256 cw,, uint256 total,) = game.challengeTallyOf(cid);
        assertGe(cw * 10_000, 3_000 * total, "fixture: the bloc alone meets quorum");

        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);

        vm.prank(g2);
        game.voteOnChallenge(cid, false);
        vm.prank(g3);
        game.voteOnChallenge(cid, false);
        vm.warp(_windowEnd(cid));
        game.resolve(cid);

        assertEq(_status(cid), uint8(IChallengeGame.Status.Failed), "the majority acquits");
        assertEq(wood.balanceOf(address(swood)), swoodBefore, "no approver stake burned");
        (uint8 tierAfter,) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, tierBefore, "adapter keeps its tier");
    }

    /// @notice Once convict weight exceeds every acquit ballot still castable, the challenge settles at once.
    function test_decidedConvictionSettlesBeforeTheWindow() public {
        uint256 pid = _proposeExecuteAndStakeWhale();
        uint256 cid = _file(sock, pid, "ipfs://evidence");
        vm.prank(whale);
        game.voteOnChallenge(cid, true);
        vm.prank(g2);
        game.voteOnChallenge(cid, true); // 50k of 70k votable: 20k acquit can no longer catch up

        assertLt(vm.getBlockTimestamp(), _windowEnd(cid), "fixture: window still open");
        game.resolve(cid);
        assertEq(_status(cid), uint8(IChallengeGame.Status.Settled), "decided, so settled early");
    }

    /// @notice After the window, quorum plus a convict majority still settles an undecided challenge.
    function test_quorumMajoritySettlesAtTheWindowClose() public {
        uint256 pid = _proposeExecuteAndStakeWhale();
        uint256 cid = _file(sock, pid, "ipfs://evidence");
        vm.prank(whale);
        game.voteOnChallenge(cid, true);
        vm.prank(g2);
        game.voteOnChallenge(cid, false); // 30k convict vs 20k acquit, g3 silent

        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);
        vm.warp(_windowEnd(cid));
        game.resolve(cid);
        assertEq(_status(cid), uint8(IChallengeGame.Status.Settled), "quorum and majority at the close");
    }
}

/// @notice An accused approver's post-execution top-up does not count toward the challenge denominator.
contract ChallengeAccusedTopUpTest is ChallengeEndToEndBase {
    /// @notice A 64k top-up by the accused after execution neither blocks the filing nor raises the quorum bar.
    function test_accusedTopUpAfterExecutionDoesNotBuyImmunity() public {
        uint256 pid = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid).executedAt;
        vm.warp(vm.getBlockTimestamp() + 1);
        _stakeGuardian(g1, 64_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.slashableStakeAt(g1, executedAt), G1_STAKE, "fixture: the top-up is outside the slash basis");

        uint256 cid = _file(challenger, pid, "ipfs://evidence");
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(c.totalStakeAtFiling, G1_STAKE + 2 * FILLER_STAKE, "g1 counts at its execution-time stake");
        assertEq(c.votableAtFiling, 2 * FILLER_STAKE, "votable excludes all of g1");

        _convict(cid);
        game.resolve(cid);
        assertEq(uint8(game.challengeOf(cid).status), uint8(IChallengeGame.Status.Settled), "the rest convict");
    }

    /// @notice A top-up between approve and execute is inside the slash basis but slashes nothing
    ///         beyond the lock, so it is capped at the approve snapshot and cannot close the door.
    function test_accusedTopUpBeforeExecutionDoesNotBuyImmunity() public {
        uint256 pid = _propose();
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1);
        _stakeGuardian(g1, 64_000e18, 1);
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 cid = _file(challenger, pid, "ipfs://evidence");
        assertEq(game.challengeOf(cid).totalStakeAtFiling, G1_STAKE + 2 * FILLER_STAKE, "g1 counts at approve");
        _convict(cid);
        game.resolve(cid);
        assertEq(uint8(game.challengeOf(cid).status), uint8(IChallengeGame.Status.Settled), "the rest convict");
    }
}
