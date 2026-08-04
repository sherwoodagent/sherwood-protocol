// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TokenCourt} from "src/TokenCourt.sol";
import {ITokenCourt} from "src/interfaces/ITokenCourt.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {MockStakedWood} from "test/mocks/MockStakedWood.sol";

/// @dev Self-contained, minimal `IChallengeGame` stand-in for this file only
///      — deliberately NOT reused from `test/TokenCourt.t.sol` to keep this
///      regression test compiling and readable in isolation. Records exactly
///      what `TokenCourt.refer`/`finalize` need: a settable `Challenge`
///      (INCLUDING `challenger`, which the sibling suite's mock never had to
///      set before finding #7), the `exposureLedger` pointer, and a no-op
///      `rule` recorder.
contract MockGameForFloorTest {
    mapping(uint256 => IChallengeGame.Challenge) internal _challenges;
    address public exposureLedger;
    // Mirrors the real `ChallengeGame`'s defaults so `setChallengeGame`'s
    // window-invariant check (`autoSlashDelay + voteWindow + FINALIZE_BUFFER
    // + MIN_REFERRAL_SLACK <= disputeTimeout`) passes against the court's
    // default 5-day `voteWindow`: 7d + 5d + 1d + 1h <= 30d.
    uint256 public autoSlashDelay = 7 days;
    uint256 public disputeTimeout = 30 days;
    // MIN_REFERRAL_SLACK (issue #181 finding 20 follow-up): `setChallengeGame`
    // now reads this off the wired game too — without it here, `setUp`'s
    // `court.setChallengeGame(address(game))` reverts on a call to a
    // nonexistent selector rather than exercising the invariant this file
    // means to test.
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

/// @dev Minimal `IExposureLedger` stand-in: `refer`'s `_recordAccused` only
///      ever calls `pledgedOf`, so that is the only surface modeled.
contract MockLedgerForFloorTest {
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

/// @title  TokenCourt_floorAndProsecutor
/// @notice Regression coverage for audit #181 findings #6 and #7 on
///         `TokenCourt`.
///
///         FINDING #6: `_participationFloor` subtracted the accused cohort
///         from `total` (at `snapshotTs`) but NEVER from `earlier` (at
///         `snapshotTs - FLOOR_LOOKBACK`), so the two operands of the
///         lookback `min` were different KINDS of number. Staking large from
///         a fresh, never-approving address immediately before `snapshotTs`
///         inflates `total` (and so `reduced = total - accusedWeight`)
///         without touching `earlier` at all — which can flip the min from
///         the small, accused-reduced `reduced` term to the large, un-reduced
///         `earlier` term, inflating the floor past what the honest unaccused
///         electorate can ever reach. The fix records
///         `accusedWeightAtLookback` (the same accused set, measured at the
///         same lookback instant `earlier` is) and subtracts it from
///         `earlier` too, before the min.
///
///         FINDING #7: `vote` barred the accused (`AccusedCannotVote`) but
///         not the challenger, even though a `Guilty` verdict pays the
///         challenger the accused's bond plus the escalated pool
///         (`IChallengeGame._settle`). The fix pins `Case.challenger` at
///         `refer` (from the same `Challenge` memory struct already read for
///         `executedAt`) and bars `msg.sender == c.challenger` in `vote`.
contract TokenCourt_floorAndProsecutorTest is Test {
    TokenCourt internal court;
    MockGameForFloorTest internal game;
    MockLedgerForFloorTest internal ledger;
    MockStakedWood internal swood;

    address internal owner = makeAddr("owner");
    address internal governor = makeAddr("governor");

    function setUp() public {
        vm.warp(400 days); // clear of genesis so every `snapshotTs - FLOOR_LOOKBACK` is well above zero
        court = new TokenCourt(owner);
        game = new MockGameForFloorTest();
        ledger = new MockLedgerForFloorTest();
        swood = new MockStakedWood();
        game.setExposureLedger(address(ledger));
        vm.prank(owner);
        court.setChallengeGame(address(game));
        vm.prank(owner);
        court.setStakedWood(address(swood));
    }

    /// @dev Opens and returns a `Disputed` case for `challengeId`, filed and
    ///      executed in the current block (`executedAt = now - 1 days`, so
    ///      `snapshotTs = now - 1 days - 1`), with `accused` as the sole
    ///      accused approver holding `accusedStakeNow` at `snapshotTs` and
    ///      `accusedStakeThen` at `snapshotTs - FLOOR_LOOKBACK`. The caller
    ///      passes the two `getPastTotalVotes` checkpoints (`totalNow`,
    ///      `totalThen`) this helper writes into `swood` before calling
    ///      `refer` — `refer` reads them indirectly (through
    ///      `_recordAccused`'s `getPastStake` calls) and `finalize` reads
    ///      `getPastTotalVotes` directly later.
    function _openCase(
        uint256 challengeId,
        address challenger,
        address accused,
        uint256 accusedStakeNow,
        uint256 accusedStakeThen,
        uint256 totalNow,
        uint256 totalThen
    ) internal returns (uint256 caseId, uint256 snap, uint256 lookbackTs) {
        // `vm.getBlockTimestamp()` re-reads fresh every call; a bare
        // `block.timestamp` local here is CSE'd by this repo's optimizer
        // across the `vm.warp` calls the caller makes between `_openCase`
        // invocations, silently pinning `filedAt`/`executedAt` to a stale
        // instant (see repo Foundry gotchas — cost the sibling assertion a
        // spurious `WindowOpen()` before this fix).
        uint256 filedAt = vm.getBlockTimestamp();
        uint256 executedAt = vm.getBlockTimestamp() - 1 days;
        game.setChallenge(
            challengeId, governor, challengeId, challenger, IChallengeGame.Status.Disputed, filedAt, 30 days, executedAt
        );

        address[] memory a = new address[](1);
        uint256[] memory pledgedUsd = new uint256[](1);
        a[0] = accused;
        pledgedUsd[0] = 100e18; // nonzero pledge: `accused` is in the accused set
        ledger.setApprovers(a, pledgedUsd);

        snap = executedAt - 1;
        lookbackTs = snap - court.FLOOR_LOOKBACK();

        swood.setPastStake(accused, snap, accusedStakeNow);
        swood.setPastStake(accused, lookbackTs, accusedStakeThen);
        swood.setPastTotalVotes(snap, totalNow);
        swood.setPastTotalVotes(lookbackTs, totalThen);

        caseId = court.refer(challengeId);
    }

    /// @dev Finalizes and returns the floor `finalize` actually resolved
    ///      against, read off `CaseFinalized` — the floor is not stored on
    ///      `Case`, so recomputing it in the test would just restate the
    ///      implementation rather than pin its output.
    function _finalizeAndReadFloor(uint256 caseId) internal returns (uint256 floor) {
        vm.recordLogs();
        court.finalize(caseId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(court)) continue;
            if (logs[i].topics[0] != ITokenCourt.CaseFinalized.selector) continue;
            if (uint256(logs[i].topics[1]) != caseId) continue;
            (,,, uint256 f) = abi.decode(logs[i].data, (uint8, uint256, uint256, uint256));
            return f;
        }
        revert("CaseFinalized was not emitted for this case");
    }

    /// @notice FINDING #6, THE EXACT WORKED EXAMPLE FROM THE AUDIT: a fresh,
    ///         never-approving whale staking immediately before `snapshotTs`
    ///         must NOT raise the participation floor above what the honest
    ///         (unaccused, steady) cohort could reach on its own.
    ///
    ///         BASELINE (no attacker): accused = 900,000e18 (steady across
    ///         the lookback), total = 1,000,000e18 at both instants (honest
    ///         cohort = 100,000e18, also steady) -> `reduced` = `earlierReduced`
    ///         = 100,000e18 -> floor = 10% * 100,000e18 = 10,000e18.
    ///
    ///         ATTACK: identical accused cohort and identical `earlier`
    ///         (1,000,000e18 — the attacker's stake is absent from the
    ///         lookback checkpoint, exactly as the audit describes), but
    ///         `total` at `snapshotTs` is inflated by a fresh 1,000,000e18
    ///         stake from an address that never approved anything (not in
    ///         the ledger's approver list, so it never enters `accusedWeight`
    ///         either): total = 2,000,000e18.
    ///
    ///         PRE-FIX, this computed `reduced` = 2,000,000e18 - 900,000e18 =
    ///         1,100,000e18, `earlier` = 1,000,000e18 UNREDUCED, so
    ///         `earlier < reduced` flipped the min to the un-reduced
    ///         `earlier` term: floor = 10% * 1,000,000e18 = 100,000e18 — TEN
    ///         TIMES the baseline, and far beyond the honest cohort's
    ///         100,000e18 of reachable turnout, guaranteeing `Inconclusive`
    ///         on any abstention by even one honest voter.
    ///
    ///         POST-FIX, `accusedWeightAtLookback` = 900,000e18 (the same
    ///         accused set, same steady position, at the lookback instant)
    ///         reduces `earlier` too: `earlierReduced` = 1,000,000e18 -
    ///         900,000e18 = 100,000e18, which now correctly binds the min
    ///         (100,000e18 < 1,100,000e18) — floor = 10,000e18, IDENTICAL to
    ///         the baseline. The attacker's fresh stake buys nothing.
    ///
    ///         MUTATION-CHECKED: reverting `_participationFloor` to compare
    ///         the un-reduced `earlier` (i.e. dropping the
    ///         `accusedWeightAtLookback` subtraction) reproduces the
    ///         pre-fix 100,000e18 and fails the `attackFloor == baselineFloor`
    ///         assertion below.
    function test_participationFloor_freshNeverApprovingStakeCannotInflateFloorPastHonestCohort() public {
        // ── Baseline: no attacker ──
        (uint256 baseCaseId,,) = _openCase(
            1,
            makeAddr("challengerBaseline"),
            makeAddr("accusedBaseline"),
            900_000e18, // accusedStakeNow
            900_000e18, // accusedStakeThen (steady cohort)
            1_000_000e18, // totalNow (900k accused + 100k honest)
            1_000_000e18 // totalThen (unchanged: nothing grew over the lookback)
        );
        assertEq(court.caseOf(baseCaseId).accusedWeight, 900_000e18);
        assertEq(court.caseOf(baseCaseId).accusedWeightAtLookback, 900_000e18);

        // `vm.getBlockTimestamp()`, not `block.timestamp` — see the note in
        // `_openCase`; this is the warp `WindowOpen()` was pointing at.
        vm.warp(vm.getBlockTimestamp() + 5 days + 1 days); // past voteWindow + FINALIZE_BUFFER
        uint256 baselineFloor = _finalizeAndReadFloor(baseCaseId);
        assertEq(baselineFloor, 10_000e18, "10% of the 100,000e18 honest cohort");

        // ── Attack: same accused cohort and same `earlier`, but `total` at
        //    `snapshotTs` is inflated 1,000,000e18 by a fresh, never-approving
        //    stake absent from the lookback checkpoint ──
        vm.warp(vm.getBlockTimestamp() + 100 days); // fresh block range so this case's checkpoints don't collide with the baseline's
        (uint256 attackCaseId,,) = _openCase(
            2,
            makeAddr("challengerAttack"),
            makeAddr("accusedAttack"),
            900_000e18, // accusedStakeNow — unchanged: the attacker never approved, so it never enters accusedWeight
            900_000e18, // accusedStakeThen — unchanged: the attacker was absent a month before `snapshotTs`
            2_000_000e18, // totalNow — 900k accused + 100k honest + 1,000,000e18 attacker stake, staked immediately before executedAt
            1_000_000e18 // totalThen — IDENTICAL to the baseline's `earlier`: the attacker's stake is not present a month earlier
        );
        assertEq(
            court.caseOf(attackCaseId).accusedWeight,
            900_000e18,
            "attacker never approved, so accusedWeight is untouched"
        );
        assertEq(
            court.caseOf(attackCaseId).accusedWeightAtLookback,
            900_000e18,
            "attacker never approved, so accusedWeightAtLookback is untouched"
        );

        vm.warp(vm.getBlockTimestamp() + 5 days + 1 days);
        uint256 attackFloor = _finalizeAndReadFloor(attackCaseId);

        assertEq(
            attackFloor, baselineFloor, "a fresh, never-approving stake at snapshotTs must not move the floor at all"
        );
        assertEq(
            attackFloor,
            10_000e18,
            "must stay at the honest cohort's 10% floor, not jump to the audit's pre-fix 100,000e18"
        );
    }

    /// @notice FINDING #7: the challenge's own `challenger` must be barred
    ///         from voting on its own case — the same self-dealing hazard
    ///         `AccusedCannotVote` closes from the defendant's side. `refer`
    ///         must pin `Case.challenger` from the `Challenge` it reads for
    ///         `executedAt`, and `vote` must check it BEFORE weighing the
    ///         ballot (so the revert fires even though the challenger here is
    ///         never given any staked WOOD to vote with — the bar is on
    ///         identity, not on weight).
    function test_vote_revertsChallengerCannotVote() public {
        address challenger = makeAddr("prosecutor");
        (uint256 caseId, uint256 snap,) =
            _openCase(3, challenger, makeAddr("accusedC"), 900_000e18, 900_000e18, 1_000_000e18, 1_000_000e18);

        assertEq(
            court.caseOf(caseId).challenger, challenger, "Case.challenger must be pinned from refer's Challenge read"
        );

        vm.prank(challenger);
        vm.expectRevert(ITokenCourt.ChallengerCannotVote.selector);
        court.vote(caseId, true);

        // Sanity control: an ordinary, unaccused, non-challenger voter with
        // real snapshot weight is NOT caught by the new bar — proves this is
        // a targeted check on `c.challenger`, not a general vote() break.
        // Raw stake is set EQUAL at `snap` and `lookbackTs` (a steady,
        // non-growing position) so `vote`'s own growth-gated min (issue #82)
        // does not separately clamp this voter's weight to zero and mask the
        // assertion below.
        address honestVoter = makeAddr("honestVoter");
        uint256 lookbackTs = snap - court.FLOOR_LOOKBACK();
        swood.setPastVotes(honestVoter, snap, 50_000e18);
        swood.setPastStake(honestVoter, snap, 50_000e18);
        swood.setPastStake(honestVoter, lookbackTs, 50_000e18);
        vm.prank(honestVoter);
        court.vote(caseId, true);
        assertEq(uint256(court.voteOf(caseId, honestVoter)), uint256(ITokenCourt.Ruling.Guilty));
    }
}
