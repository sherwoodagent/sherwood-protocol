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

    /// @dev Every template the StrategyFactory must allowlist. THIS LIST IS THE
    ///      ALLOWLIST — a template absent from here can never be proposed,
    ///      because `StrategyFactory`'s approval map starts empty and nothing
    ///      else populates it.
    ///
    ///      MOONWELL_SUPPLY / AERODROME_LP / WSTETH_MOONWELL / MAMO_YIELD were
    ///      REMOVED (deprecated, 2026-08-04). None had a contract left in
    ///      `src/strategies/`, so on every chain the loop below skipped all four
    ///      and the list overstated what the protocol could actually propose.
    ///      They resolve only in `chains/8453.json` and `chains/84532.json`, the
    ///      legacy Base books, and only for a NEW StrategyFactory — already
    ///      deployed factories keep whatever they approved at their own deploy.
    function _templateKeys() internal pure returns (string[] memory keys) {
        keys = new string[](3);
        keys[0] = "PORTFOLIO_TEMPLATE";
        keys[1] = "MORPHO_SUPPLY_TEMPLATE";
        keys[2] = "CONCENTRATED_LIQUIDITY_TEMPLATE";
    }

    function _tryParseAddress(string memory json, string memory key) internal view returns (address) {
        try vm.parseJsonAddress(json, string.concat(".", key)) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }
}
