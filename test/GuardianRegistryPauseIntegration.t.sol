// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";

/// @title GuardianRegistryPauseIntegration.t
/// @notice Task 27.C — cross-cutting pause behavior: deadman unpause after
///         7 days is open to anyone; review voting is frozen while staking
///         paths (now on sWOOD, which has no pause) remain open — exit stays
///         unobstructed during an incident.
///
///         Post-split (Task 7.1): migrated onto `RegistryTestHarness`. The
///         registry's pause only gates review voting + reward claims; guardian
///         staking lives in `StakedWood` which has no pause mechanism, so the
///         "stake still works while registry paused" assertions exercise sWOOD
///         directly.
contract GuardianRegistryPauseIntegrationTest is RegistryTestHarness {
    address public guardian = makeAddr("guardian");
    address public stranger = makeAddr("stranger");

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 7 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 42;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, 3000);
    }

    // ──────────────────────────────────────────────────────────────
    // Deadman unpause — anyone can unpause after DEADMAN_UNPAUSE_DELAY
    // ──────────────────────────────────────────────────────────────

    /// @notice Full flow: owner pauses, 7 days + 1 second elapses, any EOA
    ///         unpauses permissionlessly. Emits `Unpaused(_, deadman=true)`.
    function test_pause_deadman_7days_thenAnyoneUnpauses() public {
        vm.prank(regOwner);
        registry.pause();
        assertTrue(registry.paused(), "registry paused");
        uint256 pausedAt = registry.pausedAt();
        assertGt(pausedAt, 0, "pausedAt stamped");

        vm.warp(pausedAt + registry.DEADMAN_UNPAUSE_DELAY() + 1);

        vm.expectEmit(true, false, false, true, address(registry));
        emit IGuardianRegistry.Unpaused(stranger, true);
        vm.prank(stranger);
        registry.unpause();

        assertFalse(registry.paused(), "paused cleared after deadman unpause");
        assertEq(registry.pausedAt(), 0, "pausedAt reset");
    }

    /// @notice Negative control: 1 second before the deadman window elapses,
    ///         a random EOA unpause still reverts.
    function test_pause_deadman_6days23h59m59s_strangerReverts() public {
        vm.prank(regOwner);
        registry.pause();

        vm.warp(vm.getBlockTimestamp() + registry.DEADMAN_UNPAUSE_DELAY() - 1);

        vm.prank(stranger);
        vm.expectRevert(IGuardianRegistry.NotPausedOrDeadmanNotElapsed.selector);
        registry.unpause();
    }

    function test_pause_whenAlreadyPaused_reverts() public {
        vm.prank(regOwner);
        registry.pause();
        uint64 firstPausedAt = registry.pausedAt();

        vm.warp(vm.getBlockTimestamp() + 6 days);

        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.AlreadyPaused.selector);
        registry.pause();

        assertEq(registry.pausedAt(), firstPausedAt, "deadman timer not reset");
    }

    // ──────────────────────────────────────────────────────────────
    // Pause freezes review voting but NOT sWOOD staking paths
    // ──────────────────────────────────────────────────────────────

    /// @notice While the registry is paused, `voteOnProposal` reverts with
    ///         `ProtocolPaused`, but sWOOD `stakeAsGuardian`,
    ///         `requestUnstakeGuardian`, and `claimUnstakeGuardian` all succeed
    ///         — sWOOD has no pause so guardian exit/management stay open
    ///         during a registry incident.
    function test_pause_freezesVoteOnProposal_butNotStakeOrUnstake() public {
        // Stake the guardian (50k total) so openReview meets cohort floor.
        _stakeGuardian(guardian, MIN_GUARDIAN_STAKE + 40_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 voteEnd = vm.getBlockTimestamp();
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;
        governor.setProposal(PROPOSAL_ID, voteEnd, reviewEnd);
        registry.openReview(address(governor), PROPOSAL_ID);

        // Pause the registry.
        vm.prank(regOwner);
        registry.pause();
        assertTrue(registry.paused());

        // voteOnProposal frozen.
        vm.prank(guardian);
        vm.expectRevert(IGuardianRegistry.ProtocolPaused.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        // A new guardian can still stake via sWOOD during the registry pause.
        address guardian2 = makeAddr("guardian2");
        _stakeGuardian(guardian2, MIN_GUARDIAN_STAKE, 2);
        assertEq(swood.guardianStake(guardian2), MIN_GUARDIAN_STAKE, "stake succeeds while registry paused");

        // requestUnstake works during the registry pause.
        vm.prank(guardian);
        swood.requestUnstakeGuardian();
        assertFalse(swood.isActiveGuardian(guardian), "unstake request clears active flag");

        // Cooldown elapses, claimUnstake still succeeds during the pause.
        vm.warp(vm.getBlockTimestamp() + COOL_DOWN + 1);
        uint256 balBefore = wood.balanceOf(guardian);
        vm.prank(guardian);
        swood.claimUnstakeGuardian();
        assertGt(wood.balanceOf(guardian) - balBefore, 0, "claimUnstake returns WOOD while registry paused");
        assertEq(swood.guardianStake(guardian), 0, "stake cleared post-claim");
    }
}
