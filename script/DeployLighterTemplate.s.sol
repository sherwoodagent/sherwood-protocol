// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {LighterPerpStrategy} from "../src/strategies/LighterPerpStrategy.sol";

/// @title  DeployLighterTemplate
/// @notice Deploy the LighterPerpStrategy template and approve it on the existing
///         StrategyFactory. Reads STRATEGY_FACTORY from chains/{chainId}.json and
///         patches LIGHTER_PERP_TEMPLATE back. Broadcaster MUST be the factory owner.
///
///   Usage (Robinhood fork):
///     forge script script/DeployLighterTemplate.s.sol:DeployLighterTemplate \
///       --rpc-url robinhood_fork --unlocked --sender <factory owner> --broadcast
contract DeployLighterTemplate is ScriptBase {
    function run() external {
        address factory = _readAddress("STRATEGY_FACTORY");

        vm.startBroadcast();
        LighterPerpStrategy template = new LighterPerpStrategy();
        StrategyFactory(factory).setTemplateApproval(address(template), true);
        vm.stopBroadcast();

        require(StrategyFactory(factory).approvedTemplate(address(template)), "approval failed");
        _patchAddress("LIGHTER_PERP_TEMPLATE", address(template));

        console.log("LighterPerpStrategy template:", address(template));
        console.log("approved on StrategyFactory:", factory);
    }
}
