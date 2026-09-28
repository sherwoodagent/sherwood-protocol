// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {DeploySalts} from "../DeploySalts.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {Inputs, Stack} from "./DeployTypes.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter} from "../../src/adapters/UniswapSwapAdapter.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";

/// @notice UniswapSwapAdapter + PortfolioStrategy template phase.
///         An abstract mixin — `DeployAll` owns `run()`, the broadcast and the address book.
///         Uniswap v3 (SwapRouter02 + QuoterV2) plus the v4 PoolManager + V4Quoter, which
///         is where the tokenized-stock liquidity sits on 4663.
abstract contract DeployPortfolioStrategy is ScriptBase {
    function _deployPortfolio(Stack memory s, Inputs memory i) internal {
        Create3Factory c3 = Create3Factory(s.create3Factory);

        s.uniswapSwapAdapter = _c3(
            c3,
            DeploySalts.UNISWAP_SWAP_ADAPTER,
            abi.encodePacked(
                type(UniswapSwapAdapter).creationCode,
                abi.encode(i.uniswapSwapRouter, i.uniswapQuoterV2, i.uniswapV4PoolManager, i.uniswapV4Quoter)
            )
        );
        s.portfolioTemplate = _c3(c3, DeploySalts.PORTFOLIO_TEMPLATE, type(PortfolioStrategy).creationCode);

        _attestAdapter(s.core.deployer, s.core.tierRegistry, s.uniswapSwapAdapter);
        console.log("UniswapSwapAdapter:", s.uniswapSwapAdapter);
        console.log("PortfolioStrategy template:", s.portfolioTemplate);
    }

    /// @dev REQUIRED, not a runbook line: `PortfolioStrategy._initialize` binds the adapter
    ///      through `isCounterpartyAllowed`, so an unattested adapter makes the template INERT
    ///      and the failure surfaces a governance cycle later, at clone-init.
    function _attestAdapter(address deployer, address registry, address adapter) internal {
        require(registry != address(0), "TIER_REGISTRY missing from the address book: run Deploy first");
        require(
            TierRegistry(registry).owner() == deployer,
            "PRE-FLIGHT: TIER_REGISTRY owner is not the deployer - attest the swap adapter before the Safe accepts"
        );
        if (!TierRegistry(registry).isCounterpartyAllowed(adapter)) {
            TierRegistry(registry).setCounterpartyAllowed(adapter, true);
        }
    }
}
