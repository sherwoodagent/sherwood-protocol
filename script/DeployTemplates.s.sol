// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScriptBase} from "./ScriptBase.sol";
import {console} from "forge-std/console.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MoonwellSupplyStrategy} from "../src/strategies/MoonwellSupplyStrategy.sol";
import {AerodromeLPStrategy} from "../src/strategies/AerodromeLPStrategy.sol";
import {VeniceInferenceStrategy} from "../src/strategies/VeniceInferenceStrategy.sol";
import {WstETHMoonwellStrategy} from "../src/strategies/WstETHMoonwellStrategy.sol";
import {MamoYieldStrategy} from "../src/strategies/MamoYieldStrategy.sol";
import {PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter} from "../src/adapters/UniswapSwapAdapter.sol";
import {HyperliquidPerpStrategy} from "../src/strategies/HyperliquidPerpStrategy.sol";
import {HyperliquidGridStrategy} from "../src/strategies/HyperliquidGridStrategy.sol";

/**
 * @notice Deploy strategy template singletons (one-time per chain).
 *         Templates are ERC-1167 clonable — each proposal clones and initializes.
 *
 *         Skips templates already deployed (address exists in chains/{chainId}.json).
 *         Appends new addresses and validates all templates after deployment.
 *
 *         Per-chain matrix:
 *           Base (8453):   Moonwell, Aerodrome, Venice, wstETH, Mamo, Portfolio + UniswapSwapAdapter
 *           HyperEVM (999): HyperliquidPerp, HyperliquidGrid
 *           Other:          Moonwell, Aerodrome, Venice, wstETH, Mamo (Portfolio skipped if no Uniswap V3)
 *
 *   Usage:
 *     forge script script/DeployTemplates.s.sol:DeployTemplates \
 *       --rpc-url base --broadcast --account sherwood-agent
 *
 *   Dry run (no broadcast):
 *     forge script script/DeployTemplates.s.sol:DeployTemplates --rpc-url base
 *
 *   Force-redeploy `HyperliquidGridStrategy` (e.g. after a slot-0 finalize
 *   patch where existing clones are unrecoverable on HC):
 *     FORCE_GRID_REDEPLOY=1 forge script script/DeployTemplates.s.sol:DeployTemplates \
 *       --rpc-url hyperevm --broadcast --account sherwood-agent
 *
 *   Force-redeploy `HyperliquidPerpStrategy` (e.g. after shipping a code upgrade):
 *     FORCE_PERP_REDEPLOY=1 forge script script/DeployTemplates.s.sol:DeployTemplates \
 *       --rpc-url hyperevm --broadcast --account sherwood-agent
 */
