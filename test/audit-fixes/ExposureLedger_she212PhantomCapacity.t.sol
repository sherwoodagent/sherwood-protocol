// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExposureLedgerTest, MockGovernorForLedger} from "../ExposureLedger.t.sol";

/// @title ExposureLedger — SHE-212 phantom capacity
/// @notice `settleCoverage` frees a guardian's CAPACITY while their LIABILITY is
///         still live and slashable, so the same bond can back two proposals at
///         once.
///
///         The ledger tracks coverage in two families. The BOOKING —
///         `_recorded[key][g].usd`, `_buckets` (summed by `openExposureUsd`),
///         `_liveBookedUsd` — is what `recordApproval` reads to decide whether a
///         guardian has room for a new proposal. The PLEDGE — `_reservedUsd`,
///         `_committedUsd`, `_livePledgedUsd` — is what the slasher reads.
///
///         Multi-guardian proposals deliberately over-pledge (each books the
///         full requirement, since nobody knows who else will show up), and
///         `settleCoverage` later trims each to their pro-rata share and hands
///         the excess back. That is only sound once the proposal is genuinely
///         finished. It gates on `executeBy` — the deadline to START — while the
///         proposal stays challengeable and slashable until roughly
///         `executedAt + strategyDuration + challengeWindow`. `_rebook`'s
///         downward branch then moves only the booking ("settlement never
///         rewrites the pledge, only the booking"), so between those two points
///         the guardian shows free budget while remaining fully punishable.
///
/// @dev    WHY THE FIX IS ON THE READ SIDE. Two alternatives were rejected with
///         reasons worth keeping:
///
///         - Gating `settleCoverage` on the challenge window would make it a
///           no-op until then (the trim IS its entire effect), stranding
///           guardian capital for weeks, and would override an explicit
///           "DELIBERATELY NOT GATED ON `_frozen`" decision.
///         - Trimming the PLEDGE alongside the booking would put a
///           permissionless, re-runnable, live-priced number back on the slash
///           path — the exact defect `slashBpsFor` was moved off the booking to
///           fix (pashov review #13).
///
///         So the cap is bounded below by `_livePledgedUsd`, the exact
///         non-decaying sum of live pledges. It is not a liveness trap:
///         `retireApproval` is permissionless and clears it once the challenge
///         window has elapsed and nothing is frozen or pinned.
///
///         This is ALSO required under the proportional-slashing design in
///         SHE-232 — that changes the SIZE of a loss, not the requirement that
///         capacity be computed from what is still slashable.
contract ExposureLedgerShe212PhantomCapacityTest is ExposureLedgerTest {
    /// @dev The co-approver whose presence makes proposal A over-pledged. The
    ///      inherited fixture carries only one guardian.
    address internal guardian2 = makeAddr("guardian2");

    /// @dev One guardian's pledge on one proposal. `pledgedOf` returns parallel
    ///      arrays over the whole approver cohort and the ledger exposes no
    ///      per-guardian scalar, so the lookup lives here rather than widening
    ///      the production surface for a test's convenience.
    function _pledge(address governor, uint256 pid, address g) internal view returns (uint256) {
        (address[] memory approvers, uint256[] memory pledgedUsd) = ledger.pledgedOf(governor, pid);
        for (uint256 i = 0; i < approvers.length; i++) {
            if (approvers[i] == g) return pledgedUsd[i];
        }
        return 0;
    }
    /// @notice THE ATTACK. After `settleCoverage` trims the booking, the ledger
    ///         must not hand the freed room to a second proposal while the first
    ///         is still slashable.
    ///
    /// @dev    Arithmetic: the guardian holds a $1,000 slashable bond and
    ///         `kNumerator == 1`, so their whole budget is $1,000 and backing one
    ///         $1,000 proposal consumes all of it. Proposal A is over-pledged by
    ///         a sibling guardian, so `settleCoverage` trims this guardian's
    ///         BOOKING to their $500 pro-rata share while `_reservedUsd[A]` stays
    ///         at $1,000. Pre-fix the cap then sees $500 free and books proposal
    ///         B — leaving the guardian pledged $1,500 against a $1,000 bond,
    ///         with a conviction on A wiping the stake B relies on.
    function test_she212_settledBookingDoesNotFreeCapacityWhileStillSlashable() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18); // $1,000 slashable bond
        vm.prank(owner);
        ledger.setKNumerator(1); // budget == the bond: one $1,000 proposal fills it

        // ── Proposal A, over-pledged by two guardians ──
        mgov.set(1_000e6);
        mgov.setScheduleFull(block.timestamp + 20 days, 3 days, block.timestamp + 1 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        assertEq(_pledge(address(mgov), 1, guardian), 1_000e18, "A is pledged at the full requirement");
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "and the whole budget is spoken for");

        // A second approver is what makes the cohort over-pledged, so the
        // settlement trim has something to hand back. Without it the pro-rata
        // share equals the pledge and the trim is a no-op.
        swood.setStake(guardian2, 20_000e18);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian2);

        // ── Settle A: permissionless, past `executeBy`, A still slashable ──
        skip(25 days);
        ledger.settleCoverage(address(mgov), 1);

        // The booking has been trimmed. This is the divergence itself, pinned so
        // a failure here reads as "settlement stopped trimming" rather than as
        // the capacity bug below.
        assertLt(ledger.openExposureUsd(guardian), 1_000e18, "settlement trimmed the BOOKING to the pro-rata share");
        assertEq(
            _pledge(address(mgov), 1, guardian),
            1_000e18,
            "but the PLEDGE is untouched - the guardian is still slashable for the full amount"
        );

        // ── Proposal B tries to use the freed room ──
        MockGovernorForLedger mgovB = _secondGovernor(1_000e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgovB), 1, guardian);

        // THE PIN. Capacity must be bounded by what is still SLASHABLE, not by a
        // booking that settlement wrote down. Pre-fix B booked the phantom $500,
        // leaving $1,500 of live pledges against a $1,000 bond.
        assertEq(
            _pledge(address(mgovB), 1, guardian),
            0,
            "B must book nothing: the bond is still fully committed to A"
        );
    }

    /// @notice CONTROL. Once A is genuinely finished — challenge window elapsed
    ///         and the approval retired — the capacity really is free and B
    ///         books normally.
    /// @dev    Without this the test above would pass against a cap that simply
    ///         never frees anything, which would be a liveness bug wearing the
    ///         fix's clothes. `retireApproval` is permissionless and is what
    ///         clears `_livePledgedUsd`.
    function test_she212_capacityIsReleasedOnceTheApprovalIsRetired() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18);
        vm.prank(owner);
        ledger.setKNumerator(1);

        mgov.set(1_000e6);
        mgov.setScheduleFull(block.timestamp + 20 days, 3 days, block.timestamp + 1 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        // Past the full retirement deadline, not merely past `executeBy`.
        // `retireApproval` gates on the end of the BOOKED epoch plus
        // `challengeWindow`, and the approval books into the epoch covering
        // SETTLEMENT (~23 days out here), so the deadline sits well beyond the
        // approval itself. Warped generously rather than reconstructing the
        // epoch arithmetic, which would silently drift if `epochLength` changed.
        skip(90 days + ledger.challengeWindow());
        ledger.retireApproval(address(mgov), 1, guardian);

        assertEq(_pledge(address(mgov), 1, guardian), 0, "A's pledge is gone");

        MockGovernorForLedger mgovB = _secondGovernor(1_000e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgovB), 1, guardian);

        assertGt(
            _pledge(address(mgovB), 1, guardian), 0, "a retired commitment must give its budget back"
        );
    }
}
