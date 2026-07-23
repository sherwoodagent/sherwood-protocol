// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {LighterAccountOwner} from "../test/harness/LighterAccountOwner.sol";
import {IZkLighter} from "../src/lighter/IZkLighter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  DeployLighterCanary
/// @notice Deploys the LighterAccountOwner canary on Robinhood mainnet (4663).
///         Owner = broadcaster. Venue + USDG are hardcoded 4663 constants — the
///         canary predates the Sherwood deployment on this chain, so it does NOT
///         read chains/4663.json.
/// @dev    RUN BY THE USER WITH THEIR KEY. This script only deploys the harness;
///         it moves no funds. Every money-moving step is a manual cast in
///         test/harness/LighterCanary.md.
///
///   Usage:
///     forge script script/DeployLighterCanary.s.sol:DeployLighterCanary \
///       --rpc-url https://rpc.mainnet.chain.robinhood.com \
///       --private-key $DEPLOYER_PK --broadcast
contract DeployLighterCanary is ScriptBase {
    address internal constant ZK_LIGHTER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        vm.startBroadcast();
        LighterAccountOwner harness = new LighterAccountOwner(msg.sender, IZkLighter(ZK_LIGHTER), IERC20(USDG));
        vm.stopBroadcast();

        console.log("LighterAccountOwner:", address(harness));
        console.log("owner:", harness.owner());
        console.log("zkLighter:", address(harness.zkLighter()));
        console.log("usdg:", address(harness.usdg()));
    }
}
