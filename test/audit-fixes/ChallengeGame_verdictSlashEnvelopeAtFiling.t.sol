// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenCourtEndToEndTest} from "../TokenCourtEndToEnd.t.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";

/// @notice v1 audit F6: the verdict slash envelope is pinned at filing, so the
///         sWOOD owner can neither nullify nor inflate an already-decided burn
///         by moving `[minSlashBps, maxSlashBps]` while the challenge runs.
contract ChallengeGame_verdictSlashEnvelopeAtFilingTest is TokenCourtEndToEndTest {
    /// @notice Court path: the owner zeroes BOTH bounds after the cohort voted
    ///         guilty and before `finalize`. The pinned envelope still burns.
    function test_ownerZeroesEnvelopeMidDispute_pinnedVerdictStillBurns() public {
        uint256 pid = _proposeApproveExecute();
        _stakeGuardian(g4, FILLER_STAKE, 4);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(_g1SlashBpsFor(pid), 10_000, "fixture: the ledger prices g1 at the ceiling");

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/f6"
        );
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(c.minSlashBpsAtFiling, 1000, "floor pinned at filing");
        assertEq(c.maxSlashBpsAtFiling, 10_000, "ceiling pinned at filing");

        _disputeFull(cid);
        uint256 caseId = court.caseOfChallenge(address(game), cid);
        vm.prank(g2);
        court.vote(caseId, true); // guilty

        // One multisig batch, after the cohort voted, before the verdict lands.
        vm.startPrank(owner);
        swood.setMinSlashBps(0);
        swood.setMaxSlashBps(0);
        vm.stopPrank();

        _warpPastVoteWindow(caseId);
        uint256 g1StakeBefore = swood.guardianStake(g1);
        uint256 swoodBalBefore = wood.balanceOf(address(swood));
        court.finalize(caseId);

        assertEq(
            uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "the verdict still lands"
        );
        assertEq(swood.guardianStake(g1), 0, "the decided burn took the whole pinned rate");
        assertEq(swoodBalBefore - wood.balanceOf(address(swood)), g1StakeBefore, "the WOOD really left the custodian");
        assertTrue(
            swood.verdictSlashed(keccak256(abi.encode(address(gov), pid)), g1), "the per-approver mark is now set"
        );
    }

    /// @notice Silence path: `resolve` reaches the same `_settle` after
    ///         `autoSlashDelayAtFiling` with no court, dispute or vote — so the
    ///         owner's window is 7 days and needs no counter-bond.
    function test_ownerZeroesEnvelopeDuringSilenceWindow_pinnedVerdictStillBurns() public {
        uint256 pid = _proposeApproveExecute();
        _stakeGuardian(g4, FILLER_STAKE, 4);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/f6-silence"
        );

        vm.startPrank(owner);
        swood.setMinSlashBps(0);
        swood.setMaxSlashBps(0);
        vm.stopPrank();

        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        vm.warp(c.filedAt + c.autoSlashDelayAtFiling);
        uint256 g1StakeBefore = swood.guardianStake(g1);
        game.resolve(cid);

        assertEq(
            uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "silence convicted anyway"
        );
        assertEq(swood.guardianStake(g1), 0, "the undisputed conviction burned the pinned rate");
        assertEq(g1StakeBefore, G1_STAKE, "fixture: nothing had burned before the resolve");
    }

    /// @notice The pin binds BOTH ways: a ceiling raised after filing cannot
    ///         inflate a burn the accused was already exposed to at filing.
    function test_ownerRaisesCeilingMidDispute_pinnedVerdictDoesNotInflate() public {
        uint256 pid = _proposeApproveExecute();
        _stakeGuardian(g4, FILLER_STAKE, 4);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // The envelope the accused files under: half the ledger's 10_000 rate.
        vm.prank(owner);
        swood.setMaxSlashBps(5000);

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/f6-inflate"
        );
        assertEq(game.challengeOf(cid).maxSlashBpsAtFiling, 5000, "the narrow ceiling is what got pinned");

        _disputeFull(cid);
        uint256 caseId = court.caseOfChallenge(address(game), cid);
        vm.prank(g2);
        court.vote(caseId, true);

        vm.prank(owner);
        swood.setMaxSlashBps(10_000); // the live ceiling reopens mid-dispute

        _warpPastVoteWindow(caseId);
        uint256 g1StakeBefore = swood.guardianStake(g1);
        court.finalize(caseId);

        uint256 burned = g1StakeBefore - swood.guardianStake(g1);
        assertEq(burned, g1StakeBefore / 2, "burned at the PINNED 5000 bps, not the live 10_000");
    }
}
