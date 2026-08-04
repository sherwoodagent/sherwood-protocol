// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TokenCourt} from "src/TokenCourt.sol";
import {ITokenCourt} from "src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {MockStakedWood} from "test/mocks/MockStakedWood.sol";

/// @dev Self-contained, minimal `IChallengeGame` stand-in for this file only
///      (mirrors `test/audit-181/TokenCourt_floorAndProsecutor.t.sol`'s own
///      mock, deliberately NOT shared, so this file compiles and reads in
///      isolation and stays entirely inside the files this agent owns).
contract MockGameForFloorCollapseTest {
    mapping(uint256 => IChallengeGame.Challenge) internal _challenges;
    address public exposureLedger;
    uint256 public autoSlashDelay = 7 days;
    uint256 public disputeTimeout = 30 days;
    uint256 public constant MIN_REFERRAL_SLACK = 1 hours;
    bool public ruled;
    uint256 public lastRuledChallenge;
    IChallengeGame.Verdict public lastVerdict;

    function setExposureLedger(address l) external {
        exposureLedger = l;
    }

    function setChallenge(
        uint256 id,
        address governor,
        uint256 proposalId,
        address challenger,
        IChallengeGame.Status status,
        uint256 filedAt,
        uint256 disputeTimeoutAtFiling,
        uint256 executedAt
    ) external {
        IChallengeGame.Challenge storage c = _challenges[id];
        c.governor = governor;
        c.proposalId = proposalId;
        c.challenger = challenger;
        c.status = status;
        c.filedAt = filedAt;
        c.disputeTimeoutAtFiling = disputeTimeoutAtFiling;
        c.executedAt = executedAt;
    }

    function challengeOf(uint256 id) external view returns (IChallengeGame.Challenge memory) {
        return _challenges[id];
    }

    function rule(uint256 challengeId, IChallengeGame.Verdict verdict) external {
        ruled = true;
        lastRuledChallenge = challengeId;
        lastVerdict = verdict;
    }
}

/// @dev Minimal `IExposureLedger` stand-in — `refer`'s `_recordAccused` only
///      ever calls `pledgedOf`.
contract MockLedgerForFloorCollapseTest {
    address[] internal _approvers;
    uint256[] internal _pledged;

    function setApprovers(address[] memory a, uint256[] memory pledgedUsd) external {
        _approvers = a;
        _pledged = pledgedUsd;
    }

    function pledgedOf(address, uint256) external view returns (address[] memory, uint256[] memory) {
        return (_approvers, _pledged);
    }
}

