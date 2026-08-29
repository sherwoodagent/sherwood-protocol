// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {TokenizeFundStrategy} from "../../src/strategies/TokenizeFundStrategy.sol";
import {SushiLaunchAdapter} from "../../src/adapters/SushiLaunchAdapter.sol";
import {ISushiLaunchpad} from "../../src/vendor/sushi/ISushiLaunchpad.sol";
import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";

/**
 * @notice Deploy the TokenizeFundStrategy template and the SushiLaunchAdapter
 *         to Robinhood Chain mainnet (chain 4663).
 *
 *   MAINNET-ONLY BY CONSTRUCTION. Sushi Launchpad V1 exists on 4663 and
 *   nowhere else — `cast code` against the testnet (46630) address returns
 *   empty — so the testnet ceremony SKIPS this script entirely rather than
 *   deploying a template whose every clone would revert at init. Fork
 *   rehearsal happens on a 4663 fork via ROBINHOOD_FORK_CHAIN_ID.
 *
 *   Prerequisites:
 *     - Core stack deployed (Deploy.s.sol) and StrategyFactory deployed.
 *     - UniswapSwapAdapter deployed (DeployPortfolioStrategy) — the template
 *       routes its asset->quote leg through an allowlisted `ISwapAdapter`.
 *     - chains/4663.json seeded with SUSHI_LAUNCHPAD_V1. Resolved venue
 *       addresses and their identity evidence live in addresses/4663.json.
 *
 *   Post-deploy, the REGISTRY OWNER must, and the runbook below prints it:
 *     - `TierRegistry.setAdapterAllowed(SUSHI_LAUNCH_ADAPTER, true)` + tier
 *       certification (Gate A + Gate B, docs/adapter-onboarding-checklist.md).
 *     - `TierRegistry.setCounterpartyAllowed(SUSHI_LAUNCHPAD_V1, true)`.
 *     - `StrategyFactory.setTemplateApproval(TOKENIZE_FUND_TEMPLATE, true)`.
 *
 *   Usage:
 *     forge script script/robinhood-mainnet/DeployTokenizeFundStrategy.s.sol:DeployTokenizeFundStrategy \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast
 */
contract DeployTokenizeFundStrategy is ScriptBase {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170).
    uint256 constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    function run() external {
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );

        address launchpad = _readAddress("SUSHI_LAUNCHPAD_V1");
        address weth = _readAddress("WETH");
        _assertIsSushiLaunchpad(launchpad, weth);

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood Chain (chain ID 4663)");

        SushiLaunchAdapter adapter = new SushiLaunchAdapter(launchpad);
        TokenizeFundStrategy template = new TokenizeFundStrategy();

        vm.stopBroadcast();

        uint256 size = address(template).code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");

        _patchAddress("SUSHI_LAUNCH_ADAPTER", address(adapter));
        _patchAddress("TOKENIZE_FUND_TEMPLATE", address(template));
        console.log("SushiLaunchAdapter:   ", address(adapter));
        console.log("TokenizeFundStrategy: ", address(template));

        _printRegistryRunbook(address(adapter), launchpad, address(template));
    }

    /// @dev IDENTITY, NOT PRESENCE — the assertion this chain specifically
    ///      requires. `addresses/4663.json` records the hazard in full: the
    ///      canonical Uniswap mainnet addresses each hold ~2110 bytes of an
    ///      unrelated contract here, so `code.length != 0` passes on the WRONG
    ///      address and every later call fails in a way that reads as a bug in
    ///      our own code. A launchpad that is merely codeful would be approved,
    ///      the ceremony would complete, agents would write proposals, and each
    ///      one would revert at clone-init a governance cycle later.
    ///
    ///      The round trip below is what makes this cheap to check and hard to
    ///      fake: the venue names its own WETH, factory and position manager,
    ///      the position manager names a factory back, and the two must agree.
    ///      A squatter would have to reproduce the whole graph.
    function _assertIsSushiLaunchpad(address launchpad, address weth) internal view {
        require(launchpad != address(0), "SUSHI_LAUNCHPAD_V1 unset");
        require(launchpad.code.length != 0, "SUSHI_LAUNCHPAD_V1 holds no code");

        ISushiLaunchpad pad = ISushiLaunchpad(launchpad);
        require(pad.WETH() == weth, "launchpad WETH() disagrees with the address book");

        address v3Factory = _readAddress("SUSHI_V3_FACTORY");
        address positionManager = _readAddress("SUSHI_V3_POSITION_MANAGER");
        require(pad.v3Factory() == v3Factory, "launchpad v3Factory() disagrees with SUSHI_V3_FACTORY");
        require(
            pad.positionManager() == positionManager,
            "launchpad positionManager() disagrees with SUSHI_V3_POSITION_MANAGER"
        );
        require(v3Factory.code.length != 0, "SUSHI_V3_FACTORY holds no code");
        require(positionManager.code.length != 0, "SUSHI_V3_POSITION_MANAGER holds no code");

        // The launchpad must still be able to price SOMETHING, or every launch
        // reverts `UnsupportedQuoteToken`. WETH is the lane we know is live;
        // WOOD is deliberately NOT required here (see the runbook note).
        require(pad.quoteTokenPriceFeed(weth) != address(0), "launchpad has no WETH quote feed");
    }

    /// @dev Printed, not executed: these are REGISTRY-OWNER actions and the
    ///      deployer is not the owner on mainnet. `DeployConcentratedLiquidity
    ///      Strategy` asserts its counterparty precondition instead, because
    ///      that template is INERT without it — every clone reverts at init.
    ///      This one is different in a way worth stating: the adapter allowlist
    ///      is checked at clone-init too, so the same inertness applies, but
    ///      the registry writes here are for a template that does not exist
    ///      until this very script runs. Asserting a precondition about an
    ///      address the script itself is minting is impossible, so the runbook
    ///      is the honest form and the post-deploy reads below are how it is
    ///      verified.
    function _printRegistryRunbook(address adapter, address launchpad, address template) internal view {
        // TOLERANT read: this script can legitimately run on a fork whose book
        // predates the core deploy, and a mandatory read would revert the whole
        // ceremony over a runbook printout.
        address registry = _optionalAddress("TIER_REGISTRY");
        console.log("");
        console.log("== REGISTRY OWNER RUNBOOK (not executed by this script) ==");
        console.log("1. TierRegistry.setAdapterAllowed(adapter, true)      ", adapter);
        console.log("2. Tier certification for that adapter (Gate A)       ", adapter);
        console.log("3. TierRegistry.setCounterpartyAllowed(launchpad,true)", launchpad);
        console.log("4. StrategyFactory.setTemplateApproval(template, true)", template);
        console.log("");
        console.log("== POST-DEPLOY VALIDATION READS ==");
        if (registry != address(0)) {
            console.log(
                "tierRegistry.isAdapterAllowed(adapter):     ", ITierRegistry(registry).isAdapterAllowed(adapter)
            );
            console.log(
                "tierRegistry.isCounterpartyAllowed(launchpad):",
                ITierRegistry(registry).isCounterpartyAllowed(launchpad)
            );
        } else {
            console.log("TIER_REGISTRY unset in the address book - verify the two reads by hand");
        }
        console.log("");
        console.log("NOTE: quoteTokenPriceFeed(WOOD) is NOT required for this deploy.");
        console.log("      WOOD-paired launches revert UnsupportedQuoteToken until the");
        console.log("      Sushi owner registers a WOOD/USD aggregator; every other");
        console.log("      supported lane (WETH, USDG, stock tokens) works meanwhile,");
        console.log("      and the adapter needs no change when that feed lands.");
    }
}
