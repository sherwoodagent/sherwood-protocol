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
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
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
}
