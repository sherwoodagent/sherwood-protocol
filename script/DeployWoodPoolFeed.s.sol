// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {WoodPoolFeed, IUniswapV2PairMinimal, IAggregatorMinimal} from "../src/pricing/WoodPoolFeed.sol";
import {IUniswapV3Pool} from "../src/vendor/uniswap/IUniswapV3Pool.sol";

/**
 * @title  DeployWoodPoolFeed
 * @notice Deploys the `WoodPoolFeed` that `ExposureLedger` prices WOOD against.
 *         Runs BEFORE `DeployPlanB`, whose pre-flight 8 refuses a ledger with no
 *         live WOOD price source.
 *
 *         There is no Chainlink WOOD/USD feed on chain 4663. This contract is
 *         one: it reads WOOD priced in ETH off two WOOD/WETH venues — a
 *         Uniswap-V2-style pair's cumulative-price accumulators and a Uniswap V3
 *         pool's observation ring — takes the LOWER of the two long-window
 *         averages, and converts to USD through the chain's ETH/USD Chainlink
 *         feed. It is wired at the ledger with `setWoodFeed`, exactly like a real
 *         aggregator.
 *
 *   Ceremony position (openspec/specs/deployment-docs/spec.md):
 *     core (3 phases) -> GrowV3Cardinality (below) -> THIS -> run the keeper
 *     until latestRoundData() answers -> DeployPlanB
 *
 *   Address book (read from chains/{chainId}.json, each overridable by an env var
 *   of the same name):
 *     WOOD_WETH_V2_PAIR          — the Uniswap V2 pair holding exactly {WOOD, WETH}
 *     WOOD_WETH_UNISWAP_V3_POOL  — the Uniswap V3 pool, the same two tokens
 *     WOOD_TOKEN, WETH
 *     CHAINLINK_ETH_USD_FEED     — the ETH leg
 *
 *   Environment:
 *     TWAP_WINDOW            — averaging window (default and minimum 24h)
 *     ETH_USD_MAX_AGE        — staleness bound on the ETH leg (default 24h)
 *     MIN_WETH_RESERVE       — the V2 leg's depth floor, in WETH wei (default 10e18)
 *     MIN_V3_LIQUIDITY       — the V3 leg's depth floor, in in-range liquidity
 *                              (default 1e22)
 *     AVG_BLOCK_TIME_SECONDS — seconds per block, used only to derive the
 *                              cardinality this script prints as the remedy
 *                              (default 1)
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
    /// @dev The V3 leg's depth floor, in in-range liquidity: half of what the
    ///      live WOOD/WETH V3 pool carries today.
    uint128 constant DEFAULT_MIN_V3_LIQUIDITY = 1e22;
    /// @dev DEPLOY POLICY ONLY, not a feed parameter: how stale a pair's last
    ///      trade may be for this script to accept it as a live market.
    uint256 constant MAX_PAIR_IDLE = 5 minutes;
    /// @dev The keeper cadence the runbook assumes, and the slack `DeployPlanB`
    ///      pre-flight 12 adds to the window when bounding WOOD_FEED_MAX_DELAY.
    ///      Keep in step with `DeployPlanB.KEEPER_CADENCE_SLACK`.
    uint256 constant KEEPER_CADENCE = 2 hours;
    /// @dev Seconds per block on a Robinhood/Arbitrum-class chain. DERIVATION
    ///      INPUT ONLY: nothing is enforced against it.
    uint256 constant DEFAULT_AVG_BLOCK_TIME = 1;
    /// @dev Observations asked for beyond the window's own worth, so a slow
    ///      block or a second write in the same second cannot clip the tail.
    uint256 constant CARDINALITY_SLACK = 10;
    /// @dev A pool indexes its observation ring with a uint16, so this is the
    ///      most history any V3 pool can ever hold.
    uint16 constant MAX_CARDINALITY = type(uint16).max;

    /// @notice The `WOOD_FEED_MAX_DELAY` an operator should seat for a feed with
    ///         this window: a snapshot rolls at most once per window, so the
    ///         bound has to clear a whole window plus the keeper's cadence.
    function suggestedWoodFeedMaxDelay(uint256 window) public pure returns (uint256) {
        return window + KEEPER_CADENCE + 1;
    }

    /// @notice The `increaseObservationCardinalityNext(N)` a pool needs to hold a
    ///         whole `window` of history, and whether that N is the ring's hard
    ///         ceiling rather than the derivation.
    /// @dev    `capped == true` is not a smaller ask, it is a DIFFERENT claim: at
    ///         65535 observations the ring spans only as much time as those
    ///         observations cover, which on a pool touched every 1s block is
    ///         ~18h12m — less than a 24h window. Which is why the pre-flight
    ///         below asks the pool itself rather than trusting this number.
    function requiredCardinality(uint256 window_, uint256 avgBlockTime) public pure returns (uint16 n, bool capped) {
        require(avgBlockTime != 0, "PRE-FLIGHT: AVG_BLOCK_TIME_SECONDS zero");
        uint256 needed = (window_ + avgBlockTime - 1) / avgBlockTime + CARDINALITY_SLACK;
        capped = needed > MAX_CARDINALITY;
        // Bounded by `MAX_CARDINALITY` on the capped branch; the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        n = capped ? MAX_CARDINALITY : uint16(needed);
    }

    /// @notice `MIN_V3_LIQUIDITY` narrowed to the width a pool reports liquidity
    ///         in.
    /// @dev    A silent truncation here WEAKENS the floor — 2**128 would wrap to
    ///         zero, i.e. no floor at all — so it is refused rather than clamped.
    function toMinV3Liquidity(uint256 raw) public pure returns (uint128) {
        require(raw <= type(uint128).max, "PRE-FLIGHT: MIN_V3_LIQUIDITY above uint128");
        // Bounded directly above; the cast cannot change the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(raw);
    }

    struct Params {
        address uniPair;
        address v3Pool;
        address wood;
        address weth;
        address ethUsdFeed;
        uint256 window;
        uint256 ethUsdMaxAge;
        uint256 minWethReserve;
        uint128 minV3Liquidity;
    }

    /// @notice Thin env adapter. `deploy()` takes the params as an argument so
    ///         the tests never touch `vm.setEnv`.
    function run() external {
        WoodPoolFeed feed = deploy(
            Params({
                uniPair: vm.envOr("WOOD_WETH_V2_PAIR", _readAddress("WOOD_WETH_V2_PAIR")),
                // TOLERANT BOOK READ, unlike its neighbours: `vm.envOr`'s default
                // is evaluated EAGERLY, so a strict `_readAddress` would revert on
                // a book missing this key even when the env var supplies it — and
                // would do it with a JSON parse error instead of the named
                // pre-flight below.
                v3Pool: vm.envOr("WOOD_WETH_UNISWAP_V3_POOL", _optionalAddress("WOOD_WETH_UNISWAP_V3_POOL")),
                wood: vm.envOr("WOOD_TOKEN", _readAddress("WOOD_TOKEN")),
                weth: vm.envOr("WETH", _readAddress("WETH")),
                ethUsdFeed: vm.envOr("CHAINLINK_ETH_USD_FEED", _readAddress("CHAINLINK_ETH_USD_FEED")),
                window: vm.envOr("TWAP_WINDOW", DEFAULT_TWAP_WINDOW),
                ethUsdMaxAge: vm.envOr("ETH_USD_MAX_AGE", DEFAULT_ETH_USD_MAX_AGE),
                minWethReserve: vm.envOr("MIN_WETH_RESERVE", DEFAULT_MIN_WETH_RESERVE),
                minV3Liquidity: toMinV3Liquidity(vm.envOr("MIN_V3_LIQUIDITY", uint256(DEFAULT_MIN_V3_LIQUIDITY)))
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
        // The constructor derives which side of each venue holds WOOD from the
        // venue itself, and refuses one that is not exactly {WOOD, WETH}.
        feed = new WoodPoolFeed(
            p.uniPair,
            p.v3Pool,
            p.wood,
            p.weth,
            p.ethUsdFeed,
            p.ethUsdMaxAge,
            p.window,
            p.minWethReserve,
            p.minV3Liquidity
        );
        // The first call only ever lays a baseline on the V2 pair; `latestRoundData`
        // still needs a SECOND snapshot a full window later, which is the keeper's
        // job. Permissionless, so doing it here costs one call and saves a step.
        feed.update();
        vm.stopBroadcast();

        console.log("WoodPoolFeed:      %s", address(feed));
        console.log("uni pair:          %s", p.uniPair);
        console.log("v3 pool:           %s", p.v3Pool);
        console.log("window (s):        %s", p.window);
        console.log("minWethReserve:    %s", p.minWethReserve);
        console.log("minV3Liquidity:    %s", p.minV3Liquidity);

        // INSTANTANEOUS SPOT, FOR SIZING THE CAP ONLY — the manipulable quantity
        // the averaging exists to defeat, never a price. It is printed because the
        // operator's next decision is `WOOD_PRICE_CAP_X8`, which the runbook
        // requires to sit 1.25-2x ABOVE market.
        uint256 spotX8 = _spotWoodUsdX8(p, p.uniPair);
        console.log("spot WOOD/USD x8 (cap-sizing only, NOT a price): %s", spotX8);
        console.log("suggested WOOD_PRICE_CAP_X8 band 1.25-2x: %s .. %s", (spotX8 * 125) / 100, spotX8 * 2);

        console.log("\nNOTE: this deploy transaction's update() WRITES to the live V2 pair");
        console.log("      (permissionless sync()), it does not only read it. The V3 leg is");
        console.log("      read-only: it stores nothing here and needs no keeper.");
        console.log("\nNEXT, IN ORDER:");
        console.log("  1. Run the keeper: WoodPoolFeed.update(), permissionless, at least");
        console.log("     once per window + %s s. That single call is the whole job:", KEEPER_CADENCE);
        console.log("     update() sync()s THE V2 PAIR itself, so a pair that has not traded");
        console.log("     still snapshots and the keeper never has to sync anything first.");
        console.log("     A snapshot ROLLS AT MOST ONCE PER WINDOW, so extra calls in");
        console.log("     between are no-ops for the feed's snapshots (each one still");
        console.log("     syncs the V2 pair) and updatedAt does not advance: a stale");
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
        require(p.v3Pool != address(0), "PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL unset");
        require(p.uniPair != p.v3Pool, "PRE-FLIGHT: the V2 pair and the V3 pool are the same address");
        require(p.wood != address(0), "PRE-FLIGHT: WOOD_TOKEN unset");
        require(p.weth != address(0), "PRE-FLIGHT: WETH unset");
        require(p.ethUsdFeed != address(0), "PRE-FLIGHT: CHAINLINK_ETH_USD_FEED unset");

        require(p.window >= 24 hours, "PRE-FLIGHT: TWAP_WINDOW below MIN_WINDOW (24h)");
        require(p.window <= 7 days, "PRE-FLIGHT: TWAP_WINDOW above MAX_SNAPSHOT_SPAN (7d)");
        require(p.ethUsdMaxAge != 0, "PRE-FLIGHT: ETH_USD_MAX_AGE zero");
        require(p.minWethReserve != 0, "PRE-FLIGHT: MIN_WETH_RESERVE zero");
        require(p.minV3Liquidity != 0, "PRE-FLIGHT: MIN_V3_LIQUIDITY zero");

        // WOOD AND WETH MUST SHARE A DECIMALS COUNT: the feed multiplies the
        // pairs' raw UQ112x112 ratio by ETH/USD with no decimals normalisation.
        require(
            IERC20Metadata(p.wood).decimals() == IERC20Metadata(p.weth).decimals(),
            "PRE-FLIGHT: WOOD and WETH decimals differ - the feed does not normalise them"
        );

        _preflightPair(p, p.uniPair);
        _preflightV3Pool(p);
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

    /// @dev The V3 leg carries no reserves and no last-trade stamp: its depth is
    ///      the in-range liquidity standing behind the tick, and its liveness is
    ///      the observation ring, asked here rather than assumed.
    function _preflightV3Pool(Params memory p) internal view {
        require(p.v3Pool.code.length != 0, "PRE-FLIGHT: V3 pool has no code");

        address t0 = IUniswapV3Pool(p.v3Pool).token0();
        address t1 = IUniswapV3Pool(p.v3Pool).token1();
        require(
            (t0 == p.wood && t1 == p.weth) || (t0 == p.weth && t1 == p.wood),
            "PRE-FLIGHT: V3 pool does not hold exactly {WOOD, WETH}"
        );
        require(
            IUniswapV3Pool(p.v3Pool).liquidity() >= p.minV3Liquidity, "PRE-FLIGHT: V3 pool is below MIN_V3_LIQUIDITY"
        );

        // `fee()` answering is what separates a V3 pool from any contract that
        // happens to carry the two token getters.
        console.log("v3 pool fee (1e-6):        %s", IUniswapV3Pool(p.v3Pool).fee());
        _preflightV3Cardinality(p);
    }

    /// @dev THE CHECK THE CEREMONY'S CARDINALITY STEP EXISTS FOR. A ring that
    ///      cannot serve `window` deploys a feed whose V3 leg reverts from every
    ///      read, i.e. no WOOD price at all. The remedy is printed FIRST, and
    ///      unconditionally, because it is also what an operator sizes
    ///      `V3_CARDINALITY` from on the happy path.
    function _preflightV3Cardinality(Params memory p) internal view {
        (,,, uint16 cardinality, uint16 cardinalityNext,,) = IUniswapV3Pool(p.v3Pool).slot0();
        uint256 avgBlockTime = vm.envOr("AVG_BLOCK_TIME_SECONDS", DEFAULT_AVG_BLOCK_TIME);
        (uint16 n, bool capped) = requiredCardinality(p.window, avgBlockTime);

        console.log("v3 observationCardinality: %s (next %s)", cardinality, cardinalityNext);
        console.log("required for a %s s window at %s s blocks: %s", p.window, avgBlockTime, n);
        if (capped) {
            console.log("  ^ THAT IS THE uint16 CEILING, NOT THE DERIVATION. A pool indexes its");
            console.log("    ring with a uint16, so 65535 observations is the most it can hold, and");
            console.log("    the ring spans only what those observations cover: ONE PER BLOCK IN");
            console.log("    WHICH THE POOL IS TOUCHED. At 1s blocks with continuous trading that");
            console.log("    is ~18h12m - LESS than a 24h window, and observe() keeps reverting. A");
            console.log("    pool touched less often than every block spans proportionally longer,");
            console.log("    which is why the check below asks the pool instead of this number.");
        }
        console.log("  remedy (permissionless): increaseObservationCardinalityNext(%s), i.e.", n);
        console.log("    V3_CARDINALITY=%s forge script script/DeployWoodPoolFeed.s.sol:GrowV3Cardinality \\", n);
        console.log("      --rpc-url robinhood --account sherwood-deployer --broadcast --slow");
        console.log("    then WAIT: `next` is a target the ring reaches only as the pool is traded.");

        uint32[] memory secondsAgos = new uint32[](2);
        // `p.window` is bounded by MAX_SNAPSHOT_SPAN (7d) above.
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsAgos[0] = uint32(p.window);
        try IUniswapV3Pool(p.v3Pool).observe(secondsAgos) returns (int56[] memory cumulatives, uint160[] memory) {
            require(cumulatives.length == 2, "PRE-FLIGHT: V3 pool cannot span TWAP_WINDOW");
        } catch {
            revert("PRE-FLIGHT: V3 pool cannot span TWAP_WINDOW");
        }
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

/**
 * @title  GrowV3Cardinality
 * @notice Grows the WOOD/WETH V3 pool's observation ring so it can serve
 *         `TWAP_WINDOW`. A NAMED CEREMONY STEP, run BEFORE `DeployWoodPoolFeed`,
 *         because that script's cardinality pre-flight refuses a pool whose
 *         `observe(window)` reverts — and because the call is permissionless,
 *         costs the pool's next writers the slots' initialisation gas, and is
 *         monotonic, so it can be run early and repeated harmlessly.
 *
 *   Address book / environment:
 *     WOOD_WETH_UNISWAP_V3_POOL — the pool (env override first, book second)
 *     V3_CARDINALITY            — REQUIRED. The N to ask for; size it from the
 *                                 `required for a <window> s window` line
 *                                 `DeployWoodPoolFeed` prints.
 *
 *   Usage:
 *     V3_CARDINALITY=65535 forge script \
 *       script/DeployWoodPoolFeed.s.sol:GrowV3Cardinality \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast --slow
 *
 * @dev THE GROWTH IS NOT INSTANT. `increaseObservationCardinalityNext` raises a
 *      TARGET; the ring reaches it one slot at a time, as the pool is traded.
 *      `observationCardinality` is what `observe` can actually serve.
 */
