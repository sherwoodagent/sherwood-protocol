// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WoodPoolFeed, IUniswapV2PairMinimal, IAggregatorMinimal} from "../../src/pricing/WoodPoolFeed.sol";
import {IUniswapV3Pool} from "../../src/vendor/uniswap/IUniswapV3Pool.sol";

/**
 * @title WoodPoolFeedV3LegForkTest
 * @notice `WoodPoolFeed` against the LIVE WOOD/WETH venues on Robinhood Chain
 *         mainnet (4663): the Uniswap V2 pair it snapshots and the Uniswap V3
 *         pool whose tick accumulator it snapshots. The claim under test is the
 *         one the unit suite cannot make — that the two legs, read off real
 *         accumulators, meet in the same scale, so `min` compares prices rather
 *         than units.
 *
 *         Both legs are recomputed HERE without reusing the feed's arithmetic —
 *         the pair's own cumulative-price delta, and the pool's own
 *         `slot0().sqrtPriceX96` rather than a second copy of the mean-tick math
 *         — and the feed's answer is asserted to be the lower of them. A scale or
 *         orientation error in either leg misses by orders of magnitude.
 *
 *         On-chain facts (probed 2026-09-16): the V3 pool is fee 3000 /
 *         tickSpacing 60, liquidity 2.128e22, and reports `observationCardinality`
 *         1 — which the snapshotting V3 leg does not care about.
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
    /// @dev Only shapes `vm.roll`, so the block number advances with the clock.
    ///      Nothing under test reads a block number — the observation ring and
    ///      both accumulators are keyed on timestamps.
    uint256 constant ROLL_SECONDS_PER_BLOCK = 1;

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

    // ── The feed itself ──

    /// @dev THE POINT OF THE SUITE. Both legs are recomputed from the venues'
    ///      own state — the pair's accumulators and the pool's `slot0` price,
    ///      neither of them the feed's own machinery — and the answer is asserted
    ///      to be the LOWER one.
    ///
    ///      WHAT THAT DOES AND DOES NOT ESTABLISH. The fork is frozen, so BOTH
    ///      legs here report the standing price rather than an average over live
    ///      history: what this suite pins is that the two machineries agree on
    ///      SCALE AND ORIENTATION against real venues, so `min` compares prices
    ///      and not units. Averaging behaviour is the unit suite's claim, where
    ///      the price history is ours to write.
    function test_theFeedAnswersTheLowerOfTheTwoLiveLegsOnceTheWindowIsSpanned() public {
        feed = new WoodPoolFeed(
            V2_PAIR, V3_POOL, WOOD, WETH, ETH_USD_FEED, ETH_USD_MAX_AGE, WINDOW, MIN_WETH_RESERVE, MIN_V3_LIQUIDITY
        );

        // One snapshot cannot span a window — this is what `DeployPlanB`
        // pre-flight 8 refuses until the keeper has run.
        feed.update();
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();

        uint256 c0 = _v2Cumulative();
        // `vm.getBlockTimestamp()`, never a cached `block.timestamp`: the two
        // reads straddle a warp and the optimizer folds them into one.
        uint256 t0 = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        vm.roll(block.number + (WINDOW + 1) / ROLL_SECONDS_PER_BLOCK);
        feed.update();

        uint256 c1 = _v2Cumulative();
        uint256 t1 = vm.getBlockTimestamp();

        uint256 v2X112;
        // The pair's accumulator wraps at 2^256; the wrapping difference is the
        // span's true accumulation, exactly as the feed reads it.
        unchecked {
            v2X112 = (c1 - c0) / (t1 - t0);
        }
        uint256 v3X112 = _v3SpotX112();
        uint256 ethUsdX8 = _ethUsdX8();

        console2.log("V2 leg (WETH per WOOD, x8): %s", Math.mulDiv(v2X112, ethUsdX8, Q112));
        console2.log("V3 leg (WETH per WOOD, x8): %s", Math.mulDiv(v3X112, ethUsdX8, Q112));

        // READ LATER THAN THE SNAPSHOT, so `updatedAt` is distinguishable from
        // the block it is read in.
        vm.warp(vm.getBlockTimestamp() + 30);
        vm.roll(block.number + 30 / ROLL_SECONDS_PER_BLOCK);

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertGt(answer, 0, "the feed answers");
        // APPROXIMATE BY CONSTRUCTION, not by sloppiness: the expected value here
        // comes from `slot0().sqrtPriceX96`, the exact price INSIDE the current
        // tick, while the feed prices the tick itself. One tick is 0.01%, so the
        // two can differ by up to that and no more — a scale or orientation error
        // in either leg misses by orders of magnitude, not by a tick.
        assertApproxEqRel(
            uint256(answer),
            Math.mulDiv(v2X112 < v3X112 ? v2X112 : v3X112, ethUsdX8, Q112),
            5e14,
            "the answer is the LOWER leg, converted through ETH/USD"
        );
        // IMPLIED BY `min`, not a second measurement: this holds even if the V3
        // leg were deleted. The discriminating claim is the approximate equality
        // above, which pins WHICH leg was taken — the two differ by ~0.06%, so
        // `min` and `max` are distinguishable there and not here.
        assertLe(uint256(answer), Math.mulDiv(v2X112, ethUsdX8, Q112), "above the V2 leg");

        // `updatedAt` is the OLDER of the two legs, i.e. the snapshot the keeper
        // rolled 30s ago, never the block the read happens in.
        assertEq(updatedAt, t1, "updatedAt is the snapshot");
        assertLt(updatedAt, vm.getBlockTimestamp(), "control: the two legs' stamps are distinguishable");

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

    /// @dev The V3 leg's expected value, derived INDEPENDENTLY of the feed: from
    ///      `slot0().sqrtPriceX96` — the pool's own standing price — rather than
    ///      from `observe`, `TickMath` and a mean-tick calculation, which would
    ///      only be the feed's own arithmetic written twice.
    ///
    ///      Legitimate here precisely because the fork is frozen: nothing trades,
    ///      so both accumulator readings sit at the standing tick and the span's
    ///      mean tick IS that tick. The remaining gap is sub-tick —
    ///      `sqrtPriceX96` sits inside the tick, the feed prices the tick's own
    ///      boundary — which is why the caller asserts approximately. On a chain
    ///      where the pool is trading this derivation would NOT hold.
    function _v3SpotX112() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(V3_POOL).slot0();
        assertGt(sqrtPriceX96, 0, "the live V3 pool reports no price");

        // token1 per token0, in X112: (sqrtP / 2**96)**2 * 2**112, split across
        // two mulDivs so the square never has to fit a uint256 on its own.
        uint256 token1PerToken0X112 = Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96), Q112, 1 << 96);
        // WETH per WOOD, in the V2 leg's orientation.
        return woodIsToken0Pool ? token1PerToken0X112 : Math.mulDiv(Q112, Q112, token1PerToken0X112);
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
