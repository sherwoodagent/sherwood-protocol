// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";

/// @title ClockAndBasis
/// @notice Regression pins for the 2026-08 pashov audit findings that are about
///         WHICH CLOCK or WHICH BASIS a value is read on, rather than about a
///         missing check.
///
///         Both classes have bitten this contract repeatedly: a value is read
///         two ways in two places, the two agree in every ordinary case, and
///         they diverge only in a window an attacker (or an ordinary incident
///         pause) can reach. Nothing looks wrong at either site in isolation.
contract PashovClockAndBasisTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 1;

    address[5] guardians = [address(0xAA01), address(0xAA02), address(0xAA03), address(0xAA04), address(0xAA05)];

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, 3000);
    }

    function _stakeFullCohort() internal {
        for (uint256 i = 0; i < 5; i++) {
            _stakeGuardian(guardians[i], 10_000e18, 1 + i);
        }
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Finding #6 — cancelReview measured the window on the wall clock ──

    /// @dev `cancelReview` was the last reader of `reviewEnd` still on
    ///      `block.timestamp`, while `openReview`, `voteOnProposal`,
    ///      `resolveReview`, `outcomeOf` and the declared mirror
    ///      `cancelEmergency` had all moved to `_effNow`.
    ///
    ///      In the deferred span `[reviewEnd, reviewEnd + pauseShiftTotal)` the
    ///      two disagree: the wall clock says the window closed, the effective
    ///      clock says it is still open. `cancelReview` refused while
    ///      `resolveReview` also refused (not ready) — so the review was
    ///      neither cancellable nor resolvable, and only new block votes could
    ///      still land.
    ///
    ///      `SyndicateGovernor.cancelProposal` calls `cancelReview` UNWRAPPED,
    ///      so the proposer lost their exit outright; `_closeReviewIfRegistered`
    ///      calls it inside a bare `try`, so on every terminal transition the
    ///      failure was SILENT and left a live, slashable review attached to a
    ///      dead proposal.
    function test_finding6_cancelReviewSucceedsInsideThePauseDeferredSpan() public {
        _stakeFullCohort();
        uint256 voteEnd = vm.getBlockTimestamp() + 1 hours;
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PROPOSAL_ID, voteEnd, reviewEnd);

        vm.warp(voteEnd + 1);
        registry.openReview(address(governor), PROPOSAL_ID);

        // An ordinary incident pause partway through the review window.
        uint256 pauseSpan = 2 hours;
        vm.prank(regOwner);
        registry.pause();
        vm.warp(vm.getBlockTimestamp() + pauseSpan);
        vm.prank(regOwner);
        registry.unpause();
        assertEq(registry.pauseShiftTotal(), pauseSpan, "the shift is exactly the outage");

        // Wall clock past reviewEnd, effective clock not: the deferred span.
        vm.warp(reviewEnd + 1);
        assertEq(
            uint256(registry.outcomeOf(address(governor), PROPOSAL_ID)),
            uint256(IGuardianRegistry.ReviewOutcome.Unresolved),
            "the review is deferred, not decided"
        );

        // THE FIX. Pre-fix this reverted `ReviewNotOpen`, taking the proposer's
        // exit away while block votes could still accumulate against them.
        vm.prank(address(governor));
        registry.cancelReview(PROPOSAL_ID);

        (, bool resolved,,) = registry.getReviewState(address(governor), PROPOSAL_ID);
        assertTrue(resolved, "cancel must close the review inside the deferred span");
    }

    /// @dev The stated rationale must survive the fix: the proposer still gets
    ///      exactly ONE window and still cannot race a pending slash. Once the
    ///      EFFECTIVE clock passes `reviewEnd`, cancel is refused as before.
    function test_finding6_cancelStillRefusedOnceTheEffectiveClockPasses() public {
        _stakeFullCohort();
        uint256 voteEnd = vm.getBlockTimestamp() + 1 hours;
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PROPOSAL_ID, voteEnd, reviewEnd);

        vm.warp(voteEnd + 1);
        registry.openReview(address(governor), PROPOSAL_ID);

        uint256 pauseSpan = 2 hours;
        vm.prank(regOwner);
        registry.pause();
        vm.warp(vm.getBlockTimestamp() + pauseSpan);
        vm.prank(regOwner);
        registry.unpause();

        // Past reviewEnd on BOTH clocks now.
        vm.warp(reviewEnd + pauseSpan + 1);
        vm.prank(address(governor));
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        registry.cancelReview(PROPOSAL_ID);
    }

    /// @dev With no pause at all the two clocks coincide, so behaviour is
    ///      unchanged — the fix must not widen the cancel window in the
    ///      ordinary case.
    function test_finding6_noPauseLeavesTheCancelWindowUnchanged() public {
        _stakeFullCohort();
        uint256 voteEnd = vm.getBlockTimestamp() + 1 hours;
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PROPOSAL_ID, voteEnd, reviewEnd);

        vm.warp(voteEnd + 1);
        registry.openReview(address(governor), PROPOSAL_ID);

        vm.warp(reviewEnd + 1);
        vm.prank(address(governor));
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        registry.cancelReview(PROPOSAL_ID);
    }

    // ── Finding #21 — registerReview over-credited a pause in progress ──

    /// @dev `registerReview` is the only review-clock writer without
    ///      `whenNotPaused`, so it is the one that can land MID pause.
    ///      `pauseShiftTotal` is advanced only by `unpause`, so reading it bare
    ///      during a pause snapshots the PRE-pause figure — and `unpause` then
    ///      adds the whole outage, crediting this review with all of it rather
    ///      than with the part that overlapped its own clock.
    ///
    ///      Measured through observable behaviour rather than the private
    ///      field: a review registered at the very END of a long pause should
    ///      get essentially NO deferral, so its window closes on schedule.
    function test_finding21_reviewRegisteredMidPauseIsNotCreditedTheWholeOutage() public {
        _stakeFullCohort();

        // A long outage. The review is registered at the very end of it, so
        // almost none of the pause overlapped this review's own clock.
        vm.prank(regOwner);
        registry.pause();
        vm.warp(vm.getBlockTimestamp() + 10 hours);

        uint256 voteEnd = vm.getBlockTimestamp() + 1 hours;
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PROPOSAL_ID, voteEnd, reviewEnd);

        vm.prank(regOwner);
        registry.unpause();
        assertGe(registry.pauseShiftTotal(), 10 hours, "the outage really was long");

        // PRE-FIX THIS LINE IS WHERE IT DIES, with `ReviewNotOpen()` —
        // observed, not assumed. The unearned 10h of credit puts this review's
        // effective clock 10h BEHIND, so `openReview`'s own `_effNow >= voteEnd`
        // check has not been reached yet and the window cannot even be opened.
        // Same root cause as the assertion below, surfacing one step earlier.
        vm.warp(voteEnd + 1);
        registry.openReview(address(governor), PROPOSAL_ID);

        // One second past reviewEnd on the wall clock. Post-fix the effective
        // clock tracks the wall clock, so the window is genuinely closed and
        // the outcome is determined rather than deferred.
        vm.warp(reviewEnd + 1);
        assertTrue(
            registry.outcomeOf(address(governor), PROPOSAL_ID) != IGuardianRegistry.ReviewOutcome.Unresolved,
            "a review registered at the tail of a pause must not inherit the whole outage"
        );
    }

    /// @dev THE PANIC THE FIRST VERSION OF THE #21 FIX INTRODUCED, found by an
    ///      independent reviewer and pinned here.
    ///
    ///      Stamping the in-progress pause span into `clockShiftAtRegister`
    ///      broke an invariant that had held globally: `pauseShiftTotal` is
    ///      advanced only by `unpause`, so between a mid-pause `registerReview`
    ///      and the end of that pause, `clockShiftAtRegister > pauseShiftTotal`
    ///      and `_effNow`'s checked subtraction panicked `0x11`.
    ///
    ///      Both readers reachable mid-pause are exercised: `outcomeOf` (the
    ///      view `ProposalLifecycle._afterVote` calls, so every state commit on
    ///      the proposal reverted) and `cancelReview` (no `whenNotPaused`, and
    ///      `SyndicateGovernor.cancelProposal` calls it unwrapped).
    ///
    ///      The original #21 tests could not catch this: both unpause before
    ///      reading anything.
    function test_finding21_readsDuringTheSamePauseDoNotUnderflow() public {
        _stakeFullCohort();

        vm.prank(regOwner);
        registry.pause();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        // Registered mid-pause: the write that used to break the invariant.
        uint256 voteEnd = vm.getBlockTimestamp() + 1 hours;
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PROPOSAL_ID, voteEnd, reviewEnd);

        // STILL PAUSED. Pre-fix both of these panicked 0x11.
        vm.warp(voteEnd + 1);
        registry.outcomeOf(address(governor), PROPOSAL_ID);

        vm.prank(address(governor));
        registry.cancelReview(PROPOSAL_ID);

        (, bool resolved,,) = registry.getReviewState(address(governor), PROPOSAL_ID);
        assertTrue(resolved, "cancel must work mid-pause on a mid-pause registration");
    }

    /// @dev The genuine case the deferral exists for is untouched: a pause that
    ///      starts AFTER registration still defers this review's clock in full.
    function test_finding21_pauseAfterRegistrationStillDefersInFull() public {
        _stakeFullCohort();
        uint256 voteEnd = vm.getBlockTimestamp() + 1 hours;
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PROPOSAL_ID, voteEnd, reviewEnd);

        vm.warp(voteEnd + 1);
        registry.openReview(address(governor), PROPOSAL_ID);

        uint256 pauseSpan = 3 hours;
        vm.prank(regOwner);
        registry.pause();
        vm.warp(vm.getBlockTimestamp() + pauseSpan);
        vm.prank(regOwner);
        registry.unpause();

        vm.warp(reviewEnd + 1);
        assertEq(
            uint256(registry.outcomeOf(address(governor), PROPOSAL_ID)),
            uint256(IGuardianRegistry.ReviewOutcome.Unresolved),
            "a pause overlapping the review's own clock must still defer it"
        );
    }
}
