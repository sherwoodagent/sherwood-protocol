// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";

/// @notice Task 1 of the ProposalLifecycle refactor: the governor now PUSHES the
///         review-window timestamps + vault to the registry at propose time
///         (`registerReview` / two-arg `addGovernor`) instead of the registry
///         reading them back through `IGovernorMinimal.getProposalView`. The old
///         call-back still exists in this task (deleted in Task 2); these tests
///         cover only the new push path.
contract GuardianRegistryRegisterReviewTest is RegistryTestHarness {
    function setUp() public {
        // Wires registry + sWOOD and authorizes `governor` (the mock) via the
        // two-arg `addGovernor` from the factory.
        _deployRegistryAndSwood(24 hours, 3000);
    }

    function test_registerReview_storesWindow() public {
        vm.prank(address(governor));
        registry.registerReview(1, block.timestamp + 1 days, block.timestamp + 2 days);
        (uint64 ve, uint64 re) = registry.reviewWindow(address(governor), 1);
        assertEq(ve, block.timestamp + 1 days);
        assertEq(re, block.timestamp + 2 days);
    }

    function test_registerReview_revertsForNonGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(IGuardianRegistry.UnauthorizedGovernor.selector);
        registry.registerReview(1, block.timestamp + 1, block.timestamp + 2);
    }

    function test_registerReview_revertsOnReRegister() public {
        vm.startPrank(address(governor));
        registry.registerReview(1, block.timestamp + 1, block.timestamp + 2);
        vm.expectRevert(IGuardianRegistry.ReviewAlreadyRegistered.selector);
        registry.registerReview(1, block.timestamp + 5, block.timestamp + 6);
        vm.stopPrank();
    }

    function test_registerReview_revertsOnInvalidWindow() public {
        vm.prank(address(governor));
        vm.expectRevert(IGuardianRegistry.InvalidReviewWindow.selector);
        registry.registerReview(1, block.timestamp + 2, block.timestamp + 1);
    }

    function test_registerReview_revertsOnZeroLengthWindow() public {
        vm.prank(address(governor));
        vm.expectRevert(IGuardianRegistry.InvalidReviewWindow.selector);
        registry.registerReview(1, block.timestamp + 1, block.timestamp + 1); // reviewEnd == voteEnd
    }

    function test_addGovernor_recordsVault() public {
        address gov2 = address(0xCAFE);
        address vault2 = address(0xFA11);
        vm.prank(regFactory);
        registry.addGovernor(gov2, vault2);
        assertEq(registry.vaultOf(gov2), vault2);
    }
}
