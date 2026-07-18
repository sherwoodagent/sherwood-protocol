// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {VestingFactory} from "../src/vesting/VestingFactory.sol";

/// @title  DeployVestingFactory
/// @notice One-shot deploy of the vesting stack: the factory deploys the
///         `TokenVesting` implementation in its own constructor, and the
///         factory itself is permissionless and unowned — no params, no
///         multisig handoff. Grants are created afterwards per wallet via
///         `createVesting` (approve the factory on the vesting token first).
///
///   Usage:
///     forge script script/DeployVestingFactory.s.sol:DeployVestingFactory \
///       --rpc-url <rpc> --broadcast
contract DeployVestingFactory is ScriptBase {
    function run() external {
        vm.startBroadcast();
        VestingFactory factory = new VestingFactory();
        vm.stopBroadcast();

        console.log("VestingFactory:", address(factory));
        console.log("TokenVesting impl:", factory.implementation());

        _patchAddress("VESTING_FACTORY", address(factory));
        _patchAddress("TOKEN_VESTING_IMPL", factory.implementation());
    }
}
