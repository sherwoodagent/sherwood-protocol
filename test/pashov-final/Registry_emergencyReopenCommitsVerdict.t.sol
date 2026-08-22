// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GuardianRegistryEmergencyTest} from "../GuardianRegistry.t.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";

/// @title GuardianRegistry — re-opening an emergency must not erase its verdict
/// @notice `openEmergency`'s re-open guard asks only "is a window still
///         running?" (`_effNow < er.reviewEnd`). It never asks "was the last
///         round settled?" — and those are different facts, because the ONLY
///         path that commits a Blocked verdict and its `slashOwnerBond`
///         (`resolveEmergencyReview` -> `_resolveEmergency`) is itself gated on
///         `_effNow >= er.reviewEnd`.
///
///         Both predicates therefore flip at the SAME instant. The entire
///         deterrent was a same-block race whose timestamp the vault owner knows
///         in advance: re-open at exactly `reviewEnd` and the record is reset —
///         `blockStakeWeight` to 0, `resolved` to false, `round` bumped, which
///         also voids every cast block vote since `_emergencyBlockVotes` is
///         round-keyed. The owner keeps its bond and retries indefinitely.
///
///         What that buys is not cosmetic: `finalizeEmergencySettle` runs
///         OWNER-SUPPLIED calldata with EMPTY per-call caps — `StakedWood.
///         requiredOwnerBond` names it — so the bond is the only thing pricing
///         the attempt.
contract PashovFinalEmergencyReopenTest is GuardianRegistryEmergencyTest {
    /// @notice THE PIN. A blocked round that has run its clock is committed by
    ///         the re-open itself, so the owner pays before it may try again.
    function test_openEmergency_atReviewEndCommitsTheBlockedVerdict() public {
        uint64 reviewEnd_ = _openEmergency();

        // 2 blockers = 20_000e18 = 40% of the 50_000e18 snapshot >= 30% quorum.
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
        vm.prank(_guardian(1));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        uint256 stakeBefore = swood.ownerStake(address(vault));
        assertGt(stakeBefore, 0, "fixture posted no owner bond, the slash could not show");

        // The exact instant both predicates flip. Pre-fix this call sailed
        // through and wiped the verdict; the owner never paid.
        vm.warp(reviewEnd_);
        vm.prank(address(governor));
        registry.openEmergency(PROPOSAL_ID, _emptyCallsHash(), _emptyCalls());

        assertLt(
            swood.ownerStake(address(vault)),
            stakeBefore,
            "the elapsed round's Blocked verdict must be committed before its record is reused"
        );
    }

    /// @notice The re-open still SUCCEEDS — this is a "pay, then proceed" gate,
    ///         not a lockout. The owner's escape hatch must stay reachable, or a
    ///         guardian cohort could strand a genuinely stuck proposal by
    ///         blocking once.
    function test_openEmergency_reopenStillProceedsAfterCommitting() public {
        uint64 reviewEnd_ = _openEmergency();
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
        vm.prank(_guardian(1));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        vm.warp(reviewEnd_);
        vm.prank(address(governor));
        registry.openEmergency(PROPOSAL_ID, _emptyCallsHash(), _emptyCalls());

        // A fresh window is open, and the previous round's block votes do NOT
        // carry into it — guardians must re-state their objection, which is the
        // pre-existing round-keyed design, not something this fix changes.
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
    }

    /// @notice An UNBLOCKED round that simply expired carries no penalty, so the
    ///         re-open must leave the owner's bond alone. Without this the fix
    ///         could be "slash on every re-open", which would punish the honest
    ///         path where guardians never objected.
    function test_openEmergency_reopenAfterUnblockedRoundDoesNotSlash() public {
        uint64 reviewEnd_ = _openEmergency();

        // One blocker only: 10_000e18 = 20% < 30% quorum → not blocked.
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        uint256 stakeBefore = swood.ownerStake(address(vault));

        vm.warp(reviewEnd_);
        vm.prank(address(governor));
        registry.openEmergency(PROPOSAL_ID, _emptyCallsHash(), _emptyCalls());

        assertEq(swood.ownerStake(address(vault)), stakeBefore, "a below-quorum round is not a Blocked verdict");
    }

    /// @notice A first open — no prior record at all — must not attempt to
    ///         resolve anything. `er.callsHash == 0` is the sentinel, and this
    ///         pins that the guard short-circuits on it rather than reverting or
    ///         slashing against an empty record.
    function test_openEmergency_firstOpenIsUnaffected() public {
        uint256 stakeBefore = swood.ownerStake(address(vault));
        _openEmergency();
        assertEq(swood.ownerStake(address(vault)), stakeBefore, "nothing to commit on a first open");
    }

    /// @notice Re-opening while the window is genuinely still running stays
    ///         refused — the fix adds a commit step, it does not relax the
    ///         original guard.
    function test_openEmergency_stillRefusedWhileWindowRunning() public {
        uint64 reviewEnd_ = _openEmergency();
        vm.warp(reviewEnd_ - 1);
        vm.prank(address(governor));
        vm.expectRevert(IGuardianRegistry.EmergencyAlreadyOpen.selector);
        registry.openEmergency(PROPOSAL_ID, _emptyCallsHash(), _emptyCalls());
    }
}
