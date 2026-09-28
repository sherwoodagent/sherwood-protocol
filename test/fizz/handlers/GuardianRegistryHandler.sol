// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {IGuardianRegistry} from "../../../src/interfaces/IGuardianRegistry.sol";

/// @notice Handles the interaction with GuardianRegistry
abstract contract GuardianRegistryHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @dev Only one governor is registered; an arbitrary address reverts at
    ///      `UnauthorizedGovernor` before any review mechanics run.
    function guardianRegistry_openReview_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        guardianRegistry_openReview(address(governor), clampBetween(proposalId, 1, count));
    }

    function guardianRegistry_resolveReview_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        guardianRegistry_resolveReview(address(governor), clampBetween(proposalId, 1, count));
    }

    function guardianRegistry_resolveEmergencyReview_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        guardianRegistry_resolveEmergencyReview(address(governor), clampBetween(proposalId, 1, count));
    }

    /// @dev Emergency block votes only carry weight from an active guardian.
    function guardianRegistry_voteBlockEmergencySettle_clamped(uint256 proposalId, uint256 guardianSeed) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        actor = toGuardian(guardianSeed);
        guardianRegistry_voteBlockEmergencySettle(address(governor), clampBetween(proposalId, 1, count));
    }

    /// @dev The approve side of this call books USD coverage against the
    ///      guardian's stake (I-5, X-8) and the block side releases it — the
    ///      single highest-signal action in the guardian subsystem. Routed
    ///      through a real guardian so the ballot has non-zero weight.
    function guardianRegistry_voteOnProposal_clamped(uint256 proposalId, uint256 guardianSeed, uint8 support) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        actor = toGuardian(guardianSeed);
        // GuardianVoteType.None (0) is rejected outright — clamp onto
        // {Approve = 1, Block = 2}, the two votes that actually move coverage.
        guardianRegistry_voteOnProposal(address(governor), clampBetween(proposalId, 1, count), uint8(support % 2) + 1);
    }

    function guardianRegistry_secondary(uint8 selector, uint256 arg0, address arg1) public {
        selector = uint8(selector % 6);
        if (selector == 0) {
            uint256 bal = wood.balanceOf(admin);
            if (bal == 0) return;
            _guardianRegistry_fundSlashAppealReserve(clampBetween(arg0, 1, bal));
        } else if (selector == 1) {
            _guardianRegistry_pause();
        } else if (selector == 2) {
            uint256 reserve = registry.slashAppealReserve();
            if (reserve == 0) return;
            _guardianRegistry_refundSlash(toActor(arg1), clampBetween(arg0, 1, reserve));
        } else if (selector == 3) {
            _guardianRegistry_setBlockQuorumBps(clampBetween(arg0, 1_000, 10_000));
        } else if (selector == 4) {
            // X-1 / X-4: the review period must stay under both the ledger's
            // challenge window minus the execution window, and the cooldown.
            _guardianRegistry_setReviewPeriod(clampBetween(arg0, 1 minutes, 3 days));
        } else {
            _guardianRegistry_unpause();
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function guardianRegistry_openReview(address governor_, uint256 proposalId) public asActor {
        registry.openReview(governor_, proposalId);
    }

    function guardianRegistry_resolveEmergencyReview(address governor_, uint256 proposalId) public asActor {
        registry.resolveEmergencyReview(governor_, proposalId);
    }

    function guardianRegistry_resolveReview(address governor_, uint256 proposalId) public asActor {
        registry.resolveReview(governor_, proposalId);
    }

    function guardianRegistry_voteBlockEmergencySettle(address governor_, uint256 proposalId) public asActor {
        registry.voteBlockEmergencySettle(governor_, proposalId);
    }

    function guardianRegistry_voteOnProposal(address governor_, uint256 proposalId, uint8 support) public asActor {
        registry.voteOnProposal(governor_, proposalId, IGuardianRegistry.GuardianVoteType(support), type(uint256).max);
    }

    // ── Secondary (owner-gated; dispatcher-only entry) ──

    function _guardianRegistry_fundSlashAppealReserve(uint256 amount) internal asAdmin {
        wood.approve(address(registry), amount);
        registry.fundSlashAppealReserve(amount);
    }

    function _guardianRegistry_pause() internal asAdmin {
        registry.pause();
    }

    function _guardianRegistry_refundSlash(address recipient, uint256 amount) internal asAdmin {
        registry.refundSlash(recipient, amount);
    }

    function _guardianRegistry_setBlockQuorumBps(uint256 v) internal asAdmin {
        registry.setBlockQuorumBps(v);
    }

    function _guardianRegistry_setReviewPeriod(uint256 v) internal asAdmin {
        registry.setReviewPeriod(v);
    }

    /// @dev Deliberately NOT `asAdmin`: after `DEADMAN_UNPAUSE_DELAY` this is
    ///      permissionless, and that branch is the one worth exercising.
    function _guardianRegistry_unpause() internal asActor {
        registry.unpause();
    }
}
