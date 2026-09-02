// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExposureLedgerTest, MockGovernorForLedger} from "../ExposureLedger.t.sol";

/// @title ExposureLedger — SHE-212 phantom capacity, pinned as "cannot happen"
/// @notice THE ATTACK, AS FILED. The ledger used to track coverage in two
///         families. The BOOKING — `_recorded[key][g].usd`, the epoch
///         `_buckets` summed by the capacity check — was what `recordApproval`
///         read to decide whether a guardian had room for a new proposal. The
///         PLEDGE — `_reservedUsd`, `_committedUsd` — was what the slasher
///         read. Multi-guardian proposals deliberately over-pledged (each
///         approver booked the full requirement, since nobody knew who else
///         would show up) and a permissionless, re-runnable `settleCoverage`
///         later trimmed each BOOKING to its pro-rata share, gated only on
///         `executeBy` — the deadline to START — while the proposal stayed
///         challengeable and slashable until roughly `executedAt +
///         strategyDuration + challengeWindow`. `_rebook` "never rewrites the
///         pledge, only the booking", so between those two points a guardian
///         showed free budget while remaining fully punishable: a $1,000 bond
///         could be pledged $1,500 across two proposals, and a conviction on
///         the first wiped the stake the second relied on.
///
/// @dev    WHY IT CANNOT HAPPEN NOW. Declared coverage locks collapsed booking,
///         pledge and slash base into ONE WOOD lock per (proposal, guardian),
///         written once by `recordApproval` and erased only by `releaseApproval`
///         (a vote change, refused while frozen) or `retireApproval` (refused
///         until the bucket has expired, and while frozen or pinned). There is
///         no cohort cap, so nothing is over-pledged; there is no settlement
///         pass, so nothing can trim a booking out from under a live pledge;
///         and the capacity check reads the same buckets the lock was credited
///         to. The divergence the attack needed is not merely closed — it is
///         no longer expressible.
///
///         The two rejected alternatives from the original fix are recorded
///         because they still explain the shape of the model: gating
///         settlement on the challenge window would have stranded capital for
///         weeks, and trimming the pledge alongside the booking would have put
///         a permissionless, live-priced number back on the slash path (the
///         defect pashov review #13 removed). Deleting settlement sidesteps
///         both.
contract ExposureLedgerShe212PhantomCapacityTest is ExposureLedgerTest {
    /// @dev The co-approver whose presence made proposal A over-pledged under
    ///      the old model. Kept so the fixture is the attack's own: A is still
    ///      backed by two guardians, and that no longer frees anything.
    address internal guardian2 = makeAddr("guardian2");

    /// @dev Stake the attacker at a $1,000 bond (20,000 WOOD at $0.05) with
    ///      `kNumerator == 1`, so its whole budget is exactly one full-stake
    ///      lock; wire proposal A with the review shutting well before
    ///      `executeBy`, the window the attack lived in.
    function _wireAttack() internal {
        _wireRecording();
        swood.setStake(guardian, 20_000e18);
        vm.prank(owner);
        ledger.setKNumerator(1);

        mgov.set(1_000e6);
        mgov.setScheduleFull(block.timestamp + 20 days, 3 days, block.timestamp + 1 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian, type(uint256).max);
        assertEq(ledger.lockOf(address(mgov), 1, guardian), 20_000e18, "A holds the guardian's whole stake");
        assertEq(ledger.openExposure(guardian), 20_000e18, "and the whole budget is spoken for");

        // The second approver that used to make the cohort over-pledged. Under
        // locks it is simply a second, independent lock: A is well covered and
        // nothing about guardian's own lock depends on it.
        swood.setStake(guardian2, 20_000e18);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian2, type(uint256).max);
        assertEq(ledger.lockOf(address(mgov), 1, guardian2), 20_000e18, "the co-approver's lock stands too");
    }

    /// @notice THE PIN. With the guardian's whole stake locked on A, a second
    ///         approval on B locks NOTHING — at the vote, and at every later
    ///         instant the old attack exploited (past `reviewEnd`, past
    ///         `executeBy`, with A executed and still slashable). There is no
    ///         settlement pass to create phantom room and no cohort trim to
    ///         hand budget back.
    function test_she212_secondLockIsRefusedWhileTheFirstIsLive() public {
        _wireAttack();
        MockGovernorForLedger mgovB = _secondGovernor(1_000e6, 3 days);

        // 1. Immediately: no free budget.
        vm.prank(registry);
        ledger.recordApproval(address(mgovB), 1, guardian, type(uint256).max);
        assertEq(ledger.lockOf(address(mgovB), 1, guardian), 0, "B locks nothing: the stake is committed to A");
        (address[] memory listedB,) = ledger.approversOf(address(mgovB), 1);
        assertEq(listedB.length, 0, "and the guardian is not listed on B");

        // 2. Past A's `reviewEnd` and `executeBy` — exactly the window the old
        //    `settleCoverage` was callable in — with A executed and slashable.
        skip(2 days);
        mgov.setExecutedAt(block.timestamp);
        skip(23 days);
        assertGt(mgov.executeBy(), 0);
        assertGt(block.timestamp, mgov.executeBy(), "past executeBy: the old trim would have run here");
        (, uint256[] memory ratesA) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(ratesA[0], 10_000, "A is still fully slashable: a conviction takes the whole lock");

        mgovB.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgovB), 1, guardian, type(uint256).max);
        assertEq(ledger.lockOf(address(mgovB), 1, guardian), 0, "still nothing: no pass exists that could free room");
        assertEq(ledger.openExposure(guardian), 20_000e18, "the budget is exactly the one live lock");

        // 3. The lock on A is exactly what a conviction can take, and it is the
        //    same number the capacity check consumed — one figure, not two.
        assertEq(ledger.lockOf(address(mgov), 1, guardian), 20_000e18, "A's lock is untouched by any of the above");
        (address[] memory pledged, uint256[] memory pledgedWood) = ledger.pledgedOf(address(mgov), 1);
        assertEq(pledged[0], guardian);
        assertEq(pledgedWood[0], 20_000e18, "and `pledgedOf` is the same lock - nothing to diverge");
    }

    /// @notice CONTROL. Once A is genuinely finished — its bucket's challenge
    ///         window elapsed — the budget really is free and B locks in full.
    ///         Without this the pin above would pass against a cap that simply
    ///         never frees anything, which would be a liveness bug wearing the
    ///         fix's clothes.
    /// @dev    Two things recycle here and the test tells them apart: the BUDGET
    ///         recycles on the bucket's own expiry (`openExposure` decays on
    ///         wall clock, with no call at all), and the lock RECORD is what
    ///         `retireApproval` sweeps. B can lock the moment the budget is
    ///         back; the sweep is list hygiene.
    function test_she212_capacityIsReleasedOnceTheFirstLockExpires() public {
        _wireAttack();

        // Past the full retirement deadline, not merely past `executeBy`.
        // `retireApproval` gates on the end of the BOOKED epoch plus
        // `challengeWindow`, and the approval books into the epoch covering
        // SETTLEMENT (~23 days out here), so the deadline sits well beyond the
        // approval itself. Warped generously rather than reconstructing the
        // epoch arithmetic, which would silently drift if `epochLength` changed.
        skip(90 days + ledger.challengeWindow());
        assertEq(ledger.openExposure(guardian), 0, "the bucket expired: the budget recycled on its own");
        assertEq(ledger.lockOf(address(mgov), 1, guardian), 20_000e18, "...while the lock record still stands");

        ledger.retireApproval(address(mgov), 1, guardian);
        assertEq(ledger.lockOf(address(mgov), 1, guardian), 0, "A's lock is swept");
        (address[] memory listedA,) = ledger.pledgedOf(address(mgov), 1);
        assertEq(listedA.length, 1, "only the co-approver remains listed on A");
        assertEq(listedA[0], guardian2);

        MockGovernorForLedger mgovB = _secondGovernor(1_000e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgovB), 1, guardian, type(uint256).max);
        assertEq(ledger.lockOf(address(mgovB), 1, guardian), 20_000e18, "a retired commitment gives its budget back");
        assertEq(ledger.openExposure(guardian), 20_000e18);
    }
}
