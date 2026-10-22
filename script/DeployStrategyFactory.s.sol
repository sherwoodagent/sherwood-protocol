// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";
import {Stack} from "./robinhood-mainnet/DeployTypes.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {TierRegistry} from "../src/TierRegistry.sol";

/// @title  DeployStrategyFactory
/// @notice Keyless-clone StrategyFactory: mint it, approve the three canonical templates and
///         wire it into the TierRegistry. An abstract mixin — `DeployAll` owns `run()`, the
///         broadcast, the handoff and the address book.
///
/// @dev    THE WIRING IS MANDATORY. The vault and the governor resolve the strategy registry
///         through `TierRegistry.strategyFactory()`; while it is unwired every `propose`
///         reverts `StrategyNotRegistered` and every non-asset batch target is refused.
abstract contract DeployStrategyFactory is ScriptBase {
    /// @notice The ceremony phase: exactly the three templates this Stack minted.
    function _deployStrategyFactory(Stack memory s) internal {
        address[] memory templates = new address[](3);
        templates[0] = s.portfolioTemplate;
        templates[1] = s.morphoSupplyTemplate;
        templates[2] = s.concentratedLiquidityTemplate;

        StrategyFactory sf = deploy(s.core.factoryProxy, s.core.tierRegistry, templates);
        s.strategyFactory = address(sf);

        for (uint256 i; i < templates.length; ++i) {
            require(sf.approvedTemplate(templates[i]), "template approval did not land");
        }
        console.log("StrategyFactory:", address(sf));
    }

    /// @notice The ceremony proper, book passed in so a test can drive it without the env.
    /// @dev The caller must be the `Create3Factory` owner — `_c3Factory` bootstraps it at
    ///      `msg.sender`, exactly as `deployCore` does. Ownership stays on the deployer;
    ///      `DeployAll._handoffAll` moves it.
    function deploy(address syndicateFactory, address tierRegistry, address[] memory templates)
        public
        returns (StrategyFactory sf)
    {
        require(tierRegistry != address(0), "TIER_REGISTRY missing from the address book: run Deploy first");
        require(templates.length > 0, "no templates to approve");

        address deployer = msg.sender;
        require(
            TierRegistry(tierRegistry).owner() == deployer,
            "TIER_REGISTRY owner is not the deployer: run this phase BEFORE the multisig accepts TierRegistry ownership (unwired, every propose reverts StrategyNotRegistered)"
        );

        sf = StrategyFactory(
            _c3(
                _c3Factory(deployer),
                DeploySalts.STRATEGY_FACTORY,
                abi.encodePacked(type(StrategyFactory).creationCode, abi.encode(syndicateFactory, deployer))
            )
        );
        for (uint256 i; i < templates.length; ++i) {
            // Code, not non-zero: `_predictAll` fills the template addresses before any phase
            // runs, so a zero check cannot catch this phase being ordered ahead of them.
            require(templates[i].code.length != 0, "template holds no code: run the template phases first");
            if (!sf.approvedTemplate(templates[i])) sf.setTemplateApproval(templates[i], true);
        }

        // Re-pointing a live registry at a second factory strands every already-registered
        // strategy, so a foreign pointer is refused rather than overwritten.
        address wired = TierRegistry(tierRegistry).strategyFactory();
        require(
            wired == address(0) || wired == address(sf), "TIER_REGISTRY already points at a foreign StrategyFactory"
        );
        if (wired == address(0)) TierRegistry(tierRegistry).setStrategyFactory(address(sf));

        require(TierRegistry(tierRegistry).strategyFactory() == address(sf), "TIER_REGISTRY wiring did not land");
    }

    /// @dev Every template the StrategyFactory must allowlist. THIS LIST IS THE ALLOWLIST —
    ///      `StrategyFactory`'s approval map starts empty and nothing else populates it.
    ///      MOONWELL_SUPPLY / AERODROME_LP / WSTETH_MOONWELL / MAMO_YIELD were removed with
    ///      their contracts (2026-08-04); the exact set is pinned by a test.
    function _templateKeys() internal pure returns (string[] memory keys) {
        keys = new string[](3);
        keys[0] = "PORTFOLIO_TEMPLATE";
        keys[1] = "MORPHO_SUPPLY_TEMPLATE";
        keys[2] = "CONCENTRATED_LIQUIDITY_TEMPLATE";
    }
}
