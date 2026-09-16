// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {DeploySalts} from "./DeploySalts.sol";
import {Create3} from "./utils/Create3.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";

/// @notice Shared helpers for deploy and admin scripts.
///         - Assertion helpers (_checkAddr, _checkUint)
///         - CREATE3 minting (_c3Factory, _c3, _predict)
///         - JSON address persistence (_patchAddress, _readAddress)
///
///         Chain addresses live in chains/{chainId}.json with
///         CAPS_SNAKE_CASE keys matching contract names.
abstract contract ScriptBase is Script {
    /// @notice Deterministic deployment proxy, same address on every EVM chain.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // ── CREATE3 ──

    /// @notice Bootstrap (or adopt) the Create3Factory at its CREATE2 address.
    /// @dev Address = f(CREATE2_DEPLOYER, salt, initcode), so it is the same for
    ///      any deployer that pins the same `deployer` constructor arg; the
    ///      initcode-hash assert turns a solc/optimizer drift into a loud failure
    ///      instead of silently moving every CREATE3 address downstream.
    function _c3Factory(address deployer) internal returns (Create3Factory) {
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer not on this chain");
        require(
            keccak256(type(Create3Factory).creationCode) == DeploySalts.CREATE3_FACTORY_INITCODE_HASH,
            "Create3Factory initcode hash drift"
        );
        bytes memory initcode = abi.encodePacked(type(Create3Factory).creationCode, abi.encode(deployer));
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), CREATE2_DEPLOYER, DeploySalts.CREATE3_FACTORY, keccak256(initcode)
                        )
                    )
                )
            )
        );
        if (predicted.code.length == 0) {
            (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(DeploySalts.CREATE3_FACTORY, initcode));
            require(ok, "Create3Factory bootstrap reverted");
            require(predicted.code.length != 0, "Create3Factory bootstrap produced no code");
        }
        Create3Factory c3 = Create3Factory(predicted);
        require(c3.owner() == deployer, "Create3Factory owned by a different deployer");
        return c3;
    }

    /// @notice Address this factory mints `salt` at. Depends on (factory, salt) only.
    function _predict(Create3Factory c3, bytes32 salt) internal pure returns (address) {
        return Create3.addressOf(address(c3), salt);
    }

    /// @notice Mint `initcode` at the salt's address, or adopt it if already there.
    function _c3(Create3Factory c3, bytes32 salt, bytes memory initcode) internal returns (address deployed) {
        deployed = _predict(c3, salt);
        if (deployed.code.length != 0) return deployed;
        require(c3.deploy(salt, initcode) == deployed, "CREATE3 address mismatch");
    }

    // ── Assertions ──

    function _checkAddr(string memory label, address actual, address expected) internal pure {
        require(actual == expected, string.concat(label, " mismatch"));
    }

    function _checkUint(string memory label, uint256 actual, uint256 expected) internal pure {
        require(actual == expected, string.concat(label, " mismatch"));
    }

    // ── JSON address persistence ──

    /// @notice Path to this chain's address book.
    function _chainsPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/chains/", vm.toString(block.chainid), ".json");
    }

    function _fileExists(string memory path) internal view returns (bool) {
        try vm.readFile(path) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Patch a single address into chains/{chainId}.json at a top-level
    ///         key, preserving any existing keys (uses `vm.writeJson` path mode).
    /// @dev Writes the address as a flat JSON string at `.key`. The path-mode
    ///      `writeJson` value must already be valid JSON, so quote the address.
    function _patchAddress(string memory key, address value) internal {
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), _chainsPath(), string.concat(".", key));
    }

    /// @notice Patch a key ONLY when this chain already has an address book.
    /// @dev    For phases whose `run()` is also driven by a test suite. The
    ///         pre-flight suites call `run()` under `vm.setEnv` on the default
    ///         test chain id, where `_patchAddress` would CREATE
    ///         `chains/31337.json` — a junk file committed into the repo by the
    ///         act of running the tests.
    ///
    ///         Silence is correct here rather than a revert: a chain with no
    ///         address book is not a chain this key belongs to, and the deploy
    ///         phases that matter all run against a book the core ceremony
    ///         wrote several phases earlier. A missing book on a real deploy
    ///         target is caught long before this, by the `_readAddress` calls
    ///         that every one of those phases opens with.
    function _patchAddressIfBook(string memory key, address value) internal {
        if (!_fileExists(_chainsPath())) {
            console.log("address book absent for this chain - %s not persisted", key);
            return;
        }
        _patchAddress(key, value);
    }

    /// @notice Read a deployed address from chains/{chainId}.json
    function _readAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(_chainsPath()), string.concat(".", key));
    }

    /// @notice Read an OPTIONAL address from chains/{chainId}.json.
    /// @dev    `_readAddress` reverts on a missing file or key, which is right
    ///         for a mandatory dependency and wrong for one that legitimately
    ///         varies per chain — a phase that must run both before and after
    ///         the core deploy cannot ask "is TIER_REGISTRY in the book yet?"
    ///         without a tolerant read. Returns `address(0)` for a missing
    ///         file, key, or value; callers treat zero as "not on this chain".
    function _optionalAddress(string memory key) internal view returns (address) {
        string memory path = _chainsPath();
        if (!_fileExists(path)) return address(0);
        try vm.parseJsonAddress(vm.readFile(path), string.concat(".", key)) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }
}
