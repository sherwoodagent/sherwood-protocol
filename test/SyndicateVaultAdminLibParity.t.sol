// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {SyndicateVaultAdminLib} from "../src/SyndicateVaultAdminLib.sol";

/// @title SyndicateVaultAdminLibParityTest
/// @notice Pins the hand-synced mirror constants between the vault and its
///         delegatecall admin library. The library duplicates the values
///         ("kept in sync by hand" — SyndicateVaultAdminLib.sol) because it
///         must compile standalone; this test turns silent drift into a
///         `forge test` failure (this repo has no CI workflows — the guard
///         fires on any manual run) instead of a behavioral divergence between the vault's
///         advertised caps and the library's enforced ones. Same hazard
///         family as the LeveragedAero storage-layout lockstep.
contract SyndicateVaultAdminLibParityTest is Test {
    function test_mirrorConstants_inLockstep() public {
        SyndicateVault impl = new SyndicateVault(); // bare implementation; constructor only disables initializers
        assertEq(SyndicateVaultAdminLib.MAX_PAGE_LIMIT, impl.MAX_PAGE_LIMIT(), "MAX_PAGE_LIMIT drifted");
        assertEq(
            SyndicateVaultAdminLib.MAX_AGENTS_PER_VAULT, impl.MAX_AGENTS_PER_VAULT(), "MAX_AGENTS_PER_VAULT drifted"
        );
    }
}
