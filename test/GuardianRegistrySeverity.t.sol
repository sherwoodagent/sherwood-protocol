// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";

/// @title GuardianRegistrySeverityTest
/// @notice Part D (spec 2026-07-19 §6): the slash severity applied to
///         approvers of a blocked proposal is a DETERMINISTIC function of
///         block-side decisiveness — no longer the blockers' stake-weighted
///         median vote. Quadratic ramp:
///
///           bBps     = blockStakeWeight × 10_000 / (totalStakeAtOpen + totalDelegatedAtOpen)
///           t        = (bBps − blockQuorumBpsAtOpen) / (SUPERMAJORITY_BPS − blockQuorumBpsAtOpen)
///           severity = minSlashBps + (maxSlashBps − minSlashBps) × t²
///
///         Floor at a scraped quorum (genuinely contested call), ceiling at
///         2/3 supermajority (overwhelming condemnation). Degenerate guard:
///         a quorum already ≥ SUPERMAJORITY_BPS means any successful block
///         is ceiling-severity.
contract GuardianRegistrySeverityTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PID = 1;
    /// @dev Block quorum the registry is deployed with (30%).
    uint256 constant Q = 3000;
    uint256 constant SUPERMAJORITY_BPS = 6_667;
    /// @dev Fresh 2-guardian cohort total. Meets MIN_COHORT_STAKE_AT_OPEN
    ///      (50_000e18) and makes stake sizing exact: with no delegation the
    ///      severity denominator is exactly this total, so a blocker staked at
    ///      `TOTAL × bps / 10_000` (exact for integer bps: bps × 10e18) lands
    ///      the decisiveness at precisely `bps`.
    uint256 constant TOTAL_COHORT = 100_000e18;

    address internal approver1 = makeAddr("approver1");
    address internal blocker1 = makeAddr("blocker1");

    /// @dev approver1's own stake for the current run — recorded by
    ///      `_runReviewWithBlockFraction` (it varies with the target fraction).
    uint256 internal _initialStake;
    uint256 internal reviewEnd;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, Q);
        // Widen the slash band to [1000, 10_000]: the harness deploys
        // 1000/9999, but Part D allows maxSlashBps == 10_000 (full wipe at
        // the supermajority ceiling) and deploy scripts use it.
        vm.prank(regOwner);
        swood.setMaxSlashBps(10_000);
    }

    /// @dev Owner call — must run BEFORE `_runReviewWithBlockFraction`, since
    ///      `openReview` snapshots the quorum into `blockQuorumBpsAtOpen`.
    function _setBlockQuorum(uint256 bps) internal {
        vm.prank(regOwner);
        registry.setBlockQuorumBps(bps);
    }

    /// @dev Drives a full review whose block-side decisiveness is exactly
    ///      `bps` of the at-open total:
    ///
    ///        blockerStake  = TOTAL_COHORT × bps / 10_000  (exact: bps × 10e18)
    ///        approverStake = TOTAL_COHORT − blockerStake
    ///        no delegation → denom = totalStakeAtOpen = TOTAL_COHORT
    ///        bBps = blockerStake × 10_000 / TOTAL_COHORT = bps  (exact)
    ///
    ///      Weight subtlety: vote weight is snapshotted at `r.openedAt` with
    ///      the age factor applied. Both guardians mature 30 days (par) before
    ///      the review opens, so aged weight == raw stake and the decisiveness
    ///      fraction is undistorted.
    function _runReviewWithBlockFraction(uint256 bps) internal {
        uint256 blockerStake = TOTAL_COHORT * bps / 10_000;
        uint256 approverStake = TOTAL_COHORT - blockerStake;
        _initialStake = approverStake;

        _stakeGuardian(approver1, approverStake, 1);
        _stakeGuardian(blocker1, blockerStake, 2);

        // Age-weighted voting: mature both guardians to par so their aged
        // vote weight equals raw stake. The extra +1 warp (ToB C-1 pattern)
        // matters: openReview snapshots at `block.timestamp - 1`, so without
        // it the age at `openedAt` would be 30d − 1s — a hair under par,
        // deflating the blocker's weight below an exact-at-quorum target.
        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        governor.setProposal(PID, voteEnd, reviewEnd);
        registry.openReview(address(governor), PID);

        vm.prank(approver1);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(blocker1);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertTrue(registry.resolveReview(address(governor), PID), "expected blocked");
    }

    function test_severity_floorAtScrapedQuorum() public {
        // Block weight lands exactly at quorum (30_000e18 × 10_000 ==
        // 3000 × 100_000e18 → blocked on the >= edge). bBps == qBps →
        // severity = minSlashBps (10%). approver1 stake 70_000e18 → slash
        // 7_000e18 exactly (no delegation → snapDelegated 0 → fallback pool
        // bases are the empty pools → spill 0; pure own-stake slash).
        _runReviewWithBlockFraction(Q);
        assertEq(swood.guardianStake(approver1), _initialStake * 9000 / 10_000);
    }

    function test_severity_ceilingAtSupermajority() public {
        // Block weight 67% >= SUPERMAJORITY_BPS (66.67%) → severity =
        // maxSlashBps = 10_000 → full wipe of the approver's own stake.
        _runReviewWithBlockFraction(6700);
        assertEq(swood.guardianStake(approver1), 0);
    }

    function test_severity_quadraticMidpoint() public {
        // mid = 3000 + (6667 − 3000) / 2 = 4833 → t = 1833e18 / 3667
        // ≈ 0.49986e18 (just under exactly 1/2 from integer floor of the odd
        // span). severity = 1000 + 9000 × (t²/1e18)/1e18 = 3248 vs the ideal
        // t = 0.5 → 1000 + 9000 × 0.25 = 3250. Remaining stake differs by
        // ~0.03%, well inside the 1% tolerance.
        uint256 mid = Q + (SUPERMAJORITY_BPS - Q) / 2;
        _runReviewWithBlockFraction(mid);
        uint256 expectedBps = 1000 + (10_000 - 1000) * 25 / 100;
        assertApproxEqRel(
            swood.guardianStake(approver1),
            _initialStake * (10_000 - expectedBps) / 10_000,
            0.01e18 // 1% tolerance for the integer-floored t
        );
    }

    function test_severity_degenerateQuorumAboveSupermajority() public {
        // blockQuorumBps >= SUPERMAJORITY_BPS: any successful block already
        // carries supermajority condemnation → ceiling severity regardless
        // of where in [quorum, 100%] the block weight lands.
        _setBlockQuorum(7000);
        _runReviewWithBlockFraction(7100);
        assertEq(swood.guardianStake(approver1), 0);
    }

    /// @notice Ported from the retired median suite: severity always respects
    ///         the owner-set [minSlashBps, maxSlashBps] band. A raised floor
    ///         binds at scraped quorum.
    function test_severity_respectsRaisedFloor() public {
        vm.prank(regOwner);
        swood.setMinSlashBps(4000);
        _runReviewWithBlockFraction(Q);
        // Floor severity is now 4000 bps → 60% of own stake remains.
        assertEq(swood.guardianStake(approver1), _initialStake * 6000 / 10_000);
    }

    function test_vote_blockCarriesNoSeverityArg() public {
        // New 3-arg signature compiles and works end-to-end: a lone blocker
        // holding 100% of the cohort blocks the proposal with no severity arg.
        _stakeGuardian(blocker1, TOTAL_COHORT, 1);
        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        governor.setProposal(PID, voteEnd, reviewEnd);
        registry.openReview(address(governor), PID);

        vm.prank(blocker1);
        registry.voteOnProposal(address(governor), PID, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertTrue(registry.resolveReview(address(governor), PID), "block vote registered");
    }
}
