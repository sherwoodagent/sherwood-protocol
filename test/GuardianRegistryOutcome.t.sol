// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";

/// @notice Tests for the pure-view `outcomeOf` guardian-review verdict and the
///         anti-twin-drift invariant that it never disagrees with the mutating
///         `resolveReview` commit (both read the single `_isBlocked` predicate).
///
///         Cohort/voting flow reuses `RegistryTestHarness` exactly as
///         `GuardianRegistryResolveTest` does: 5 guardians × 10_000e18 =
///         50_000e18 (== MIN_COHORT_STAKE_AT_OPEN), matured 30 days to par so
///         vote weights read the full staked amount, block quorum 3000 bps.
contract GuardianRegistryOutcomeTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PID = 1;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%

    uint256 voteEnd;
    uint256 reviewEnd;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, BLOCK_QUORUM_BPS);

        // 5 guardians × 10_000e18 = 50_000e18 — matches MIN_COHORT_STAKE_AT_OPEN.
        for (uint256 i = 0; i < 5; i++) {
            _stakeGuardian(_guardian(i), 10_000e18, 1 + i);
        }

        // Mature the cohort to par so quorum math runs on full stake weight.
        skip(30 days);
        // ToB C-1: openReview snapshots at `block.timestamp - 1`.
        vm.warp(vm.getBlockTimestamp() + 1);

        voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PID, voteEnd, reviewEnd);
    }

    function _guardian(uint256 i) internal pure returns (address) {
        return address(uint160(0xAA00 + i + 1));
    }

    function _open() internal {
        registry.openReview(address(governor), PID);
    }

    function _vote(uint256 i, IGuardianRegistry.GuardianVoteType side) internal {
        vm.prank(_guardian(i));
        registry.voteOnProposal(address(governor), PID, side);
    }

    function _outcome(uint256 pid) internal view returns (uint8) {
        return uint8(registry.outcomeOf(address(governor), pid));
    }

    // ── Unresolved ──

    function test_outcomeOf_unresolvedBeforeReviewEnd() public {
        _open();
        vm.warp(reviewEnd - 1);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Unresolved));
    }

    function test_outcomeOf_unregisteredIsUnresolved() public view {
        assertEq(_outcome(999), uint8(IGuardianRegistry.ReviewOutcome.Unresolved));
    }

    // ── Cleared ──

    function test_outcomeOf_clearedWhenNeverOpened() public {
        // Window registered in setUp, never openReview'd.
        vm.warp(reviewEnd);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Cleared));
    }

    function test_outcomeOf_cohortTooSmallIsCleared() public {
        // Drop 2 guardians → combined at-open stake 30_000e18 < 50_000e18 floor.
        vm.prank(_guardian(3));
        swood.requestUnstakeGuardian();
        vm.prank(_guardian(4));
        swood.requestUnstakeGuardian();
        // Make the cohort drop visible at `block.timestamp - 1`.
        vm.warp(vm.getBlockTimestamp() + 1);

        _open();
        // Even a unanimous block from the 3 survivors can't flip a too-small
        // cohort.
        for (uint256 i = 0; i < 3; i++) {
            _vote(i, IGuardianRegistry.GuardianVoteType.Block);
        }

        vm.warp(reviewEnd);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Cleared));
    }

    // ── Blocked / Cleared at quorum ──

    function test_outcomeOf_blockedAtQuorum() public {
        _open();
        // 2 blockers = 20_000e18 = 40% of 50_000e18 >= 30% quorum.
        _vote(0, IGuardianRegistry.GuardianVoteType.Block);
        _vote(1, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Blocked));
    }

    function test_outcomeOf_clearedBelowQuorum() public {
        _open();
        // 1 blocker = 10_000e18 = 20% of 50_000e18 < 30% quorum.
        _vote(0, IGuardianRegistry.GuardianVoteType.Block);
        _vote(1, IGuardianRegistry.GuardianVoteType.Approve);

        vm.warp(reviewEnd);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Cleared));
    }

    // ── Cached read after commit ──

    function test_outcomeOf_reportsCachedAfterResolve() public {
        _open();
        _vote(0, IGuardianRegistry.GuardianVoteType.Block);
        _vote(1, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Blocked));

        bool committed = registry.resolveReview(address(governor), PID);
        assertTrue(committed);

        // Cached path (`r.resolved` first branch) reports the same verdict.
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Blocked));
    }

    /// @notice `cancelReview` commits Cleared DURING the open window, which used
    ///         to leave the ONE state where cached != freshly-computed: further
    ///         block votes could inflate `blockStakeWeight` past quorum before
    ///         `reviewEnd`, so a fresh `_isBlocked` said Blocked while the cache
    ///         said Cleared.
    ///
    ///         `voteOnProposal` now rejects a resolved review, which closes that
    ///         divergence AT THE SOURCE: `blockStakeWeight` is frozen the moment
    ///         the review resolves, so cached and recomputed agree in every
    ///         reachable state. The resolved-first branch stays as the cheap,
    ///         authoritative answer (and as the guarantee that a future edit
    ///         re-opening a write path cannot make the view drift from the
    ///         commit) — this test pins BOTH halves: the vote is rejected, and
    ///         the cache holds.
    function test_outcomeOf_cachedClearedSurvivesLateBlockInflation() public {
        // Healthy cohort (50_000e18 == MIN), opened inside the window.
        _open();

        // Below-quorum block weight: 1 blocker = 10_000e18 = 20% < 30%.
        _vote(0, IGuardianRegistry.GuardianVoteType.Block);

        // Governor cancels while still inside the window → resolved, not blocked.
        vm.prank(address(governor));
        registry.cancelReview(PID);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Cleared));

        // Still inside the window, so the vote window itself is open — but the
        // review is resolved, so the inflation that would have taken
        // blockStakeWeight to 20_000e18 = 40% >= 30% is refused outright.
        vm.prank(_guardian(1));
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);

        // Cache holds, and nothing could have moved the recompute off it.
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Cleared));

        // `resolveReview` is idempotent (returns the cached `false`), and the
        // view still reports Cleared afterwards.
        bool committed = registry.resolveReview(address(governor), PID);
        assertFalse(committed);
        assertEq(_outcome(PID), uint8(IGuardianRegistry.ReviewOutcome.Cleared));
    }

    // ── Anti-twin-drift invariant: view and commit always agree ──

    function testFuzz_outcomeOf_agreesWithResolveReview(uint128 blockW, uint128 approveW, bool healthyCohort) public {
        // Optionally shrink the cohort below MIN_COHORT_STAKE_AT_OPEN. The base
        // cohort (5 × 10_000e18 = 50_000e18) exactly meets the floor; dropping 2
        // (→ 30_000e18) makes it too-small so the review must Clear regardless
        // of block weight.
        uint256 available = 5;
        if (!healthyCohort) {
            vm.prank(_guardian(3));
            swood.requestUnstakeGuardian();
            vm.prank(_guardian(4));
            swood.requestUnstakeGuardian();
            vm.warp(vm.getBlockTimestamp() + 1);
            available = 3;
        }

        _open();

        // Fuzz how many active guardians block vs approve (bounded so both sit
        // inside the active set). Block weight drives the quorum decision.
        uint256 nBlock = bound(uint256(blockW), 0, available);
        uint256 nApprove = bound(uint256(approveW), 0, available - nBlock);
        for (uint256 i = 0; i < nBlock; i++) {
            _vote(i, IGuardianRegistry.GuardianVoteType.Block);
        }
        for (uint256 i = 0; i < nApprove; i++) {
            _vote(nBlock + i, IGuardianRegistry.GuardianVoteType.Approve);
        }

        vm.warp(reviewEnd);

        IGuardianRegistry.ReviewOutcome v = registry.outcomeOf(address(governor), PID);
        bool committed = registry.resolveReview(address(governor), PID);

        // The view's Blocked verdict must exactly match the committed slash flag.
        assertEq(v == IGuardianRegistry.ReviewOutcome.Blocked, committed, "view disagrees with commit");
        // And the cached read after commit matches the pre-commit view.
        assertEq(_outcome(PID), uint8(v), "cached read drifted from pre-commit view");
    }
}
