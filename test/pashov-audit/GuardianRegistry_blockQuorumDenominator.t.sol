// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";

/// @title GuardianRegistry_blockQuorumDenominatorTest
/// @notice CHARACTERIZATION SUITE for pashov 2026-08 finding #1 — the
///         block-quorum denominator (`Review.totalStakeAtOpen`, written from
///         `_lookbackMinTotalVotes`'s `minTotal`).
///
///         THIS SUITE FIXES NOTHING. It exists because finding #1 has no local
///         fix, and the next reader needs the two opposing attacks pinned as
///         executable fixtures rather than as prose, so that a future "obvious"
///         patch cannot be shipped without watching the other attack turn green.
///         Same posture the repo already took on the sibling construction in
///         `TokenCourt._participationFloor` (see `test/audit-2/
///         TokenCourt_floorCollapse.t.sol` and the in-source block there).
///
///         THE TWO ATTACKS, both against `_isBlocked`
///         (`blockStakeWeight * 10_000 >= blockQuorumBps * denom`):
///
///           OVER-WEIGHTING (finding #1). A SMALL denominator makes a block
///           cheap. `minTotal` is up to `FLOOR_LOOKBACK` stale, so a guardian
///           whose own stake never moved votes full weight against a
///           30-day-old electorate. `test_overWeighting_*` reproduces the
///           audit's own numbers.
///
///           DILUTION (what `minTotal` was introduced to close). A LARGE
///           denominator makes a block impossible. `stakeAsGuardian` has no
///           cap and no allowlist, so anyone can park never-voting stake and
///           raise the absolute weight an honest cohort must clear.
///           `test_dilution_*` reproduces it.
///
///         WHY NO FUNCTION OF THE AGGREGATE TRACE SEPARATES THEM. Both attacks
///         turn on stake younger than `FLOOR_LOOKBACK`. Any denominator rule
///         computable here is a function of `getPastTotalVotes` readings, and
///         in that trace honest young stake and attacker-planted young stake
///         are THE SAME OBJECT — an attacker can reproduce any growth curve by
///         paying the matching holding time. So every rule counts young stake
///         at some weight k in [0, 1]:
///
///           k = 0  -> `minTotal`, today's rule: dilution closed, over-weighting open.
///           k = 1  -> the live total: over-weighting closed, dilution open.
///           0<k<1  -> `max(minTotal, k * totalNow)`: BOTH bounded, NEITHER closed.
///
///         `test_algebra_*` pins that "scale each voter's numerator by
///         minTotal/totalNow and keep comparing against minTotal" is not a
///         third option — it is bit-for-bit the k = 1 rule.
///         `test_blend_*` pins that the k in between really does interpolate:
///         the smallest k that defeats the over-weighting fixture also hands
///         the dilution fixture to the attacker.
///
///         The only construction that separates the two is a denominator built
///         from per-voter `min(stake(now), stake(now - FLOOR_LOOKBACK))` summed
///         over the WHOLE electorate. That is not derivable from the aggregate
///         checkpoints `StakedWood` publishes and cannot be iterated on-chain;
///         it would need new `StakedWood` accounting (a checkpointed total of
///         stake continuously present for at least `FLOOR_LOOKBACK`).
contract GuardianRegistry_blockQuorumDenominatorTest is RegistryTestHarness {
    uint256 internal constant REVIEW_PERIOD = 24 hours;
    /// @dev The audit's own quorum: 30%.
    uint256 internal constant Q = 3000;

    address internal attacker = makeAddr("staticWhaleAttacker");
    address internal honestOld = makeAddr("honestOldCohort");
    address internal honestNew = makeAddr("honestNewCohort");
    address internal diluter = makeAddr("diluter");

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, Q);
    }

    // ─────────────────────── shared fixture plumbing ───────────────────────

    /// @dev Registers, warps one second (so `openReview`'s `ts1 =
    ///      block.timestamp - 1` lands on the instant the caller just built),
    ///      and opens. Returns `reviewEnd`.
    function _registerAndOpen(uint256 pid) internal returns (uint256 reviewEnd) {
        uint256 voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        _registerReview(pid, voteEnd, reviewEnd);
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.openReview(address(governor), pid);
    }

    /// @dev The two aggregate readings `_lookbackMinTotalVotes` is built from,
    ///      taken at the same `ts1` a review opened at. Every candidate rule in
    ///      this suite is evaluated from exactly these two numbers, which is
    ///      the point: they are all the information the contract has.
    function _totalsAt(uint256 openedAt) internal view returns (uint256 totalNow, uint256 minTotal) {
        totalNow = swood.getPastTotalVotes(openedAt);
        uint256 lookbackTs = openedAt > registry.FLOOR_LOOKBACK() ? openedAt - registry.FLOOR_LOOKBACK() : 0;
        uint256 earlier = swood.getPastTotalVotes(lookbackTs);
        minTotal = (earlier != 0 && earlier < totalNow) ? earlier : totalNow;
    }

    /// @dev `_isBlocked` against an arbitrary denominator — the candidate-rule
    ///      evaluator. Mirrors the production predicate exactly, including the
    ///      `>=` edge and the bps scaling.
    function _wouldBlock(uint256 blockWeight, uint256 denom) internal pure returns (bool) {
        return blockWeight * 10_000 >= Q * denom;
    }

    // ═══════════════════ ATTACK 1 — OVER-WEIGHTING (finding #1) ═══════════════════

    /// @notice THE FINDING, with the audit's numbers. `attacker` holds
    ///         40_000e18 of a 60_000e18 cohort at t0 and never touches it. By
    ///         t0 + `FLOOR_LOOKBACK` the honest side has grown the electorate
    ///         to 600_000e18, so the attacker is 6.67% of the LIVE cohort.
    ///
    ///         `openReview` still pins `totalStakeAtOpen = min(600k, 60k) =
    ///         60k`, and `_growthGatedVoteWeight` does not clamp the attacker
    ///         (their own raw stake did not grow), so a single voter clears a
    ///         30% quorum on their own — and the same stale denominator drives
    ///         `_severityBps` to the top of the slash envelope, wiping the
    ///         honest approver.
    function test_overWeighting_staticWhaleBlocksAloneAndMaxesSeverity() public {
        _stakeGuardian(attacker, 40_000e18, 1);
        _stakeGuardian(honestOld, 20_000e18, 2);
        // t0 electorate: 60_000e18.

        vm.warp(vm.getBlockTimestamp() + 30 days);
        _stakeGuardian(honestNew, 540_000e18, 3);
        // Live electorate: 600_000e18. The attacker is now 6.67% of it.

        uint256 reviewEnd = _registerAndOpen(1);
        uint256 openedAt = vm.getBlockTimestamp() - 1;

        (uint256 totalNow, uint256 minTotal) = _totalsAt(openedAt);
        assertEq(totalNow, 600_000e18, "live electorate at ts1");
        assertEq(minTotal, 60_000e18, "denominator is the 30-day-old electorate");

        (,,, bool cohortTooSmall) = registry.getReviewState(address(governor), 1);
        assertFalse(cohortTooSmall, "the veto pipeline must actually run for this fixture to mean anything");

        // The honest approver is an OLD guardian, so it is not itself clamped —
        // this is a real approver taking real slash risk, not a strawman.
        vm.prank(honestOld);
        registry.voteOnProposal(address(governor), 1, IGuardianRegistry.GuardianVoteType.Approve);

        vm.prank(attacker);
        registry.voteOnProposal(address(governor), 1, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertTrue(
            registry.resolveReview(address(governor), 1),
            "finding #1: 6.67% of the live electorate blocks alone against a 30% quorum"
        );

        // ...and the same stale denominator sets the penalty. bBps =
        // 40_000e18 * 10_000 / 60_000e18 = 6666 under integer division — ONE
        // bps under `SUPERMAJORITY_BPS` (6667), so the audit's "reads 6,667"
        // is off by one. It does not matter: the quadratic ramp at t = 3666/3667
        // still lands within a handful of bps of `maxSlashBps`, so the honest
        // approver is wiped either way.
        assertLt(
            swood.guardianStake(honestOld),
            20_000e18 / 100,
            "the honest approver keeps under 1% of its stake -- severity is effectively maxSlashBps"
        );

        // THE COUNTERFACTUAL that makes this a finding rather than a design
        // choice: measured against the electorate that actually exists, the
        // attacker is nowhere near quorum.
        assertFalse(
            _wouldBlock(40_000e18, totalNow), "against the LIVE electorate the same vote is 667 bps, far under quorum"
        );
        assertTrue(_wouldBlock(40_000e18, minTotal), "against the stale electorate it is 6666 bps, over quorum");
    }

    // ═════════════════ ATTACK 2 — DILUTION (what minTotal closes) ═════════════════

    /// @notice The attack `minTotal` exists to defeat, and it is not
    ///         hypothetical: `stakeAsGuardian` has no cap and no allowlist, and
    ///         a diluter never votes, so it takes no slash risk at all.
    ///
    ///         Honest electorate 600_000e18, matured. An honest blocker holds
    ///         200_000e18 — 33.3%, comfortably over the 30% quorum. The diluter
    ///         parks 1_400_000e18 one block before `openReview`, taking the live
    ///         electorate to 2_000_000e18 and the honest blocker to 10%.
    ///
    ///         Today the veto survives, because fresh stake cannot lower the
    ///         `ts1 - FLOOR_LOOKBACK` reading. Against a live denominator it
    ///         does not.
    function test_dilution_freshParkedStakeCannotKillTheVetoToday() public {
        _stakeGuardian(honestOld, 200_000e18, 1); // the blocker
        _stakeGuardian(honestNew, 400_000e18, 2); // silent honest cohort

        vm.warp(vm.getBlockTimestamp() + 31 days);
        _stakeGuardian(diluter, 1_400_000e18, 3);

        uint256 reviewEnd = _registerAndOpen(2);
        uint256 openedAt = vm.getBlockTimestamp() - 1;

        (uint256 totalNow, uint256 minTotal) = _totalsAt(openedAt);
        assertEq(totalNow, 2_000_000e18, "diluted live electorate");
        assertEq(minTotal, 600_000e18, "the lookback read is untouched by two-block-old stake");

        vm.prank(honestOld);
        registry.voteOnProposal(address(governor), 2, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertTrue(
            registry.resolveReview(address(governor), 2),
            "today's rule: a genuine 33% honest blocker still vetoes through a 3.3x dilution"
        );

        // THE COUNTERFACTUAL, and the exact reason finding #1 has no local fix:
        // the rule that would have defeated attack 1 hands attack 2 to the
        // diluter.
        assertFalse(
            _wouldBlock(200_000e18, totalNow),
            "against the LIVE electorate the honest blocker falls to 1000 bps and the veto dies"
        );
        assertTrue(_wouldBlock(200_000e18, minTotal), "against the lookback-min it is 3333 bps and the veto holds");
    }

    /// @notice The diluter's cost, pinned. `minTotal` does not DEFEAT dilution,
    ///         it PRICES it at `FLOOR_LOOKBACK` of held capital: stake older
    ///         than the lookback is present in both reads, so a patient diluter
    ///         beats the current rule too. Anyone re-deriving the tradeoff needs
    ///         this number, because it is what a candidate rule has to beat.
    function test_dilution_aPatientDiluterBeatsTheLookbackMinToo() public {
        _stakeGuardian(honestOld, 200_000e18, 1);
        _stakeGuardian(honestNew, 400_000e18, 2);
        // The diluter parks BEFORE the lookback window instead of inside it.
        _stakeGuardian(diluter, 1_400_000e18, 3);

        vm.warp(vm.getBlockTimestamp() + 31 days);

        uint256 reviewEnd = _registerAndOpen(3);
        uint256 openedAt = vm.getBlockTimestamp() - 1;

        (uint256 totalNow, uint256 minTotal) = _totalsAt(openedAt);
        assertEq(totalNow, 2_000_000e18, "live electorate");
        assertEq(minTotal, 2_000_000e18, "31-day-old parked stake is in BOTH reads -- the min buys nothing");

        vm.prank(honestOld);
        registry.voteOnProposal(address(governor), 3, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertFalse(
            registry.resolveReview(address(governor), 3),
            "a diluter willing to hold for FLOOR_LOOKBACK kills the veto under the CURRENT rule"
        );
    }

    // ═══════════════ THE ALGEBRA — scaling the numerator is not a third option ═══════════════

    /// @notice "Scale each voter's weight by `minTotal / totalNow` and keep
    ///         comparing against `minTotal`" is proposed every time this finding
    ///         is re-derived. It is the LIVE-DENOMINATOR rule wearing a hat:
    ///
    ///           (w * minTotal / totalNow) * 10_000 >= Q * minTotal
    ///             <=> w * 10_000 / totalNow        >= Q
    ///             <=> w * 10_000                   >= Q * totalNow
    ///
    ///         Pinned over BOTH fixtures' numbers, including the rounding the
    ///         integer division introduces, so the identity is checked as code
    ///         and not as algebra in a comment.
    function test_algebra_scaledNumeratorAgainstMinTotalIsTheLiveDenominatorRule() public pure {
        // Parallel arrays rather than a nested literal: the over-weighting
        // fixture, the dilution fixture, an at-the-edge case with no staleness,
        // and a dust case chosen to be the worst available for the rounding the
        // scaling division introduces.
        uint256[4] memory weights = [uint256(40_000e18), 200_000e18, 30_000e18, 1e18];
        uint256[4] memory totalsNow = [uint256(600_000e18), 2_000_000e18, 100_000e18, 3e18];
        uint256[4] memory minTotals = [uint256(60_000e18), 600_000e18, 100_000e18, 2e18];

        for (uint256 i = 0; i < weights.length; i++) {
            uint256 w = weights[i];
            uint256 totalNow = totalsNow[i];
            uint256 minTotal = minTotals[i];

            uint256 scaled = w * minTotal / totalNow;
            bool scaledAgainstMin = scaled * 10_000 >= Q * minTotal;
            bool rawAgainstLive = w * 10_000 >= Q * totalNow;

            assertEq(
                scaledAgainstMin,
                rawAgainstLive,
                "scaling the numerator is the live-denominator rule, not a third option"
            );
        }
    }

    // ═══════════════ THE BLEND — bounds both, defeats neither ═══════════════

    /// @notice `denom = max(minTotal, k * totalNow)` is the only genuinely
    ///         different shape available from the two readings, and it does
    ///         exactly what the k-interpolation says: the smallest k that
    ///         defeats the over-weighting fixture is already large enough to
    ///         hand the dilution fixture to the attacker.
    ///
    ///         Over-weighting fixture: attacker 40_000e18, totalNow 600_000e18,
    ///         minTotal 60_000e18. Defeated once `Q * k * totalNow > 40_000e18`,
    ///         i.e. `k > 2222` bps.
    ///
    ///         Dilution fixture: honest blocker 200_000e18, totalNow
    ///         2_000_000e18, minTotal 600_000e18. Survives only while
    ///         `Q * k * totalNow <= 200_000e18`, i.e. `k <= 3333` bps.
    ///
    ///         The two constraints overlap in [2223, 3333] bps ONLY for these
    ///         two specific fixtures. That window is an artifact of the numbers
    ///         chosen, not a safe setting: it closes entirely as soon as either
    ///         attacker scales their position, which the loop below pins by
    ///         re-running the dilution fixture with a diluter twice as large.
    function test_blend_noKDefeatsBothOnceEitherAttackerScales() public pure {
        uint256[6] memory ks = [uint256(0), 1000, 2500, 5000, 7500, 10_000];

        for (uint256 i = 0; i < ks.length; i++) {
            uint256 k = ks[i];

            // Over-weighting fixture.
            uint256 denomA = _blend(60_000e18, 600_000e18, k);
            bool attackerBlocks = _wouldBlock(40_000e18, denomA);

            // Dilution fixture, with the diluter at 2x the size used in
            // `test_dilution_freshParkedStakeCannotKillTheVetoToday`
            // (live electorate 3_400_000e18 instead of 2_000_000e18). Nothing
            // stops them: `stakeAsGuardian` has no cap.
            uint256 denomB = _blend(600_000e18, 3_400_000e18, k);
            bool honestStillVetoes = _wouldBlock(200_000e18, denomB);

            assertFalse(
                !attackerBlocks && honestStillVetoes,
                "no k both denies the static whale and preserves the honest veto once the diluter scales"
            );
        }
    }

    /// @notice The blend's endpoints are the two rules it interpolates — pinned
    ///         so the sweep above cannot be read as testing something exotic.
    function test_blend_endpointsAreTheTwoKnownRules() public pure {
        assertEq(_blend(60_000e18, 600_000e18, 0), 60_000e18, "k = 0 is today's lookback-min rule");
        assertEq(_blend(60_000e18, 600_000e18, 10_000), 600_000e18, "k = 10_000 is the live-total rule");
    }

    function _blend(uint256 minTotal, uint256 totalNow, uint256 kBps) internal pure returns (uint256) {
        uint256 scaled = totalNow * kBps / 10_000;
        return scaled > minTotal ? scaled : minTotal;
    }

    // ═══════════════ BASIS CHECK — numerator and denominator agree ═══════════════

    /// @notice Finding #1's premise depends on the numerator and the
    ///         denominator being the SAME measure. They are: `getPastStake`
    ///         (the numerator, via `_growthGatedVoteWeight`) and
    ///         `getPastTotalVotes` (the denominator) are both RAW, while
    ///         `getPastVotes` alone applies `_ageFactorBps`. Pinned here
    ///         because a future change that swaps the numerator back to
    ///         `getPastVotes` would silently re-scale every comparison in this
    ///         file, and the age factor reads LIVE owner-tunable slots.
    function test_basis_stakeAndTotalAreRawWhileVotesIsAgeWeighted() public {
        assertEq(swood.ageFloorBps(), 2500, "fixture precondition: a young position is discounted to 25%");

        _stakeGuardian(honestOld, 100_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 ts = vm.getBlockTimestamp() - 1;

        assertEq(swood.getPastStake(honestOld, ts), 100_000e18, "getPastStake is RAW");
        assertEq(swood.getPastTotalVotes(ts), 100_000e18, "getPastTotalVotes is RAW -- same basis as the numerator");
        assertEq(swood.getPastVotes(honestOld, ts), 25_000e18, "getPastVotes alone is age-weighted -- NOT the basis");

        // And after maturation the age-weighted read converges on the raw one,
        // which is why the mismatch is a scaling bug rather than a constant one.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 matured = vm.getBlockTimestamp() - 1;
        assertEq(swood.getPastVotes(honestOld, matured), 100_000e18, "at par the two bases coincide");
    }

    /// @notice The growth gate is what makes the over-weighting attack a
    ///         STATIC-stake attack rather than a fresh-capital one, so it is
    ///         pinned alongside the fixtures: the attacker's discount comes
    ///         from holding still, and topping up would COST them weight.
    function test_growthGate_toppingUpCostsTheAttackerWeightRatherThanBuyingIt() public {
        _stakeGuardian(attacker, 40_000e18, 1);
        _stakeGuardian(honestOld, 20_000e18, 2);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        _stakeGuardian(honestNew, 540_000e18, 3);
        // The attacker tops up, chasing a bigger numerator (`stakeAsGuardian`
        // is the top-up path; the `agentId` argument is ignored on a top-up).
        _stakeGuardian(attacker, 500_000e18, 1);

        uint256 reviewEnd = _registerAndOpen(4);

        vm.prank(honestOld);
        registry.voteOnProposal(address(governor), 4, IGuardianRegistry.GuardianVoteType.Approve);

        // The top-up made the attacker's RAW stake grow across the lookback, so
        // `_growthGatedVoteWeight` clamps them back to the 40_000e18 they held
        // 30 days ago — the top-up bought exactly nothing.
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.GuardianVoteCast(4, attacker, IGuardianRegistry.GuardianVoteType.Block, 40_000e18);
        vm.prank(attacker);
        registry.voteOnProposal(address(governor), 4, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        assertTrue(
            registry.resolveReview(address(governor), 4), "still blocked -- on the OLD 40_000e18, not the top-up"
        );
    }
}
