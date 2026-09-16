// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

/// @title GuardianRegistry_blockQuorumDenominatorTest
/// @notice The block-quorum comparison (`blockStakeWeight * 10_000 >=
///         blockQuorumBps * totalStakeAtOpen`) reads its numerator and its
///         denominator from the same raw stake instant: `snapshotAt` on the
///         review path, `openedAt` on the emergency path. This suite pins what
///         that single instant buys and what it does not.
///
///         Buys: stake that lands after the instant is in neither read, so
///         nobody can move the comparison by staking once a review is in
///         flight, and no voter is ever measured against an electorate they
///         are not themselves counted in.
///
///         Does not buy: a defence against dilution by stake parked BEFORE the
///         instant. `stakeAsGuardian` has no cap and no allowlist, and a
///         diluter that never votes takes no slash risk, so a large enough
///         position held across the snapshot lowers every honest guardian's
///         share. That is priced, not closed, and
///         `test_dilution_stakeParkedBeforeTheSnapshotDilutesTheVeto` keeps the
///         cost visible.
contract GuardianRegistry_blockQuorumDenominatorTest is RegistryTestHarness {
    uint256 internal constant REVIEW_PERIOD = 24 hours;
    /// @dev The audit's own quorum: 30%.
    uint256 internal constant Q = 3000;

    address internal attacker = makeAddr("staticWhaleAttacker");
    address internal honestOld = makeAddr("honestOldCohort");
    address internal honestNew = makeAddr("honestNewCohort");
    address internal diluter = makeAddr("diluter");

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, Q);
    }

    // ─────────────────────── shared fixture plumbing ───────────────────────

    /// @dev Registers, warps one second (so `openReview`'s `ts1 =
    ///      block.timestamp - 1` lands on the instant the caller just built),
    ///      and opens. Returns `reviewEnd`.
    function _registerAndOpen(uint256 pid) internal returns (uint256 reviewEnd) {
        uint256 voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(pid, voteEnd, reviewEnd);
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.openReview(address(governor), pid);
    }

    /// @dev `_isBlocked` against an arbitrary denominator, so a fixture can pin
    ///      the counterfactual outcome as well as the real one. Mirrors the
    ///      production predicate exactly, including the `>=` edge.
    function _wouldBlock(uint256 blockWeight, uint256 denom) internal pure returns (bool) {
        return blockWeight * 10_000 >= Q * denom;
    }

    // ═══════════════════ A STALE SHARE BUYS NOTHING ═══════════════════

    /// @notice `attacker` holds 40_000e18 of a 60_000e18 cohort and never
    ///         touches it; a month later the honest side has taken the
    ///         electorate to 600_000e18, so the attacker is 667 bps of it.
    ///         Measured at the snapshot instant that is what they are, and a
    ///         lone 667 bps vote does not reach a 3000 bps quorum — so there is
    ///         no block, no severity, and no slash against the honest approver.
    function test_staticWhaleCannotBlockAloneOnAStaleShare() public {
        _stakeGuardian(attacker, 40_000e18, 1);
        _stakeGuardian(honestOld, 20_000e18, 2);
        // t0 electorate: 60_000e18.

        vm.warp(vm.getBlockTimestamp() + 30 days);
        _stakeGuardian(honestNew, 540_000e18, 3);
        // Live electorate: 600_000e18. The attacker is now 6.67% of it.
        //
        // ONE SECOND, AND IT IS LOAD-BEARING. The quorum basis is stamped at
        // `registerReview` time MINUS ONE, so a cohort that staked in the very
        // same block as the proposal is invisible to it. Without this warp the
        // fixture would still see the 60_000e18 pre-growth total.
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 totalNow = swood.getPastTotalVotes(vm.getBlockTimestamp() - 1);
        assertEq(totalNow, 600_000e18, "live electorate at the snapshot instant");
        uint256 reviewEnd = _registerAndOpen(1);

        // The honest approver is an OLD guardian taking real slash risk, not a
        // strawman.
        vm.prank(honestOld);
        registry.voteOnProposal(address(governor), 1, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);

        vm.prank(attacker);
        registry.voteOnProposal(address(governor), 1, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max);

        vm.warp(reviewEnd);
        assertFalse(
            registry.resolveReview(address(governor), 1),
            "a 6.67% holder must not block alone once both sides share an instant"
        );
        assertEq(
            swood.guardianStake(honestOld), 20_000e18, "no block means no slash -- the honest approver is untouched"
        );
        assertFalse(
            _wouldBlock(40_000e18, totalNow), "against the LIVE electorate the same vote is 667 bps, far under quorum"
        );
        assertTrue(
            _wouldBlock(40_000e18, 60_000e18),
            "against the month-old electorate it would have been 6666 bps, over quorum"
        );
    }

    // ═════════════════════════ DILUTION, PRICED ═════════════════════════

    /// @notice Honest electorate 600_000e18, of which an honest blocker holds
    ///         200_000e18 — 3333 bps, over the 3000 bps quorum. A diluter parks
    ///         1_400_000e18 in the same block the review is registered in.
    ///         Because the snapshot is that block minus one, the parked stake
    ///         is in neither the denominator nor anybody's numerator, and the
    ///         veto survives.
    function test_dilution_stakeParkedAfterTheSnapshotCannotKillTheVeto() public {
        _stakeGuardian(honestOld, 200_000e18, 1); // the blocker
        _stakeGuardian(honestNew, 400_000e18, 2); // silent honest cohort

        vm.warp(vm.getBlockTimestamp() + 31 days);
        _stakeGuardian(diluter, 1_400_000e18, 3);

        assertEq(
            swood.getPastTotalVotes(vm.getBlockTimestamp() - 1),
            600_000e18,
            "the diluter staked after the snapshot instant"
        );
        uint256 reviewEnd = _registerAndOpen(2);

        vm.prank(honestOld);
        registry.voteOnProposal(address(governor), 2, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max);

        vm.warp(reviewEnd);
        assertTrue(
            registry.resolveReview(address(governor), 2),
            "a genuine 33% honest blocker still vetoes through a 3.3x park"
        );
        assertFalse(
            _wouldBlock(200_000e18, 2_000_000e18),
            "had the park counted, the honest blocker would have fallen to 1000 bps"
        );
    }

    /// @notice The diluter's cost, pinned. A position held across the snapshot
    ///         instant IS in the denominator, so dilution is priced in held
    ///         capital rather than defeated. Anyone re-deriving the tradeoff
    ///         needs this number, because it is what a candidate rule has to
    ///         beat.
    function test_dilution_stakeParkedBeforeTheSnapshotDilutesTheVeto() public {
        _stakeGuardian(honestOld, 200_000e18, 1);
        _stakeGuardian(honestNew, 400_000e18, 2);
        _stakeGuardian(diluter, 1_400_000e18, 3);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        assertEq(
            swood.getPastTotalVotes(vm.getBlockTimestamp() - 1), 2_000_000e18, "the parked stake is at the snapshot"
        );
        uint256 reviewEnd = _registerAndOpen(3);

        vm.prank(honestOld);
        registry.voteOnProposal(address(governor), 3, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max);

        vm.warp(reviewEnd);
        assertFalse(
            registry.resolveReview(address(governor), 3),
            "a diluter that holds across the snapshot takes the honest blocker to 1000 bps"
        );
    }

    // ═══════════════ EMERGENCY PATH — one instant, both sides ═══════════════

    /// @notice `openEmergency` stamps both sides of the emergency block quorum
    ///         at `block.timestamp - 1`, so a vault owner who stakes as a
    ///         guardian in that same block is in neither read and changes
    ///         nothing. The blocker holds 60_000e18 of the 80_000e18 electorate
    ///         that instant carries — 7500 bps against a 3000 bps quorum — and
    ///         the emergency is blocked; had the owner's 200_000e18 landed in
    ///         the denominator alone, the same vote would fall to 2142 bps.
    function test_sameBlockOwnerStakeCannotChangeEmergencyBlockQuorum() public {
        _stakeGuardian(honestOld, 20_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        _stakeGuardian(honestNew, 60_000e18, 2);
        vm.warp(vm.getBlockTimestamp() + 1);

        BatchExecutorLib.Call[] memory emptyCalls = new BatchExecutorLib.Call[](0);
        bytes32 emptyHash = keccak256(abi.encode(emptyCalls));

        // Same block as the open: the vault owner's guardian stake lands after
        // the `block.timestamp - 1` instant both sides are read at.
        _stakeGuardian(diluter, 200_000e18, 3);
        vm.prank(address(governor));
        registry.openEmergency(5, emptyHash, emptyCalls);

        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.EmergencyBlockVoteCast(address(governor), 5, honestNew, 60_000e18);
        vm.prank(honestNew);
        registry.voteBlockEmergencySettle(address(governor), 5);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        vm.prank(address(governor));
        (bool blocked,) = registry.finalizeEmergency(5);
        assertTrue(blocked, "a 75% blocker must veto whatever the owner stakes in the opening block");
        assertFalse(_wouldBlock(60_000e18, 280_000e18), "had the owner's stake counted, the vote would be 2142 bps");
    }

    /// @notice The unfavourable half of that same instant. An attacker who
    ///         stakes one second BEFORE `openEmergency` is inside the
    ///         `block.timestamp - 1` read, so their position counts in the
    ///         numerator exactly as it does in the denominator: any
    ///         X >= Q * E / (10_000 - Q) reaches the block quorum alone. Here
    ///         E is the 70_000e18 honest cohort and Q is 3000 bps, so
    ///         30_000e18 lands on the `>=` edge and vetoes the round with no
    ///         honest guardian voting at all. Symmetry is what makes that
    ///         stake votable, and this is its price.
    function test_stakeParkedOneSecondBeforeOpenEmergencyCountsTowardTheBlockQuorum() public {
        _stakeGuardian(honestOld, 20_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _stakeGuardian(honestNew, 50_000e18, 2);

        // One second before the open, not in it: the attacker's stake is inside
        // the `block.timestamp - 1` instant both sides are read at.
        _stakeGuardian(attacker, 30_000e18, 3);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(
            swood.getPastTotalVotes(vm.getBlockTimestamp() - 1),
            100_000e18,
            "the parked stake is inside the denominator too"
        );

        BatchExecutorLib.Call[] memory emptyCalls = new BatchExecutorLib.Call[](0);
        bytes32 emptyHash = keccak256(abi.encode(emptyCalls));

        vm.prank(address(governor));
        registry.openEmergency(6, emptyHash, emptyCalls);

        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.EmergencyBlockVoteCast(address(governor), 6, attacker, 30_000e18);
        vm.prank(attacker);
        registry.voteBlockEmergencySettle(address(governor), 6);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        vm.prank(address(governor));
        (bool blocked,) = registry.finalizeEmergency(6);
        assertTrue(blocked, "3E/7 parked one second early vetoes the emergency alone");
    }

    // ═══════════════ BASIS CHECK — numerator and denominator agree ═══════════════

    /// @notice The comparison depends on the numerator and the denominator
    ///         being the SAME measure. They are: `getPastStake` (the numerator)
    ///         and `getPastTotalVotes` (the denominator) are both RAW, while
    ///         `getPastVotes` alone applies `_ageFactorBps`. Pinned because a
    ///         future change that swaps the numerator to `getPastVotes` would
    ///         silently re-scale every comparison in this file, and the age
    ///         factor reads LIVE owner-tunable slots.
    function test_basis_stakeAndTotalAreRawWhileVotesIsAgeWeighted() public {
        assertEq(swood.ageFloorBps(), 2500, "fixture precondition: a young position is discounted to 25%");

        _stakeGuardian(honestOld, 100_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 ts = vm.getBlockTimestamp() - 1;

        assertEq(swood.getPastStake(honestOld, ts), 100_000e18, "getPastStake is RAW");
        assertEq(swood.getPastTotalVotes(ts), 100_000e18, "getPastTotalVotes is RAW -- same basis as the numerator");
        assertEq(swood.getPastVotes(honestOld, ts), 25_000e18, "getPastVotes alone is age-weighted -- NOT the basis");

        // And after maturation the age-weighted read converges on the raw one,
        // which is why the mismatch is a scaling bug rather than a constant one.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 matured = vm.getBlockTimestamp() - 1;
        assertEq(swood.getPastVotes(honestOld, matured), 100_000e18, "at par the two bases coincide");
    }
}