/// @title  TokenCourt_floorCollapse
/// @notice Regression coverage for audit-2 finding #10 on `TokenCourt`: the
///         finding-#6 remediation subtracted `accusedWeightAtLookback` from
///         `earlier` to get `earlierReduced`, and gated the bootstrap
///         fallback on `earlierReduced == 0` EXACTLY. `accusedWeightAtLookback
///         <= earlier` always holds (subset-sum), so an exact-zero
///         `earlierReduced` really does mean "the accused consumed the whole
///         lookback electorate" — but a merely TINY NONZERO `earlierReduced`
///         (one unrelated guardian holding 1 wei at the lookback instant
///         while the accused otherwise dominated it) sails past that test,
///         wins the pre-fix `min(earlierReduced, reduced)` whenever
///         `earlierReduced < reduced` (essentially always, since `reduced` is
///         today's full honest electorate), and then gets rounded to a
///         floor of LITERAL ZERO by `participationFloorBps * base /
///         BPS_DENOMINATOR`'s integer division — regardless of how large the
///         honest, unaccused electorate actually present at `snapshotTs` is.
///         A zero floor lets a single voter's nonzero turnout decide a
///         `Guilty`/`NotGuilty` verdict on its own, which on this contract
///         means a single pre-positioned voter can burn an honest accused
///         guardian's entire bond (see `TokenCourt`'s contract-level docs on
///         why convictions here are a PROFIT question, not just a fairness
///         one).
///
///         THE FIX: a NONZERO `earlierReduced` is floored at
///         `MIN_LOOKBACK_BASE_BPS` (10%) of the same-instant `reduced` before
///         it is allowed to win the min, so the lookback term can still LOWER
///         the base (finding #6's anti-inflation purpose) but can never drag
///         it down to a value with no relation to today's electorate. The
///         exact-zero fallback (true bootstrap, or the accused genuinely
///         consuming the entire lookback electorate) is UNCHANGED and still
///         returns the unclamped `reduced` — this file also pins that, so a
///         future edit cannot "fix" finding #10 by accidentally tightening
///         bootstrap instead.
contract TokenCourt_floorCollapseTest is Test {
    TokenCourt internal court;
    MockGameForFloorCollapseTest internal game;
    MockLedgerForFloorCollapseTest internal ledger;
    MockStakedWood internal swood;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");

    function setUp() public {
        vm.warp(400 days); // clear of genesis so every snapshotTs - FLOOR_LOOKBACK is well above zero
        court = new TokenCourt(owner);
        game = new MockGameForFloorCollapseTest();
        ledger = new MockLedgerForFloorCollapseTest();
        swood = new MockStakedWood();
        game.setExposureLedger(address(ledger));
        vm.prank(owner);
        court.setChallengeGame(address(game));
        vm.prank(owner);
        court.setStakedWood(address(swood));
    }

    /// @dev Mirrors `TokenCourt_floorAndProsecutor.t.sol`'s own `_openCase`
    ///      helper (kept local to this file, not imported, for the same
    ///      isolation reason as the mocks above).
    function _openCase(
        uint256 challengeId,
        address challenger,
        address accused,
        uint256 accusedStakeNow,
        uint256 accusedStakeThen,
        uint256 totalNow,
        uint256 totalThen
    ) internal returns (uint256 caseId, uint256 snap, uint256 lookbackTs) {
        uint256 filedAt = vm.getBlockTimestamp();
        uint256 executedAt = vm.getBlockTimestamp() - 1 days;
        game.setChallenge(
            challengeId, governor, challengeId, challenger, IChallengeGame.Status.Disputed, filedAt, 30 days, executedAt
        );

        address[] memory a = new address[](1);
        uint256[] memory pledgedUsd = new uint256[](1);
        a[0] = accused;
        pledgedUsd[0] = 100e18;
        ledger.setApprovers(a, pledgedUsd);

        snap = executedAt - 1;
        lookbackTs = snap - court.FLOOR_LOOKBACK();

        swood.setPastStake(accused, snap, accusedStakeNow);
        swood.setPastStake(accused, lookbackTs, accusedStakeThen);
        swood.setPastTotalVotes(snap, totalNow);
        swood.setPastTotalVotes(lookbackTs, totalThen);

        caseId = court.refer(challengeId);
    }

    /// @dev Finalizes and returns (verdict, floor) read off `CaseFinalized` —
    ///      the floor is not stored on `Case`, so recomputing it in the test
    ///      would just restate the implementation rather than pin its output.
    function _finalizeAndRead(uint256 caseId) internal returns (IChallengeGame.Verdict verdict, uint256 floor) {
        vm.recordLogs();
        court.finalize(caseId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(court)) continue;
            if (logs[i].topics[0] != ITokenCourt.CaseFinalized.selector) continue;
            if (uint256(logs[i].topics[1]) != caseId) continue;
            uint8 v;
            uint256 f;
            (v,,, f) = abi.decode(logs[i].data, (uint8, uint256, uint256, uint256));
            return (IChallengeGame.Verdict(v), f);
        }
        revert("CaseFinalized was not emitted for this case");
    }

    /// @notice THE CORE FINDING #10 REPRO: the accused dominate the lookback
    ///         electorate down to a 1-wei residual (an unrelated guardian's
    ///         dust stake) while a real 5,000,000e18 honest electorate stands
    ///         present TODAY. Pre-fix this collapses the floor to literal
    ///         zero and lets a single 1-wei-weight voter alone produce a
    ///         binding `Guilty` verdict; post-fix the floor is a meaningful
    ///         fraction of today's honest electorate and that same
    ///         dust-weight voter cannot decide the case alone.
    ///
    ///         Numbers: accusedWeight(snapshotTs) = 1,000,000e18,
    ///         total(snapshotTs) = 6,000,000e18 -> reduced = 5,000,000e18.
    ///         accusedWeightAtLookback = 999,999e18,
    ///         earlier = 999,999e18 + 1 wei -> earlierReduced = 1 (nonzero,
    ///         so the exact-zero fallback does NOT fire).
    ///
    ///         PRE-FIX: base = min(1, 5,000,000e18) = 1 ->
    ///         floor = 1_000 * 1 / 10_000 = 0 (rounds down). ANY nonzero
    ///         turnout would have cleared it.
    ///         POST-FIX: minBase = earlier * 1_000 / 10_000 =
    ///         (999,999e18 + 1) / 10 = 99,999.9e18 ->
    ///         flooredEarlierReduced = 99,999.9e18 -> base =
    ///         min(99,999.9e18, 5,000,000e18) = 99,999.9e18 ->
    ///         floor = 1_000 * 99,999.9e18 / 10_000 = 9,999.99e18.
    ///
    ///         THE CLAMP'S BASIS IS `earlier`, NOT `reduced`. An earlier
    ///         revision of the finding #10 fix clamped against `reduced`
    ///         (today's unaccused electorate), which would put this floor at
    ///         50,000e18 instead. That basis is wrong and this test was
    ///         originally written against it: `reduced` is measured at
    ///         `snapshotTs`, so it is exactly the term finding #6's attacker
    ///         inflates with fresh never-approving stake, and a clamp
    ///         proportional to it hands that attacker a bounded lever to
    ///         RAISE the conviction bar. See
    ///         `test_participationFloor_clampBasisIsTheLookbackInstantNotTheSnapshot`
    ///         in `test/audit-181/TokenCourt_floorAndProsecutor.t.sol` for
    ///         the worked exploit, and `TokenCourt`'s finding #10 @dev block
    ///         for the argument. The lower absolute floor here is the
    ///         intended conservatism: the bar stays anchored to a
    ///         month-old reading that nobody can move today.
    ///
    ///         What finding #10 actually requires is unchanged and still
    ///         asserted below — the floor is no longer ZERO, so a lone
    ///         dust-weight voter cannot decide the case.
    function test_participationFloor_tinyNonzeroLookbackResidualNoLongerCollapsesFloorToZero() public {
        uint256 accusedStakeNow = 1_000_000e18;
        uint256 totalNow = 6_000_000e18; // reduced = 5,000,000e18
        uint256 accusedStakeThen = 999_999e18;
        uint256 totalThen = accusedStakeThen + 1; // earlierReduced = 1 wei, NOT zero

        // ── Sub-case A: a single dust-weight (1 wei) voter alone. Pre-fix
        //    this alone would have cleared a floor of 0 and produced a
        //    binding Guilty verdict on its own vote. ──
        (uint256 caseIdDustOnly, uint256 snapA,) = _openCase(
            1, makeAddr("challengerA"), makeAddr("accusedA"), accusedStakeNow, accusedStakeThen, totalNow, totalThen
        );

        address dustVoter = makeAddr("dustVoter");
        swood.setPastVotes(dustVoter, snapA, 1);
        swood.setPastStake(dustVoter, snapA, 1);
        swood.setPastStake(dustVoter, snapA - court.FLOOR_LOOKBACK(), 1); // steady stake: growth-gated min does not additionally clamp this voter
        vm.prank(dustVoter);
        court.vote(caseIdDustOnly, true);

        vm.warp(vm.getBlockTimestamp() + 5 days + 1 days); // past voteWindow + FINALIZE_BUFFER
        (IChallengeGame.Verdict verdictDustOnly, uint256 floorDustOnly) = _finalizeAndRead(caseIdDustOnly);

        // `earlier / 100` exactly: (999,999e18 + 1) / 10 for the clamp, then
        // * 1_000 / 10_000 for the floor, truncating at each step.
        uint256 expectedFloor = 9_999_990_000_000_000_000_000;
        assertEq(floorDustOnly, expectedFloor, "floor must be a meaningful fraction of the lookback electorate, not 0");
        assertEq(
            uint256(verdictDustOnly),
            uint256(IChallengeGame.Verdict.Inconclusive),
            "a single 1-wei-weight voter must NOT be able to decide the case on its own (finding #10)"
        );

        // ── Sub-case B: identical accused/lookback shape, fresh case, but an
        //    honest voter turns out with weight exactly at the fixed floor.
        //    Proves the floor is reachable, not merely nonzero — the fix
        //    must not make convictions impossible either. ──
        vm.warp(vm.getBlockTimestamp() + 100 days); // fresh checkpoint range, no collision with case A
        (uint256 caseIdHonestTurnout, uint256 snapB,) = _openCase(
            2, makeAddr("challengerB"), makeAddr("accusedB"), accusedStakeNow, accusedStakeThen, totalNow, totalThen
        );

        // Weight EXACTLY at the floor, so this still proves the floor is
        // reachable rather than merely nonzero.
        address honestVoter = makeAddr("honestVoterFloorCollapse");
        swood.setPastVotes(honestVoter, snapB, expectedFloor);
        swood.setPastStake(honestVoter, snapB, expectedFloor);
        swood.setPastStake(honestVoter, snapB - court.FLOOR_LOOKBACK(), expectedFloor);
        vm.prank(honestVoter);
        court.vote(caseIdHonestTurnout, true);

        vm.warp(vm.getBlockTimestamp() + 5 days + 1 days);
        (IChallengeGame.Verdict verdictHonestTurnout, uint256 floorHonestTurnout) =
            _finalizeAndRead(caseIdHonestTurnout);

        assertEq(floorHonestTurnout, expectedFloor, "floor is deterministic off the same accused/lookback shape");
        assertEq(
            uint256(verdictHonestTurnout),
            uint256(IChallengeGame.Verdict.Guilty),
            "turnout AT the (now-meaningful) floor must still be able to convict"
        );
    }

    /// @notice GENUINE BOOTSTRAP MUST STAY UNCHANGED: when `earlier == 0`
    ///         (nobody, accused or not, had any stake yet at `lookbackTs`),
    ///         `earlierReduced` is a STRUCTURAL zero, not an attacker-shaped
    ///         near-zero, and the exact-zero fallback must keep returning the
    ///         UNCLAMPED `reduced` — exactly the pre-finding-#10 behaviour.
    ///         If this regressed to the `MIN_LOOKBACK_BASE_BPS`-clamped value
    ///         instead, a young protocol's floor would be LOWER than before
    ///         (easier, not impossible, to convict) — the opposite failure
    ///         from what finding #10 is about, but still a behaviour change
    ///         this test exists to catch.
    function test_participationFloor_genuineBootstrapFallsBackToUnclampedReduced() public {
        uint256 accusedStakeNow = 900_000e18;
        uint256 totalNow = 1_000_000e18; // reduced = 100,000e18
        // Nobody existed yet at the lookback instant: both `earlier` and
        // `accusedWeightAtLookback` are the mock's default zero.
        uint256 accusedStakeThen = 0;
        uint256 totalThen = 0;

        (uint256 caseId,,) = _openCase(
            10,
            makeAddr("challengerBootstrap"),
            makeAddr("accusedBootstrap"),
            accusedStakeNow,
            accusedStakeThen,
            totalNow,
            totalThen
        );
        assertEq(court.caseOf(caseId).accusedWeightAtLookback, 0, "genuine bootstrap: nobody staked yet at lookbackTs");

        vm.warp(vm.getBlockTimestamp() + 5 days + 1 days);
        (, uint256 floor) = _finalizeAndRead(caseId);

        // Unclamped fallback: floor = participationFloorBps * reduced / BPS_DENOMINATOR
        // = 1_000 * 100_000e18 / 10_000 = 10_000e18 — the FULL 10% of the
        // same-instant unaccused electorate, NOT the 10%-of-10% a
        // MIN_LOOKBACK_BASE_BPS clamp would produce if wrongly applied here.
        assertEq(
            floor,
            10_000e18,
            "true bootstrap must fall back to the unclamped same-instant reduced, not a clamped fraction of it"
        );
    }

    /// @notice THE OTHER STRUCTURAL ZERO MUST ALSO STAY UNCHANGED: the
    ///         accused genuinely consumed the ENTIRE lookback electorate
    ///         (`accusedWeightAtLookback >= earlier > 0`), a real, honest
    ///         zero (not attacker-plantable, since it requires the accused to
    ///         hold literally everything that existed at that instant) — the
    ///         fallback must still return the unclamped `reduced`.
    function test_participationFloor_accusedConsumedEntireLookbackElectorateFallsBackToUnclampedReduced() public {
        uint256 accusedStakeNow = 900_000e18;
        uint256 totalNow = 1_000_000e18; // reduced = 100,000e18
        uint256 accusedStakeThen = 500_000e18;
        uint256 totalThen = 500_000e18; // earlier == accusedWeightAtLookback exactly -> earlierReduced == 0

        (uint256 caseId,,) = _openCase(
            11,
            makeAddr("challengerConsumed"),
            makeAddr("accusedConsumed"),
            accusedStakeNow,
            accusedStakeThen,
            totalNow,
            totalThen
        );
        assertEq(court.caseOf(caseId).accusedWeightAtLookback, 500_000e18);

        vm.warp(vm.getBlockTimestamp() + 5 days + 1 days);
        (, uint256 floor) = _finalizeAndRead(caseId);

        assertEq(
            floor, 10_000e18, "accused-consumed-the-whole-lookback-electorate must also fall back to unclamped reduced"
        );
    }

    /// @notice A MEANINGFULLY-SIZED (not tiny) `earlierReduced` that sits
    ///         BETWEEN the `MIN_LOOKBACK_BASE_BPS` floor and `reduced` must
    ///         keep binding the min EXACTLY as before finding #10 — the fix
    ///         must not over-clamp ordinary, legitimate lookback readings
    ///         that were never the problem.
    function test_participationFloor_meaningfulLookbackTermStillBindsUnclamped() public {
        uint256 accusedStakeNow = 1_000_000e18;
        uint256 totalNow = 6_000_000e18; // reduced = 5,000,000e18; minBase = 500,000e18
        uint256 accusedStakeThen = 100_000e18;
        uint256 totalThen = 2_100_000e18; // earlierReduced = 2,000,000e18: above minBase, below reduced

        (uint256 caseId,,) = _openCase(
            12,
            makeAddr("challengerMid"),
            makeAddr("accusedMid"),
            accusedStakeNow,
            accusedStakeThen,
            totalNow,
            totalThen
        );

        vm.warp(vm.getBlockTimestamp() + 5 days + 1 days);
        (, uint256 floor) = _finalizeAndRead(caseId);

        // base = min(2,000,000e18, 5,000,000e18) = 2,000,000e18 (the clamp
        // never engages: earlierReduced already exceeds minBase) ->
        // floor = 1_000 * 2,000,000e18 / 10_000 = 200,000e18.
        assertEq(
            floor,
            200_000e18,
            "a meaningfully-sized lookback term must bind the min unclamped, exactly as before finding #10"
        );
    }
}
