// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTransferPerformanceFeeCapTest} from "../audit-fixes/Vault_transferPerformanceFee_cap.t.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";

/// @title SyndicateVault.spendableFee
/// @notice The ceiling `transferPerformanceFee` tests `amount` against, exposed
///         so `SyndicateGovernor._payFee` can size an escrow it is about to book
///         rather than discovering the ceiling by reverting.
///
///         WHY IT MATTERS. `_payFee`'s catch cannot see WHY a transfer failed,
///         and the two reasons want opposite treatment: a blacklisted recipient
///         means the money IS here and the full amount must be held for them;
///         `AmountExceedsBalance` means it is not. Escrowing the full amount for
///         the second reason books a liability that is unbacked by construction
///         — it flows into `_escrowedFeeLiability()`, which `totalAssets()`
///         subtracts, so an oversized escrow pins `totalAssets()` to 0 (zeroing
///         every LP's conversion AND stamping the settle price at `num == 1`),
///         while `claimUnclaimedFees` re-requests the same full amount and fails
///         the same comparison forever, with `rescueERC20` unable to touch the
///         vault asset.
///
///         Inherits the MS-H9 cap suite so `spendableFee` is pinned against the
///         very bound it must mirror, in the same fixture, rather than against a
///         second harness that could drift from it.
contract PashovFinalSpendableFeeTest is VaultTransferPerformanceFeeCapTest {
    /// @notice The view and the bound agree exactly: `spendableFee` is the
    ///         largest amount `transferPerformanceFee` accepts, and one wei more
    ///         reverts. If these two ever disagree, `_payFee` books the wrong
    ///         number — so pin them against each other, not against a literal.
    function test_spendableFee_isExactlyTheTransferBound() public {
        usdc.mint(address(vault), 100e6);

        uint256 ceiling = vault.spendableFee(address(usdc));
        assertEq(ceiling, 100e6, "no queue reserve and no escrow: the whole balance is spendable");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(ISyndicateVault.AmountExceedsBalance.selector);
        vault.transferPerformanceFee(address(usdc), recipient, ceiling + 1);

        // And the ceiling itself lands — the bound is inclusive on both sides.
        vm.prank(MOCK_GOVERNOR);
        vault.transferPerformanceFee(address(usdc), recipient, ceiling);
        assertEq(usdc.balanceOf(recipient), ceiling, "the reported ceiling must be payable in full");
    }

    /// @notice An empty vault reports zero rather than reverting. `_payFee` runs
    ///         inside a catch block on a settlement path that must not brick, so
    ///         this view has to answer for every state the vault can be in.
    function test_spendableFee_zeroOnEmptyVault() public view {
        assertEq(vault.spendableFee(address(usdc)), 0, "nothing held, nothing spendable");
    }

    /// @notice A foreign token reports zero instead of reverting, matching
    ///         `transferPerformanceFee`'s `InvalidAsset` refusal in effect while
    ///         keeping the view total. A revert here would propagate into
    ///         `_payFee`'s catch and defeat the whole point of reading it.
    function test_spendableFee_zeroForNonVaultAsset() public {
        address foreign = makeAddr("someOtherToken");
        assertEq(vault.spendableFee(foreign), 0, "only the vault asset is ever spendable as a fee");
    }

    /// @notice The view tracks the balance rather than caching, so a vault that
    ///         recovers float (a strategy `sweep()`, say) reports the larger
    ///         ceiling on the next read.
    function test_spendableFee_tracksBalanceChanges() public {
        usdc.mint(address(vault), 40e6);
        assertEq(vault.spendableFee(address(usdc)), 40e6);

        usdc.mint(address(vault), 60e6);
        assertEq(vault.spendableFee(address(usdc)), 100e6, "must re-read, not cache");
    }

    /// @notice The direction that matters for the bug: whenever the requested
    ///         fee exceeds the ceiling, the ceiling is what is bookable. Pinned
    ///         as an explicit inequality so the relationship `_payFee` relies on
    ///         is stated in a test rather than only in a comment.
    function test_spendableFee_boundsAnOversizedFeeRequest() public {
        usdc.mint(address(vault), 179e6); // the surviving float from the audit trace
        uint256 chargedByFormula = 3_288e6; // what the fee formula produced

        uint256 bookable = vault.spendableFee(address(usdc));
        assertLt(bookable, chargedByFormula, "the trace's premise: the charge outruns the assets");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(ISyndicateVault.AmountExceedsBalance.selector);
        vault.transferPerformanceFee(address(usdc), recipient, chargedByFormula);

        // The capped amount is payable, which is what makes the escrow
        // discharge-able instead of a permanent unbacked claim.
        vm.prank(MOCK_GOVERNOR);
        vault.transferPerformanceFee(address(usdc), recipient, bookable);
        assertEq(usdc.balanceOf(recipient), bookable);
    }
}
