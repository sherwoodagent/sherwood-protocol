// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultWithdrawalQueueTest} from "../queue/VaultWithdrawalQueue.t.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";

/// @title VaultWithdrawalQueue — stamp monotonicity
/// @notice `_lastStampedPid` is a high-water mark that the two surviving exits
///         use as EXACT COMPLEMENTS of one another: `claim` on a Deposit needs
///         `_lastStampedPid >= r.pid`, `cancel` needs its negation. That is what
///         makes exactly one exit open at any instant — the property pashov #10
///         closed, after the earlier `stamped`-alone gate let a depositor hold
///         both open and take the better of the two.
///
///         Nothing local enforced the ordering. It followed from the governor's
///         single-open-proposal invariant, i.e. from a different contract, and a
///         cross-contract invariant that two local branches silently depend on
///         is the kind that survives until it doesn't.
contract PashovFinalQueueStampTest is VaultWithdrawalQueueTest {
    /// @notice A backwards stamp is refused outright. Were it accepted, an
    ///         already-claimable deposit at the higher pid would become
    ///         unclaimable (`_lastStampedPid < r.pid` again) AND its `cancel`
    ///         exit would reopen — both halves of the straddle at once.
    function test_stampSettlement_refusesABackwardsPid() public {
        vm.prank(address(vault));
        queue.stampSettlement(5, NUM, DEN);

        vm.prank(address(vault));
        vm.expectRevert(IVaultWithdrawalQueue.StampOutOfOrder.selector);
        queue.stampSettlement(4, NUM, DEN);
    }

    /// @notice Forward stamps are unaffected, including gaps — proposals can be
    ///         cancelled without settling, so pids are not required to be dense.
    function test_stampSettlement_allowsForwardGaps() public {
        vm.prank(address(vault));
        queue.stampSettlement(2, NUM, DEN);
        vm.prank(address(vault));
        queue.stampSettlement(9, NUM, DEN);

        // Re-stamping 9 is still refused by the pre-existing one-shot guard, so
        // the new check has not displaced it.
        vm.prank(address(vault));
        vm.expectRevert(IVaultWithdrawalQueue.AlreadySettled.selector);
        queue.stampSettlement(9, NUM, DEN);
    }

    /// @notice The very first stamp is unconstrained — `_lastStampedPid` starts
    ///         at 0 and every real pid is >= 1, so the guard must not make the
    ///         initial settlement a special case.
    function test_stampSettlement_firstStampAtAnyPid() public {
        vm.prank(address(vault));
        queue.stampSettlement(7, NUM, DEN);
        // No revert; the high-water mark is now 7 and only >= 7 may follow.
        vm.prank(address(vault));
        vm.expectRevert(IVaultWithdrawalQueue.StampOutOfOrder.selector);
        queue.stampSettlement(6, NUM, DEN);
    }

    /// @notice The guard sits BEFORE the one-shot check in precedence only where
    ///         they do not overlap: a repeat of the CURRENT high-water pid is
    ///         `AlreadySettled`, not `StampOutOfOrder`, so existing callers keep
    ///         the error they were written against.
    function test_stampSettlement_repeatOfCurrentPidStillReportsAlreadySettled() public {
        vm.prank(address(vault));
        queue.stampSettlement(3, NUM, DEN);

        vm.prank(address(vault));
        vm.expectRevert(IVaultWithdrawalQueue.AlreadySettled.selector);
        queue.stampSettlement(3, NUM, DEN);
    }
}
