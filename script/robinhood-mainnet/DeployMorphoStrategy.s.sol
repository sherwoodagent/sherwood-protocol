// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";

/**
 * @title  DeployMorphoStrategy
 * @notice Deploy the `MorphoSupplyStrategy` TEMPLATE to Robinhood Chain mainnet
 *         (chain 4663), and persist it as `MORPHO_SUPPLY_TEMPLATE` so
 *         `DeployStrategyFactory._templateKeys()` allowlists it.
 *
 *         WITHOUT THIS STEP THE STRATEGY IS UNREACHABLE. The contract has
 *         existed in `src/strategies/` with no deploy step and no template key,
 *         and `StrategyFactory`'s approval map starts empty — so even a
 *         hand-deployed template could never be cloned by a proposal.
 *
 * @dev NO MORPHO ADDRESS AND NO MARKET PARAMS ARE NEEDED HERE, which is the
 *      thing most likely to be assumed otherwise. `MorphoSupplyStrategy` is an
 *      ERC-1167 template: the Morpho singleton, the `MarketParams` tuple and
 *      the supply amount all arrive PER CLONE through `_initialize(bytes)`, so
 *      they are proposal inputs, not ceremony inputs. The template itself is
 *      constructed with no arguments and holds no market state.
 *
 *      This also means the template is deliberately left UNINITIALIZED. Its
 *      `vault()` is zero and `morpho`/`marketId` are unset; that is the correct
 *      resting state for a clone source, not an incomplete deployment.
 *
 * @dev WHY A SEPARATE PHASE from `DeployPortfolioStrategy`. That script deploys
 *      the `UniswapSwapAdapter` too, and reads four Uniswap addresses out of the
 *      address book to do it. This template needs none of them, so folding it in
 *      would make a Morpho deploy fail on a chain that merely lacks a Uniswap
 *      quoter. The market venue it targets is Morpho Blue
 *      (`0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` on 4663, verified live),
 *      which the CLONE validates at init via `MarketNotCreated`.
 *
 *   Ceremony position (openspec/specs/deployment-docs/spec.md):
 *     core (3 phases) -> DeployPortfolioStrategy -> THIS -> DeployStrategyFactory
 *
 *   Prerequisites:
 *     - Core stack already deployed via Deploy.s.sol.
 *
 *   Usage:
 *     forge script script/robinhood-mainnet/DeployMorphoStrategy.s.sol:DeployMorphoStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 */
contract DeployMorphoStrategy is ScriptBase {
    /// @notice Thin env adapter. `deploy()` takes no environment so the tests
    ///         never touch `vm.setEnv` — that writes one shared mutable process
    ///         global which forge does not roll back between tests and which
    ///         every parallel suite races. Same split, and the same reason, as
    ///         `DeployWoodTwapOracle`.
    function run() external {
        // Accept Robinhood mainnet (4663) OR a Tenderly-fork chain id via
        // ROBINHOOD_FORK_CHAIN_ID so the byte-same phase runs against the fork.
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );

        MorphoSupplyStrategy template = deploy();

        // The key `DeployStrategyFactory._templateKeys()` reads. Without this
        // patch the factory silently approves nothing for this strategy — its
        // loop skips absent keys — and the deployment looks clean.
        _patchAddress("MORPHO_SUPPLY_TEMPLATE", address(template));

        console.log("MorphoSupplyStrategy template:", address(template));
        console.log("\nNEXT: DeployStrategyFactory, which allowlists MORPHO_SUPPLY_TEMPLATE.");
        console.log("      Until it runs, no proposal can clone this template.");
    }

    /// @notice Deploy the template. Public so tests drive the real thing without
    ///         the process environment. Does NOT persist to
    ///         chains/{chainId}.json — `run()` does that, so a test calling this
    ///         never writes a junk `chains/31337.json`.
    function deploy() public returns (MorphoSupplyStrategy template) {
        vm.startBroadcast();
        template = new MorphoSupplyStrategy();
        vm.stopBroadcast();
    }
}
