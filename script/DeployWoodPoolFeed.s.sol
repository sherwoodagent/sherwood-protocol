// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {WoodPoolFeed, IUniswapV2PairMinimal, IAggregatorMinimal} from "../src/pricing/WoodPoolFeed.sol";

/**
 * @title  DeployWoodPoolFeed
 * @notice Deploys the `WoodPoolFeed` that `ExposureLedger` prices WOOD against.
 *         Runs BEFORE `DeployPlanB`, whose pre-flight 8 refuses a ledger with no
 *         live WOOD price source.
 *
 *         There is no Chainlink WOOD/USD feed on chain 4663. This contract is
 *         one: it reads WOOD priced in ETH off the two WOOD/WETH Uniswap-V2-style
 *         pairs' cumulative-price accumulators, takes the LOWER of the two
 *         long-window averages, and converts to USD through the chain's ETH/USD
 *         Chainlink feed. It is wired at the ledger with `setWoodFeed`, exactly
 *         like a real aggregator.
 *
 *   Ceremony position (openspec/specs/deployment-docs/spec.md):
 *     core (3 phases) -> THIS -> run the keeper until latestRoundData() answers
 *     -> DeployPlanB
 *
 *   Address book (read from chains/{chainId}.json, each overridable by an env var
 *   of the same name):
 *     WOOD_WETH_V2_PAIR        — the Uniswap V2 pair holding exactly {WOOD, WETH}
 *     WOOD_WETH_SUSHI_V2_PAIR  — the Sushiswap V2 pair, same tokens
 *     WOOD_TOKEN, WETH
 *     CHAINLINK_ETH_USD_FEED   — the ETH leg
 *
 *   Environment:
 *     TWAP_WINDOW        — averaging window (default and minimum 24h)
 *     ETH_USD_MAX_AGE    — staleness bound on the ETH leg (default 24h)
 *     MIN_WETH_RESERVE   — per-pool depth floor, in WETH wei (default 10e18)
 *
 *   Usage:
 *     forge script script/DeployWoodPoolFeed.s.sol:DeployWoodPoolFeed \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast --slow
 *
 * @dev NOT OWNED. Every parameter is immutable, so there is no owner, no setter
 *      and no handoff: a different window, depth floor or pair means a new feed
 *      and a deliberate `setWoodFeed` at the ledger.
 */
