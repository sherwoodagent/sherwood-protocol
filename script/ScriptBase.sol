// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

/// @notice Shared helpers for deploy and admin scripts.
///         - Assertion helpers (_checkAddr, _checkUint)
///         - JSON address persistence (_writeAddresses, _readAddress)
///
///         Chain addresses live in contracts/chains/{chainId}.json with
///         CAPS_SNAKE_CASE keys matching contract names.
abstract contract ScriptBase is Script {
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

    /// @notice Write core deployed addresses to chains/{chainId}.json.
    /// @dev When the file already exists, patches the core keys IN PLACE so
    ///      pre-existing keys (templates, ENS, PRICE_ROUTER, WOOD_TOKEN written
    ///      by other phases) survive — the deploy phases are order-independent
    ///      and re-runnable. Only a first-ever deploy on a novel chain serializes
    ///      a fresh object. (Previously this overwrote the whole file, silently
    ///      dropping every key it didn't own.)
    function _writeAddresses(
        string memory name,
        address deployer,
        address factory,
        address governor,
        address executorLib,
        address vaultImpl
    ) internal {
        string memory path = _chainsPath();
        if (_fileExists(path)) {
            _patchAddress("BATCH_EXECUTOR_LIB", executorLib);
            _patchAddress("DEPLOYER", deployer);
            _patchAddress("SYNDICATE_FACTORY", factory);
            _patchAddress("SYNDICATE_GOVERNOR", governor);
            _patchAddress("SYNDICATE_VAULT_IMPL", vaultImpl);
            vm.writeJson(vm.toString(block.chainid), path, ".chainId");
            vm.writeJson(string.concat("\"", name, "\""), path, ".name");
        } else {
            string memory obj = "deploy";
            vm.serializeAddress(obj, "BATCH_EXECUTOR_LIB", executorLib);
            vm.serializeAddress(obj, "DEPLOYER", deployer);
            vm.serializeAddress(obj, "SYNDICATE_FACTORY", factory);
            vm.serializeAddress(obj, "SYNDICATE_GOVERNOR", governor);
            vm.serializeAddress(obj, "SYNDICATE_VAULT_IMPL", vaultImpl);
            vm.serializeUint(obj, "chainId", block.chainid);
            string memory json = vm.serializeString(obj, "name", name);
            vm.writeJson(json, path);
        }
        console.log("Addresses written to %s", path);
    }

    /// @notice Patch a single address into chains/{chainId}.json at a top-level
    ///         key, preserving any existing keys (uses `vm.writeJson` path mode).
    /// @dev Writes the address as a flat JSON string at `.key`. The path-mode
    ///      `writeJson` value must already be valid JSON, so quote the address.
    function _patchAddress(string memory key, address value) internal {
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), _chainsPath(), string.concat(".", key));
    }

    /// @notice Read a deployed address from chains/{chainId}.json
    function _readAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(_chainsPath()), string.concat(".", key));
    }

    /// @notice Write tokenomics addresses to chains/{chainId}.json (appends to existing)
    function _writeTokenomicsAddresses(
        address woodToken,
        address votingEscrow,
        address voter,
        address minter,
        address rewardsDistributor,
        address voteIncentive
    ) internal {
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(block.chainid), ".json");

        vm.writeJson(vm.serializeAddress("", "", woodToken), path, ".WOOD_TOKEN");
        vm.writeJson(vm.serializeAddress("", "", votingEscrow), path, ".VOTING_ESCROW");
        vm.writeJson(vm.serializeAddress("", "", voter), path, ".VOTER");
        vm.writeJson(vm.serializeAddress("", "", minter), path, ".MINTER");
        vm.writeJson(vm.serializeAddress("", "", rewardsDistributor), path, ".REWARDS_DISTRIBUTOR");
        vm.writeJson(vm.serializeAddress("", "", voteIncentive), path, ".VOTE_INCENTIVE");

        console.log("Tokenomics addresses written to %s", path);
    }
}
