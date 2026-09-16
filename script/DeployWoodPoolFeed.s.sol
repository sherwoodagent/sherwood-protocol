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
    /// @dev DEPLOY POLICY ONLY, not a feed parameter: how stale a pair's last
    ///      trade may be for this script to accept it as a live market.
    uint256 constant MAX_PAIR_IDLE = 5 minutes;
    /// @dev The keeper cadence the runbook assumes, and the slack `DeployPlanB`
    ///      pre-flight 12 adds to the window when bounding WOOD_FEED_MAX_DELAY.
    ///      Keep in step with `DeployPlanB.KEEPER_CADENCE_SLACK`.
    uint256 constant KEEPER_CADENCE = 2 hours;

    /// @notice The `WOOD_FEED_MAX_DELAY` an operator should seat for a feed with
    ///         this window: a snapshot rolls at most once per window, so the
    ///         bound has to clear a whole window plus the keeper's cadence.
    function suggestedWoodFeedMaxDelay(uint256 window) public pure returns (uint256) {
        return window + KEEPER_CADENCE + 1;
    }

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

        vm.startBroadcast();
        // The constructor derives which side of each pair holds WOOD from the
        // pair itself, and refuses a pair that is not exactly {WOOD, WETH}.
        feed = new WoodPoolFeed(
            p.uniPair, p.sushiPair, p.wood, p.weth, p.ethUsdFeed, p.ethUsdMaxAge, p.window, p.minWethReserve
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

        console.log("\nNOTE: this deploy transaction's update() WRITES to the two live pairs");
        console.log("      (permissionless sync()), it does not only read them.");
        console.log("\nNEXT, IN ORDER:");
        console.log("  1. Run the keeper: WoodPoolFeed.update(), permissionless, at least");
        console.log("     once per window + %s s. That single call is the whole job:", KEEPER_CADENCE);
        console.log("     update() sync()s BOTH PAIRS itself, so a pool that has not traded");
        console.log("     still snapshots and the keeper never has to sync anything first.");
        console.log("     A snapshot ROLLS AT MOST ONCE PER WINDOW, so extra calls in");
        console.log("     between are no-ops for the feed's snapshots (each one still");
        console.log("     syncs both pairs) and updatedAt does not advance: a stale");
        console.log("     reading is NoWoodPrice, and nothing proposes.");
        console.log("  2. Wait for latestRoundData() to answer (needs a second snapshot");
        console.log("     one full window after the baseline this script just recorded).");
        console.log("  3. DeployPlanB with WOOD_USD_FEED=<above> and a WOOD_FEED_MAX_DELAY");
        console.log("     that EXCEEDS window + %s s, i.e. above %s.", KEEPER_CADENCE, p.window + KEEPER_CADENCE);
        console.log("     Suggested WOOD_FEED_MAX_DELAY: %s", suggestedWoodFeedMaxDelay(p.window));
        console.log("     A tighter bound halts every read BETWEEN rolls, for up to a window.");
        console.log("     Pre-flight 8 enforces step 2; pre-flight 12 enforces this bound.");
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
    ///      be trading. The feed itself never needs a recent trade — `update()`
    ///      syncs each pair — but a pair with no trade in the last
    ///      `MAX_PAIR_IDLE` has no live market behind it, and the average of a
    ///      spot nobody is standing behind is a number, not a price. That is the
    ///      standing condition on a FORK, where the pools stop trading at the
    ///      fork point.
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
            idle <= MAX_PAIR_IDLE,
            "PRE-FLIGHT: pair has no trade in the last 5m - no live market is standing behind "
            "it. On a fork/vnet the pool does not trade at all: generate swaps, or wire a plain "
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
