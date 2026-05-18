// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MinimalGuardianRegistry} from "../src/MinimalGuardianRegistry.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";

/// @title MinimalGuardianRegistry unit tests
/// @notice Stub registry for beta deploys without WOOD. Verifies the read
///         surface returns the values that collapse the governor's review
///         lifecycle to a no-op (Approved-immediate), and that every
///         non-stub call reverts with `Disabled()` so a misconfig fails loud.
contract MinimalGuardianRegistryTest is Test {
    MinimalGuardianRegistry registry;

    function setUp() public {
        registry = new MinimalGuardianRegistry();
    }

    // ──────────────────────── read surface (collapses review to Approved) ────────────────────────

    function test_reviewPeriod_isZero() public view {
        assertEq(registry.reviewPeriod(), 0, "review window collapsed in beta");
    }

    function test_resolveReview_returnsNotBlocked() public view {
        assertFalse(registry.resolveReview(1));
        assertFalse(registry.resolveReview(type(uint256).max));
    }

    function test_getReviewState_preResolvedNotBlocked() public view {
        (bool opened, bool resolved, bool blocked, bool cohortTooSmall) = registry.getReviewState(1);
        assertTrue(opened, "stub reports opened so view paths skip cold-start branch");
        assertTrue(resolved, "stub reports resolved so _resolveAfterVote skips waiting");
        assertFalse(blocked, "blocked=false so vote outcome sticks");
        assertFalse(cohortTooSmall, "cohort flag clear");
    }

    function test_isEmergencyOpen_alwaysFalse() public view {
        assertFalse(registry.isEmergencyOpen(0));
        assertFalse(registry.isEmergencyOpen(42));
    }

    // ──────────────────────── governor-side no-ops ────────────────────────

    function test_openReview_isNoOp() public {
        // Should not revert; should not change any observable state.
        registry.openReview(1);
        registry.openReview(2);
        // Re-querying still returns the stub default.
        (bool opened,,,) = registry.getReviewState(1);
        assertTrue(opened);
    }

    function test_cancelReview_isNoOp() public {
        // Mirrors the openReview no-op; governor's GuardianReview-cancel path
        // calls this on the registry. Stub must accept the call without
        // reverting and without mutating state.
        registry.cancelReview(1);
        registry.cancelReview(7);
    }

    // ──────────────────────── factory-side no-ops + canCreateVault gate ────────────────────────

    function test_canCreateVault_alwaysTrue() public {
        assertTrue(registry.canCreateVault(address(0)));
        assertTrue(registry.canCreateVault(makeAddr("alice")));
    }

    function test_bindOwnerStake_isNoOp() public {
        // Factory-only in production; this stub is permissionless and a no-op.
        registry.bindOwnerStake(makeAddr("owner"), makeAddr("vault"));
    }

    function test_transferOwnerStakeSlot_isNoOp() public {
        registry.transferOwnerStakeSlot(makeAddr("vault"), makeAddr("newOwner"));
    }

    function test_hasOwnerStake_alwaysFalse() public {
        assertFalse(registry.ownerStake(makeAddr("owner")) > 0);
    }

    // ──────────────────────── disabled surface (loud reverts) ────────────────────────

    function test_openEmergency_revertsDisabled() public {
        BatchExecutorLib.Call[] memory empty = new BatchExecutorLib.Call[](0);
        vm.expectRevert(MinimalGuardianRegistry.Disabled.selector);
        registry.openEmergency(1, bytes32(0), empty);
    }

    function test_cancelEmergency_revertsDisabled() public {
        vm.expectRevert(MinimalGuardianRegistry.Disabled.selector);
        registry.cancelEmergency(1);
    }

    function test_finalizeEmergency_revertsDisabled() public {
        vm.expectRevert(MinimalGuardianRegistry.Disabled.selector);
        registry.finalizeEmergency(1);
    }

    function test_fundProposalGuardianPool_revertsDisabled() public {
        vm.expectRevert(MinimalGuardianRegistry.Disabled.selector);
        registry.fundProposalGuardianPool(1, address(0), 0);
    }

    function test_stakeAsGuardian_revertsDisabled() public {
        vm.expectRevert(MinimalGuardianRegistry.Disabled.selector);
        registry.stakeAsGuardian(0, 0);
    }

    function test_prepareOwnerStake_revertsDisabled() public {
        vm.expectRevert(MinimalGuardianRegistry.Disabled.selector);
        registry.prepareOwnerStake(0);
    }
}
