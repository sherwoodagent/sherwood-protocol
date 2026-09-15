// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @notice Age-weighted own-stake voting tests (spec §4-§5 of
///         2026-07-19-slash-cap-age-weighted-voting-design.md).
///         Own-stake weight ramps linearly from `ageFloorBps` (25%) at age 0
///         to par (100%) at `maturationPeriod` (30 days), then plateaus.
///         Totals (`getPastTotalVotes` / `getPastTotalSupply`) deliberately
///         stay raw — a conservative quorum denominator (spec Part C).
contract StakedWoodAgeWeightTest is Test {
    StakedWood swood;
    ERC20Mock wood;
    address owner = address(0xA11CE);
    address factory = address(0xFAC10);
    address alice = address(0xA11CE5);
    address bob = address(0xB0B);

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: 100e18, // allows the 100e18 test stake
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        wood.mint(alice, 100_000e18);
        vm.prank(alice);
        wood.approve(address(swood), type(uint256).max);
    }

    function test_ageWeight_floorAtStake() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        // Same-block read: age 0 → floor 25%.
        assertEq(swood.getVotes(alice), 25e18);
    }

    function test_ageWeight_linearMidpoint() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(15 days); // half maturation → 25% + 75%/2 = 62.5%
        assertEq(swood.getVotes(alice), 62.5e18);
    }

    function test_ageWeight_parAtMaturationAndBeyond() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(30 days);
        assertEq(swood.getVotes(alice), 100e18);
        skip(300 days); // plateau — never exceeds par
        assertEq(swood.getVotes(alice), 100e18);
    }

    function test_ageWeight_pastReadUsesRequestedTimestamp() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        // vm.getBlockTimestamp, not block.timestamp: the optimizer treats the
        // TIMESTAMP opcode as call-invariant and may rematerialize it AFTER
        // the skip/warp below (house pattern from StakedWood.t.sol).
        uint256 t0 = vm.getBlockTimestamp();
        skip(30 days);
        // Past read at t0 + 15d computes age from stakedAt to THAT timestamp.
        assertEq(swood.getPastVotes(alice, t0 + 15 days), 62.5e18);
    }

    function test_ageWeight_totalsStayRaw() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        // Quorum denominator is deliberately un-aged (spec Part C).
        assertEq(swood.getPastTotalVotes(block.timestamp), 100e18);
    }

    // ── stakedAt lifecycle (spec §4): top-up re-anchor + request reset ──

    /// @notice A top-up re-anchors `stakedAt` to the stake-weighted average
    ///         timestamp instead of inheriting the old tranche's full age.
    ///         100 fully matured + 300 fresh → avg stakedAt = t0 + 22.5d,
    ///         i.e. age 7.5d at top-up: factor = 2500 + 7500·7.5/30 = 4375.
    ///         Integer math is exact here: with t0 = 1, t30 = t0 + 30d the
    ///         numerator 100e18·t0 + 300e18·t30 divides 400e18 evenly.
    function test_topUp_weightedAverageAge() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(30 days); // fully matured
        vm.prank(alice);
        swood.stakeAsGuardian(300e18, 1); // top-up 3x at age 0
        assertEq(swood.getVotes(alice), 400e18 * 4375 / 10_000); // 175e18
    }

    /// @notice The dust-then-whale exploit: a minimum stake aged to full
    ///         maturity must NOT lend its age to a 10_000x top-up. The
    ///         weighted average lands ~259s before `now` (100e18·30d /
    ///         1_000_100e18), below the 345.6s-per-bps ramp granularity —
    ///         so the combined position votes at exactly the age floor.
    function test_topUp_roundsTowardNow() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1); // minGuardianStake tranche, aged
        skip(30 days);
        wood.mint(alice, 1_000_000e18);
        vm.prank(alice);
        swood.stakeAsGuardian(1_000_000e18, 1); // whale top-up at age 0
        uint256 floorW = (1_000_000e18 + 100e18) * 2500 / 10_000;
        assertEq(swood.getVotes(alice), floorW);
    }

    /// @notice `requestUnstakeGuardian` resets the age clock: a request →
    ///         cancel round-trip restarts maturation at request time (no
    ///         free age-parking while the stake is unvotable). Age at read
    ///         is 1 day (since the request), not 31 days (since stake).
    function test_requestUnstake_resetsAgeClock() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(30 days);
        vm.prank(alice);
        swood.requestUnstakeGuardian();
        skip(1 days);
        vm.prank(alice);
        swood.cancelUnstakeGuardian();
        // factor = 2500 + 7500 · 1d/30d = 2750.
        assertEq(swood.getVotes(alice), 100e18 * 2750 / 10_000); // 27.5e18
    }

    /// @notice Boundary one second before maturation: the ramp stays
    ///         strictly below par (floor division), pinning rounding.
    function test_ageWeight_oneSecondBeforeMaturation() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        uint256 age = 30 days - 1;
        skip(age);
        // factor = 2500 + (7500 × (30d − 1)) / 30d = 2500 + 7499 (floored,
        // since 7500 × 2_591_999 / 2_592_000 = 7499.997…) = 9999 bps.
        uint256 factor = 2500 + (7500 * age) / 30 days;
        assertEq(factor, 9999, "ramp strictly below par pre-maturation");
        assertEq(swood.getVotes(alice), (100e18 * factor) / 10_000); // 99.99e18
    }

    /// @notice Companion to `test_requestUnstake_resetsAgeClock` (Task 3
    ///         review): age accrues FROM the request timestamp THROUGH the
    ///         cooldown — waiting one full maturation period inside the
    ///         cooldown before cancelling returns a stake already at par.
    ///         Proves the reset re-anchors age (pre-request age forfeited) but
    ///         does NOT freeze it: the request → wait → cancel round-trip is
    ///         not penalized for the time spent on cooldown.
    function test_requestUnstake_ageAccruesThroughCooldownToPar() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(10 days); // partial maturity — forfeited by the request below
        vm.prank(alice);
        swood.requestUnstakeGuardian();

        // Wait a full maturation window WHILE on cooldown, then cancel.
        skip(30 days);
        vm.prank(alice);
        swood.cancelUnstakeGuardian();

        // Age since the request == 30 days == maturationPeriod → par, despite
        // the pre-request 10 days being dropped.
        assertEq(swood.getVotes(alice), 100e18);
    }

    // ── issue #82: anchor checkpoint exactness (the mock cannot witness this
    //    — TokenCourt.t.sol's MockStakedWood has no age-factor model at all,
    //    so only the REAL contract can prove a historical read is immune to
    //    a LATER anchor write) ──

    /// @notice A top-up strictly AFTER `ts` must not move `getPastVotes(g,
    ///         ts)` — the top-up's forward re-anchor (`stakeAsGuardian`'s
    ///         weighted-average branch) only ever pushes a NEW checkpoint at
    ///         `block.timestamp`; `upperLookupRecent(ts)` still resolves to
    ///         the anchor that existed at `ts`. Pre-#82 (live-anchor read),
    ///         this same top-up would have dragged the read toward age 0.
    function test_ageWeight_topUpAfterTsDoesNotChangePastRead() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(15 days); // age 15d -> factor 2500 + 7500*15/30 = 6250
        uint256 ts = vm.getBlockTimestamp();
        uint256 before = swood.getPastVotes(alice, ts);
        assertEq(before, 62.5e18);

        skip(1 days);
        vm.prank(alice);
        swood.stakeAsGuardian(300e18, 1); // top-up: re-anchors the LIVE stakedAt forward

        assertEq(swood.getPastVotes(alice, ts), before, "a later top-up must not change an already-past read");
    }

    /// @notice An unstake request strictly AFTER `ts` must not move
    ///         `getPastVotes(g, ts)` either — `requestUnstakeGuardian` also
    ///         re-anchors `stakedAt` (to the request instant) and zeroes the
    ///         raw checkpoint, but both writes land at `block.timestamp`, a
    ///         later instant than `ts`.
    function test_ageWeight_unstakeRequestAfterTsDoesNotChangePastRead() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(10 days); // age 10d -> factor 2500 + 7500*10/30 = 5000
        uint256 ts = vm.getBlockTimestamp();
        uint256 before = swood.getPastVotes(alice, ts);
        assertEq(before, 50e18);

        skip(5 days);
        vm.prank(alice);
        swood.requestUnstakeGuardian();

        assertEq(swood.getPastVotes(alice, ts), before, "a later unstake request must not change an already-past read");
    }

    /// @notice A read at a timestamp strictly before the guardian's first
    ///         anchor checkpoint sees an empty trace (anchor 0) — and the raw
    ///         checkpoint trace is empty there too, so the product is 0
    ///         regardless of `_ageFactorBps(0, ts) == ageFloorBps`.
    function test_ageWeight_readBeforeFirstStakeReturnsZero() public {
        uint256 tBefore = vm.getBlockTimestamp();
        skip(1 days);
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        assertEq(swood.getPastVotes(alice, tBefore), 0);
    }

    /// @notice `getVotes` (the live read, delegating to `getPastVotes` at
    ///         `block.timestamp`) is bit-identical before and after the
    ///         anchor-checkpoint change: at the CURRENT timestamp the
    ///         checkpointed anchor IS the live anchor, so this guards that
    ///         the historical-exactness fix did not perturb the live path at
    ///         all.
    function test_ageWeight_getVotesStaysBitIdenticalToLiveGetPastVotes() public {
        vm.prank(alice);
        swood.stakeAsGuardian(100e18, 1);
        skip(12 days); // factor 2500 + 7500*12/30 = 5500
        assertEq(swood.getVotes(alice), swood.getPastVotes(alice, block.timestamp));
        assertEq(swood.getVotes(alice), 100e18 * 5500 / 10_000); // 55e18
    }
}
