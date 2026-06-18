// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {MoonwellSupplyAdapter} from "../src/pricing/adapters/MoonwellSupplyAdapter.sol";

/// @title  DeployPriceRouter
/// @notice Phase 1 of the live-NAV redesign (PR #357): deploy the
///         governance-owned PriceRouter (UUPS) + the MoonwellSupplyAdapter,
///         register the adapter, seed a small Moonwell accrual-lag haircut, and
///         hand ownership to the multisig. No vault is touched — nothing
///         consumes the router yet, so this is a zero-blast-radius deploy.
///
/// @dev    Local fork dry run:
///           anvil --fork-url $BASE_RPC_URL --fork-block-number 47500000 &
///           SKIP_MULTISIG_HANDOFF=true forge script script/DeployPriceRouter.s.sol \
///             --rpc-url http://localhost:8545 --broadcast \
///             --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
///         Production:
///           OWNER_MULTISIG=0xSafe... forge script script/DeployPriceRouter.s.sol \
///             --rpc-url $BASE_RPC_URL --broadcast --account deployer
contract DeployPriceRouter is ScriptBase {
    /// @notice Moonwell Comptroller (Base mainnet) — the canonical market registry.
    address constant MOONWELL_COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
    /// @notice Accrual-lag haircut for Moonwell supply (bps). Monotone-increasing on-chain.
    uint16 constant MOONWELL_HAIRCUT_BPS = 25;

    function run() external {
        bool skipHandoff = vm.envOr("SKIP_MULTISIG_HANDOFF", false);
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (!skipHandoff) {
            require(ownerMultisig != address(0), "OWNER_MULTISIG required (or set SKIP_MULTISIG_HANDOFF=true)");
            require(ownerMultisig.code.length > 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }

        vm.startBroadcast();
        address deployer = msg.sender;

        // Router behind a UUPS proxy, initially owned by the deployer so the
        // config calls below succeed within this same broadcast.
        PriceRouter impl = new PriceRouter();
        PriceRouter router =
            PriceRouter(address(new ERC1967Proxy(address(impl), abi.encodeCall(PriceRouter.initialize, (deployer)))));

        // Deploy + register the first adapter (Moonwell supply) and seed its haircut.
        MoonwellSupplyAdapter moonwell = new MoonwellSupplyAdapter(MOONWELL_COMPTROLLER);
        bytes32 kind = moonwell.KIND();
        router.registerAdapter(kind, address(moonwell));
        router.setHaircutBps(kind, MOONWELL_HAIRCUT_BPS);
        // Phase 4: Moonwell supply is the first audited Lane-A-eligible kind.
        router.setLaneAEnabled(kind, true);

        // Hand ownership to the multisig in prod; beta/local keeps the deployer.
        if (!skipHandoff) {
            router.transferOwnership(ownerMultisig);
        }

        vm.stopBroadcast();

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("PriceRouter (proxy):", address(router));
        console.log("PriceRouter (impl):", address(impl));
        console.log("MoonwellSupplyAdapter:", address(moonwell));
        console.log("Owner:", router.owner());

        _writeFlatAddress("PRICE_ROUTER", address(router));
        _writeFlatAddress("PRICE_ROUTER_IMPL", address(impl));
        _writeFlatAddress("MOONWELL_SUPPLY_ADAPTER", address(moonwell));
    }

    /// @dev Patch a single FLAT address string into chains/{chainId}.json at a
    ///      top-level key, preserving existing keys. The shared
    ///      `ScriptBase._patchAddress` nests the value as `{"": "0x..."}` (which
    ///      breaks `_readAddress`/`parseJsonAddress`); this writes a plain
    ///      string matching the rest of the chains file.
    function _writeFlatAddress(string memory key, address value) internal {
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(block.chainid), ".json");
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), path, string.concat(".", key));
    }
}
