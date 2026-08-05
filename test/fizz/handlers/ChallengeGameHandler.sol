// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {IChallengeGame} from "../../../src/interfaces/IChallengeGame.sol";

/// @notice Handles the interaction with ChallengeGame
abstract contract ChallengeGameHandler is Properties {
    // ―――――――――――――――――― Challenge economics (GL-51) ―――――――――――――――――
    // Three of the four inputs to `honestFilingNetPayoffBps` (the fourth,
    // `proposerBondBps`, lives on ExposureLedger). Without these the property
    // is vacuous: it would re-check one fixed deploy configuration forever.
    // The harness is the games's owner, so no prank is needed.
    //
    // Each is clamped to its OWN setter's bounds, deliberately not to the
    // break-even condition — the whole question GL-51 asks is whether a
    // configuration the setters accept can drive the payoff negative, so
    // clamping to keep it non-negative would assume the answer.

    function challengeGame_setChallengerBondBps(uint256 bps) public {
        // Zero is rejected by the setter (it would make the coverage freeze
        // free), hence a floor of 1 rather than 0.
        game.setChallengerBondBps(clampBetween(bps, 1, 10_000));
    }

    function challengeGame_setSettleBurnBps(uint256 bps) public {
        game.setSettleBurnBps(clampBetween(bps, 0, 5_000)); // MAX_SETTLE_BURN_BPS
    }

    function challengeGame_setProsecutorFeeBps(uint256 bps) public {
        game.setProsecutorFeeBps(clampBetween(bps, 0, game.MAX_PROSECUTOR_FEE_BPS()));
    }

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @dev `challengeId` is 1-indexed and `challengeCount` is the high-water
    ///      mark. Clamping into `[1, count]` is what makes these reach a real
    ///      challenge instead of bouncing off `WrongStatus`.
    function challengeGame_claimContribution_clamped(uint256 challengeId) public {
        uint256 count = game.challengeCount();
        if (count == 0) return;
        challengeId = clampBetween(challengeId, 1, count);
        challengeGame_claimContribution(challengeId);
    }

    function challengeGame_dispute_clamped(uint256 challengeId, uint256 amountWood) public {
        uint256 count = game.challengeCount();
        if (count == 0) return;
        challengeId = clampBetween(challengeId, 1, count);

        // Bound by what the actor holds AND by what the pool still needs: an
        // over-target contribution is refused, and a balance-exceeding one
        // reverts in the transfer rather than in the game.
        uint256 bal = wood.balanceOf(actor);
        if (bal == 0) return;
        IChallengeGame.Challenge memory c = game.challengeOf(challengeId);
        uint256 remaining = c.bondWood > c.counterBondWood ? c.bondWood - c.counterBondWood : 0;
        if (remaining == 0) return;
        amountWood = clampBetween(amountWood, 1, remaining < bal ? remaining : bal);

        challengeGame_dispute(challengeId, amountWood);
    }

    /// @dev The pool-completing contribution is the transition that flips
    ///      `Filed → Disputed` and auto-refers to the court (I-38). Under the
    ///      generic clamp above the fuzzer would rarely land on it exactly.
    function challengeGame_dispute_completePool(uint256 challengeId) public {
        uint256 count = game.challengeCount();
        if (count == 0) return;
        challengeId = clampBetween(challengeId, 1, count);

        IChallengeGame.Challenge memory c = game.challengeOf(challengeId);
        uint256 remaining = c.bondWood > c.counterBondWood ? c.bondWood - c.counterBondWood : 0;
        if (remaining == 0 || wood.balanceOf(actor) < remaining) return;

        challengeGame_dispute(challengeId, remaining);
    }

    function challengeGame_file_clamped(uint256 proposalId, uint8 predicate, string memory evidenceURI) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        proposalId = clampBetween(proposalId, 1, count);
        // Only one governor exists in this harness; an arbitrary address would
        // revert before any challenge mechanics ran.
        challengeGame_file(address(governor), proposalId, uint8(predicate % 3), address(0), bytes4(0), evidenceURI);
    }

    function challengeGame_resolve_clamped(uint256 challengeId) public {
        uint256 count = game.challengeCount();
        if (count == 0) return;
        challengeId = clampBetween(challengeId, 1, count);
        challengeGame_resolve(challengeId);
    }

    /// @dev Secondary tier. Every rate is bounded to its own setter's legal
    ///      range so the dispatcher spends its budget inside the reachable
    ///      parameter space rather than on `InvalidParameter` reverts — the
    ///      point is to perturb E-4's economics, not to re-test the bounds.
    function challengeGame_secondary(uint8 selector, uint256 arg0) public {
        selector = uint8(selector % 8);
        if (selector == 0) _challengeGame_setAutoSlashDelay(clampBetween(arg0, 1 hours, game.disputeTimeout() - 1));
        else if (selector == 1) _challengeGame_setChallengerBondBps(clampBetween(arg0, 1, 10_000));
        else if (selector == 2) _challengeGame_setDisputeTimeout(clampBetween(arg0, game.autoSlashDelay() + 1, 90 days));
        else if (selector == 3) _challengeGame_setFilingsPaused(arg0 % 2 == 0);
        else if (selector == 4) _challengeGame_setForfeitBurnBps(clampBetween(arg0, 0, 10_000));
        else if (selector == 5) _challengeGame_setInconclusiveBurnBps(clampBetween(arg0, 0, 10_000));
        else if (selector == 6) _challengeGame_setProsecutorFeeBps(clampBetween(arg0, 0, 2_000));
        else _challengeGame_setSettleBurnBps(clampBetween(arg0, 0, 10_000));
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function challengeGame_claimContribution(uint256 challengeId) public asActor {
        game.claimContribution(challengeId);
    }

    function challengeGame_dispute(uint256 challengeId, uint256 amountWood) public asActor {
        game.dispute(challengeId, amountWood);
    }

    function challengeGame_file(
        address governor_,
        uint256 proposalId,
        uint8 predicate,
        address adapterTarget,
        bytes4 adapterSelector,
        string memory evidenceURI
    ) public asActor {
        game.file(
            governor_, proposalId, IChallengeGame.Predicate(predicate), adapterTarget, adapterSelector, evidenceURI
        );
    }

    function challengeGame_resolve(uint256 challengeId) public asActor {
        game.resolve(challengeId);
    }

    // ── Secondary (owner-gated; dispatcher-only entry) ──

    function _challengeGame_setAutoSlashDelay(uint256 newDelay) internal asAdmin {
        game.setAutoSlashDelay(newDelay);
    }

    function _challengeGame_setChallengerBondBps(uint256 newBps) internal asAdmin {
        game.setChallengerBondBps(newBps);
    }

    function _challengeGame_setDisputeTimeout(uint256 newTimeout) internal asAdmin {
        game.setDisputeTimeout(newTimeout);
    }

    function _challengeGame_setFilingsPaused(bool paused) internal asAdmin {
        game.setFilingsPaused(paused);
    }

    function _challengeGame_setForfeitBurnBps(uint256 newBps) internal asAdmin {
        game.setForfeitBurnBps(newBps);
    }

    function _challengeGame_setInconclusiveBurnBps(uint256 newBps) internal asAdmin {
        game.setInconclusiveBurnBps(newBps);
    }

    function _challengeGame_setProsecutorFeeBps(uint256 newBps) internal asAdmin {
        game.setProsecutorFeeBps(newBps);
    }

    function _challengeGame_setSettleBurnBps(uint256 newBps) internal asAdmin {
        game.setSettleBurnBps(newBps);
    }
}
