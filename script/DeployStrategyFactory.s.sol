// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";

/// @title  DeployStrategyFactory
/// @notice #387 phase: deploy the keyless-clone StrategyFactory and approve the
///         canonical templates so deterministic strategy proposals
///         (cloneAndInitDeterministic) work. Run AFTER Deploy + DeployTemplates
///         — reads SYNDICATE_FACTORY and the *_TEMPLATE keys from
///         chains/{chainId}.json.
///
/// @dev    The allowlist defaults empty (every clone reverts), so each template
///         the CLI can propose MUST be approved here. Absent keys (e.g. the HL
///         templates on Base) are skipped, so one list covers every chain.
///         Owner-aware handoff mirrors the other phase scripts.
///
///   Usage:
///     SKIP_MULTISIG_HANDOFF=true forge script \
///       script/DeployStrategyFactory.s.sol:DeployStrategyFactory \
///       --rpc-url <vnet> --broadcast
contract DeployStrategyFactory is ScriptBase {
    function run() external {
        bool skipHandoff = vm.envOr("SKIP_MULTISIG_HANDOFF", false);
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (!skipHandoff) {
            require(ownerMultisig != address(0), "OWNER_MULTISIG required (or SKIP_MULTISIG_HANDOFF=true)");
            require(ownerMultisig.code.length > 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }

        address syndicateFactory = _readAddress("SYNDICATE_FACTORY");
        string memory json = vm.readFile(_chainsPath());
        string[] memory keys = _templateKeys();

        vm.startBroadcast();
        address deployer = msg.sender;
        StrategyFactory sf = new StrategyFactory(syndicateFactory, deployer);

        uint256 approved;
        for (uint256 i; i < keys.length; ++i) {
            address tmpl = _tryParseAddress(json, keys[i]);
            if (tmpl == address(0)) continue;
            sf.setTemplateApproval(tmpl, true);
            console.log(string.concat("approved ", keys[i]), tmpl);
            ++approved;
        }
        require(approved > 0, "no templates found in chains.json - run DeployTemplates first");

        if (!skipHandoff) sf.transferOwnership(ownerMultisig);
        vm.stopBroadcast();

        console.log("StrategyFactory:", address(sf));
        console.log("Templates approved:", approved);
        console.log("Owner:", sf.owner());

        _patchAddress("STRATEGY_FACTORY", address(sf));
    }

    /// @dev Every template the StrategyFactory must allowlist.
    function _templateKeys() internal pure returns (string[] memory keys) {
        keys = new string[](8);
        keys[0] = "MOONWELL_SUPPLY_TEMPLATE";
        keys[1] = "AERODROME_LP_TEMPLATE";
        keys[2] = "VENICE_INFERENCE_TEMPLATE";
        keys[3] = "WSTETH_MOONWELL_TEMPLATE";
        keys[4] = "MAMO_YIELD_TEMPLATE";
        keys[5] = "PORTFOLIO_TEMPLATE";
        keys[6] = "HYPERLIQUID_PERP_TEMPLATE";
        keys[7] = "HYPERLIQUID_GRID_TEMPLATE";
    }

    function _tryParseAddress(string memory json, string memory key) internal view returns (address) {
        try vm.parseJsonAddress(json, string.concat(".", key)) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }
}
