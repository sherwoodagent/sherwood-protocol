// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";

/// @notice Regression tests for audit issue #181:
///
///         FINDING #8 (HIGH) — `openReview` (and `openEmergency`) read the
///         block-quorum DENOMINATOR as a bare `sw.getPastTotalVotes(ts1)`
///         with no lookback floor. `StakedWood.stakeAsGuardian` has no
///         cap/allowlist gate, so an attacker can park a large, never-voting
///         stake immediately before `openReview` to inflate the denominator
///         and push the absolute vote weight an honest cohort must clear to
///         block a proposal out of reach. The fix takes the lookback-min
///         `TokenCourt._participationFloor` already uses (`FLOOR_LOOKBACK`),
///         so stake younger than 30 days cannot move the denominator.
///
///         FINDING #25 (confidence 72) — `EmergencyReview.nonce` is a
///         `uint8` bumped unchecked at BOTH `openEmergency` and
///         `cancelEmergency` (+2 per cycle) over
///         `_emergencyBlockVotes[eKey][nonce][guardian]`, which is never
///         cleared. After 128 governor-driven open/cancel cycles the nonce
///         wraps back onto a round whose block-vote flags still stand, and
///         every guardian who blocked that earlier round is permanently
///         refused with `AlreadyVoted` on the new round, even though they
///         never voted in it. The fix replaces the wrap-prone `nonce` key
///         with a `uint256 round` that is bumped the same way but can never
///         recur in practice.
contract GuardianRegistry_quorumDenominatorTest is RegistryTestHarness {
    uint256 internal constant PROPOSAL_ID = 1;
    uint256 internal constant REVIEW_PERIOD = 24 hours;
    uint256 internal constant BLOCK_QUORUM_BPS = 2000; // 20%

    address internal honestBlocker = address(0xB10C4);
    address internal honestSilent = address(0x51E17);
    address internal attacker = address(0xA77AC4);

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, BLOCK_QUORUM_BPS);
    }

    // ── Finding #8 ──

    /// @notice A fresh, never-voting stake parked immediately before
    ///         `openReview` must NOT raise the block-quorum denominator: the
    ///         honest cohort's genuine 40% block vote must still clear a 20%
    ///         quorum measured against the honest-only base, not against a
    ///         base inflated by an attacker's same-block stake.
    ///
    ///         Numbers mirror the audit finding: honest cohort E =
    ///         1_000_000e18 (400_000e18 blocker + 600_000e18 silent),
    ///         blockQuorumBps = 2000. Baseline (no attack):
    ///           400_000e18 * 10_000 = 4e9 >= 2000 * 1_000_000e18 = 2e9  -> BLOCKED
    ///         Attack (pre-fix): attacker stakes 1_100_000e18 just before
    ///         `openReview`, inflating the live total to 2_100_000e18:
    ///           400_000e18 * 10_000 = 4e9  <  2000 * 2_100_000e18 = 4.2e9 -> NOT BLOCKED
    ///         Fixed code takes `min(total(ts1), total(ts1 - 30 days))`. The
    ///         attacker's stake is younger than 30 days at `ts1`, so the
    ///         lookback read excludes it and the denominator stays at the
    ///         honest-only 1_000_000e18 — restoring the baseline BLOCKED
    ///         outcome. Against the OLD (unfixed) code, this test fails
    ///         because `ReviewOpened` fires with `totalStakeAtOpen ==
    ///         2_100_000e18` (not `1_000_000e18`) and `resolveReview` returns
    ///         `false` (not `true`).
    function test_openReview_freshStakeCannotInflateBlockQuorumDenominator() public {
        // Honest cohort stakes now.
        _stakeGuardian(honestBlocker, 400_000e18, 1);
        _stakeGuardian(honestSilent, 600_000e18, 2);

        // Mature the honest cohort past BOTH `maturationPeriod` (so their
        // block vote weight reads at full par) and `FLOOR_LOOKBACK` (so the
        // lookback-min read at `ts1 - 30 days` still sees their full stake) —
        // both are 30 days in this harness, so a 31-day warp clears both.
        vm.warp(vm.getBlockTimestamp() + 31 days);

        uint256 voteEnd = vm.getBlockTimestamp();
        _registerReview(PROPOSAL_ID, voteEnd, voteEnd + REVIEW_PERIOD);

        // Attacker parks a fresh, never-voting stake in the SAME block as
        // registration -- large enough to flip the outcome if it counted
        // toward the denominator.
        _stakeGuardian(attacker, 1_100_000e18, 3);

        // ToB C-1 pattern (see other GuardianRegistry review tests): warp 1s
        // so `openReview`'s `ts1 = now - 1` checkpoint read sees the
        // just-written checkpoints (honest AND attacker).
        vm.warp(vm.getBlockTimestamp() + 1);

        // The at-open denominator must be the honest-only lookback-min
        // (1_000_000e18), never the attacker-inflated live total
        // (2_100_000e18). `ReviewOpened` carries `totalStakeAtOpen` directly.
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ReviewOpened(PROPOSAL_ID, 1_000_000e18);
        registry.openReview(address(governor), PROPOSAL_ID);

        // Honest cohort casts its genuine 40% block vote.
        vm.prank(honestBlocker);
        registry.voteOnProposal(
            address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block, type(uint256).max
        );

        vm.warp(voteEnd + REVIEW_PERIOD);
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ReviewResolved(address(governor), PROPOSAL_ID, true, 0);
        bool blocked = registry.resolveReview(address(governor), PROPOSAL_ID);
        assertTrue(
            blocked, "honest 40% block-side must clear a 20% quorum measured against the honest-only 1_000_000e18 base"
        );
    }

    // ── Finding #25 ──

    /// @notice The emergency block-vote round key must never recur, even
    ///         after many governor-driven open/cancel cycles. Runs 128 full
    ///         open+cancel cycles on the SAME (governor, proposalId) key
    ///         (256 total legacy-nonce increments -- the exact wrap point for
    ///         a `uint8` bumped twice per cycle) with a guardian block-voting
    ///         on the very first cycle, then opens a 129th round and has the
    ///         SAME guardian block-vote again.
    ///
    ///         Against the OLD code, the 129th open's `nonce` wraps back to
    ///         `1` -- the exact value used during cycle 1 -- so the
    ///         guardian's fresh vote in round 129 hits the STALE
    ///         `_emergencyBlockVotes[eKey][1][guardian] == true` flag from
    ///         cycle 1 and reverts `AlreadyVoted`, even though the guardian
    ///         never voted in round 129. Against the fixed code, `round` is
    ///         bumped the same way but never recurs, so the vote succeeds.
    function test_voteBlockEmergencySettle_roundCannotWrapOntoAUsedRound() public {
        uint256 wrapCycles = 128;
        _stakeGuardian(honestBlocker, 10_000e18, 1);
        // A silent majority, so the single block vote below does NOT itself
        // reach quorum. Without it `cancelEmergency` refuses in cycle 1: with
        // the cold-start waiver removed, a lone blocker in a lone-guardian
        // cohort is 100% of the electorate and the owner may not cancel out
        // from under a met quorum. That gate is the point of `cancelEmergency`;
        // this test is about the ROUND KEY never recurring, so the fixture is
        // sized to leave the gate open rather than to fight it. This suite runs
        // a 20% quorum (not the 30% default), so 10k of 100k is 10% — clear of
        // it with margin.
        _stakeGuardian(honestSilent, 90_000e18, 2);
        // Mature past maturationPeriod so the guardian's vote weight is
        // stable (full par) for both the cycle-1 vote and the cycle-129 vote.
        vm.warp(vm.getBlockTimestamp() + 31 days);

        BatchExecutorLib.Call[] memory emptyCalls = new BatchExecutorLib.Call[](0);
        bytes32 emptyHash = keccak256(abi.encode(emptyCalls));

        for (uint256 i = 0; i < wrapCycles; i++) {
            vm.prank(address(governor));
            registry.openEmergency(PROPOSAL_ID, emptyHash, emptyCalls);

            if (i == 0) {
                // Cycle 1: the guardian blocks. Pre-fix this stakes the stale
                // flag at legacy-nonce key 1; post-fix at round key 1.
                vm.prank(honestBlocker);
                registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
            }

            vm.prank(address(governor));
            registry.cancelEmergency(PROPOSAL_ID);

            // `cancelEmergency` repurposes `reviewEnd` as the post-cancel
            // cooldown deadline; the next `openEmergency` on this key
            // requires `block.timestamp >= reviewEnd`.
            vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        }

        // Round 129. Pre-fix, the legacy nonce has wrapped exactly back to
        // the value used in cycle 1 (256 increments from 0, then +1 = 1).
        vm.prank(address(governor));
        registry.openEmergency(PROPOSAL_ID, emptyHash, emptyCalls);

        // The guardian never voted in round 129 and must be able to block
        // again. Asserted via the emitted event: a stale `AlreadyVoted`
        // revert (the pre-fix bug) means this event never fires.
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.EmergencyBlockVoteCast(address(governor), PROPOSAL_ID, honestBlocker, 10_000e18);
        vm.prank(honestBlocker);
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
    }
}