contract GrowV3Cardinality is ScriptBase {
    function run() external {
        grow(
            vm.envOr("WOOD_WETH_UNISWAP_V3_POOL", _optionalAddress("WOOD_WETH_UNISWAP_V3_POOL")),
            vm.envOr("V3_CARDINALITY", uint256(0))
        );
    }

    /// @notice Pre-flights and broadcasts the growth. Public so the tests can
    ///         drive the real thing without the process environment.
    function grow(address pool, uint256 target) public {
        require(pool != address(0), "PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL unset");
        require(pool.code.length != 0, "PRE-FLIGHT: V3 pool has no code");
        require(target != 0, "PRE-FLIGHT: V3_CARDINALITY unset");
        require(target <= type(uint16).max, "PRE-FLIGHT: V3_CARDINALITY above the uint16 ceiling (65535)");

        (,,, uint16 cardinality, uint16 cardinalityNext,,) = IUniswapV3Pool(pool).slot0();
        console.log("v3 pool:                    %s", pool);
        console.log("observationCardinality:     %s", cardinality);
        console.log("observationCardinalityNext: %s", cardinalityNext);

        if (cardinality >= target || cardinalityNext >= target) {
            console.log("already at or above V3_CARDINALITY (%s) - nothing broadcast", target);
            return;
        }

        vm.startBroadcast();
        // Bounded against the uint16 ceiling above; the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(uint16(target));
        vm.stopBroadcast();

        (,,, uint16 grown, uint16 grownNext,,) = IUniswapV3Pool(pool).slot0();
        console.log("-> observationCardinality:     %s", grown);
        console.log("-> observationCardinalityNext: %s", grownNext);
        console.log("\nTHE RING IS NOT YET THAT LONG. `next` is a target the pool fills one");
        console.log("observation at a time, as it is traded; `observationCardinality` rises");
        console.log("behind it. Until it does, observe(window) still reverts and");
        console.log("DeployWoodPoolFeed's cardinality pre-flight still refuses - which is the");
        console.log("honest signal that the window is not yet spannable, not a script bug.");
    }
}
