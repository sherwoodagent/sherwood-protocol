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

    // --- SHE-167: expose the pause-shift baseline the daemon mirrors -----------

    /// @notice The common case: a review registered while the registry is NOT
    ///         paused stamps a zero baseline, so the getter reads `0` — exactly
    ///         the value the daemon previously had to assume (SHE-57 / PR#15).
    function test_reviewClockShift_zeroWhenRegisteredNotPaused() public {
        vm.prank(address(governor));
        registry.registerReview(1, block.timestamp + 1 days, block.timestamp + 2 days);
        assertEq(registry.reviewClockShift(address(governor), 1), 0);
        // effectiveNowFor with a zero baseline and no pause is plain wall clock.
        assertEq(registry.effectiveNowFor(address(governor), 1), block.timestamp);
    }

    /// @notice A review registered MID-pause stamps the in-progress span, and the
    ///         getter surfaces exactly that non-zero value — matching
    ///         GuardianRegistry's stamping (`paused ? pauseShiftTotal + (now -
    ///         pausedAt) : pauseShiftTotal`). Cross-checks that the surfaced value
    ///         is the same baseline the contract's own `_effNow` math consumes, by
    ///         reproducing `_effNow` off-chain against `effectiveNowFor`.
    function test_reviewClockShift_stampsInProgressPauseSpan() public {
        // Pause, then let 3h of outage elapse before the governor proposes.
        vm.prank(regOwner);
        registry.pause();
        uint64 pausedAt = registry.pausedAt();
        uint256 span = 3 hours;
        vm.warp(block.timestamp + span);

        // registerReview is the one review-clock writer without `whenNotPaused`,
        // so it lands during the pause.
        vm.prank(address(governor));
        registry.registerReview(2, block.timestamp + 1 days, block.timestamp + 2 days);

        // pauseShiftTotal is still 0 (advanced only by unpause), so the stamped
        // baseline is exactly the in-progress span.
        uint64 baseline = registry.reviewClockShift(address(governor), 2);
        assertEq(baseline, uint64(block.timestamp - uint256(pausedAt)));
        assertEq(baseline, uint64(span));
        assertGt(baseline, 0);

        // Cross-check: the value the getter returns is the SAME baseline the
        // contract's lockout math (`_effNow`) uses. Reproduce `_effNow` off-chain
        // from the public fields and assert it equals the on-chain `effectiveNowFor`.
        uint256 total = uint256(registry.pauseShiftTotal())
            + (registry.paused() ? block.timestamp - uint256(registry.pausedAt()) : 0);
        uint256 expectedEffNow = block.timestamp - (total - uint256(baseline));
        assertEq(registry.effectiveNowFor(address(governor), 2), expectedEffNow);
    }

    /// @notice Unknown `(governor, proposalId)` reads `0` — mirrors
    ///         `reviewWindow`'s zero-for-unknown-key convention (no revert).
    function test_reviewClockShift_zeroForUnknownKey() public {
        assertEq(registry.reviewClockShift(address(governor), 999), 0);
        // effectiveNowFor(unknown) uses a zero baseline => wall clock (no pause).
        assertEq(registry.effectiveNowFor(address(governor), 999), block.timestamp);
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
