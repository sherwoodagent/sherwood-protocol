// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScriptBase} from "./ScriptBase.sol";
import {console} from "forge-std/console.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {VeniceInferenceStrategy} from "../src/strategies/VeniceInferenceStrategy.sol";
import {PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter} from "../src/adapters/UniswapSwapAdapter.sol";

/**
 * @notice Deploy strategy template singletons (one-time per chain).
 *         Templates are ERC-1167 clonable — each proposal clones and initializes.
 *
 *         Skips templates already deployed (address exists in chains/{chainId}.json).
 *         Appends new addresses and validates all templates after deployment.
 *
 *         Per-chain matrix:
 *           Chains with Uniswap V3: Venice, Portfolio + UniswapSwapAdapter
 *           Other:                  Venice (Portfolio skipped if no Uniswap V3)
 *
 *   Usage:
 *     forge script script/DeployTemplates.s.sol:DeployTemplates \
 *       --rpc-url base --broadcast --account sherwood-agent
 *
 *   Dry run (no broadcast):
 *     forge script script/DeployTemplates.s.sol:DeployTemplates --rpc-url base
 */
contract DeployTemplates is ScriptBase {
    string constant VENICE_KEY = "VENICE_INFERENCE_TEMPLATE";
    string constant PORTFOLIO_KEY = "PORTFOLIO_TEMPLATE";
    string constant UNISWAP_SWAP_ADAPTER_KEY = "UNISWAP_SWAP_ADAPTER";

    // Uniswap V3 deployment per chain. Portfolio + UniswapSwapAdapter only deploy
    // on chains where these are non-zero. Add new chains here when extending.
    function _uniswapV3Router(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) return 0x2626664c2603336E57B271c5C0b26F421741e481; // Base SwapRouter02
        return address(0);
    }

    function _uniswapV3Quoter(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) return 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a; // Base QuoterV2
        return address(0);
    }

    struct Templates {
        address venice;
        address portfolio;
        address uniswapSwapAdapter;
    }

    function run() external {
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(block.chainid), ".json");

        // ── 1. Check which templates are already deployed ──

        Templates memory t;
        _readExisting(t, vm.readFile(path));

        // Portfolio + UniswapSwapAdapter deploy only where Uniswap V3 is wired.
        // Currently Base mainnet (8453); extend `_uniswapV3*` per chain to enable.
        bool hasUniswapV3 = _uniswapV3Router(block.chainid) != address(0);

        console.log("\n=== Strategy Template Deployment ===\n");

        // ── 2. Deploy missing templates ──

        bool anyDeployed = _deployAll(t, hasUniswapV3);

        // ── 3. Save addresses ──

        if (anyDeployed) {
            _save(t, path, hasUniswapV3);
            console.log("\n  Addresses saved to %s", path);
        } else {
            console.log("\n  All templates already deployed, nothing to save.");
        }

        // ── 4. Validate ──

        console.log("\n=== Validation ===\n");
        _validate(t, hasUniswapV3);
        console.log("\n  All validations passed.\n");
    }

    /// @notice Read already-deployed template addresses from the chain JSON into `t`.
    function _readExisting(Templates memory t, string memory json) internal pure {
        t.venice = _tryReadAddress(json, VENICE_KEY);
        t.portfolio = _tryReadAddress(json, PORTFOLIO_KEY);
        t.uniswapSwapAdapter = _tryReadAddress(json, UNISWAP_SWAP_ADAPTER_KEY);
    }

    /// @notice Persist deployed template addresses back to the chain JSON.
    function _save(Templates memory t, string memory path, bool hasUniswapV3) internal {
        vm.writeJson(vm.toString(t.venice), path, string.concat(".", VENICE_KEY));
        if (hasUniswapV3) {
            vm.writeJson(vm.toString(t.uniswapSwapAdapter), path, string.concat(".", UNISWAP_SWAP_ADAPTER_KEY));
            vm.writeJson(vm.toString(t.portfolio), path, string.concat(".", PORTFOLIO_KEY));
        }
    }

    /// @notice Deploy every missing template for the active chain. Returns true if anything deployed.
    function _deployAll(Templates memory t, bool hasUniswapV3) internal returns (bool anyDeployed) {
        vm.startBroadcast();

        if (_needsDeploy(t.venice)) {
            if (t.venice != address(0)) {
                console.log("  Stale    VeniceInferenceStrategy:  %s (no code, redeploying)", t.venice);
            }
            t.venice = address(new VeniceInferenceStrategy());
            console.log("  Deployed VeniceInferenceStrategy:  %s", t.venice);
            anyDeployed = true;
        } else {
            console.log("  Skipped  VeniceInferenceStrategy:  %s (already deployed)", t.venice);
        }

        // Portfolio + UniswapSwapAdapter ship as a pair — the strategy hardcodes
        // the adapter address into each clone's InitParams, so they're always
        // deployed together. Skip on chains without a known Uniswap V3 router.
        if (hasUniswapV3) {
            if (_needsDeploy(t.uniswapSwapAdapter)) {
                if (t.uniswapSwapAdapter != address(0)) {
                    console.log("  Stale    UniswapSwapAdapter:        %s (no code, redeploying)", t.uniswapSwapAdapter);
                }
                t.uniswapSwapAdapter = address(
                    new UniswapSwapAdapter(
                        _uniswapV3Router(block.chainid), _uniswapV3Quoter(block.chainid), address(0), address(0)
                    )
                );
                console.log("  Deployed UniswapSwapAdapter:        %s", t.uniswapSwapAdapter);
                anyDeployed = true;
            } else {
                console.log("  Skipped  UniswapSwapAdapter:        %s (already deployed)", t.uniswapSwapAdapter);
            }

            if (_needsDeploy(t.portfolio)) {
                if (t.portfolio != address(0)) {
                    console.log("  Stale    PortfolioStrategy:        %s (no code, redeploying)", t.portfolio);
                }
                t.portfolio = address(new PortfolioStrategy());
                console.log("  Deployed PortfolioStrategy:        %s", t.portfolio);
                anyDeployed = true;
            } else {
                console.log("  Skipped  PortfolioStrategy:        %s (already deployed)", t.portfolio);
            }
        } else {
            console.log("  Skipped  UniswapSwapAdapter:        N/A (no Uniswap V3 on chainId=%s)", block.chainid);
            console.log("  Skipped  PortfolioStrategy:        N/A (no Uniswap V3 on chainId=%s)", block.chainid);
        }

        vm.stopBroadcast();
    }

    // ── Helpers ──

    function _needsDeploy(address addr) internal view returns (bool) {
        return addr == address(0) || addr.code.length == 0;
    }

    /// @notice Try to read an address from JSON; return address(0) if key missing or zero.
    function _tryReadAddress(string memory json, string memory key) internal pure returns (address) {
        bytes memory raw = vm.parseJson(json, string.concat(".", key));
        if (raw.length == 0) return address(0);
        address addr = abi.decode(raw, (address));
        return addr;
    }

    /// @notice Validate all deployed templates have correct on-chain state.
    function _validate(Templates memory t, bool hasUniswapV3) internal view {
        require(t.venice.code.length > 0, "VeniceInferenceStrategy: no code");
        console.log("  VeniceInferenceStrategy: code OK (%s bytes)", t.venice.code.length);

        if (hasUniswapV3) {
            require(t.uniswapSwapAdapter.code.length > 0, "UniswapSwapAdapter: no code");
            console.log("  UniswapSwapAdapter:      code OK (%s bytes)", t.uniswapSwapAdapter.code.length);

            require(t.portfolio.code.length > 0, "PortfolioStrategy: no code");
            console.log("  PortfolioStrategy:       code OK (%s bytes)", t.portfolio.code.length);

            _validateName(t.portfolio, "Portfolio", "PortfolioStrategy");
            require(IStrategy(t.portfolio).vault() == address(0), "PortfolioStrategy: already initialized");
        } else {
            console.log("  UniswapSwapAdapter:      skipped (no Uniswap V3)");
            console.log("  PortfolioStrategy:       skipped (no Uniswap V3)");
        }

        _validateName(t.venice, "Venice Inference", "VeniceInferenceStrategy");

        require(IStrategy(t.venice).vault() == address(0), "VeniceInferenceStrategy: already initialized");

        console.log("  All templates: vault == address(0) (not initialized) OK");
    }

    function _validateName(address template, string memory expected, string memory label) internal view {
        string memory actual = IStrategy(template).name();
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), string.concat(label, ": wrong name"));
        console.log("  %s: name OK (\"%s\")", label, actual);
    }
}
