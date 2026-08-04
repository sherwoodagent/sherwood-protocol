// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";

/// @notice Regressions for the pashov `solidity-auditor` review, registry half:
///         finding #11 (slash severity read live at resolve), finding #12 (aged
///         vote numerator against a raw frozen denominator), finding #7 (a
///         pause consuming the review window rather than deferring it).
///
///         Each test is written so that REVERTING the corresponding fix makes
///         it fail — the assertions target the fixed behaviour directly, not
///         incidental side effects.
contract GuardianRegistry_severityPauseAndBasisTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%
    uint256 constant PID = 1;

    address internal approver1 = makeAddr("approver1");
    address internal blocker1 = makeAddr("blocker1");

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, BLOCK_QUORUM_BPS);
    }

    // ════════════════════════════════════════════════════════════════════
    // Finding #11 — the slash severity envelope is snapshotted at open
    // ════════════════════════════════════════════════════════════════════

    /// @dev `blockQuorumBpsAtOpen` was snapshotted so the owner could not shift
    ///      the THRESHOLD mid-review, but the PENALTY that decision carries was
    ///      still read live from sWOOD at resolve time, and neither
    ///      `setMinSlashBps` nor `setMaxSlashBps` carries an open-review guard.
    ///      Driving both to zero between the last vote and `resolveReview`
    ///      collapsed every branch of `_severityBps` to 0, and `_slashOne`
    ///      skips the burn entirely on a zero rate — so a review that committed
    ///      `blocked = true` recovered nothing, irreversibly (`resolveReview`
    ///      writes `r.resolved` before the slash call and short-circuits on
    ///      re-entry).
    ///
    ///      Post-fix the envelope is pinned at `openReview`, so the same owner
    ///      transaction cannot reach this review's penalty.
    function test_finding11_severityUsesAtOpenEnvelope_notLiveSlots() public {
        uint256 approverStake = 30_000e18;
        uint256 blockerStake = 20_000e18; // 40% of a 50_000e18 cohort, clears the 30% quorum

        _stakeGuardian(approver1, approverStake, 1);
        _stakeGuardian(blocker1, blockerStake, 2);

        // Mature to par so the decisiveness fraction is undistorted (same
        // convention as GuardianRegistrySeverity).
        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 voteEnd = vm.getBlockTimestamp();
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PID, voteEnd, reviewEnd);
        registry.openReview(address(governor), PID);

        vm.prank(approver1);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(blocker1);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Block);

        // THE ATTACK: the review is decided but not yet committed, and the
        // owner of sWOOD — the same multisig that owns the registry, per
        // `Deploy.s.sol::_handoffOwnership` — zeroes the whole envelope.
        vm.startPrank(regOwner);
        swood.setMinSlashBps(0);
        swood.setMaxSlashBps(0);
        vm.stopPrank();
        assertEq(swood.minSlashBps(), 0, "live envelope really is zero");
        assertEq(swood.maxSlashBps(), 0, "live envelope really is zero");

        uint256 approverStakeBefore = swood.guardianStake(approver1);

        vm.warp(reviewEnd);
        assertTrue(registry.resolveReview(address(governor), PID), "review resolves blocked");

        assertLt(
            swood.guardianStake(approver1),
            approverStakeBefore,
            "approver must still be slashed: severity comes from the at-open envelope, so zeroing the live slots mid-review recovers nothing"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Finding #12 — the block-quorum numerator matches its denominator
    // ════════════════════════════════════════════════════════════════════

    /// @dev The numerator came from `getPastVotes`, which applies
    ///      `StakedWood._ageFactorBps`; the denominator (`r.totalStakeAtOpen`)
    ///      is RAW stake. A guardian old enough to clear the growth gate but
    ///      younger than `maturationPeriod` therefore contributed a FRACTION of
    ///      its stake to a comparison whose other side counted all of it — so a
    ///      cohort genuinely holding 40% of the electorate could fail a 30%
    ///      block quorum. The veto failing OPEN, with no attacker involved.
    ///
    ///      The regime needs `maturationPeriod > FLOOR_LOOKBACK` (30 days), so
    ///      the owner widens it here — a legal, routine retune. At the shipped
    ///      30-day default the two windows coincide and the defect is inert,
    ///      which is exactly why it survived.
    function test_finding12_blockQuorumTalliesRawStake_notAgedWeight() public {
        vm.prank(regOwner);
        swood.setMaturationPeriod(90 days);

        _stakeGuardian(approver1, 30_000e18, 1);
        _stakeGuardian(blocker1, 20_000e18, 2); // 40% raw of the 50_000e18 cohort

        // 31 days: past FLOOR_LOOKBACK, so the lookback read sees the same flat
        // stake and the growth gate cannot fire (`S > S` is false) — this test
        // is about the age factor, not the gate. Still far short of the 90-day
        // maturation, so the factor is a genuine discount (~5083 bps).
        skip(31 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 voteEnd = vm.getBlockTimestamp();
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PID, voteEnd, reviewEnd);
        registry.openReview(address(governor), PID);

        vm.prank(blocker1);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        // 20_000e18 raw against a 50_000e18 raw denominator is 4000 bps, clear
        // of the 3000 bps quorum. Under the aged numerator it was ~2033 bps and
        // this returned false.
        assertTrue(
            registry.resolveReview(address(governor), PID),
            "a cohort holding 40% of raw stake must clear a 30% block quorum: numerator and denominator have to be the same measure"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Finding #7 — a pause defers the review window, it does not consume it
    // ════════════════════════════════════════════════════════════════════

    /// @dev Review windows are wall-clock, but every writer into them
    ///      (`openReview`, `voteOnProposal`) is `whenNotPaused`. A pause
    ///      spanning `[voteEnd, reviewEnd)` left `r.opened == false` with no
    ///      guardian able to change it, and BOTH readers scored that emptiness
    ///      as a clean bill of health: `resolveReview` short-circuits
    ///      `if (!r.opened) { resolved = true; return false; }` and `outcomeOf`
    ///      returns `Cleared`. The proposal executed with a guardian review
    ///      that structurally could not happen — and an ordinary incident
    ///      pause does it, no malice required.
    function test_finding7_pauseDefersReviewWindow_ratherThanClearingIt() public {
        _stakeGuardian(approver1, 30_000e18, 1);
        _stakeGuardian(blocker1, 20_000e18, 2);

        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 voteEnd = vm.getBlockTimestamp();
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(PID, voteEnd, reviewEnd);

        // Paused across the ENTIRE review window: nobody can open it, nobody
        // can vote in it.
        vm.prank(regOwner);
        registry.pause();

        vm.warp(reviewEnd + 1 hours); // wall clock is now past the deadline
        vm.prank(regOwner);
        registry.unpause();

        // Pre-fix this call succeeded and committed `blocked = false` — the
        // proposal clearing a review nobody could take part in.
        vm.expectRevert(IGuardianRegistry.ReviewNotReadyForResolve.selector);
        registry.resolveReview(address(governor), PID);

        assertEq(
            uint256(registry.outcomeOf(address(governor), PID)),
            uint256(IGuardianRegistry.ReviewOutcome.Unresolved),
            "an unheld review is UNDETERMINED, never Cleared"
        );

        // And the deferred window is genuinely usable.
        registry.openReview(address(governor), PID);
        vm.prank(blocker1);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 2 hours);
        assertTrue(
            registry.resolveReview(address(governor), PID), "the guardians got their window back and used it to block"
        );
    }
}