contract DeployWoodPoolFeed is ScriptBase {
    /// @dev `WoodPoolFeed.MIN_WINDOW`, retyped because a contract-level constant
    ///      is not reachable off an undeployed contract. Move both together.
    uint256 constant DEFAULT_TWAP_WINDOW = 24 hours;
    /// @dev The live 4663 ETH/USD feed was measured ~10.7h old while healthy, so
    ///      anything tighter makes the ordinary case look degraded.
    uint256 constant DEFAULT_ETH_USD_MAX_AGE = 1 days;
    /// @dev Depth floor per pool, WETH side. The live WOOD/WETH pool is ~$438k.
    uint256 constant DEFAULT_MIN_WETH_RESERVE = 10e18;
    /// @dev Mirrors `WoodPoolFeed.MAX_IDLE`.
    uint256 constant MAX_IDLE = 5 minutes;

    struct Params {
        address uniPair;
        address sushiPair;
        address wood;
        address weth;
        address ethUsdFeed;
        uint256 window;
        uint256 ethUsdMaxAge;
        uint256 minWethReserve;
    }

    /// @notice Thin env adapter. `deploy()` takes the params as an argument so
    ///         the tests never touch `vm.setEnv`.
    function run() external {
        WoodPoolFeed feed = deploy(
            Params({
                uniPair: vm.envOr("WOOD_WETH_V2_PAIR", _readAddress("WOOD_WETH_V2_PAIR")),
                sushiPair: vm.envOr("WOOD_WETH_SUSHI_V2_PAIR", _readAddress("WOOD_WETH_SUSHI_V2_PAIR")),
                wood: vm.envOr("WOOD_TOKEN", _readAddress("WOOD_TOKEN")),
                weth: vm.envOr("WETH", _readAddress("WETH")),
                ethUsdFeed: vm.envOr("CHAINLINK_ETH_USD_FEED", _readAddress("CHAINLINK_ETH_USD_FEED")),
                window: vm.envOr("TWAP_WINDOW", DEFAULT_TWAP_WINDOW),
                ethUsdMaxAge: vm.envOr("ETH_USD_MAX_AGE", DEFAULT_ETH_USD_MAX_AGE),
                minWethReserve: vm.envOr("MIN_WETH_RESERVE", DEFAULT_MIN_WETH_RESERVE)
            })
        );

        _patchAddress("WOOD_USD_FEED", address(feed));
    }

    /// @notice Pre-flights, deploy, first snapshot. Public so the tests can drive
    ///         the real thing without the process environment. Does NOT persist
    ///         to chains/{chainId}.json — `run()` does that.
    function deploy(Params memory p) public returns (WoodPoolFeed feed) {
        _preflight(p);

        bool woodIsToken0Uni = IUniswapV2PairMinimal(p.uniPair).token0() == p.wood;
        bool woodIsToken0Sushi = IUniswapV2PairMinimal(p.sushiPair).token0() == p.wood;

        vm.startBroadcast();
        feed = new WoodPoolFeed(
            p.uniPair,
            woodIsToken0Uni,
            p.sushiPair,
            woodIsToken0Sushi,
            p.ethUsdFeed,
            p.ethUsdMaxAge,
            p.window,
            p.minWethReserve
        );
        // The first call only ever lays a baseline on each pool; `latestRoundData`
        // still needs a SECOND snapshot a full window later, which is the keeper's
        // job. Permissionless, so doing it here costs one call and saves a step.
        feed.update();
        vm.stopBroadcast();

        console.log("WoodPoolFeed:      %s", address(feed));
        console.log("uni pair:          %s", p.uniPair);
        console.log("sushi pair:        %s", p.sushiPair);
        console.log("window (s):        %s", p.window);
        console.log("minWethReserve:    %s", p.minWethReserve);

        // INSTANTANEOUS SPOT, FOR SIZING THE CAP ONLY — the manipulable quantity
        // the averaging exists to defeat, never a price. It is printed because the
        // operator's next decision is `WOOD_PRICE_CAP_X8`, which the runbook
        // requires to sit 1.25-2x ABOVE market.
        uint256 spotX8 = _spotWoodUsdX8(p, p.uniPair);
        console.log("spot WOOD/USD x8 (cap-sizing only, NOT a price): %s", spotX8);
        console.log("suggested WOOD_PRICE_CAP_X8 band 1.25-2x: %s .. %s", (spotX8 * 125) / 100, spotX8 * 2);

        console.log("\nNEXT, IN ORDER:");
        console.log("  1. Run the keeper: WoodPoolFeed.update(), permissionless, on a");
        console.log("     schedule shorter than WOOD_FEED_MAX_DELAY. A stale feed is");
        console.log("     NoWoodPrice: nothing proposes, nothing executes.");
        console.log("  2. Wait for latestRoundData() to answer (needs a second snapshot");
        console.log("     one full window after the baseline this script just recorded).");
        console.log("  3. DeployPlanB with WOOD_USD_FEED=<above> and WOOD_FEED_MAX_DELAY.");
        console.log("     Its pre-flight 8 is what actually enforces step 2.");
    }

    // ── Pre-flights (all PRE-broadcast: fail before anything is deployed) ──

    function _preflight(Params memory p) internal view {
        require(p.uniPair != address(0), "PRE-FLIGHT: WOOD_WETH_V2_PAIR unset");
        require(p.sushiPair != address(0), "PRE-FLIGHT: WOOD_WETH_SUSHI_V2_PAIR unset");
        require(p.uniPair != p.sushiPair, "PRE-FLIGHT: the two pairs are the same address");
        require(p.wood != address(0), "PRE-FLIGHT: WOOD_TOKEN unset");
        require(p.weth != address(0), "PRE-FLIGHT: WETH unset");
        require(p.ethUsdFeed != address(0), "PRE-FLIGHT: CHAINLINK_ETH_USD_FEED unset");

        require(p.window >= 24 hours, "PRE-FLIGHT: TWAP_WINDOW below MIN_WINDOW (24h)");
        require(p.window <= 7 days, "PRE-FLIGHT: TWAP_WINDOW above MAX_SNAPSHOT_SPAN (7d)");
        require(p.ethUsdMaxAge != 0, "PRE-FLIGHT: ETH_USD_MAX_AGE zero");
        require(p.minWethReserve != 0, "PRE-FLIGHT: MIN_WETH_RESERVE zero");

        // WOOD AND WETH MUST SHARE A DECIMALS COUNT: the feed multiplies the
        // pairs' raw UQ112x112 ratio by ETH/USD with no decimals normalisation.
        require(
            IERC20Metadata(p.wood).decimals() == IERC20Metadata(p.weth).decimals(),
            "PRE-FLIGHT: WOOD and WETH decimals differ - the feed does not normalise them"
        );

        _preflightPair(p, p.uniPair);
        _preflightPair(p, p.sushiPair);
        _preflightEthLeg(p);
    }

    /// @dev Each pair must hold exactly {WOOD, WETH}, clear the depth floor, and
    ///      be trading: the feed refuses to extrapolate across an idle span above
    ///      `MAX_IDLE`, so a pool that has stopped trading can never be snapshot.
    ///      That is the dominant failure on a FORK, where the pools stop trading
    ///      at the fork point.
    function _preflightPair(Params memory p, address pair) internal view {
        address t0 = IUniswapV2PairMinimal(pair).token0();
        address t1 = IUniswapV2PairMinimal(pair).token1();
        require(
            (t0 == p.wood && t1 == p.weth) || (t0 == p.weth && t1 == p.wood),
            "PRE-FLIGHT: pair does not hold exactly {WOOD, WETH}"
        );

        (uint112 r0, uint112 r1, uint32 last) = IUniswapV2PairMinimal(pair).getReserves();
        require(r0 != 0 && r1 != 0, "PRE-FLIGHT: pair has a zero reserve");
        uint256 wethReserve = t0 == p.weth ? uint256(r0) : uint256(r1);
        require(wethReserve >= p.minWethReserve, "PRE-FLIGHT: pair is below MIN_WETH_RESERVE");

        uint256 idle = block.timestamp > last ? block.timestamp - uint256(last) : 0;
        require(
            idle <= MAX_IDLE,
            "PRE-FLIGHT: pair has not traded within MAX_IDLE (5m) - update() would no-op forever. "
            "On a fork/vnet the pool does not trade at all: generate swaps, or wire a plain "
            "Chainlink-shaped WOOD feed instead."
        );
    }

    /// @dev The constructor reads only `decimals()` on the ETH leg. A feed that is
    ///      dead or negative constructs fine and then reverts from every read.
    function _preflightEthLeg(Params memory p) internal view {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(p.ethUsdFeed).latestRoundData();
        require(answer > 0, "PRE-FLIGHT: ETH/USD feed answer is not positive");
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        require(age <= p.ethUsdMaxAge, "PRE-FLIGHT: ETH/USD feed is already staler than ETH_USD_MAX_AGE");
    }

    // ── Helpers ──

    /// @dev Instantaneous spot, 8 decimals. Both tokens share a decimals count
    ///      (asserted in `_preflight`), so only the feed's own decimals scale.
    function _spotWoodUsdX8(Params memory p, address pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(pair).getReserves();
        bool woodIsToken0 = IUniswapV2PairMinimal(pair).token0() == p.wood;
        uint256 woodReserve = woodIsToken0 ? uint256(r0) : uint256(r1);
        uint256 wethReserve = woodIsToken0 ? uint256(r1) : uint256(r0);

        (, int256 answer,,,) = IAggregatorMinimal(p.ethUsdFeed).latestRoundData();
        uint8 dec = IAggregatorMinimal(p.ethUsdFeed).decimals();
        // `answer > 0` is asserted in `_preflightEthLeg`, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(answer);
        uint256 ethUsdX8 = dec >= 8 ? raw / (10 ** (uint256(dec) - 8)) : raw * (10 ** (8 - uint256(dec)));

        return (wethReserve * ethUsdX8) / woodReserve;
    }
}
