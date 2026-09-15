// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with TokenCourt
abstract contract TokenCourtHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function tokenCourt_finalize_clamped(uint256 caseId) public {
        uint256 count = court.caseCount();
        if (count == 0) return;
        caseId = clampBetween(caseId, 1, count);
        tokenCourt_finalize(caseId);
    }

    /// @dev `refer` is normally auto-triggered by `dispute` completing the
    ///      counter-bond pool; exposing it directly lets the fuzzer reach the
    ///      race where that auto-refer was swallowed by its try/catch.
    function tokenCourt_refer_clamped(uint256 challengeId) public {
        uint256 count = game.challengeCount();
        if (count == 0) return;
        challengeId = clampBetween(challengeId, 1, count);
        tokenCourt_refer(challengeId);
    }

    function tokenCourt_vote_clamped(uint256 caseId, bool guilty) public {
        uint256 count = court.caseCount();
        if (count == 0) return;
        caseId = clampBetween(caseId, 1, count);
        tokenCourt_vote(caseId, guilty);
    }

    /// @dev Guardians are the electorate that actually carries weight — an
    ///      unstaked actor's ballot is zero-weight and never moves a tally.
    ///      This variant guarantees the vote comes from a staked guardian.
    function tokenCourt_vote_asGuardian(uint256 caseId, uint256 guardianSeed, bool guilty) public {
        uint256 count = court.caseCount();
        if (count == 0) return;
        caseId = clampBetween(caseId, 1, count);
        actor = toGuardian(guardianSeed);
        tokenCourt_vote(caseId, guilty);
    }

    /// @dev X-3 requires `participationFloorBps < ageFloorBps` strictly. The
    ///      upper clamp keeps the dispatcher inside the legal range so it
    ///      perturbs I-20's floor rather than bouncing off the invariant guard.
    function tokenCourt_secondary(uint8 selector, uint256 arg0) public {
        selector = uint8(selector % 2);
        if (selector == 0) {
            uint256 ageFloor = swood.ageFloorBps();
            if (ageFloor <= 1) return;
            _tokenCourt_setParticipationFloorBps(clampBetween(arg0, 1, ageFloor - 1));
        } else {
            _tokenCourt_setVoteWindow(clampBetween(arg0, 1 hours, 14 days));
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function tokenCourt_finalize(uint256 caseId) public asActor {
        court.finalize(caseId);
    }

    function tokenCourt_refer(uint256 challengeId) public asActor {
        court.refer(challengeId);
    }

    function tokenCourt_vote(uint256 caseId, bool guilty) public asActor {
        court.vote(caseId, guilty);
    }

    // ── Secondary (owner-gated; dispatcher-only entry) ──

    function _tokenCourt_setParticipationFloorBps(uint256 newBps) internal asAdmin {
        court.setParticipationFloorBps(newBps);
    }

    function _tokenCourt_setVoteWindow(uint256 newWindow) internal asAdmin {
        court.setVoteWindow(newWindow);
    }
}
