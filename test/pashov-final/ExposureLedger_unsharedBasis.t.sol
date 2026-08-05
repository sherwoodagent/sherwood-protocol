// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExposureLedgerTest, MockGovernorForLedger} from "../ExposureLedger.t.sol";

/// @title ExposureLedger — unshared coverage basis
/// @notice A value read on one basis in one place and on a different basis
///         everywhere else, where the two agree right up until an ordinary,
///         permissionless operation moves one of them.
///
///         Inherits the main suite's fixture so the mocks, the price wiring and
///         the `_wireRecording` setup are the ones the rest of the file is
///         written against, rather than a second parallel harness that could
///         drift from it.
contract PashovFinalExposureLedgerTest is ExposureLedgerTest {
    // ── Finding 8 — the unshared basis was the movable one ──

    /// @notice `unsharedLiabilityUsd` exists for exactly one caller —
    ///         `ChallengeGame.file`'s challenger bond — and its whole purpose is
    ///         to NOT be diluted by the accused cohort's unrelated commitments.
    ///         Its own natspec: the bond "must not shrink merely because the
    ///         same guardians are juggling other open commitments."
    ///
    ///         It summed `_recorded[key][g].usd`, the live BOOKING. But
    ///         `settleCoverage`'s `_rebook` writes the booking down to the
    ///         cross-proposal pro-rata allocation and never touches the pledge —
    ///         `_rebook` says so itself: "settlement never rewrites the pledge,
    ///         only the booking." So one `settleCoverage` pass silently converted
    ///         the unshared read into the shared one.
    ///
    ///         This is the same divergence `test_finding24_settleCoverageMovesThe
    ///         BookingButNotThePledge` pins on `approversOf`/`pledgedOf`, reaching
    ///         a different consumer. That test proves the booking moves; this one
    ///         proves the bond basis does not follow it.
    function test_finding8_unsharedTotalSurvivesSettleCoverage() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18); // $1,000 slashable bond
        vm.prank(owner);
        ledger.setKNumerator(2); // capUsd = $2,000, room for two $1,000 pledges

        mgov.set(1_000e6);
        mgov.setScheduleFull(block.timestamp + 20 days, 3 days, block.timestamp + 1 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        // The sibling commitment that supplies the sharing denominator. Without
        // it `_sharedSlashableUsd` reduces to the unshared value and the bug is
        // invisible — `reserved == liveTotal` makes the pro-rata a no-op.
        MockGovernorForLedger mgov2 = _secondGovernor(1_000e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);

        assertEq(ledger.unsharedLiabilityUsd(address(mgov), 1), 1_000e18, "undiluted before settlement");
        assertEq(ledger.liabilityUsd(address(mgov), 1), 500e18, "the SHARED read is half, and correctly so");

        // Permissionless, past executeBy, by a stranger — and in production this
        // is not even opt-in: `SyndicateGovernor._finishSettlement` and
        // `reclaimProposerBond` both call `_settleCoverageBestEffort`, so a
        // normally-settled proposal has already been through this before any
        // challenger can file.
        skip(25 days);
        ledger.settleCoverage(address(mgov), 1);

        // THE PIN. Pre-fix this returned 500e18 — the booking had been rewritten
        // to the shared allocation, so the "unshared" total was the shared one
        // and `file`'s anti-spam bond halved. Generalises to 1/K for K siblings.
        assertEq(
            ledger.unsharedLiabilityUsd(address(mgov), 1),
            1_000e18,
            "unshared basis must read the PLEDGE, which settlement does not move"
        );
    }

    /// @notice The shared read is deliberately left alone — it is correct for
    ///         what a conviction can actually recover, and moving both to the
    ///         pledge would over-state recovery on a shared bond. Pinned so a
    ///         future "make them consistent" refactor has to argue with a test.
    function test_finding8_sharedTotalStillTracksTheBooking() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18);
        vm.prank(owner);
        ledger.setKNumerator(2);

        mgov.set(1_000e6);
        mgov.setScheduleFull(block.timestamp + 20 days, 3 days, block.timestamp + 1 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        MockGovernorForLedger mgov2 = _secondGovernor(1_000e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);

        uint256 sharedBefore = ledger.liabilityUsd(address(mgov), 1);
        assertEq(sharedBefore, 500e18, "pre-settlement: G's $1,000 bond split evenly across two $1,000 claims");

        skip(25 days);
        ledger.settleCoverage(address(mgov), 1);

        // The shared read MOVES, and correctly so: `_rebook` wrote P1's booking
        // down to 500, so `_liveBookedUsd` is now 500 + 1,000 = 1,500 and the
        // pro-rata is `1000 * 500 / 1500`. That is the point of the shared basis
        // — it tracks the booking, which settlement is allowed to move. The
        // unshared basis must NOT follow it, which is the sibling test.
        assertEq(
            ledger.liabilityUsd(address(mgov), 1),
            333_333_333_333_333_333_333,
            "shared read follows the booking through settlement"
        );
        assertLt(
            ledger.liabilityUsd(address(mgov), 1),
            ledger.unsharedLiabilityUsd(address(mgov), 1),
            "the two bases must stay distinguishable after settlement, not collapse together"
        );
    }
}
