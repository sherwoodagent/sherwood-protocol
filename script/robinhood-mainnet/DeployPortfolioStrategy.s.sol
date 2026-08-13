// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter} from "../../src/adapters/UniswapSwapAdapter.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";

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

        _attestAdapter(deployer, address(adapter));

        vm.stopBroadcast();

        _patchAddress("UNISWAP_SWAP_ADAPTER", address(adapter));
        // PORTFOLIO_TEMPLATE (not the testnet-era PORTFOLIO_STRATEGY key) so
        // DeployStrategyFactory._templateKeys() picks it up for approval.
        _patchAddress("PORTFOLIO_TEMPLATE", address(template));

        console.log("UniswapSwapAdapter:", address(adapter));
        console.log("PortfolioStrategy template:", address(template));
    }

    /// @dev Attest the adapter this script just minted, in the same broadcast.
    ///
    ///      `PortfolioStrategy._initialize` calls `_requireAllowedAdapter`, and
    ///      the vault's `_guardBatchCalls` independently refuses an
    ///      `asset.approve(spender)` whose spender is not adapter-allowed. So
    ///      an unattested adapter does not degrade the template — it makes it
    ///      INERT, exactly as an unlisted factory does for the CL template,
    ///      and the failure surfaces a governance cycle later at clone-init.
    ///
    ///      This address cannot be seeded by `Deploy.s.sol` because it does not
    ///      exist until this phase runs. `TierRegistry` is `Ownable2Step`, so
    ///      the core deploy's `transferOwnership` only ARMED the handoff —
    ///      the deployer is still owner until the multisig calls
    ///      `acceptOwnership()`, which is the window this writes in. Run the
    ///      strategy phases BEFORE that acceptance; afterwards this degrades to
    ///      a runbook line and the multisig owes one transaction per adapter.
    function _attestAdapter(address deployer, address adapter) internal {
        address registry = _optionalAddress("TIER_REGISTRY");
        if (registry == address(0)) {
            console.log("RUNBOOK: no TIER_REGISTRY in the address book - adapter NOT attested.");
            console.log("RUNBOOK: the registry owner must call setAdapterAllowed(<adapter>, true):", adapter);
            return;
        }
        if (TierRegistry(registry).owner() != deployer) {
            console.log("RUNBOOK: deployer no longer owns TIER_REGISTRY - adapter NOT attested.");
            console.log("RUNBOOK: the owner must call setAdapterAllowed(<adapter>, true):", adapter);
            return;
        }
        TierRegistry(registry).setAdapterAllowed(adapter, true);
        console.log("UniswapSwapAdapter attested on TierRegistry:", registry);
    }
}
