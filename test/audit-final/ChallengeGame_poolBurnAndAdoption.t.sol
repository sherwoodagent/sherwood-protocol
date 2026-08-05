// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChallengeGameTest, MockRecordingCourt} from "../ChallengeGame.t.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";

/// @title ChallengeGame — two defects introduced by the finding-#10 burn model
/// @notice Both are about what happens to the counter-bond POOL on paths the
///         new model did not separate.
contract ChallengeGamePoolBurnAndAdoptionTest is ChallengeGameTest {
    // ── 1. A pool that never completed must not be burned ──

    /// @notice THE PIN. `_settle` burned the pool on EVERY conviction, complete
    ///         or not. On the silence branch an incomplete pool is money the
    ///         accused paid that bought them nothing: `_poolBacked` requires
    ///         `completedAt != 0`, so a part-funded pool never made any
    ///         challenge `Disputed`, never opened a verdict path, and cannot be
    ///         why the conviction landed. Pre-#10 it was refunded.
    ///
    ///         Worse, the shortfall is manufacturable. `file` raises
    ///         `pool.target` while the pool is incomplete, and `bondWood` scales
    ///         with `coverageUsd * bps / priceX8` — so a second filing, or
    ///         merely a WOOD price decline, moves the bar away from a defence
    ///         that was part-funded in good faith and converts it into a burn.
    ///
    ///         Released, not refunded-by-push: the WOOD lands in `unclaimedWood`
    ///         and each funder collects with `claimContribution`, so one
    ///         reverting recipient cannot brick the resolution.
    function test_settle_partFundedPoolIsReturnedNotBurned() public {
        uint256 id = _fileStandard(PROPOSAL);
        (, uint256 target,,,) = game.counterBondPoolOf(id);
        assertGt(target, 0, "fixture priced no pool, the branch could not show");

        // Fund SHORT of target — a defence begun and never completed.
        uint256 partFunded = target / 2;
        assertGt(partFunded, 0, "target too small to underfund meaningfully");
        _fund(guardianA);
        vm.prank(guardianA);
        game.dispute(id, partFunded);

        (uint256 poolWood,, uint256 raised, uint256 completedAt,) = game.counterBondPoolOf(id);
        assertEq(completedAt, 0, "fixture completed the pool, this is not the incomplete branch");
        assertEq(raised, partFunded);
        assertEq(poolWood, partFunded);

        // Run out the silence clock and convict.
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        vm.warp(c.filedAt + c.autoSlashDelayAtFiling + 1);
        uint256 burnedBefore = wood.balanceOf(game.BURN_ADDRESS());
        game.resolve(id);

        // The pool is CLOSED but not destroyed, and its funder can collect.
        (,,,, bool burned) = game.counterBondPoolOf(id);
        assertFalse(burned, "an incomplete pool must not be burned");
        assertEq(
            game.claimableContribution(id, guardianA), partFunded, "the funder's stake is claimable, not destroyed"
        );

        // EXACTLY the challenger's own bond slice, and nothing of the pool. An
        // upper bound like `< partFunded + target` would pass even if most of
        // the pool burned, which is the failure this test exists to catch.
        uint256 settleBurn = (c.bondWood * c.settleBurnBpsAtFiling) / 10_000;
        assertGt(settleBurn, 0, "fixture uses a zero burn rate, the assertion would be vacuous");
        uint256 burnDelta = wood.balanceOf(game.BURN_ADDRESS()) - burnedBefore;
        assertEq(burnDelta, settleBurn, "only the challenger's bond slice burns; no pool WOOD reaches the dead address");
    }

    /// @notice A COMPLETED pool is still burned in full — it bought a real
    ///         defence, opened the verdict path, and losing it is the point.
    ///         Without this the fix could be "never burn", which would remove
    ///         the finding-#10 deterrent entirely.
    function test_settle_completedPoolIsStillBurned() public {
        uint256 id = _fileStandard(PROPOSAL);
        (, uint256 target,,,) = game.counterBondPoolOf(id);
        _fund(guardianA);
        vm.prank(guardianA);
        game.dispute(id, type(uint256).max);

        (,,, uint256 completedAt,) = game.counterBondPoolOf(id);
        assertGt(completedAt, 0, "fixture left the pool incomplete, wrong branch");

        // AND ACTUALLY CONVICT. Asserting only that the fixture completed the
        // pool would pass against a mutant that released on BOTH branches —
        // i.e. against the exact over-correction this test exists to catch.
        //
        // Through the COURT, not through silence: completing the pool makes the
        // challenge `Disputed`, and `resolve` on a Disputed challenge waits for
        // `disputeTimeout` and then routes to `_fail`, never to `_settle`. A
        // `Guilty` ruling is the only way a COMPLETED pool reaches the burn.
        assertEq(
            uint8(game.challengeOf(id).status),
            uint8(IChallengeGame.Status.Disputed),
            "a completed pool must have bought the dispute"
        );
        uint256 burnedBefore = wood.balanceOf(game.BURN_ADDRESS());
        vm.prank(court);
        game.rule(id, IChallengeGame.Verdict.Guilty);

        assertEq(
            uint8(game.poolOutcomeOf(id)), uint8(IChallengeGame.PoolOutcome.Burned), "a completed pool must still burn"
        );
        assertGe(wood.balanceOf(game.BURN_ADDRESS()) - burnedBefore, target, "pool WOOD did not reach the burn address");
        assertEq(game.claimableContribution(id, guardianA), 0, "and a burned pool owes its funder nothing");
    }

    /// @notice The release closes the pool, so contribution cannot continue
    ///         against an already-convicted proposal. That is the seam the burn
    ///         model was defending, and `Released` shuts it exactly as `Burned`
    ///         does — `dispute` reverts on any outcome other than `Open`.
    function test_settle_releasedPoolRefusesFurtherContribution() public {
        uint256 id = _fileStandard(PROPOSAL);
        (, uint256 target,,,) = game.counterBondPoolOf(id);
        _fund(guardianA);
        vm.prank(guardianA);
        game.dispute(id, target / 2);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        vm.warp(c.filedAt + c.autoSlashDelayAtFiling + 1);
        game.resolve(id);

        _fund(guardianB);
        vm.prank(guardianB);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.dispute(id, target);
    }

    // ── 2. Free adoption leaves an un-referred sibling exposed ──

    /// @notice One payment completes the single per-proposal pool and
    ///         `challengeOf` then derives `Disputed` for EVERY live challenge it
    ///         backs — but `dispute` auto-refers only the challenge the payment
    ///         routed through. Every adopted sibling is `Disputed` with no case.
    ///
    ///         That is the exposure: an accused who self-files from a fresh
    ///         address and pays through their OWN filing opens the case on that
    ///         one, while an honest challenger rides to `disputeTimeout` and
    ///         resolves through `_fail`, forfeiting its bond pro-rata to the
    ///         pool's funders — the accused.
    ///
    ///         Pinned as BEHAVIOUR, not as a bug to be auto-fixed: enumerating
    ///         siblings inside `dispute` is an unbounded loop over `_liveCount`,
    ///         which any number of addresses can grow.
    ///         The remedy is that an adopted sibling can refer ITSELF —
    ///         `TokenCourt.refer` is permissionless and `challengeOf` already
    ///         reports the sibling as `Disputed`, so no new entrypoint is needed
    ///         — but it must happen with enough slack left for `refer`'s own
    ///         `InsufficientClock` gate. That is why the fix here is a stated
    ///         hazard plus this pin, not an unbounded auto-refer loop.
    function test_dispute_adoptedSiblingGetsNoCaseAutomatically() public {
        (uint256[] memory ids,) = _fileNAndFundOnePool(3);

        // All three read Disputed off ONE payment — adoption is by derivation
        // through `_poolBacked`, not by anything the siblings did.
        for (uint256 i; i < 3; i++) {
            assertEq(
                uint8(game.challengeOf(ids[i]).status),
                uint8(IChallengeGame.Status.Disputed),
                "adoption is by derivation, for every live sibling"
            );
        }

        // ...but referral reached exactly ONE of them: the challenge the
        // payment routed through. `_fileNAndFundOnePool` disputes `ids[0]`.
        assertEq(MockRecordingCourt(court).lastReferred(), ids[0], "only the paying challenge is auto-referred");
        assertTrue(ids[1] != ids[0] && ids[2] != ids[0], "fixture sanity: the siblings are distinct");
    }

    /// @notice STAGGERED WINDOWS: a pool completed too late for the EARLIEST
    ///         live challenge still burns, and the sibling it actually backed
    ///         loses it.
    ///
    ///         Windows are per-challenge and staggered; the pool is per-proposal
    ///         and shared. A completion landing inside a later filing's window
    ///         but after an earlier one's has closed backs the later challenge
    ///         only — so the earlier one silence-convicts, `_settle` sees
    ///         `completedAt != 0`, and the burn destroys a defence that was real
    ///         for the sibling.
    ///
    ///         Pinned as the CURRENT behaviour, with the operational rule stated
    ///         at `_poolBacked`: the accused must complete before the earliest
    ///         live challenge's deadline, not their own. Closing it properly
    ///         means pricing the burn per-challenge rather than per-pool.
    function test_settle_poolCompletedTooLateForTheEarliestChallengeStillBurns() public {
        uint256 idEarly = _fileStandard(PROPOSAL);
        IChallengeGame.Challenge memory early = game.challengeOf(idEarly);

        // A second filing well after the first, so its window outlives the
        // first's by the gap between them.
        vm.warp(early.filedAt + (early.autoSlashDelayAtFiling / 2));
        address filerLate = makeAddr("lateFiler");
        _fund(filerLate);
        vm.prank(filerLate);
        uint256 idLate =
            game.file(address(gov), PROPOSAL, IChallengeGame.Predicate.DrawdownBreach, ADAPTER, SELECTOR, EVIDENCE);

        // Pay AFTER the early challenge's deadline, inside the late one's.
        vm.warp(early.filedAt + early.autoSlashDelayAtFiling + 1);
        _fund(guardianA);
        vm.prank(guardianA);
        game.dispute(idLate, type(uint256).max);

        assertEq(
            uint8(game.challengeOf(idLate).status),
            uint8(IChallengeGame.Status.Disputed),
            "the late filing IS backed - it paid inside its own window"
        );
        assertEq(
            uint8(game.challengeOf(idEarly).status),
            uint8(IChallengeGame.Status.Filed),
            "the early one is NOT - the payment landed after its deadline"
        );

        // The early challenge silence-convicts, and takes the pool with it.
        game.resolve(idEarly);
        assertEq(
            uint8(game.poolOutcomeOf(idEarly)),
            uint8(IChallengeGame.PoolOutcome.Burned),
            "a completed-but-too-late pool still burns"
        );
        assertEq(
            game.claimableContribution(idLate, guardianA),
            0,
            "and the sibling it DID back is left with nothing to claim"
        );
    }

    /// @notice The sibling that never got referred is the one that pays at the
    ///         timeout. Pins the consequence so the hazard is not just a comment:
    ///         an un-referred `Disputed` challenge resolves through `_fail` and
    ///         forfeits its bond to the pool's funders — who, in the attack this
    ///         describes, are the accused.
    function test_resolve_unreferredSiblingForfeitsAtTimeout() public {
        (uint256[] memory ids,) = _fileNAndFundOnePool(3);

        IChallengeGame.Challenge memory sibling = game.challengeOf(ids[1]);
        vm.warp(sibling.filedAt + sibling.disputeTimeoutAtFiling + 1);
        game.resolve(ids[1]);

        assertEq(
            uint8(game.challengeOf(ids[1]).status),
            uint8(IChallengeGame.Status.Failed),
            "an adopted sibling nobody referred loses at the timeout"
        );
    }
}
