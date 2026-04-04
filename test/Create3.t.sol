// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Create3} from "../src/Create3.sol";

contract SimpleContract {
    uint256 public value;

    constructor(uint256 _value) {
        value = _value;
    }
}

/// @dev External wrapper so vm.expectRevert works with CREATE2 assembly reverts
contract Create3Wrapper {
    function deployWith(bytes32 salt, bytes memory creationCode) external returns (address) {
        return Create3.deploy(salt, creationCode);
    }
}

contract Create3Test is Test {
    function testAddressPrediction() public {
        bytes32 salt = keccak256("test.v1");

        // Predict before deploying
        address predicted = Create3.addressOf(address(this), salt);

        // Deploy
        address deployed =
            Create3.deploy(salt, abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(42))));

        assertEq(deployed, predicted);
        assertEq(SimpleContract(deployed).value(), 42);
    }

    function testDifferentArgsDoNotChangeAddress() public {
        // The address depends only on deployer + salt, NOT on constructor args
        bytes32 salt = keccak256("test.v2");

        // Predict (doesn't know constructor args)
        address predicted = Create3.addressOf(address(this), salt);

        // Deploy with specific args — address should match prediction regardless
        address deployed =
            Create3.deploy(salt, abi.encodePacked(type(SimpleContract).creationCode, abi.encode(uint256(999))));

        assertEq(deployed, predicted);
        assertEq(SimpleContract(deployed).value(), 999);
    }

    function testDifferentSaltsProduceDifferentAddresses() public {
        address addr1 = Create3.addressOf(address(this), keccak256("salt.a"));
        address addr2 = Create3.addressOf(address(this), keccak256("salt.b"));
        assertTrue(addr1 != addr2);
    }

    function testSameSaltSameDeployerSameAddress() public {
        // Same deployer + same salt = same predicted address (cross-chain guarantee)
        address deployer = address(0xDEAD);
        bytes32 salt = keccak256("sherwood.wood.v1");

        address addr1 = Create3.addressOf(deployer, salt);
        address addr2 = Create3.addressOf(deployer, salt);
        assertEq(addr1, addr2);
    }

    function testCannotReuseSalt() public {
        // Deploy via wrapper first time
        Create3Wrapper wrapper = new Create3Wrapper();
        wrapper.deployWith(keccak256("test.dup"), abi.encodePacked(type(SimpleContract).creationCode, abi.encode(1)));

        // Same wrapper + same salt = CREATE2 collision → revert
        vm.expectRevert(Create3.TrampolineDeployFailed.selector);
        wrapper.deployWith(keccak256("test.dup"), abi.encodePacked(type(SimpleContract).creationCode, abi.encode(2)));
    }
}
