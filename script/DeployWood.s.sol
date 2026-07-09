// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {WoodToken} from "../src/WoodToken.sol";

/// @notice Minimal LayerZero endpoint stub — only `setDelegate`, called by the
///         OApp constructor. Used on fork/testnet chains that have no LZ
///         endpoint; the fixture WOOD is non-production (see WoodToken natspec).
contract StubLzEndpoint {
    function setDelegate(address) external {}
}

/// @title  DeployWood
/// @notice Fork / beta WOOD bootstrap. Deploys the in-repo WoodToken FIXTURE
///         (explicitly non-production — see WoodToken natspec), mints a supply to
///         the deployer for guardian / owner staking + registry seeding, and
///         persists WOOD_TOKEN so Deploy.s.sol can wire the full guardian stack
///         against it.
///
///         Mainnet uses the EXTERNAL WOOD token — never run this there; set
///         WOOD_TOKEN to the real token instead. Gated behind ALLOW_FIXTURE_WOOD
///         because a Base-fork vnet shares mainnet's chainid (8453), so chainid
///         alone can't tell a fork from mainnet.
///
/// @dev    env: ALLOW_FIXTURE_WOOD (required, "true"), LZ_ENDPOINT (default
///         canonical EndpointV2), WOOD_MINT (default 100M, capped at 1B supply).
///
///   Usage (run BEFORE Deploy.s.sol so WOOD_TOKEN is in chains.json):
///     ALLOW_FIXTURE_WOOD=true forge script script/DeployWood.s.sol:DeployWood \
///       --rpc-url <vnet> --broadcast
contract DeployWood is ScriptBase {
    /// @notice Canonical LayerZero EndpointV2 (Base + most EVM chains). Present
    ///         on any Base fork. Override via LZ_ENDPOINT for other chains.
    address constant DEFAULT_LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    uint256 constant DEFAULT_WOOD_MINT = 100_000_000e18;

    function run() external {
        require(vm.envOr("ALLOW_FIXTURE_WOOD", false), "set ALLOW_FIXTURE_WOOD=true (fork/beta only; never mainnet)");
        address lzEndpoint = vm.envOr("LZ_ENDPOINT", DEFAULT_LZ_ENDPOINT);
        uint256 mintAmount = vm.envOr("WOOD_MINT", DEFAULT_WOOD_MINT);

        vm.startBroadcast();
        address deployer = msg.sender;
        // OApp's constructor calls `endpoint.setDelegate` — a code-less endpoint
        // reverts the deploy. On fork/testnet chains with no LZ endpoint, stand
        // up a stub (fixture WOOD is non-production anyway).
        if (lzEndpoint.code.length == 0) {
            lzEndpoint = address(new StubLzEndpoint());
            console.log("LZ endpoint had no code; deployed StubLzEndpoint:", lzEndpoint);
        }
        WoodToken wood = new WoodToken(lzEndpoint, deployer);
        uint256 minted = wood.mint(deployer, mintAmount);
        vm.stopBroadcast();

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("WoodToken (FIXTURE):", address(wood));
        console.log("Minted to deployer:", minted);

        _patchAddress("WOOD_TOKEN", address(wood));
    }
}
