// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {DeploySherwood} from "./Deploy.s.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {RobinhoodParams} from "./robinhood-mainnet/RobinhoodParams.sol";

/// @title  SeedPriceSources
/// @notice Brings a LIVE TierRegistry up to the current `RobinhoodParams.launchSetSymbols()`:
///         allowlists each CHAINLINK_<SYM>_USD_FEED and pairs it to its token. The deploy
///         ceremony seeds the launch set once, while the deployer still owns the registry; this
///         is the post-deploy path for symbols added to the list afterwards.
///
///         Idempotent: every write is skipped when the registry already holds it, so re-running
///         after a partial run, or against a fully seeded registry, broadcasts nothing.
///
///         Two modes, picked from who owns the registry:
///           - broadcaster IS the owner -> the missing writes are broadcast (the same
///             `_seedPriceSource` the ceremony runs, so the encoding cannot drift);
///           - broadcaster is NOT the owner (e.g. a Safe) -> nothing is broadcast; the missing
///             writes are printed as (target, calldata) for the owner to submit.
///
///   Usage (owner EOA, or an unlocked owner on a Tenderly vnet):
///     forge script script/SeedPriceSources.s.sol:SeedPriceSources \
///       --rpc-url <rpc> --sender <owner> [--unlocked] --broadcast
///   Usage (Safe-owned registry, print only):
///     forge script script/SeedPriceSources.s.sol:SeedPriceSources --rpc-url <rpc>
contract SeedPriceSources is DeploySherwood {
    function run() external {
        TierRegistry registry = TierRegistry(_readAddress("TIER_REGISTRY"));
        string[30] memory symbols = RobinhoodParams.launchSetSymbols();

        console.log("TierRegistry:", address(registry));
        console.log("owner:", registry.owner());
        console.log("launch-set symbols:", symbols.length);
        uint256 pending = _plan(registry, symbols);
        console.log("missing writes:", pending);
        if (pending == 0) return;

        if (registry.owner() != msg.sender) {
            console.log("Broadcaster is not the owner: submit the calls listed above from the owner.");
            return;
        }

        vm.startBroadcast();
        for (uint256 i; i < symbols.length; ++i) {
            _seedPriceSource(address(registry), symbols[i]);
        }
        vm.stopBroadcast();

        uint256 left = _plan(registry, symbols);
        require(left == 0, "SeedPriceSources: writes still missing after the broadcast");
    }

    /// @dev Counts the missing writes and logs each one as its target and calldata.
    function _plan(TierRegistry registry, string[30] memory symbols) internal view returns (uint256 pending) {
        for (uint256 i; i < symbols.length; ++i) {
            string memory feedKey = string.concat("CHAINLINK_", symbols[i], "_USD_FEED");
            address feed = _readAddress(feedKey);
            require(feed != address(0), string.concat("launch set: ", feedKey, " is zero in the address book"));

            if (!registry.isCounterpartyAllowed(feed)) {
                ++pending;
                bytes memory cd = abi.encodeCall(TierRegistry.setCounterpartyAllowed, (feed, true));
                console.log(string.concat("  ", symbols[i], " allowlist feed:"), address(registry));
                console.logBytes(cd);
            }

            string memory tokenKey = keccak256(bytes(symbols[i])) == keccak256("ETH") ? "WETH" : symbols[i];
            address token = _optionalAddress(tokenKey);
            if (token == address(0)) continue; // feed-only symbol; `_seedPriceSource` enforces which
            bytes32 priceSource = bytes32(uint256(uint160(feed)));
            if (!registry.isPriceSourceForToken(token, priceSource)) {
                ++pending;
                bytes memory cd = abi.encodeCall(TierRegistry.setPriceSourceForToken, (token, priceSource, true));
                console.log(string.concat("  ", symbols[i], " pair feed -> token:"), address(registry));
                console.logBytes(cd);
            }
        }
    }
}
