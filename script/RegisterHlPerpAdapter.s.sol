// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {HyperliquidPerpAdapter} from "../src/pricing/adapters/HyperliquidPerpAdapter.sol";

/// @title  RegisterHlPerpAdapter
/// @notice Deploys HyperliquidPerpAdapter and prints the multisig calldata to:
///           1. registerAdapter(HL_PERP, adapter)
///           2. setHaircutBps(HL_PERP, 1000)      — 10% force-close slippage buffer
///           3. setInstantCap(HL_PERP, 500_000e6)  — $500k initial USDC cap
///
///         Does NOT enable Lane A (setLaneAEnabled). That call requires a separate
///         post-audit governance decision via the multisig.
///
/// @dev    Run (HyperEVM mainnet):
///           forge script script/RegisterHlPerpAdapter.s.sol \
///             --rpc-url $HYPEREVM_RPC_URL --broadcast --account deployer
contract RegisterHlPerpAdapter is ScriptBase {
    uint16 constant HL_PERP_HAIRCUT_BPS = 1000; // 10% — covers force-close slippage at leverage
    uint256 constant HL_PERP_INSTANT_CAP = 500_000e6; // $500k USDC (6 decimals)

    function run() external {
        vm.startBroadcast();
        HyperliquidPerpAdapter adapter = new HyperliquidPerpAdapter();
        vm.stopBroadcast();

        bytes32 kind = adapter.KIND();
        address routerAddr = _readAddress("PRICE_ROUTER");
        PriceRouter router = PriceRouter(routerAddr);

        console.log("HyperliquidPerpAdapter:", address(adapter));
        console.log("KIND (HL_PERP):", vm.toString(kind));
        console.log("PriceRouter:", routerAddr);
        console.log("---");
        console.log("Multisig calldata (execute in order via Safe batch):");
        console.log("");
        console.log("1. registerAdapter(kind, adapter):");
        console.logBytes(abi.encodeCall(router.registerAdapter, (kind, address(adapter))));
        console.log("");
        console.log("2. setHaircutBps(kind, 1000):");
        console.logBytes(abi.encodeCall(router.setHaircutBps, (kind, HL_PERP_HAIRCUT_BPS)));
        console.log("");
        console.log("3. setInstantCap(kind, 500_000e6):");
        console.logBytes(abi.encodeCall(router.setInstantCap, (kind, HL_PERP_INSTANT_CAP)));
        console.log("");
        console.log("Lane A enable (POST-AUDIT only):");
        console.log("4. setLaneAEnabled(kind, true):");
        console.logBytes(abi.encodeCall(router.setLaneAEnabled, (kind, true)));
    }
}
