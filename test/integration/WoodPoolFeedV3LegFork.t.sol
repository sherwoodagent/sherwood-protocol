// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WoodPoolFeed, IUniswapV2PairMinimal, IAggregatorMinimal} from "../../src/pricing/WoodPoolFeed.sol";
import {IUniswapV3Pool} from "../../src/vendor/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "../../src/vendor/uniswap/TickMath.sol";

/**
 * @title WoodPoolFeedV3LegForkTest
 * @notice `WoodPoolFeed` against the LIVE WOOD/WETH venues on Robinhood Chain
 *         mainnet (4663): the Uniswap V2 pair it snapshots and the Uniswap V3
 *         pool it reads through `observe`. The claim under test is the one the
 *         unit suite cannot make — that the two legs, read off real accumulators
 *         and a real observation ring, meet in the same scale, so `min` compares
 *         prices rather than units.
 *
 *         Both legs are recomputed HERE, from the pair's own cumulatives and the
 *         pool's own tick cumulatives, and the feed's answer is asserted equal to
 *         the lower of them. A scale or orientation error in either leg changes
 *         that equality by orders of magnitude.
 *
 *         On-chain facts (probed 2026-09-16): the V3 pool is fee 3000 /
 *         tickSpacing 60, liquidity 2.128e22, and reports `observationCardinality`
 *         1 — which is why the deploy ceremony grows it.
 *
 * @dev Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention);
 *      excluded from default CI via the `test/integration/**` path filter.
 *      Run explicitly:
 *        set -a; source .env; set +a
 *        export ROBINHOOD_RPC_URL="$TENDERLY_ROBINHOOD_RPC_URL"
 *        forge test --match-path "test/integration/WoodPoolFeedV3LegFork.t.sol" -vv
 */
