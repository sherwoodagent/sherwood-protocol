// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {TokenVesting} from "../../src/vesting/TokenVesting.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract TokenVestingTest is Test {
    TokenVesting internal impl;
    ERC20Mock internal token;

    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");

    uint64 internal start;
    uint64 internal constant CLIFF = 180 days;
    uint64 internal constant DURATION = 365 days;
    uint256 internal constant GRANT = 1_000_000e18;

    function setUp() public {
        impl = new TokenVesting();
        token = new ERC20Mock("Wood", "WOOD", 18);
        start = uint64(vm.getBlockTimestamp());
    }

    /// Deploys a funded clone with the default schedule.
    function _newVesting(uint64 cliffDuration, bool cancelable) internal returns (TokenVesting v) {
        v = TokenVesting(Clones.clone(address(impl)));
        v.initialize(owner, beneficiary, address(token), start, cliffDuration, DURATION, cancelable);
        token.mint(address(v), GRANT);
    }

    // ── initialize ──

    function test_initialize_storesParams() public {
        TokenVesting v = _newVesting(CLIFF, true);
        assertEq(v.owner(), owner);
        assertEq(v.beneficiary(), beneficiary);
        assertEq(address(v.token()), address(token));
        assertEq(v.start(), start);
        assertEq(v.cliff(), start + CLIFF);
        assertEq(v.duration(), DURATION);
        assertTrue(v.cancelable());
        assertFalse(v.cancelled());
        assertEq(v.released(), 0);
    }

    function test_initialize_revertsOnZeroAddresses() public {
        TokenVesting v = TokenVesting(Clones.clone(address(impl)));
        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        v.initialize(address(0), beneficiary, address(token), start, CLIFF, DURATION, true);

        v = TokenVesting(Clones.clone(address(impl)));
        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        v.initialize(owner, address(0), address(token), start, CLIFF, DURATION, true);

        v = TokenVesting(Clones.clone(address(impl)));
        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        v.initialize(owner, beneficiary, address(0), start, CLIFF, DURATION, true);
    }

    function test_initialize_revertsOnZeroDuration() public {
        TokenVesting v = TokenVesting(Clones.clone(address(impl)));
        vm.expectRevert(TokenVesting.ZeroDuration.selector);
        v.initialize(owner, beneficiary, address(token), start, 0, 0, true);
    }

    function test_initialize_revertsWhenCliffExceedsDuration() public {
        TokenVesting v = TokenVesting(Clones.clone(address(impl)));
        vm.expectRevert(TokenVesting.CliffExceedsDuration.selector);
        v.initialize(owner, beneficiary, address(token), start, DURATION + 1, DURATION, true);
    }

    function test_initialize_revertsOnScheduleOverflow() public {
        TokenVesting v = TokenVesting(Clones.clone(address(impl)));
        vm.expectRevert(TokenVesting.ScheduleOverflow.selector);
        v.initialize(owner, beneficiary, address(token), type(uint64).max - DURATION + 1, 0, DURATION, true);
    }

    function test_initialize_onlyOnce() public {
        TokenVesting v = _newVesting(CLIFF, true);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v.initialize(owner, beneficiary, address(token), start, CLIFF, DURATION, true);
    }

    function test_implementation_cannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner, beneficiary, address(token), start, CLIFF, DURATION, true);
    }

    // ── vesting curve ──

    function test_vestedAmount_zeroBeforeCliff() public {
        TokenVesting v = _newVesting(CLIFF, true);
        assertEq(v.vestedAmount(start), 0);
        assertEq(v.vestedAmount(start + CLIFF - 1), 0);
        assertEq(v.releasable(), 0);
    }

    function test_vestedAmount_retroactiveAtCliff() public {
        TokenVesting v = _newVesting(CLIFF, true);
        // At the cliff instant the linear-from-start amount unlocks at once.
        assertEq(v.vestedAmount(start + CLIFF), GRANT * CLIFF / DURATION);
    }

    function test_vestedAmount_linearMidVest() public {
        TokenVesting v = _newVesting(CLIFF, true);
        uint64 t = start + 200 days;
        assertEq(v.vestedAmount(t), GRANT * 200 days / DURATION);
    }

    function test_vestedAmount_fullAfterEnd() public {
        TokenVesting v = _newVesting(CLIFF, true);
        assertEq(v.vestedAmount(start + DURATION), GRANT);
        assertEq(v.vestedAmount(start + DURATION + 365 days), GRANT);
    }

    function test_vestedAmount_noCliffIsPlainLinear() public {
        TokenVesting v = _newVesting(0, true);
        assertEq(v.vestedAmount(start + 1), GRANT * 1 / DURATION);
        assertEq(v.vestedAmount(start + DURATION / 2), GRANT / 2);
    }

    function test_vestedAmount_topUpGrowsCurve() public {
        TokenVesting v = _newVesting(0, true);
        token.mint(address(v), GRANT); // double the allocation mid-flight
        assertEq(v.vestedAmount(start + DURATION / 2), GRANT); // half of 2×GRANT
    }

    function testFuzz_vestedAmount_monotoneAndBounded(uint64 t1, uint64 t2) public {
        TokenVesting v = _newVesting(CLIFF, true);
        t1 = uint64(bound(t1, start, start + 2 * DURATION));
        t2 = uint64(bound(t2, t1, start + 2 * DURATION));
        uint256 v1 = v.vestedAmount(t1);
        uint256 v2 = v.vestedAmount(t2);
        assertLe(v1, v2); // monotone non-decreasing
        assertLe(v2, GRANT); // never exceeds allocation
        assertEq(v.vestedAmount(start + DURATION), GRANT); // completeness anchor: a constant-zero curve can't pass
    }

    function test_topUp_afterCancel_isStranded() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 2);
        vm.prank(owner);
        v.cancel();
        token.mint(address(v), GRANT); // late arrival, invisible to the frozen curve
        assertEq(v.totalAllocation(), GRANT / 2);
        assertEq(v.releasable(), GRANT / 2);
        v.release();
        assertEq(token.balanceOf(beneficiary), GRANT / 2);
        assertEq(token.balanceOf(address(v)), GRANT); // stranded forever
        assertEq(v.releasable(), 0);
    }

    function test_topUp_afterVestEnd_unlocksInstantly() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION);
        token.mint(address(v), GRANT); // top-up after the schedule ended
        assertEq(v.releasable(), 2 * GRANT); // instant full unlock of the addition
    }

    // ── release ──

    function test_release_paysBeneficiary() public {
        TokenVesting v = _newVesting(CLIFF, true);
        vm.warp(start + CLIFF);
        uint256 expected = GRANT * CLIFF / DURATION;
        v.release();
        assertEq(token.balanceOf(beneficiary), expected);
        assertEq(v.released(), expected);
        assertEq(v.releasable(), 0);
    }

    function test_release_permissionless_anyCaller() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION);
        vm.prank(makeAddr("randomKeeper"));
        v.release();
        assertEq(token.balanceOf(beneficiary), GRANT);
    }

    function test_release_incremental() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 2);
        v.release();
        assertEq(token.balanceOf(beneficiary), GRANT / 2);
        vm.warp(start + DURATION);
        v.release();
        assertEq(token.balanceOf(beneficiary), GRANT);
        // totalAllocation stays constant across releases
        assertEq(v.totalAllocation(), GRANT);
    }

    function test_release_beforeCliff_isNoop() public {
        TokenVesting v = _newVesting(CLIFF, true);
        vm.warp(start + CLIFF - 1);
        v.release();
        assertEq(token.balanceOf(beneficiary), 0);
    }

    function test_release_emitsReleased() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 2);
        vm.expectEmit(true, true, true, true, address(v));
        emit TokenVesting.Released(GRANT / 2);
        v.release();
    }

    function test_release_balanceShrink_clampsInsteadOfBricking() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 2);
        v.release(); // released = GRANT / 2
        // External shrink (negative rebase / admin burn): wallet loses half its remaining balance.
        token.burn(address(v), GRANT / 4);
        // vested(now) = (balance + released) * 1/2 = (GRANT/4 + GRANT/2) / 2 = 3*GRANT/8 < released.
        assertEq(v.releasable(), 0); // clamped, not underflow revert
        v.release(); // no-op, must not revert
        assertEq(token.balanceOf(beneficiary), GRANT / 2);
        // At vest end the curve catches back up to everything still in the wallet.
        vm.warp(start + DURATION);
        assertEq(v.releasable(), GRANT / 4);
        v.release();
        assertEq(token.balanceOf(beneficiary), GRANT / 2 + GRANT / 4);
    }

    // ── cancel ──

    function test_cancel_midVest_splitsVestedAndResidue() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 4);
        vm.prank(owner);
        v.cancel();
        // Residue returned to owner immediately.
        assertEq(token.balanceOf(owner), GRANT - GRANT / 4);
        assertTrue(v.cancelled());
        // Vested-to-date frozen and claimable, even much later.
        vm.warp(start + DURATION);
        assertEq(v.releasable(), GRANT / 4);
        v.release();
        assertEq(token.balanceOf(beneficiary), GRANT / 4);
        assertEq(token.balanceOf(address(v)), 0);
    }

    function test_cancel_beforeCliff_returnsEverything() public {
        TokenVesting v = _newVesting(CLIFF, true);
        vm.warp(start + CLIFF - 1);
        vm.prank(owner);
        v.cancel();
        assertEq(token.balanceOf(owner), GRANT);
        assertEq(v.releasable(), 0);
        vm.warp(start + DURATION);
        assertEq(v.releasable(), 0); // nothing ever becomes claimable
    }

    function test_cancel_afterFullVest_returnsNothing() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION);
        vm.prank(owner);
        v.cancel();
        assertEq(token.balanceOf(owner), 0);
        assertEq(v.releasable(), GRANT);
    }

    function test_cancel_afterPartialRelease() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 4);
        v.release(); // beneficiary takes first quarter
        vm.warp(start + DURATION / 2);
        vm.prank(owner);
        v.cancel();
        assertEq(token.balanceOf(owner), GRANT / 2); // unvested half
        assertEq(v.releasable(), GRANT / 4); // vested half minus released quarter
        v.release();
        assertEq(token.balanceOf(beneficiary), GRANT / 2);
    }

    function test_cancel_revertsForNonOwner() public {
        TokenVesting v = _newVesting(0, true);
        vm.prank(beneficiary);
        vm.expectRevert(TokenVesting.NotOwner.selector);
        v.cancel();
    }

    function test_cancel_revertsWhenNotCancelable() public {
        TokenVesting v = _newVesting(0, false);
        vm.prank(owner);
        vm.expectRevert(TokenVesting.NotCancelable.selector);
        v.cancel();
    }

    function test_cancel_revertsOnDoubleCancel() public {
        TokenVesting v = _newVesting(0, true);
        vm.startPrank(owner);
        v.cancel();
        vm.expectRevert(TokenVesting.AlreadyCancelled.selector);
        v.cancel();
        vm.stopPrank();
    }

    function test_cancel_emitsVestingCancelled() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 4);
        vm.expectEmit(true, true, true, true, address(v));
        emit TokenVesting.VestingCancelled(GRANT / 4, GRANT - GRANT / 4);
        vm.prank(owner);
        v.cancel();
    }

    function test_cancel_balanceShrink_clampsResidue() public {
        TokenVesting v = _newVesting(0, true);
        vm.warp(start + DURATION / 2);
        v.release(); // released = GRANT / 2
        token.burn(address(v), GRANT / 4); // balance = GRANT/4; vested(now) = 3*GRANT/8 < released
        vm.prank(owner);
        v.cancel(); // must NOT revert
        assertEq(token.balanceOf(owner), GRANT / 4); // swept remaining balance
        assertEq(token.balanceOf(address(v)), 0);
        assertEq(v.releasable(), 0);
        vm.warp(start + DURATION);
        assertEq(v.releasable(), 0); // frozen; nothing further ever claimable
    }

    function testFuzz_cancel_conservation(uint64 cancelAt, uint64 releaseAt) public {
        TokenVesting v = _newVesting(CLIFF, true);
        releaseAt = uint64(bound(releaseAt, start, start + DURATION));
        cancelAt = uint64(bound(cancelAt, releaseAt, start + 2 * DURATION));

        vm.warp(releaseAt);
        v.release();

        vm.warp(cancelAt);
        uint256 vestedAtCancel = v.vestedAmount(cancelAt);
        vm.prank(owner);
        v.cancel();

        assertEq(token.balanceOf(owner), GRANT - vestedAtCancel);

        vm.warp(start + 3 * DURATION);
        v.release();
        assertEq(token.balanceOf(beneficiary) + token.balanceOf(owner), GRANT);
        assertEq(token.balanceOf(address(v)), 0);
    }
}
