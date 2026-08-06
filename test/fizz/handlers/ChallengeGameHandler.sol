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
        // The pool is keyed per PROPOSAL now (pashov 2026-08 finding #10), so
        // the remaining headroom comes from the pool's own target/raised rather
        // than from this challenge's stale per-challenge field.
        (, uint256 target, uint256 raised,,) = game.counterBondPoolOf(challengeId);
        uint256 remaining = target > raised ? target - raised : 0;
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
        // The pool is keyed per PROPOSAL now (pashov 2026-08 finding #10), so
        // the remaining headroom comes from the pool's own target/raised rather
        // than from this challenge's stale per-challenge field.
        (, uint256 target, uint256 raised,,) = game.counterBondPoolOf(challengeId);
        uint256 remaining = target > raised ? target - raised : 0;
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

    // ―――――――――――――――――――― Lifecycle composite ――――――――――――――――――――

    /// @notice Drives a filed challenge all the way to a conviction:
    ///         file -> dispute to pool completion -> refer -> vote -> finalize
    ///         -> rule.
    ///
    /// @dev THE POINT: every terminal path in `ChallengeGame`, `TokenCourt`,
    ///      `ProposerBondEscrow` and the slash half of `ExposureLedger` sits
    ///      behind this one chain, and random sequencing essentially never
    ///      assembles it — the calls are order-dependent, separated by two time
    ///      windows, and each has a different eligible caller. This is the same
    ///      shape of gap `syndicateGovernor_lifecycle_toExecuted` closed for
    ///      propose->execute, and the same fix.
    ///
    ///      Roles are kept disjoint on purpose, because the court bars three
    ///      groups from voting and a naive assignment silently produces an
    ///      Inconclusive verdict instead of a conviction:
    ///        - approvers are `isAccused` (`AccusedCannotVote`),
    ///        - the challenger is barred (`ChallengerCannotVote`),
    ///        - counter-bond contributors are barred
    ///          (`CounterBondContributorCannotVote`).
    ///      So the challenger and the disputer are drawn from the NON-guardian
    ///      actors, leaving the staked guardians as the voter pool. Voting is
    ///      attempted from every guardian under try/catch rather than computing
    ///      the accused set: whoever approved reverts and is skipped, which
    ///      keeps this correct no matter which guardian the governor composite
    ///      happened to use.
    ///
    ///      Court weight is sWOOD (`getPastVotes` at the case snapshot AND
    ///      `getVotes` now), not WOOD — guardians qualify only because they are
    ///      staked at setup, before any `executedAt`.
    ///
    ///      Everything is try/catch: a step that cannot fire leaves the
    ///      challenge parked in a legitimate intermediate state (Filed,
    ///      Disputed, or an Inconclusive/NotGuilty verdict), all of which are
    ///      themselves worth exploring. The handler never reverts the sequence.
    function challengeGame_lifecycle_toConviction(uint256 proposalSeed, uint256 predicateSeed) public {
        // Challenger: a non-guardian actor, so the guardian pool stays eligible
        // to vote. `_nonGuardian` wraps within the non-guardian range.
        //
        // DERIVED BEFORE the predictor and PASSED IN, not re-derived inside it.
        // `file`'s `AlreadyChallenged` gate is per (key, msg.sender), so the
        // predictor cannot answer it without knowing who is about to file, and
        // duplicating this derivation there is exactly the drift this helper's
        // own natspec is about.
        address challenger = _nonGuardian(proposalSeed);
        uint256 pid = _challengeableProposal(proposalSeed, challenger);
        if (pid == 0) return;
        uint256 idBefore = game.challengeCount();
        vm.prank(challenger);
        try game.file(
            address(governor),
            pid,
            IChallengeGame.Predicate(predicateSeed % 5),
            address(0),
            bytes4(0),
            "fizz-conviction"
        ) {}
        catch {
            return;
        }
        uint256 challengeId = game.challengeCount();
        if (challengeId == idBefore) return;

        // Fund the counter-bond to exactly its target. `Disputed` requires
        // `counterBondWood == bondWood`; a short pool leaves the challenge in
        // Filed and `refer` reverts, so partial funding is not enough.
        IChallengeGame.Challenge memory c = game.challengeOf(challengeId);
        // The pool is keyed per PROPOSAL now (pashov 2026-08 finding #10), so
        // the remaining headroom comes from the pool's own target/raised rather
        // than from this challenge's stale per-challenge field.
        (, uint256 target, uint256 raised,,) = game.counterBondPoolOf(challengeId);
        uint256 remaining = target > raised ? target - raised : 0;
        for (uint256 i; i < actors.length && remaining != 0; i++) {
            address d = _nonGuardian(i);
            if (d == challenger) continue;
            uint256 bal = wood.balanceOf(d);
            if (bal == 0) continue;
            uint256 amt = bal < remaining ? bal : remaining;
            vm.prank(d);
            try game.dispute(challengeId, amt) {
                remaining -= amt;
            } catch {}
        }
        if (remaining != 0) return; // pool never completed: stays Filed

        // `dispute` AUTO-REFERS the moment the counter-bond pool completes
        // (`ChallengeGame.sol:913`), so by here the case usually already
        // exists and an explicit `refer` would revert. Read the mapping first
        // and only refer when the auto-referral did not fire — treating refer
        // as mandatory aborts the composite on its own success.
        uint256 caseId = court.caseOfChallenge(address(game), challengeId);
        if (caseId == 0) {
            try court.refer(challengeId) returns (uint256 cid) {
                caseId = cid;
            } catch {
                return;
            }
        }
        if (caseId == 0) return;

        // Guilty needs turnout >= the participation floor AND
        // guiltyVotes > notGuiltyVotes (a tie fails safe to NotGuilty).
        uint256 voted;
        for (uint256 i; i < GUARDIAN_COUNT; i++) {
            vm.prank(actors[i]);
            try court.vote(caseId, true) {
                voted++;
            } catch {}
        }
        if (voted == 0) return; // every guardian barred: turnout 0 -> Inconclusive

        skipTime(court.voteWindow() + 1);
        // `finalize` calls back into `ChallengeGame.rule`, which is what
        // actually settles the slash and forfeits the proposer bond.
        try court.finalize(caseId) {} catch {}
    }

    /// @dev First proposal that `file` would currently accept: executed, still
    ///      inside its challenge window, and carrying coverage — the
    ///      `NothingToFreeze` guard rejects a proposal no guardian backed.
    ///      Returns 0 when none qualifies.
    ///
    ///      READS `pledgedOf`, NOT `approversOf`, because this predicts a
    ///      specific on-chain gate and must use the same accumulator that gate
    ///      does. Finding #24 (PR #217) migrated `ChallengeGame.file` from the
    ///      booking (`_recorded`, via `approversOf`) to the pledge
    ///      (`_reservedUsd`, via `pledgedOf`) — the last of five sites to move,
    ///      after `slashBpsFor`, `freezeCoverage`, `pinCoverageUntil` and
    ///      `TokenCourt._recordAccused`. That landed AFTER this helper did, so
    ///      the two silently diverged.
    ///
    ///      The divergence is one-directional and quiet, which is why it is
    ///      worth a comment rather than just a fix. GL-13 pins
    ///      `pledged >= recorded`, so a booking-based check can only ever be
    ///      too STRICT: it skips proposals `file` would accept, never picks one
    ///      `file` would reject. The failure mode is therefore lost
    ///      reachability, not a reverting handler — the composite quietly stops
    ///      finding targets and adjudication coverage decays, with nothing
    ///      failing to point at it. `settleCoverage` is permissionless,
    ///      re-runnable and not freeze-gated, and rebooking recorded down to
    ///      zero while the pledge stands is exactly the state that triggers it.
    ///
    ///      ALSO MODELS THE TWO GATES THE COMPOSITE ITSELF MANUFACTURES, which
    ///      are the same drift in the OPPOSITE and worse direction. A predictor
    ///      that is too strict `continue`s and keeps scanning; one that is too
    ///      LOOSE returns early on a proposal `file` will reject, and the
    ///      composite no-ops for that seed:
    ///
    ///        - `AlreadyConvicted`. Nothing clears the pledge on conviction —
    ///          `_reservedUsd` is deleted only by `_unwindApproval`, reached
    ///          from `releaseApproval`/`retireApproval` — so a convicted
    ///          proposal keeps passing the three checks above forever, and
    ///          `challengeGame_lifecycle_toConviction` mints one every time it
    ///          succeeds. Its hit rate would decay against its own output.
    ///
    ///        - `AlreadyChallenged`. One live challenge per challenger, and the
    ///          composite files from a `_nonGuardian` derived off the same seed.
    ///
    ///      `_convicted` HAS NO ACCESSOR, so the conviction gate is asked of
    ///      sWOOD instead. That is faithful rather than approximate: `file`'s
    ///      second gate is `_verdictAlreadyCollected`, itself
    ///      `_convicted[key] || any verdictSlashed(key, accused)`, and every
    ///      path that sets `_convicted` under this key also slashes under it —
    ///      `_settle`'s diverted branch only runs when a slash is already
    ///      recorded. Asked over the SAME accused set `file` builds (pledge
    ///      non-zero), against the SAME `keccak256(abi.encode(governor, pid))`
    ///      that `_settle` hands to `slashVerdict`.
    ///
    ///      Still not modelled, deliberately: `filingsPaused`, `WoodPriceUnset`
    ///      and `BondTooSmall`. All three are global rather than per-proposal,
    ///      so skipping a pid cannot route around them and a predictor that
    ///      consulted them would only ever return 0 — the composite's own
    ///      try/catch is the right handler for those.
    function _challengeableProposal(uint256 seed, address challenger) internal view returns (uint256) {
        uint256 count = governor.proposalCount();
        if (count == 0) return 0;
        uint256 start = seed % count;
        for (uint256 n; n < count; n++) {
            uint256 pid = ((start + n) % count) + 1;
            ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(pid);
            if (p.executedAt == 0) continue;
            if (block.timestamp > p.executedAt + p.strategyDuration + ledger.challengeWindow()) continue;
            // `AlreadyChallenged` — one live challenge per CHALLENGER, which is
            // why this needs the address rather than deriving one.
            if (game.liveChallengeOfBy(address(governor), pid, challenger) != 0) continue;

            (address[] memory approvers, uint256[] memory pledged) = ledger.pledgedOf(address(governor), pid);
            uint256 total;
            bool collected;
            bytes32 key = keccak256(abi.encode(address(governor), pid));
            for (uint256 i; i < pledged.length; i++) {
                // Zero-pledge entries are outside `file`'s accused set, so they
                // neither price the bond nor answer the conviction question.
                if (pledged[i] == 0) continue;
                total += pledged[i];
                if (swood.verdictSlashed(key, approvers[i])) collected = true;
            }
            // `NothingToFreeze` and both `AlreadyConvicted` gates, in that order.
            if (total == 0 || collected) continue;
            return pid;
        }
        return 0;
    }

    /// @dev An actor outside the guardian range, so using it as challenger or
    ///      counter-bond contributor does not burn a court voter.
    function _nonGuardian(uint256 seed) internal view returns (address) {
        uint256 span = actors.length - GUARDIAN_COUNT;
        return actors[GUARDIAN_COUNT + (seed % span)];
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
