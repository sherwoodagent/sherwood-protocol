// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScriptBase} from "./ScriptBase.sol";
import {console} from "forge-std/console.sol";
import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";

/**
 * @notice Deploy the LeveragedAerodromeCLStrategy template singleton (Foundry auto-links its
 *         three `library` deps) and write LEVERAGED_AERO_CL_TEMPLATE into chains/{chainId}.json.
 *         The template is an uninitialised ERC-1167 master copy — proposals clone + init it. No env.
 *
 *   Usage: forge script script/DeployLeveragedAeroTemplate.s.sol:DeployLeveragedAeroTemplate \
 *            --rpc-url "$RPC" --broadcast --slow --private-key $DEPLOYER_PK
 */
contract DeployLeveragedAeroTemplate is ScriptBase {
    string constant TEMPLATE_KEY = "LEVERAGED_AERO_CL_TEMPLATE";

    function run() external {
        vm.startBroadcast();
        address template = address(new LeveragedAerodromeCLStrategy());
        vm.stopBroadcast();

        _patchAddress(TEMPLATE_KEY, template);

        console.log("LEVERAGED_AERO_CL_TEMPLATE", template);
        console.log("template.name:", LeveragedAerodromeCLStrategy(payable(template)).name());
    }
}
