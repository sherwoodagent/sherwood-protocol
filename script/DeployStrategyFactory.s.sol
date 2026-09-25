// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {TierRegistry} from "../src/TierRegistry.sol";

/// @title  DeployStrategyFactory
/// @notice #387 phase: deploy the keyless-clone StrategyFactory, approve the
///         canonical templates and wire the factory into the TierRegistry.
///         Run AFTER Deploy + DeployTemplates and BEFORE the multisig accepts
///         TierRegistry ownership — reads SYNDICATE_FACTORY, TIER_REGISTRY and
///         the *_TEMPLATE keys from chains/{chainId}.json.
///
/// @dev    The allowlist defaults empty (every clone reverts), so each template
///         the CLI can propose MUST be approved here. Absent keys (e.g. the HL
///         templates on Base) are skipped, so one list covers every chain.
///
///         THE WIRING IS MANDATORY. The vault and the governor resolve the
///         strategy registry through `TierRegistry.strategyFactory()`; while it
///         is unwired every `propose` reverts `StrategyNotRegistered` and every
///         non-asset batch target is refused. There is no deferred path: if the
///         registry owner is no longer the deployer, the phase refuses to run.
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
        address tierRegistry = _optionalAddress("TIER_REGISTRY");
        string memory json = vm.readFile(_chainsPath());
        string[] memory keys = _templateKeys();

        address[] memory templates = new address[](keys.length);
        uint256 found;
        for (uint256 i; i < keys.length; ++i) {
            address tmpl = _tryParseAddress(json, keys[i]);
            if (tmpl == address(0)) continue;
            templates[found++] = tmpl;
            console.log(string.concat("approving ", keys[i]), tmpl);
        }
        assembly ("memory-safe") {
            mstore(templates, found)
        }

        StrategyFactory sf = deploy(syndicateFactory, tierRegistry, templates, skipHandoff ? address(0) : ownerMultisig);

        console.log("StrategyFactory:", address(sf));
        console.log("Templates approved:", found);
        console.log("Owner:", sf.owner());
        console.log("TierRegistry.strategyFactory:", TierRegistry(tierRegistry).strategyFactory());

        _patchAddress("STRATEGY_FACTORY", address(sf));
    }

    /// @notice The ceremony proper, book passed in so a test can drive it without the env.
    /// @param ownerMultisig `address(0)` keeps the deployer as the factory owner (handoff skipped).
    function deploy(address syndicateFactory, address tierRegistry, address[] memory templates, address ownerMultisig)
        public
        returns (StrategyFactory sf)
    {
        require(tierRegistry != address(0), "TIER_REGISTRY missing from the address book: run Deploy first");
        require(templates.length > 0, "no templates found in chains.json - run DeployTemplates first");

        vm.startBroadcast();
        address deployer = msg.sender;
        require(
            TierRegistry(tierRegistry).owner() == deployer,
            "TIER_REGISTRY owner is not the deployer: run this phase BEFORE the multisig accepts TierRegistry ownership (unwired, every propose reverts StrategyNotRegistered)"
        );

        sf = new StrategyFactory(syndicateFactory, deployer);
        for (uint256 i; i < templates.length; ++i) {
            require(templates[i] != address(0), "zero template");
            sf.setTemplateApproval(templates[i], true);
        }
        TierRegistry(tierRegistry).setStrategyFactory(address(sf));
        if (ownerMultisig != address(0)) sf.transferOwnership(ownerMultisig);
        vm.stopBroadcast();

        require(TierRegistry(tierRegistry).strategyFactory() == address(sf), "TIER_REGISTRY wiring did not land");
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
