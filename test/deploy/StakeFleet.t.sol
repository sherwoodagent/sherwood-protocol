// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {StakeFleet} from "../../script/robinhood-mainnet/StakeFleet.s.sol";

contract StakeFleetTest is Test {
    ERC20Mock wood;
    StakedWood swood;
    StakeFleet script;
    address safe = makeAddr("safe");
    address keyA = makeAddr("keyA");
    address keyB = makeAddr("keyB");

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: address(this),
                    wood: address(wood),
                    factory: makeAddr("factory"),
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));
        script = new StakeFleet();
        wood.mint(safe, 100_000_000e18);
    }

    function _keys() internal view returns (address[] memory k, uint256[] memory w) {
        k = new address[](2);
        w = new uint256[](2);
        (k[0], k[1]) = (keyA, keyB);
        (w[0], w[1]) = (2_000_000e18, 3_000_000e18);
    }

    /// @notice The Safe's batch then each key's own stake leaves exactly the planned split staked.
    function test_planStakesTheReserveUnderTheSafeAndFundsEachKey() public {
        (address[] memory k, uint256[] memory w) = _keys();
        StakeFleet.Call[] memory calls = script.plan(swood, safe, k, w, 60_000_000e18);
        assertEq(calls.length, 4);

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(safe);
            (bool ok,) = calls[i].target.call(calls[i].data);
            assertTrue(ok);
        }
        for (uint256 i; i < k.length; ++i) {
            vm.startPrank(k[i]);
            wood.approve(address(swood), w[i]);
            swood.stakeAsGuardian(w[i], 0);
            vm.stopPrank();
        }

        assertEq(swood.guardianStake(safe), 60_000_000e18);
        assertEq(swood.guardianStake(keyA), 2_000_000e18);
        assertEq(swood.guardianStake(keyB), 3_000_000e18);
        assertEq(swood.totalGuardianStake(), 65_000_000e18);
    }

    /// @notice A key that already staked is refused: a top-up would reset part of its 30-day clock.
    function test_refusesAKeyThatAlreadyStaked() public {
        (address[] memory k, uint256[] memory w) = _keys();
        wood.mint(keyB, 10_000e18);
        vm.startPrank(keyB);
        wood.approve(address(swood), 10_000e18);
        swood.stakeAsGuardian(10_000e18, 0);
        vm.stopPrank();
        vm.expectRevert(bytes("StakeFleet: already staked; a top-up resets the 30-day clock"));
        script.plan(swood, safe, k, w, 60_000_000e18);
    }

    /// @notice The Safe holds the reserve and must never appear as an approving key.
    function test_refusesTheSafeAsAnApprover() public {
        (address[] memory k, uint256[] memory w) = _keys();
        k[1] = safe;
        vm.expectRevert(bytes("StakeFleet: the Safe is the reserve and never approves"));
        script.plan(swood, safe, k, w, 60_000_000e18);
    }

    /// @notice A key listed twice is refused.
    function test_refusesADuplicateKey() public {
        (address[] memory k, uint256[] memory w) = _keys();
        k[1] = keyA;
        vm.expectRevert(bytes("StakeFleet: duplicate key"));
        script.plan(swood, safe, k, w, 60_000_000e18);
    }

    /// @notice An approving key under `minGuardianStake` is refused before anything moves.
    function test_refusesAKeyBelowTheMinimum() public {
        (address[] memory k, uint256[] memory w) = _keys();
        w[0] = 9_999e18;
        vm.expectRevert(bytes("StakeFleet: approving key below minGuardianStake"));
        script.plan(swood, safe, k, w, 60_000_000e18);
    }

    /// @notice A plan the Safe cannot fund is refused.
    function test_refusesAnUnfundedPlan() public {
        (address[] memory k, uint256[] memory w) = _keys();
        vm.expectRevert(bytes("StakeFleet: Safe holds too little WOOD"));
        script.plan(swood, safe, k, w, 96_000_000e18);
    }

    function test_refusesAZeroKey() public {
        address[] memory k = new address[](2);
        uint256[] memory w = new uint256[](2);
        k[0] = makeAddr("k0");
        k[1] = address(0);
        w[0] = 2_000_000e18;
        w[1] = 2_000_000e18;
        vm.expectRevert(bytes("StakeFleet: zero key"));
        script.plan(swood, safe, k, w, 60_000_000e18);
    }
}
