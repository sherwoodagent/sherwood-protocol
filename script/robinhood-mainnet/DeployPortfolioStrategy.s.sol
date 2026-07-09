// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter} from "../../src/adapters/UniswapSwapAdapter.sol";

/**
 * @notice Deploy the UniswapSwapAdapter + PortfolioStrategy template to Robinhood
 *         Chain mainnet (chain 4663).
 *
 *         Uses the official Uniswap v3 deployment (SwapRouter02 + QuoterV2) plus
 *         the Uniswap v4 PoolManager + V4Quoter (mode-2 hookless pools carry the
 *         tokenized-stock liquidity). Addresses are read from chains/4663.json.
 *
 *   Prerequisites:
 *     - Core stack already deployed via Deploy.s.sol.
 *     - chains/4663.json seeded with UNISWAP_SWAP_ROUTER + UNISWAP_QUOTER_V2 +
 *       UNISWAP_V4_POOL_MANAGER + UNISWAP_V4_QUOTER.
 *
 *   Usage:
 *     forge script script/robinhood-mainnet/DeployPortfolioStrategy.s.sol:DeployPortfolioStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 */
contract DeployPortfolioStrategy is ScriptBase {
    function run() external {
        // Accept Robinhood mainnet (4663) OR a Tenderly-fork chain id via
        // ROBINHOOD_FORK_CHAIN_ID so the byte-same phase runs against the fork.
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );

        address swapRouter = _readAddress("UNISWAP_SWAP_ROUTER");
        address quoterV2 = _readAddress("UNISWAP_QUOTER_V2");
        address v4PoolManager = _readAddress("UNISWAP_V4_POOL_MANAGER");
        address v4Quoter = _readAddress("UNISWAP_V4_QUOTER");

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood Chain (chain ID 4663)");

        UniswapSwapAdapter adapter = new UniswapSwapAdapter(swapRouter, quoterV2, v4PoolManager, v4Quoter);
        PortfolioStrategy template = new PortfolioStrategy();

        vm.stopBroadcast();

        _patchAddress("UNISWAP_SWAP_ADAPTER", address(adapter));
        // PORTFOLIO_TEMPLATE (not the testnet-era PORTFOLIO_STRATEGY key) so
        // DeployStrategyFactory._templateKeys() picks it up for approval.
        _patchAddress("PORTFOLIO_TEMPLATE", address(template));

        console.log("UniswapSwapAdapter:", address(adapter));
        console.log("PortfolioStrategy template:", address(template));
    }
}
