// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with ExposureLedger
///
/// @dev This is where the campaign's highest-value invariants live. I-5 (the
///      six coverage accumulators move in lockstep) and X-8 (a guardian's
///      aggregate booked coverage never exceeds their slashable bond) are both
///      maintained purely by construction across `recordApproval`,
///      `_unwindApproval` and `_rebook`, with no on-chain assertion anywhere.
///      `recordApproval` / `releaseApproval` are registry-gated and
///      `freeze`/`unfreeze`/`pin` are freezer-gated, so the dispatcher pranks
///      those roles directly — otherwise the fuzzer could only reach them
///      through a full propose→vote lifecycle and would almost never
///      interleave them adversarially.
abstract contract ExposureLedgerHandler is Properties {
    // ―――――――――――――――――― Challenge economics (GL-51) ―――――――――――――――――
    // The fourth input to `ChallengeGame.honestFilingNetPayoffBps`. It lives
    // here rather than on the game, which is exactly why no single setter can
    // enforce the break-even condition — the invariant spans two contracts
    // with two independent owners.

    function exposureLedger_setProposerBondBps(uint256 bps) public {
        ledger.setProposerBondBps(clampBetween(bps, 0, 10_000));
    }

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function exposureLedger_retireApproval_clamped(uint256 proposalId, uint256 guardianSeed) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        exposureLedger_retireApproval(address(governor), clampBetween(proposalId, 1, count), toGuardian(guardianSeed));
    }

    function exposureLedger_settleCoverage_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        exposureLedger_settleCoverage(address(governor), clampBetween(proposalId, 1, count));
    }

    function exposureLedger_secondary(uint8 selector, uint256 arg0, uint256 arg1, uint256 guardianSeed) public {
        uint256 count = governor.proposalCount();
        uint256 proposalId = count == 0 ? 0 : clampBetween(arg0, 1, count);

        selector = uint8(selector % 12);
        if (selector == 0) {
            if (count == 0) return;
            _exposureLedger_freezeCoverage(address(governor), proposalId);
        } else if (selector == 1) {
            if (count == 0) return;
            _exposureLedger_unfreezeCoverage(address(governor), proposalId);
        } else if (selector == 2) {
            if (count == 0) return;
            _exposureLedger_pinCoverageUntil(
                address(governor), proposalId, block.timestamp + clampBetween(arg1, 1, 30 days)
            );
        } else if (selector == 3) {
            if (count == 0) return;
            _exposureLedger_recordApproval(address(governor), proposalId, toGuardian(guardianSeed));
        } else if (selector == 4) {
            if (count == 0) return;
            _exposureLedger_releaseApproval(address(governor), proposalId, toGuardian(guardianSeed));
        } else if (selector == 5) {
            // X-1: must stay >= registry.reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW.
            _exposureLedger_setChallengeWindow(clampBetween(arg1, 8 days, 30 days));
        } else if (selector == 6) {
            _exposureLedger_setCoveredTvlCapUsd(clampBetween(arg1, 1e18, 100_000_000e18));
        } else if (selector == 7) {
            _exposureLedger_setKNumerator(clampBetween(arg1, 1, 100));
        } else if (selector == 8) {
            _exposureLedger_setProposerBondBps(clampBetween(arg1, 0, 10_000));
        } else if (selector == 9) {
            _exposureLedger_setQuorumTierThreshold(uint8(arg1 % 3));
        } else if (selector == 10) {
            // I-7: bounded [MIN_WOOD_HAIRCUT_BPS, 10000].
            _exposureLedger_setWoodHaircutBps(clampBetween(arg1, 5_000, 10_000));
        } else {
            // X-7: the governance leg is rate-limited upward (2x) but
            // unbounded downward — drive both directions around the live cap.
            _exposureLedger_setWoodUsdPrice(clampBetween(arg1, 1, 1e10));
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function exposureLedger_retireApproval(address governor_, uint256 proposalId, address guardian) public asActor {
        ledger.retireApproval(governor_, proposalId, guardian);
    }

    function exposureLedger_settleCoverage(address governor_, uint256 proposalId) public asActor {
        ledger.settleCoverage(governor_, proposalId);
    }

    // ── Secondary: registry-gated ──

    function _exposureLedger_recordApproval(address governor_, uint256 proposalId, address guardian) internal {
        vm.prank(address(registry));
        ledger.recordApproval(governor_, proposalId, guardian);
    }

    function _exposureLedger_releaseApproval(address governor_, uint256 proposalId, address guardian) internal {
        vm.prank(address(registry));
        ledger.releaseApproval(governor_, proposalId, guardian);
    }

    // ── Secondary: freezer-gated (the challenge game) ──

    function _exposureLedger_freezeCoverage(address governor_, uint256 proposalId) internal {
        vm.prank(address(game));
        ledger.freezeCoverage(governor_, proposalId);
    }

    function _exposureLedger_unfreezeCoverage(address governor_, uint256 proposalId) internal {
        vm.prank(address(game));
        ledger.unfreezeCoverage(governor_, proposalId);
    }

    function _exposureLedger_pinCoverageUntil(address governor_, uint256 proposalId, uint256 deadline) internal {
        vm.prank(address(game));
        ledger.pinCoverageUntil(governor_, proposalId, deadline);
    }

    // ── Secondary: owner-gated ──

    function _exposureLedger_setChallengeWindow(uint256 newWindow) internal asAdmin {
        ledger.setChallengeWindow(newWindow);
    }

    function _exposureLedger_setCoveredTvlCapUsd(uint256 newCap) internal asAdmin {
        ledger.setCoveredTvlCapUsd(newCap);
    }

    function _exposureLedger_setKNumerator(uint256 newK) internal asAdmin {
        ledger.setKNumerator(newK);
    }

    function _exposureLedger_setProposerBondBps(uint256 newBps) internal asAdmin {
        ledger.setProposerBondBps(newBps);
    }

    function _exposureLedger_setQuorumTierThreshold(uint8 newThreshold) internal asAdmin {
        ledger.setQuorumTierThreshold(newThreshold);
    }

    function _exposureLedger_setWoodHaircutBps(uint256 newBps) internal asAdmin {
        ledger.setWoodHaircutBps(newBps);
    }

    function _exposureLedger_setWoodUsdPrice(uint256 newPriceX8) internal asAdmin {
        ledger.setWoodUsdPrice(newPriceX8);
    }
}
