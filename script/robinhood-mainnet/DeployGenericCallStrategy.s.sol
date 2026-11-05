// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {Stack} from "./DeployTypes.sol";
import {GenericCallStrategy} from "../../src/strategies/GenericCallStrategy.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";

/// @title  DeployGenericCallStrategy
/// @notice `GenericCallStrategy` template phase. An abstract mixin — `DeployAll` owns `run()`,
///         the broadcast and the address book.
/// @dev    Needs no venue and no TierRegistry seeding: every call list arrives per clone.
///         Tier 2 forever; never certify it (docs/generic-call-strategy.md).
abstract contract DeployGenericCallStrategy is ScriptBase {
    function _deployGenericCall(Stack memory s) internal {
        s.genericCallTemplate = address(deployGenericCallTemplate());
        _checkAddr("genericCallTemplate.create3Factory", address(_c3Factory(msg.sender)), s.create3Factory);
    }

    /// @notice Mint (or adopt) the template. Public so tests drive the real thing.
    /// @dev The caller must be the `Create3Factory` owner, exactly as `deployCore` requires.
    function deployGenericCallTemplate() public returns (GenericCallStrategy template) {
        Create3Factory c3 = _c3Factory(msg.sender);
        template =
            GenericCallStrategy(_c3(c3, DeploySalts.GENERIC_CALL_TEMPLATE, type(GenericCallStrategy).creationCode));
    }
}

/// @title  DeployGenericCallTemplate
/// @notice Live-chain path for a chain whose ceremony already handed off (4663): mints the template
///         only. Approval is the owner's `StrategyFactory.setTemplateApproval(template, true)`, and the
///         `GENERIC_CALL_TEMPLATE` address-book entry is added by hand; this script does neither.
contract DeployGenericCallTemplate is DeployGenericCallStrategy {
    function run() external {
        vm.startBroadcast();
        GenericCallStrategy template = deployGenericCallTemplate();
        vm.stopBroadcast();
        console.log("GenericCallStrategy template:", address(template));
        console.log("Owner call: StrategyFactory.setTemplateApproval(template, true), calldata:");
        console.logBytes(abi.encodeCall(StrategyFactory.setTemplateApproval, (address(template), true)));
    }
}
