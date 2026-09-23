// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeploySalts} from "../../script/DeploySalts.sol";
import {ScriptBase} from "../../script/ScriptBase.sol";
import {Create3Factory} from "../../script/utils/Create3Factory.sol";

/// @notice Exposes the CREATE3 primitives; the factory owner is this harness, so it may call deploy().
contract BootstrapHarness is ScriptBase {
    function c3Factory(address deployer) external returns (Create3Factory) {
        return _c3Factory(deployer);
    }

    function c3(Create3Factory f, bytes32 salt, bytes memory initcode) external returns (address) {
        return _c3(f, salt, initcode);
    }

    function predict(Create3Factory f, bytes32 salt) external pure returns (address) {
        return _predict(f, salt);
    }
}

contract Create3BootstrapTest is Test {
    /// @dev Arachnid deterministic-deployment-proxy runtime; etched only when the EVM lacks it.
    bytes internal constant CREATE2_DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    BootstrapHarness internal h;
    bytes32 internal constant PAYLOAD_SALT = keccak256("create3-bootstrap-test.payload");

    function setUp() public {
        h = new BootstrapHarness();
        if (CREATE2_DEPLOYER.code.length == 0) vm.etch(CREATE2_DEPLOYER, CREATE2_DEPLOYER_RUNTIME);
    }

    /// @notice The pinned hash is the compiler's actual output for Create3Factory.
    function test_initcodeHashIsPinnedToThisToolchain() public pure {
        assertEq(keccak256(type(Create3Factory).creationCode), DeploySalts.CREATE3_FACTORY_INITCODE_HASH);
    }

    /// @notice The factory lands at the CREATE2 address derived from the pinned hash and the salt.
    function test_bootstrapLandsAtTheCreate2Prediction() public {
        address expected = _create2Address(address(h));
        Create3Factory f = h.c3Factory(address(h));
        assertEq(address(f), expected);
        assertGt(address(f).code.length, 0);
        assertEq(f.owner(), address(h));
    }

    /// @notice A second bootstrap adopts the existing factory instead of re-deploying it.
    function test_secondBootstrapIsANoOp() public {
        Create3Factory first = h.c3Factory(address(h));
        bytes32 codehash = address(first).codehash;
        Create3Factory second = h.c3Factory(address(h));
        assertEq(address(second), address(first));
        assertEq(address(second).codehash, codehash);
    }

    /// @notice The bootstrap refuses a chain without the deterministic deployment proxy.
    function test_bootstrapRefusesAChainWithoutTheCreate2Deployer() public {
        vm.etch(CREATE2_DEPLOYER, "");
        vm.expectRevert("CREATE2 deployer not on this chain");
        h.c3Factory(address(h));
    }

    /// @notice _c3 mints at the predicted address and adopts it on reuse.
    function test_c3MintsAtThePredictionAndSkipsOnReuse() public {
        Create3Factory f = h.c3Factory(address(h));
        address predicted = h.predict(f, PAYLOAD_SALT);
        bytes memory initcode = abi.encodePacked(type(Create3Factory).creationCode, abi.encode(address(h)));

        address minted = h.c3(f, PAYLOAD_SALT, initcode);
        assertEq(minted, predicted);
        assertGt(minted.code.length, 0);

        bytes32 codehash = minted.codehash;
        assertEq(h.c3(f, PAYLOAD_SALT, initcode), minted);
        assertEq(minted.codehash, codehash);
    }

    function _create2Address(address deployer) internal pure returns (address) {
        bytes32 initcodeHash = keccak256(abi.encodePacked(type(Create3Factory).creationCode, abi.encode(deployer)));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, DeploySalts.CREATE3_FACTORY, initcodeHash)
                    )
                )
            )
        );
    }
}
