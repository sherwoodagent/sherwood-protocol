// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {SynthraQuoterV2Shim} from "../../src/adapters/SynthraQuoterV2Shim.sol";
import {UniswapSwapAdapter} from "../../src/adapters/UniswapSwapAdapter.sol";

/**
 * @notice Targeted redeploy of the fixed `SynthraQuoterV2Shim` + its
 *         `UniswapSwapAdapter` on Robinhood L2 testnet (chain 46630).
 *
 *         Only these two contracts are redeployed — the core stack, PriceRouter,
 *         PortfolioStrategy template, and StrategyFactory are untouched. The
 *         freshly-deployed strategy clones read the adapter via the vault/strategy
 *         wiring, so patching `UNISWAP_SWAP_ADAPTER` here is sufficient for new
 *         proposals; the StrategyFactory / template do not embed the adapter.
 *
 *         The shim fix defaults a zero `sqrtPriceLimitX96` to the direction's
 *         TickMath bound (QuoterV2 semantics) — Synthra's V1 quoter reverts `SPL`
 *         on a literal zero limit, which broke every mode-0 quote.
 *
 *   Chain / path:
 *     Accepts chain 46630 OR a fork chain id via ROBINHOOD_TESTNET_FORK_CHAIN_ID
 *     (the e2e vnet is 99946630 — broadcast the SAME script to both at deployer
 *     nonce parity → identical CREATE addresses). The address book path is FORCED
 *     to chains/46630.json regardless of block.chainid, so the vnet run reads +
 *     patches the canonical testnet file (no throwaway chains/99946630.json).
 *
 *   Reads (from chains/46630.json): SYNTHRA_QUOTER, SYNTHRA_ROUTER.
 *   Patches (into chains/46630.json): SYNTHRA_QUOTER_V2_SHIM, UNISWAP_SWAP_ADAPTER.
 *
 *   Usage (testnet):
 *     forge script script/robinhood-testnet/RedeployShimAdapter.s.sol:RedeployShimAdapter \
 *       --rpc-url robinhood_testnet --account sherwood-deployer --broadcast --slow
 *
 *   Usage (e2e vnet, chain 99946630):
 *     ROBINHOOD_TESTNET_FORK_CHAIN_ID=99946630 \
 *       forge script script/robinhood-testnet/RedeployShimAdapter.s.sol:RedeployShimAdapter \
 *       --rpc-url <vnet-rpc> --account sherwood-deployer --broadcast --slow
 */
contract RedeployShimAdapter is ScriptBase {
    function run() external {
        uint256 forkChainId = vm.envOr("ROBINHOOD_TESTNET_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 46630 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood testnet 46630 or ROBINHOOD_TESTNET_FORK_CHAIN_ID"
        );

        // Path forced to 46630.json so the fork run keys off the canonical file.
        address synthraQuoter = _read46630("SYNTHRA_QUOTER");
        address synthraRouter = _read46630("SYNTHRA_ROUTER");

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Chain id:", block.chainid);

        // No v4 on testnet → poolManager / v4Quoter = address(0).
        SynthraQuoterV2Shim shim = new SynthraQuoterV2Shim(synthraQuoter);
        UniswapSwapAdapter adapter = new UniswapSwapAdapter(synthraRouter, address(shim), address(0), address(0));

        vm.stopBroadcast();

        _patch46630("SYNTHRA_QUOTER_V2_SHIM", address(shim));
        _patch46630("UNISWAP_SWAP_ADAPTER", address(adapter));

        console.log("SynthraQuoterV2Shim:", address(shim));
        console.log("UniswapSwapAdapter:", address(adapter));
    }

    /// @dev Canonical testnet address book, forced regardless of block.chainid so
    ///      a fork (99946630) reads + patches the real chains/46630.json.
    function _path46630() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/chains/46630.json");
    }

    function _read46630(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(_path46630()), string.concat(".", key));
    }

    function _patch46630(string memory key, address value) internal {
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), _path46630(), string.concat(".", key));
    }
}
