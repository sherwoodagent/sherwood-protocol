// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {MockRegistryMinimal} from "./MockRegistryMinimal.sol";

/// @notice Guards the mock's conformance contract: it IS an IGuardianRegistry
///         (compiler-checked via the `is` clause), its live surface keeps the
///         "no review" defaults, and every unmodeled member fails loudly with
///         `NotImplemented` instead of the silent `unrecognized function
///         selector` revert a duck-typed mock would produce.
contract MockRegistryMinimalTest is Test {
    MockRegistryMinimal internal mock;

    function setUp() public {
        mock = new MockRegistryMinimal();
    }

    function test_isIGuardianRegistry() public view {
        // Compile-time conformance: assignment to the interface type only
        // type-checks because the mock declares `is IGuardianRegistry`.
        IGuardianRegistry reg = mock;
        assertEq(reg.reviewPeriod(), 0);
    }

    function test_liveSurface_keepsNoReviewDefaults() public {
        assertFalse(mock.resolveReview(address(this), 1));
        (bool opened, bool resolved, bool blocked) = mock.getReviewState(address(this), 1);
        assertTrue(opened);
        assertTrue(resolved);
        assertFalse(blocked);
        assertFalse(mock.isEmergencyOpen(address(this), 1));

        mock.setReviewPeriod(2 days);
        assertEq(mock.reviewPeriod(), 2 days);

        mock.cancelReview(42);
        assertEq(mock.cancelReviewCallCount(), 1);
        assertEq(mock.lastCancelledProposalId(), 42);
    }

    /// @notice The OTHER permissive default, pinned like the ones above.
    ///
    /// @dev `ownerBondLive` defaults to `true` rather than reverting
    ///      `NotImplemented` (SHE-215): `SyndicateGovernor.propose` and
    ///      `executeProposal` read it on every call, so a reverting stub would
    ///      fail every governor fixture in the repo on a question none of them
    ///      is about. That default is load-bearing for a large blast radius and
    ///      was the only member of this mock's live surface with nothing
    ///      asserting it, so a silent flip to `false` would have surfaced as
    ///      dozens of unrelated `OwnerBondNotLive` failures rather than as one
    ///      failing mock test.
    ///
    ///      Both directions, because the default is only meaningful if the
    ///      setter can actually move off it — a hardcoded `return true` would
    ///      satisfy the first assertion alone, and that is precisely the shape
    ///      the gate's own fixtures depend on NOT being true.
    function test_liveSurface_ownerBondLiveDefaultsToLive() public {
        assertTrue(mock.ownerBondLive(address(this)), "the permissive default the governor fixtures rely on");
        assertTrue(mock.ownerBondLive(address(0xBEEF)), "the default is per-mock, not per-vault");

        mock.setOwnerBondLive(false);
        assertFalse(mock.ownerBondLive(address(this)), "setOwnerBondLive(false) must model the closed lane");

        mock.setOwnerBondLive(true);
        assertTrue(mock.ownerBondLive(address(this)), "and it must be reversible");
    }

    function test_stubbedFunction_revertsNotImplemented() public {
        vm.expectRevert(MockRegistryMinimal.NotImplemented.selector);
        mock.voteOnProposal(address(this), 1, IGuardianRegistry.GuardianVoteType.Approve, 0);

        vm.expectRevert(MockRegistryMinimal.NotImplemented.selector);
        mock.openReview(address(this), 1);

        vm.expectRevert(MockRegistryMinimal.NotImplemented.selector);
        mock.requiredOwnerBond(address(this));
    }
}