contract WoodPoolFeedV3LegForkTest is Test {
    address constant WOOD = 0xF8BC08092C06dB6148114DCf82AF881F1085f92b;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V2_PAIR = 0xBF3BB81de6285b8310A028d1C2Cd38F9419d54C1;
    address constant V3_POOL = 0xF6831AaF374B353757F0dE6B3DD2a74697671C69;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    uint256 constant Q112 = 2 ** 112;
    uint256 constant WINDOW = 24 hours;
    uint256 constant MIN_WETH_RESERVE = 10e18;
    uint128 constant MIN_V3_LIQUIDITY = 1e22;
    /// @dev DELIBERATELY LOOSER THAN THE 24h DEPLOY DEFAULT. Spanning a window
    ///      costs a 24h warp, which ages the live Chainlink round by 24h on top
    ///      of whatever it carried at the fork point. The ETH leg's staleness
    ///      gate is exercised in the unit suite, where the clock is ours.
    uint256 constant ETH_USD_MAX_AGE = 3 days;
    /// @dev What the ceremony's `GrowV3Cardinality` step asks for: the uint16
    ///      ceiling, which is what a 24h window at 1s blocks derives to.
    uint16 constant GROWN_CARDINALITY = 65_535;
    /// @dev Robinhood blocks are ~1s, so the warp below is also this many blocks.
    uint256 constant AVG_BLOCK_TIME = 1;

    WoodPoolFeed internal feed;
    bool internal woodIsToken0V2;
    bool internal woodIsToken0Pool;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // 0 (the default) means "fork at latest" — the only mode the pruned
        // public RPC supports. A nonzero value pins, for an archive endpoint.
        uint256 forkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        uint256 expectedChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(4663));
        require(
            block.chainid == expectedChainId,
            string.concat(
                "wrong chain: got ",
                vm.toString(block.chainid),
                ", expected ",
                vm.toString(expectedChainId),
                " (set ROBINHOOD_FORK_CHAIN_ID for a Tenderly vnet)"
            )
        );

        woodIsToken0V2 = IUniswapV2PairMinimal(V2_PAIR).token0() == WOOD;
        woodIsToken0Pool = IUniswapV3Pool(V3_POOL).token0() == WOOD;
    }

    // ── The venues, as the address book claims them ──

    function test_theBookedVenuesHoldWoodAndWethAndClearTheirDepthFloors() public view {
        address v2Other =
            woodIsToken0V2 ? IUniswapV2PairMinimal(V2_PAIR).token1() : IUniswapV2PairMinimal(V2_PAIR).token0();
        assertEq(v2Other, WETH, "the booked V2 pair is not WOOD/WETH");

        address poolOther = woodIsToken0Pool ? IUniswapV3Pool(V3_POOL).token1() : IUniswapV3Pool(V3_POOL).token0();
        assertEq(poolOther, WETH, "the booked V3 pool is not WOOD/WETH");
        assertEq(IUniswapV3Pool(V3_POOL).fee(), 3000, "the booked V3 pool is not the 0.3% pool");
        assertEq(IUniswapV3Pool(V3_POOL).tickSpacing(), 60, "tick spacing moved");

        (uint112 r0, uint112 r1,) = IUniswapV2PairMinimal(V2_PAIR).getReserves();
        assertGe(woodIsToken0V2 ? r1 : r0, MIN_WETH_RESERVE, "the live V2 pair is below the deploy default floor");
        assertGe(IUniswapV3Pool(V3_POOL).liquidity(), MIN_V3_LIQUIDITY, "the live V3 pool is below MIN_V3_LIQUIDITY");
    }

    /// @dev The ceremony's remedy, exercised as the ceremony runs it: NO PRANK,
    ///      no owner, no allowlist — anyone may pay to lengthen the ring.
    function test_theCardinalityRemedyIsPermissionlessAndMonotonic() public {
        (,,, uint16 cardinality, uint16 cardinalityNext,,) = IUniswapV3Pool(V3_POOL).slot0();
        console2.log("live observationCardinality:     %s", cardinality);
        console2.log("live observationCardinalityNext: %s", cardinalityNext);

        IUniswapV3Pool(V3_POOL).increaseObservationCardinalityNext(GROWN_CARDINALITY);

        (,,, uint16 grown, uint16 grownNext,,) = IUniswapV3Pool(V3_POOL).slot0();
        assertGe(grownNext, GROWN_CARDINALITY, "the ring target did not rise");
        assertGe(grown, cardinality, "the ring shrank");

        // AND IT IS A TARGET, NOT A FILLED RING: nothing trades on a fork, so
        // `observationCardinality` does not move here and would not move on
        // mainnet either until the pool is written to.
        IUniswapV3Pool(V3_POOL).increaseObservationCardinalityNext(GROWN_CARDINALITY);
    }

    // ── The feed itself ──

    /// @dev THE POINT OF THE SUITE. Both legs are recomputed from the venues'
    ///      own state and the answer is asserted equal to the LOWER one.
    ///
    ///      A CAVEAT THE ASSERTION DOES NOT CARRY: `observe` answers here partly
    ///      because the fork is frozen — the whole window post-dates the pool's
    ///      last touch, so the ring extrapolates at the standing tick instead of
    ///      searching for an observation it does not have. That is a property of
    ///      a fork, NOT evidence that cardinality 1 serves a 24h window on a
    ///      trading chain. The deploy pre-flight asks the live pool, which is the
    ///      only place that question can be answered.
    function test_theFeedAnswersTheLowerOfTheTwoLiveLegsOnceTheWindowIsSpanned() public {
        IUniswapV3Pool(V3_POOL).increaseObservationCardinalityNext(GROWN_CARDINALITY);

        feed = new WoodPoolFeed(
            V2_PAIR, V3_POOL, WOOD, WETH, ETH_USD_FEED, ETH_USD_MAX_AGE, WINDOW, MIN_WETH_RESERVE, MIN_V3_LIQUIDITY
        );

        // One snapshot cannot span a window — this is what `DeployPlanB`
        // pre-flight 8 refuses until the keeper has run.
        feed.update();
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();

        uint256 c0 = _v2Cumulative();
        uint32 t0 = uint32(block.timestamp);

        vm.warp(block.timestamp + WINDOW + 1);
        vm.roll(block.number + (WINDOW + 1) / AVG_BLOCK_TIME);
        feed.update();

        uint256 c1 = _v2Cumulative();
        uint32 t1 = uint32(block.timestamp);

        uint256 v2X112;
        // The pair's accumulator wraps at 2^256; the wrapping difference is the
        // span's true accumulation, exactly as the feed reads it.
        unchecked {
            v2X112 = (c1 - c0) / (t1 - t0);
        }
        uint256 v3X112 = _v3LegX112();
        uint256 ethUsdX8 = _ethUsdX8();

        console2.log("V2 leg (WETH per WOOD, x8): %s", Math.mulDiv(v2X112, ethUsdX8, Q112));
        console2.log("V3 leg (WETH per WOOD, x8): %s", Math.mulDiv(v3X112, ethUsdX8, Q112));

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertGt(answer, 0, "the feed answers");
        assertEq(
            uint256(answer),
            Math.mulDiv(v2X112 < v3X112 ? v2X112 : v3X112, ethUsdX8, Q112),
            "the answer is the LOWER leg, converted through ETH/USD"
        );
        assertLe(uint256(answer), Math.mulDiv(v2X112, ethUsdX8, Q112), "above the V2 leg");
        assertLe(uint256(answer), Math.mulDiv(v3X112, ethUsdX8, Q112), "above the V3 leg");

        // The live V3 leg never dates the reading forward: `updatedAt` is the
        // OLDER of the two, i.e. the V2 snapshot the keeper just rolled.
        assertEq(updatedAt, t1, "updatedAt is the V2 snapshot");

        // Both legs price the same asset in the same units. An orientation or
        // scale error in either shows up as orders of magnitude here, long
        // before `min` could hide it.
        assertLe(v2X112, v3X112 * 1000, "the two legs are not in the same scale");
        assertLe(v3X112, v2X112 * 1000, "the two legs are not in the same scale");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _v2Cumulative() internal view returns (uint256) {
        return woodIsToken0V2
            ? IUniswapV2PairMinimal(V2_PAIR).price0CumulativeLast()
            : IUniswapV2PairMinimal(V2_PAIR).price1CumulativeLast();
    }

    /// @dev The V3 leg, computed here rather than read off the feed: mean tick
    ///      over the window, floored, then converted to WETH per WOOD in X112.
    function _v3LegX112() internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = uint32(WINDOW);
        (int56[] memory cumulatives,) = IUniswapV3Pool(V3_POOL).observe(secondsAgos);

        int256 span = int256(WINDOW);
        int256 delta = int256(cumulatives[1]) - int256(cumulatives[0]);
        int256 mean = delta / span;
        if (delta < 0 && delta % span != 0) --mean;

        uint256 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(int24(mean));
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = sqrtRatioX96 * sqrtRatioX96;
            return woodIsToken0Pool ? Math.mulDiv(ratioX192, Q112, 1 << 192) : Math.mulDiv(1 << 192, Q112, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return woodIsToken0Pool ? Math.mulDiv(ratioX128, Q112, 1 << 128) : Math.mulDiv(1 << 128, Q112, ratioX128);
    }

    function _ethUsdX8() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorMinimal(ETH_USD_FEED).latestRoundData();
        assertGt(answer, 0, "the live ETH/USD feed is not answering");
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        assertLe(age, ETH_USD_MAX_AGE, "the live ETH/USD round aged past the suite's bound across the warp");
        uint8 dec = IAggregatorMinimal(ETH_USD_FEED).decimals();
        return (uint256(answer) * 1e8) / (10 ** dec);
    }
}
