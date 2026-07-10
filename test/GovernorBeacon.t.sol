// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GovernorBeacon} from "../src/GovernorBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract ImplA {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract ImplB {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract GovernorBeaconTest is Test {
    GovernorBeacon beacon;
    address multisig = address(0xA11CE);
    ImplA implA;
    ImplB implB;

    function setUp() public {
        implA = new ImplA();
        implB = new ImplB();
        beacon = new GovernorBeacon(address(implA), multisig);
    }

    function test_ownerIsMultisig() public view {
        assertEq(beacon.owner(), multisig);
    }

    function test_implementationIsImplA() public view {
        assertEq(beacon.implementation(), address(implA));
    }

    function test_upgradeToUpgradesAllProxies() public {
        BeaconProxy p1 = new BeaconProxy(address(beacon), "");
        BeaconProxy p2 = new BeaconProxy(address(beacon), "");
        assertEq(ImplA(address(p1)).version(), 1);
        assertEq(ImplA(address(p2)).version(), 1);

        vm.prank(multisig);
        beacon.upgradeTo(address(implB));

        assertEq(ImplB(address(p1)).version(), 2);
        assertEq(ImplB(address(p2)).version(), 2);
    }

    function test_upgradeToOnlyOwner() public {
        vm.expectRevert();
        beacon.upgradeTo(address(implB));
    }
}