contract DeployTemplates is ScriptBase {
    string constant MOONWELL_KEY = "MOONWELL_SUPPLY_TEMPLATE";
    string constant AERODROME_KEY = "AERODROME_LP_TEMPLATE";
    string constant VENICE_KEY = "VENICE_INFERENCE_TEMPLATE";
    string constant WSTETH_KEY = "WSTETH_MOONWELL_TEMPLATE";
    string constant MAMO_KEY = "MAMO_YIELD_TEMPLATE";
    string constant PORTFOLIO_KEY = "PORTFOLIO_TEMPLATE";
    string constant UNISWAP_SWAP_ADAPTER_KEY = "UNISWAP_SWAP_ADAPTER";
    string constant HYPERLIQUID_KEY = "HYPERLIQUID_PERP_TEMPLATE";
    string constant HYPERLIQUID_GRID_KEY = "HYPERLIQUID_GRID_TEMPLATE";

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
        address moonwell;
        address aerodrome;
        address venice;
        address wsteth;
        address mamo;
        address portfolio;
        address uniswapSwapAdapter;
        address hyperliquid;
        address hyperliquidGrid;
    }

    function run() external {
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(block.chainid), ".json");

        // ── 1. Check which templates are already deployed ──

        Templates memory t;
        _readExisting(t, vm.readFile(path));

        bool isHyperEvm = block.chainid == 999;
        // Portfolio + UniswapSwapAdapter deploy only where Uniswap V3 is wired.
        // Currently Base mainnet (8453); extend `_uniswapV3*` per chain to enable.
        bool hasUniswapV3 = _uniswapV3Router(block.chainid) != address(0);

        console.log("\n=== Strategy Template Deployment ===\n");

        // ── 2. Deploy missing templates ──

        bool anyDeployed = _deployAll(t, isHyperEvm, hasUniswapV3);

        // ── 3. Save addresses ──

        if (anyDeployed) {
            _save(t, path, isHyperEvm, hasUniswapV3);
            console.log("\n  Addresses saved to %s", path);
        } else {
            console.log("\n  All templates already deployed, nothing to save.");
        }

        // ── 4. Validate ──

        console.log("\n=== Validation ===\n");
        _validate(t, isHyperEvm, hasUniswapV3);
        console.log("\n  All validations passed.\n");
    }

    /// @notice Read already-deployed template addresses from the chain JSON into `t`.
    function _readExisting(Templates memory t, string memory json) internal pure {
        t.moonwell = _tryReadAddress(json, MOONWELL_KEY);
        t.aerodrome = _tryReadAddress(json, AERODROME_KEY);
        t.venice = _tryReadAddress(json, VENICE_KEY);
        t.wsteth = _tryReadAddress(json, WSTETH_KEY);
        t.mamo = _tryReadAddress(json, MAMO_KEY);
        t.portfolio = _tryReadAddress(json, PORTFOLIO_KEY);
        t.uniswapSwapAdapter = _tryReadAddress(json, UNISWAP_SWAP_ADAPTER_KEY);
        t.hyperliquid = _tryReadAddress(json, HYPERLIQUID_KEY);
        t.hyperliquidGrid = _tryReadAddress(json, HYPERLIQUID_GRID_KEY);
    }

    /// @notice Persist deployed template addresses back to the chain JSON.
    function _save(Templates memory t, string memory path, bool isHyperEvm, bool hasUniswapV3) internal {
        if (isHyperEvm) {
            vm.writeJson(vm.toString(t.hyperliquid), path, string.concat(".", HYPERLIQUID_KEY));
            vm.writeJson(vm.toString(t.hyperliquidGrid), path, string.concat(".", HYPERLIQUID_GRID_KEY));
        } else {
            vm.writeJson(vm.toString(t.moonwell), path, string.concat(".", MOONWELL_KEY));
            vm.writeJson(vm.toString(t.aerodrome), path, string.concat(".", AERODROME_KEY));
            vm.writeJson(vm.toString(t.venice), path, string.concat(".", VENICE_KEY));
            vm.writeJson(vm.toString(t.wsteth), path, string.concat(".", WSTETH_KEY));
            vm.writeJson(vm.toString(t.mamo), path, string.concat(".", MAMO_KEY));
            if (hasUniswapV3) {
                vm.writeJson(vm.toString(t.uniswapSwapAdapter), path, string.concat(".", UNISWAP_SWAP_ADAPTER_KEY));
                vm.writeJson(vm.toString(t.portfolio), path, string.concat(".", PORTFOLIO_KEY));
            }
        }
    }

    /// @notice Deploy every missing template for the active chain. Returns true if anything deployed.
    function _deployAll(Templates memory t, bool isHyperEvm, bool hasUniswapV3) internal returns (bool anyDeployed) {
        vm.startBroadcast();

        // Moonwell/Aerodrome/Venice/wstETH-Moonwell/Mamo are not active on HyperEVM
        // (no Moonwell, Uniswap, Venice, or Aerodrome on chain 999). Only HyperliquidPerp
        // deploys there. Off HyperEVM, only the five non-perp templates deploy.
        if (isHyperEvm) {
            console.log("  Skipped  MoonwellSupplyStrategy:   N/A on HyperEVM");
            console.log("  Skipped  AerodromeLPStrategy:      N/A on HyperEVM");
            console.log("  Skipped  VeniceInferenceStrategy:  N/A on HyperEVM");
            console.log("  Skipped  WstETHMoonwellStrategy:   N/A on HyperEVM");
            console.log("  Skipped  MamoYieldStrategy:        N/A on HyperEVM");
        } else {
            if (_needsDeploy(t.moonwell)) {
                if (t.moonwell != address(0)) {
                    console.log("  Stale    MoonwellSupplyStrategy:   %s (no code, redeploying)", t.moonwell);
                }
                t.moonwell = address(new MoonwellSupplyStrategy());
                console.log("  Deployed MoonwellSupplyStrategy:   %s", t.moonwell);
                anyDeployed = true;
            } else {
                console.log("  Skipped  MoonwellSupplyStrategy:   %s (already deployed)", t.moonwell);
            }

            if (_needsDeploy(t.aerodrome)) {
                if (t.aerodrome != address(0)) {
                    console.log("  Stale    AerodromeLPStrategy:      %s (no code, redeploying)", t.aerodrome);
                }
                t.aerodrome = address(new AerodromeLPStrategy());
                console.log("  Deployed AerodromeLPStrategy:      %s", t.aerodrome);
                anyDeployed = true;
            } else {
                console.log("  Skipped  AerodromeLPStrategy:      %s (already deployed)", t.aerodrome);
            }

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

            if (_needsDeploy(t.wsteth)) {
                if (t.wsteth != address(0)) {
                    console.log("  Stale    WstETHMoonwellStrategy:   %s (no code, redeploying)", t.wsteth);
                }
                t.wsteth = address(new WstETHMoonwellStrategy());
                console.log("  Deployed WstETHMoonwellStrategy:   %s", t.wsteth);
                anyDeployed = true;
            } else {
                console.log("  Skipped  WstETHMoonwellStrategy:   %s (already deployed)", t.wsteth);
            }

            if (_needsDeploy(t.mamo)) {
                if (t.mamo != address(0)) {
                    console.log("  Stale    MamoYieldStrategy:        %s (no code, redeploying)", t.mamo);
                }
                t.mamo = address(new MamoYieldStrategy());
                console.log("  Deployed MamoYieldStrategy:        %s", t.mamo);
                anyDeployed = true;
            } else {
                console.log("  Skipped  MamoYieldStrategy:        %s (already deployed)", t.mamo);
            }

            // Portfolio + UniswapSwapAdapter ship as a pair — the strategy hardcodes
            // the adapter address into each clone's InitParams, so they're always
            // deployed together. Skip on chains without a known Uniswap V3 router.
            if (hasUniswapV3) {
                if (_needsDeploy(t.uniswapSwapAdapter)) {
                    if (t.uniswapSwapAdapter != address(0)) {
                        console.log(
                            "  Stale    UniswapSwapAdapter:        %s (no code, redeploying)", t.uniswapSwapAdapter
                        );
                    }
                    t.uniswapSwapAdapter = address(
                        new UniswapSwapAdapter(_uniswapV3Router(block.chainid), _uniswapV3Quoter(block.chainid))
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
        }

        if (isHyperEvm) {
            // Set `FORCE_PERP_REDEPLOY=1` to redeploy the Perp template even when
            // an address with code is already on file (e.g. when shipping a code
            // upgrade like the live-NAV / onLiveDeposit hooks). Mirrors the
            // FORCE_GRID_REDEPLOY pattern below — defaults to false so normal
            // runs stay idempotent.
            bool forcePerpRedeploy = vm.envOr("FORCE_PERP_REDEPLOY", false);
            if (_needsDeploy(t.hyperliquid) || forcePerpRedeploy) {
                if (t.hyperliquid != address(0) && t.hyperliquid.code.length > 0) {
                    console.log(
                        "  Stale    HyperliquidPerpStrategy:  %s (FORCE_PERP_REDEPLOY=1, redeploying)", t.hyperliquid
                    );
                } else if (t.hyperliquid != address(0)) {
                    console.log("  Stale    HyperliquidPerpStrategy:  %s (no code, redeploying)", t.hyperliquid);
                }
                t.hyperliquid = address(new HyperliquidPerpStrategy());
                console.log("  Deployed HyperliquidPerpStrategy:  %s", t.hyperliquid);
                anyDeployed = true;
            } else {
                console.log("  Skipped  HyperliquidPerpStrategy:  %s (already deployed)", t.hyperliquid);
            }

            // Grid template uses post-init HC registration: after cloning,
            // the CLI calls finalizeForHyperCore(0, Create, deployerNonce).
            // Set `FORCE_GRID_REDEPLOY=1` to redeploy the template without
            // hand-editing chains/{chainId}.json. Defaults to false so normal
            // runs remain idempotent.
            bool forceGridRedeploy = vm.envOr("FORCE_GRID_REDEPLOY", false);
            if (_needsDeploy(t.hyperliquidGrid) || forceGridRedeploy) {
                if (t.hyperliquidGrid != address(0) && t.hyperliquidGrid.code.length > 0) {
                    console.log(
                        "  Stale    HyperliquidGridStrategy:  %s (FORCE_GRID_REDEPLOY=1, redeploying)",
                        t.hyperliquidGrid
                    );
                } else if (t.hyperliquidGrid != address(0)) {
                    console.log("  Stale    HyperliquidGridStrategy:  %s (no code, redeploying)", t.hyperliquidGrid);
                }
                t.hyperliquidGrid = address(new HyperliquidGridStrategy());
                console.log("  Deployed HyperliquidGridStrategy:  %s (post-init Create finalize)", t.hyperliquidGrid);
                anyDeployed = true;
            } else {
                console.log("  Skipped  HyperliquidGridStrategy:  %s (already deployed)", t.hyperliquidGrid);
            }
        } else {
            console.log("  Skipped  HyperliquidPerpStrategy:  N/A (not on HyperEVM, chainId=%s)", block.chainid);
            console.log("  Skipped  HyperliquidGridStrategy:  N/A (not on HyperEVM, chainId=%s)", block.chainid);
        }

        vm.stopBroadcast();
    }

    /// @notice Test helper — deploys a fresh `HyperliquidGridStrategy` template.
    ///         Used by `HyperEVMIntegrationTest.setUp()`. Does not persist to JSON.
    /// @dev Caller is responsible for `vm.startBroadcast()` if needed.
    function deployHyperliquidGridTemplate() public returns (address) {
        return address(new HyperliquidGridStrategy());
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
    function _validate(Templates memory t, bool isHyperEvm, bool hasUniswapV3) internal view {
        // Each template should have code deployed (skip the five disabled-on-HyperEVM)
        if (isHyperEvm) {
            console.log("  MoonwellSupplyStrategy:  skipped (not on HyperEVM)");
            console.log("  AerodromeLPStrategy:     skipped (not on HyperEVM)");
            console.log("  VeniceInferenceStrategy: skipped (not on HyperEVM)");
            console.log("  WstETHMoonwellStrategy:  skipped (not on HyperEVM)");
            console.log("  MamoYieldStrategy:       skipped (not on HyperEVM)");
            console.log("  UniswapSwapAdapter:      skipped (not on HyperEVM)");
            console.log("  PortfolioStrategy:       skipped (not on HyperEVM)");

            require(t.hyperliquid.code.length > 0, "HyperliquidPerpStrategy: no code");
            console.log("  HyperliquidPerpStrategy: code OK (%s bytes)", t.hyperliquid.code.length);

            require(t.hyperliquidGrid.code.length > 0, "HyperliquidGridStrategy: no code");
            console.log("  HyperliquidGridStrategy: code OK (%s bytes)", t.hyperliquidGrid.code.length);

            _validateName(t.hyperliquid, "Hyperliquid Perp", "HyperliquidPerpStrategy");
            _validateName(t.hyperliquidGrid, "Hyperliquid Grid", "HyperliquidGridStrategy");

            require(IStrategy(t.hyperliquid).vault() == address(0), "HyperliquidPerpStrategy: already initialized");
            require(IStrategy(t.hyperliquidGrid).vault() == address(0), "HyperliquidGridStrategy: already initialized");
        } else {
            require(t.moonwell.code.length > 0, "MoonwellSupplyStrategy: no code");
            console.log("  MoonwellSupplyStrategy:  code OK (%s bytes)", t.moonwell.code.length);

            require(t.aerodrome.code.length > 0, "AerodromeLPStrategy: no code");
            console.log("  AerodromeLPStrategy:     code OK (%s bytes)", t.aerodrome.code.length);

            require(t.venice.code.length > 0, "VeniceInferenceStrategy: no code");
            console.log("  VeniceInferenceStrategy: code OK (%s bytes)", t.venice.code.length);

            require(t.wsteth.code.length > 0, "WstETHMoonwellStrategy: no code");
            console.log("  WstETHMoonwellStrategy:  code OK (%s bytes)", t.wsteth.code.length);

            require(t.mamo.code.length > 0, "MamoYieldStrategy: no code");
            console.log("  MamoYieldStrategy:       code OK (%s bytes)", t.mamo.code.length);

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

            console.log("  HyperliquidPerpStrategy: skipped (not on HyperEVM)");
            console.log("  HyperliquidGridStrategy: skipped (not on HyperEVM)");

            _validateName(t.moonwell, "Moonwell Supply", "MoonwellSupplyStrategy");
            _validateName(t.aerodrome, "Aerodrome LP", "AerodromeLPStrategy");
            _validateName(t.venice, "Venice Inference", "VeniceInferenceStrategy");
            _validateName(t.wsteth, "wstETH Moonwell Yield", "WstETHMoonwellStrategy");
            _validateName(t.mamo, "Mamo Yield", "MamoYieldStrategy");

            require(IStrategy(t.moonwell).vault() == address(0), "MoonwellSupplyStrategy: already initialized");
            require(IStrategy(t.aerodrome).vault() == address(0), "AerodromeLPStrategy: already initialized");
            require(IStrategy(t.venice).vault() == address(0), "VeniceInferenceStrategy: already initialized");
            require(IStrategy(t.wsteth).vault() == address(0), "WstETHMoonwellStrategy: already initialized");
            require(IStrategy(t.mamo).vault() == address(0), "MamoYieldStrategy: already initialized");
        }
        console.log("  All templates: vault == address(0) (not initialized) OK");
    }

    function _validateName(address template, string memory expected, string memory label) internal view {
        string memory actual = IStrategy(template).name();
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), string.concat(label, ": wrong name"));
        console.log("  %s: name OK (\"%s\")", label, actual);
    }
}
