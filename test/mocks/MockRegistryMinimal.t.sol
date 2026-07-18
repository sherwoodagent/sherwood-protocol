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
        (bool opened, bool resolved, bool blocked, bool cohortTooSmall) = mock.getReviewState(address(this), 1);
        assertTrue(opened);
        assertTrue(resolved);
        assertFalse(blocked);
        assertFalse(cohortTooSmall);
        assertFalse(mock.isEmergencyOpen(address(this), 1));

        mock.setReviewPeriod(2 days);
        assertEq(mock.reviewPeriod(), 2 days);

        mock.cancelReview(42);
        assertEq(mock.cancelReviewCallCount(), 1);
        assertEq(mock.lastCancelledProposalId(), 42);
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
