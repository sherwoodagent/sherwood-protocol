// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChallengeEndToEndBase} from "../ChallengeEndToEnd.t.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";

/// @notice Audit 2026-10-01 (post-audit-v2) E-1: a challenge ballot weighs only the stake the voter
///         held both one second before the filing and at the proposal's propose-time snapshot.
/// Fixture: A = g1 30k (sole accused), H = g2 + g3 = 40k honest non-approvers, staked before propose.
contract ChallengeGameBallotStakeSinceProposeTest is ChallengeEndToEndBase {
    uint256 constant H = 2 * FILLER_STAKE; // 40k honest, non-accused
    uint256 constant SHIPPED_COOLDOWN = 7 days; // RobinhoodParams.COOLDOWN

    /// Benign proposal executes; then a day passes (so any later stake is clearly post-execution).
    function _benignExecuted() internal returns (uint256 pid) {
        vm.prank(owner);
        swood.setCooldownPeriod(SHIPPED_COOLDOWN);
        pid = _proposeApproveExecute(); // g1 approves with its whole 30k lock; batch is poke+bump, harmless
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    /// propose -> review opens -> g1 approves; stops at the end of review, not yet executed.
    function _benignApprovedAtReviewEnd() internal returns (uint256 pid) {
        pid = _propose();
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
    }

    function _status(uint256 cid) internal view returns (uint256) {
        return uint256(game.challengeOf(cid).status);
    }

    function _closeWindowAndResolve(uint256 cid) internal {
        vm.warp(game.challengeOf(cid).filedAt + game.challengeOf(cid).voteWindowAtFiling);
        game.resolve(cid);
    }

    function _expectFailsAndApproverIntact(uint256 cid) internal {
        _closeWindowAndResolve(cid);
        assertEq(_status(cid), uint256(IChallengeGame.Status.Failed), "false challenge fails");
        assertEq(swood.guardianStake(g1), G1_STAKE, "honest approver keeps its whole stake");
    }

    // ── Inverted PoCs: stake added after the propose snapshot carries no ballot ──

    /// @notice A bloc staked at the end of review that executes the proposal itself and has it challenged a second later cannot vote.
    function test_blocStakedAtReviewEndThatSelfExecutesHasNoBallot() public {
        uint256 pid = _benignApprovedAtReviewEnd();
        address fresh = makeAddr("freshBloc");
        uint256 F = H + 1;
        _stakeGuardian(fresh, F, 100);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(fresh);
        gov.executeProposal(pid);
        uint256 executedAt = gov.getProposal(pid).executedAt;
        assertEq(swood.getPastStake(fresh, executedAt - 1), F, "fixture: full stake before execution");

        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 cid = _file(challenger, pid, "ipfs://review-end-bloc");
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(c.snapshotAt, gov.getProposal(pid).snapshotTimestamp, "pinned from the governor's snapshot");
        assertEq(swood.getPastStake(fresh, c.snapshotAt), 0, "fixture: nothing at the propose snapshot");
        assertEq(c.votableAtFiling, H + F, "electorate unchanged: the bloc sits in the denominator");

        vm.prank(fresh);
        vm.expectRevert(IChallengeGame.NoVotableStake.selector);
        game.voteOnChallenge(cid, true);

        vm.prank(g2);
        game.voteOnChallenge(cid, false);
        _expectFailsAndApproverIntact(cid);
    }

    /// @notice A fresh bloc staked one second before the filing cannot vote, and the false challenge fails.
    function test_freshBlocOneSecondBeforeFilingHasNoBallot() public {
        uint256 pid = _benignExecuted();
        address fresh = makeAddr("freshBloc");
        uint256 F = H + 1;
        _stakeGuardian(fresh, F, 100);

        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 filerBefore = wood.balanceOf(challenger);
        uint256 cid = _file(challenger, pid, "ipfs://false-accusation");
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(swood.getPastStake(fresh, c.filedAt - 1), F, "fixture: full raw stake at filedAt-1");
        assertEq(c.votableAtFiling, H + F, "votable = honest + fresh");
        assertEq(c.totalStakeAtFiling, H + F + G1_STAKE, "total = honest + fresh + accused");

        vm.prank(fresh);
        vm.expectRevert(IChallengeGame.NoVotableStake.selector);
        game.voteOnChallenge(cid, true);
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);

        vm.prank(g2);
        game.voteOnChallenge(cid, false);
        vm.prank(g3);
        game.voteOnChallenge(cid, false);
        _expectFailsAndApproverIntact(cid);
        assertEq(
            filerBefore - wood.balanceOf(challenger),
            _challengerBond() * game.forfeitBurnBps() / 10_000,
            "filer burns the forfeit share of its bond"
        );
    }

    /// @notice Four min-stake sybils staked after propose each get no ballot.
    function test_sybilsAtMinStakeHaveNoBallot() public {
        uint256 pid = _benignExecuted();
        address[] memory w = new address[](4);
        for (uint256 i; i < 4; i++) {
            w[i] = makeAddr(string(abi.encodePacked("sybil", vm.toString(i))));
            _stakeGuardian(w[i], i == 3 ? MIN_GUARDIAN_STAKE + 1 : MIN_GUARDIAN_STAKE, 100 + i);
        }
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 cid = _file(challenger, pid, "ipfs://sybils");
        for (uint256 i; i < 4; i++) {
            vm.prank(w[i]);
            vm.expectRevert(IChallengeGame.NoVotableStake.selector);
            game.voteOnChallenge(cid, true);
        }
        _expectFailsAndApproverIntact(cid);
    }

    /// @notice A silent electorate no longer lets a fresh quorum-sized bloc convict at window close.
    function test_silentElectorateFreshQuorumBlocCannotConvict() public {
        uint256 pid = _benignExecuted();
        address fresh = makeAddr("freshBloc");
        _stakeGuardian(fresh, 30_000e18, 100);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 cid = _file(challenger, pid, "ipfs://silent");
        vm.prank(fresh);
        vm.expectRevert(IChallengeGame.NoVotableStake.selector);
        game.voteOnChallenge(cid, true);
        _expectFailsAndApproverIntact(cid);
    }

    // ── Clamp edges ──

    /// @notice A guardian staked before propose that tops up before execution votes with its pre-propose stake.
    function test_topUpAfterProposeVotesWithThePreProposeAmount() public {
        uint256 pid = _benignApprovedAtReviewEnd();
        _stakeGuardian(g2, 50_000e18, 2); // top-up after propose, before execution
        vm.warp(vm.getBlockTimestamp() + 1);
        gov.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 cid = _file(challenger, pid, "ipfs://top-up");

        vm.prank(g2);
        game.voteOnChallenge(cid, true);
        (uint256 convict,,,) = game.challengeTallyOf(cid);
        assertEq(convict, FILLER_STAKE, "weight = stake at the propose snapshot, the top-up carries nothing");
    }

    /// @notice A guardian whose stake fell after propose votes with the lower, later amount.
    function test_stakeReducedAfterProposeVotesWithTheLowerAmount() public {
        uint256 pid = _benignExecuted();
        // sWOOD has no partial unstake; a registry slash is the path that lowers an active stake.
        address[] memory who = new address[](1);
        who[0] = g2;
        uint256[] memory bps = new uint256[](1);
        bps[0] = 5_000;
        vm.prank(address(registry));
        swood.slashGuardians(keccak256("unrelated-review"), vm.getBlockTimestamp(), who, bps);
        uint256 reduced = swood.guardianStake(g2);
        assertLt(reduced, FILLER_STAKE, "fixture: stake fell after propose");
        assertGt(reduced, 0);

        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 cid = _file(challenger, pid, "ipfs://reduced");
        vm.prank(g2);
        game.voteOnChallenge(cid, false);
        (, uint256 acquit,,) = game.challengeTallyOf(cid);
        assertEq(acquit, reduced, "weight = the lower stake at filing");
    }

    // ── Controls kept from the PoC ──

    /// @notice Guardians staked before propose keep their full weight and still convict a bad proposal.
    function test_control_preProposeGuardiansStillConvict() public {
        uint256 pid = _proposeApproveExecute();
        uint256 cid = _file(challenger, pid, "ipfs://real-drain");
        _convict(cid);
        (uint256 convict,,,) = game.challengeTallyOf(cid);
        assertEq(convict, H, "full pre-propose weight");
        game.resolve(cid);
        assertEq(_status(cid), uint256(IChallengeGame.Status.Settled), "convicted");
        assertEq(swood.guardianStake(g1), 0, "the approver is slashed");
    }

    /// @notice Same-second stake and post-filing counter-stake have no weight; the accused cannot vote.
    function test_control_sameBlockStakeAndPostFilingCounterStakeHaveNoWeight() public {
        uint256 pid = _benignExecuted();
        address sameBlock = makeAddr("sameBlock");
        _stakeGuardian(sameBlock, 100_000e18, 100);
        uint256 cid = _file(challenger, pid, "ipfs://same-block");
        vm.prank(sameBlock);
        vm.expectRevert(IChallengeGame.NoVotableStake.selector);
        game.voteOnChallenge(cid, true);

        vm.warp(vm.getBlockTimestamp() + 1);
        address defender = makeAddr("defender");
        _stakeGuardian(defender, 100_000e18, 999);
        vm.prank(defender);
        vm.expectRevert(IChallengeGame.NoVotableStake.selector);
        game.voteOnChallenge(cid, false);

        vm.prank(g1);
        vm.expectRevert(IChallengeGame.AccusedCannotVote.selector);
        game.voteOnChallenge(cid, false);
    }

    /// @notice With no bloc, the same false challenge fails and the filer loses its forfeit share.
    function test_control_noFreshBlocFalseChallengeFails() public {
        uint256 pid = _benignExecuted();
        uint256 filerBefore = wood.balanceOf(challenger);
        uint256 cid = _file(challenger, pid, "ipfs://no-bloc");
        vm.prank(g2);
        game.voteOnChallenge(cid, false);
        vm.prank(g3);
        game.voteOnChallenge(cid, false);
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);
        _expectFailsAndApproverIntact(cid);
        assertEq(filerBefore - wood.balanceOf(challenger), _challengerBond() * game.forfeitBurnBps() / 10_000);
    }
}
