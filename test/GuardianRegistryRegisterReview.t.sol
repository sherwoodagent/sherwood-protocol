// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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

    /// @notice `initialize` must reject a `reviewPeriod` below the deployment
    ///         floor, the same bound `setReviewPeriod` enforces.
    /// @dev Regression: `reviewPeriod == 0` used to be accepted here. The
    ///      governor then skips `registerReview` (the window collapses to
    ///      `reviewEnd == voteEnd`), so the registry never learns the proposal
    ///      exists, `outcomeOf` answers Unresolved forever, and the proposal —
    ///      plus the vault it binds — can never terminate: execute, settle,
    ///      cancel, veto and emergency-cancel all revert, `openProposalCount`
    ///      stays pinned, and the owner's bond is locked. Only a beacon upgrade
    ///      recovers it. The floor turns that silent brick into a loud deploy
    ///      revert; `ProposalLifecycle._afterVote` handles the collapsed window
    ///      as defence in depth for a stub registry.
    function test_initialize_revertsOnReviewPeriodBelowFloor() public {
        GuardianRegistry impl = new GuardianRegistry(6 hours); // minReviewPeriod
        bytes memory badInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), 0, 3000));
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), badInit);

        // Just under the floor is rejected too — not only the zero sentinel.
        bytes memory nearMiss =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), 6 hours - 1, 3000));
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), nearMiss);

        // At the floor it succeeds.
        bytes memory okInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), 6 hours, 3000));
        GuardianRegistry ok = GuardianRegistry(address(new ERC1967Proxy(address(impl), okInit)));
        assertEq(ok.reviewPeriod(), 6 hours);
    }

    function test_addGovernor_recordsVault() public {
        address gov2 = address(0xCAFE);
        address vault2 = address(0xFA11);
        vm.prank(regFactory);
        registry.addGovernor(gov2, vault2);
        assertEq(registry.vaultOf(gov2), vault2);
    }
}
