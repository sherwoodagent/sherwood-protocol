// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WoodV3TwapFeed} from "src/pricing/WoodV3TwapFeed.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {MockUniswapV3Pool} from "test/mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3PoolRing} from "test/mocks/MockUniswapV3PoolRing.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

/// @dev A pool whose `observe` hands back a seated cumulative delta, so a test can
///      give the feed a delta that does not divide by the window.
contract SeatedCumulativesPool {
    address public immutable token0;
    address public immutable token1;
    uint128 public liquidity = 2e22;
    int56 internal immutable _delta;
    uint16 internal immutable _ringTarget;

    constructor(address token0_, address token1_, int56 delta_, uint16 ringTarget_) {
        (token0, token1, _delta, _ringTarget) = (token0_, token1_, delta_, ringTarget_);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, _ringTarget, _ringTarget, 0, true);
    }

    function observe(uint32[] calldata) external view returns (int56[] memory c, uint160[] memory s) {
        c = new int56[](2);
        s = new uint160[](2);
        c[1] = _delta;
    }
}

abstract contract WoodV3TwapFeedFixture is Test {
    address internal constant WOOD = address(uint160(0xD00D));
    address internal constant WETH = address(uint160(0xE7E7));

    uint128 internal constant MIN_V3_LIQUIDITY = 1e22;
    uint128 internal constant V3_LIQUIDITY = 2e22;
    uint32 internal constant WINDOW = 1 hours;
    /// @dev One slot more than the window has seconds: the smallest ring that cannot be evicted.
    uint16 internal constant RING = uint16(WINDOW) + 1;
    uint256 internal constant ETH_MAX_AGE = 26 hours;
    int256 internal constant ETH_USD_X8 = 3000e8;

    /// @dev Expected answers are `1.0001 ** tick * ETH/USD`, computed off chain at 120 digits:
    ///      tick -136339 is 359,989.43 and one tick is 36 units, so `+-1` pins the tick.
    int24 internal constant TICK = -136_339;
    int24 internal constant TICKS_PER_DOUBLING = 6932;
    uint256 internal constant ANSWER_X8 = 359_989;
    /// @dev 1e-6 relative, a hundredth of a tick, for answers too large to pin to the unit.
    uint256 internal constant HUNDREDTH_OF_A_TICK = 1e12;

    MockAggregatorV3 internal ethUsd;

    function _newPool(address token0, address token1, int24 twapTick) internal returns (MockUniswapV3Pool p) {
        p = new MockUniswapV3Pool(token0, token1, 3000, 60, makeAddr("v3Factory"));
        p.setLiquidity(V3_LIQUIDITY);
        p.setTicks(twapTick, twapTick);
        p.increaseObservationCardinalityNext(RING);
    }

    function _feed(address pool) internal returns (WoodV3TwapFeed) {
        return new WoodV3TwapFeed(pool, WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_V3_LIQUIDITY);
    }

    /// @dev A feed over a pool whose cumulative delta across the window is `delta`.
    function _seated(address token0, address token1, int256 delta) internal returns (WoodV3TwapFeed) {
        return _feed(address(new SeatedCumulativesPool(token0, token1, int56(delta), RING)));
    }

    function _answer(WoodV3TwapFeed feed) internal view returns (uint256) {
        (, int256 a,,,) = feed.latestRoundData();
        return uint256(a);
    }
}

contract WoodV3TwapFeedTest is WoodV3TwapFeedFixture {
    MockUniswapV3Pool internal pool;
    WoodV3TwapFeed internal feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        pool = _newPool(WOOD, WETH, TICK);
        feed = _feed(address(pool));
    }

    /// @notice The answer is the pool's mean tick over the window, in USD at 8 decimals.
    function test_answersTheWindowMeanTickInUsd() public view {
        assertApproxEqAbs(_answer(feed), ANSWER_X8, 1);
        assertEq(feed.decimals(), 8);
    }

    /// @notice A pool holding WOOD as token1 prices WETH in WOOD, and the feed inverts it.
    function test_answersTheSamePriceWhenWoodIsToken1() public {
        assertApproxEqAbs(_answer(_feed(address(_newPool(WETH, WOOD, -TICK)))), ANSWER_X8, 1);
    }

    /// @notice Spot standing at twice the average does not move the answer.
    function test_readsTheAverageNotSpot() public {
        pool.setTicks(TICK + TICKS_PER_DOUBLING, TICK);
        assertApproxEqAbs(_answer(feed), ANSWER_X8, 1);
    }

    /// @notice A negative mean tick with a remainder floors: -136333.94 answers tick -136334.
    function test_floorsANegativeMeanTick() public {
        // 1000 s at -136339 and 2600 s at -136332. Truncation would answer 360,205.
        assertApproxEqAbs(_answer(_seated(WOOD, WETH, -490_802_200)), 360_169, 1);
    }

    /// @notice A positive mean tick with a remainder truncates: the live ordering, WOOD as token1.
    function test_truncatesAPositiveMeanTick() public {
        // 134892.06: one tick up answers 415,993 and one tick down 416,076.
        assertApproxEqAbs(_answer(_seated(WETH, WOOD, int256(134_892) * 3600 + 200)), 416_034, 1);
    }

    /// @notice Ticks whose sqrt ratio exceeds 128 bits price correctly with WOOD as token0.
    function test_pricesTicksAboveThe128BitSqrtRatio_woodToken0() public {
        int24[3] memory ticks = [int24(443_636), 443_637, 500_000];
        uint256[3] memory want = [
            uint256(5533815213329311058932902868619),
            5534368594850643990038796158906,
            1551528244611720291467448567639037
        ];
        for (uint256 i = 0; i < ticks.length; i++) {
            uint256 answer = _answer(_seated(WOOD, WETH, int256(ticks[i]) * 3600));
            assertApproxEqRel(answer, want[i], HUNDREDTH_OF_A_TICK);
        }
    }

    /// @notice The same ticks price correctly through the reciprocal, with WOOD as token1.
    function test_pricesTicksAboveThe128BitSqrtRatio_woodToken1() public {
        ethUsd.setAnswer(1e30); // keeps the reciprocal above zero at 8 decimals
        int24[3] memory ticks = [int24(443_636), 443_637, 500_000];
        uint256[3] memory want = [uint256(54212146310), 54206725638, 193357743];
        for (uint256 i = 0; i < ticks.length; i++) {
            uint256 answer = _answer(_seated(WETH, WOOD, int256(ticks[i]) * 3600));
            assertApproxEqRel(answer, want[i], HUNDREDTH_OF_A_TICK);
        }
    }

    /// @notice A very negative tick keeps full precision: the 192-bit path, not the 128-bit one.
    function test_keepsPrecisionAtAVeryNegativeTick() public {
        uint256 answer = _answer(_seated(WETH, WOOD, int256(-800_000) * 3600));
        assertApproxEqRel(answer, 16555516896855108776054083970761486128801599337, HUNDREDTH_OF_A_TICK);
    }

    /// @notice A 30 minute feed observes and divides by its own window, not by an hour.
    function test_answersOverAWindowOtherThanAnHour() public {
        WoodV3TwapFeed halfHour =
            new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, 30 minutes, MIN_V3_LIQUIDITY);

        assertEq(halfHour.window(), 30 minutes);
        assertApproxEqAbs(_answer(halfHour), ANSWER_X8, 1);
    }

    /// @notice An ETH/USD feed of 6 or of 18 decimals gives the same answer as one of 8.
    function test_normalisesTheEthFeedDecimals() public {
        ethUsd = new MockAggregatorV3(6, 3000e6);
        assertApproxEqAbs(_answer(_feed(address(pool))), ANSWER_X8, 1);

        ethUsd = new MockAggregatorV3(18, 3000e18);
        assertApproxEqAbs(_answer(_feed(address(pool))), ANSWER_X8, 1);
    }

    /// @notice `updatedAt` is the read time: the pool leg needs no call to stay fresh.
    function test_updatedAtIsTheReadTime() public {
        vm.warp(vm.getBlockTimestamp() + 10 days);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());

        (,, uint256 startedAt, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, vm.getBlockTimestamp());
        assertEq(startedAt, vm.getBlockTimestamp());
    }

    /// @notice In-range liquidity below the floor is refused; exactly the floor answers.
    function test_revertsBelowTheLiquidityFloor() public {
        pool.setLiquidity(MIN_V3_LIQUIDITY);
        assertApproxEqAbs(_answer(feed), ANSWER_X8, 1);

        pool.setLiquidity(MIN_V3_LIQUIDITY - 1);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice An ETH/USD round older than the max age is refused; exactly the max age answers.
    function test_revertsOnAStaleEthLeg() public {
        uint256 published = vm.getBlockTimestamp();
        vm.warp(published + ETH_MAX_AGE);
        assertApproxEqAbs(_answer(feed), ANSWER_X8, 1);

        vm.warp(published + ETH_MAX_AGE + 1);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice An ETH/USD round dated in the future reads as age zero, not as an underflow.
    function test_answersOnAFutureDatedEthRound() public {
        ethUsd.setUpdatedAt(vm.getBlockTimestamp() + 100);
        assertApproxEqAbs(_answer(feed), ANSWER_X8, 1);
    }

    /// @notice A negative ETH/USD answer is refused before it is cast.
    function test_revertsOnANegativeEthAnswer() public {
        ethUsd.setAnswer(-1);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice A pool that cannot serve the window makes the feed unavailable, never wrong.
    function test_revertsWhenThePoolCannotServeTheWindow() public {
        pool.setObserveReverts(true);
        vm.expectRevert(bytes("OLD"));
        feed.latestRoundData();
    }

    /// @notice A price that rounds to zero at 8 decimals is unavailable, not zero.
    function test_revertsWhenThePriceRoundsToZero() public {
        WoodV3TwapFeed dust = _feed(address(_newPool(WOOD, WETH, -800_000)));
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        dust.latestRoundData();
    }

    /// @notice A mean tick one below the V3 minimum is unavailable.
    function test_revertsOnAMeanTickBelowTheTickRange() public {
        WoodV3TwapFeed below = _seated(WOOD, WETH, int256(-887_273) * 3600);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        below.latestRoundData();
    }

    /// @notice A mean tick one above the V3 maximum is unavailable.
    function test_revertsOnAMeanTickAboveTheTickRange() public {
        WoodV3TwapFeed above = _seated(WOOD, WETH, int256(887_273) * 3600);
        vm.expectRevert(WoodV3TwapFeed.PriceUnavailable.selector);
        above.latestRoundData();
    }

    /// @notice A pool whose ring target is below `window + 1` is refused; exactly that deploys.
    function test_constructor_refusesARingShorterThanTheWindow() public {
        _feed(address(new SeatedCumulativesPool(WOOD, WETH, 0, RING)));

        address short = address(new SeatedCumulativesPool(WOOD, WETH, 0, RING - 1));
        vm.expectRevert(WoodV3TwapFeed.RingTooShort.selector);
        _feed(short);
    }

    /// @notice A window no V3 ring can hold (above 65,534 seconds) is refused.
    function test_constructor_refusesAWindowAboveTheRingCeiling() public {
        address full = address(new SeatedCumulativesPool(WOOD, WETH, 0, type(uint16).max));
        new WoodV3TwapFeed(full, WOOD, WETH, address(ethUsd), ETH_MAX_AGE, 65_534, MIN_V3_LIQUIDITY);

        vm.expectRevert(WoodV3TwapFeed.RingTooShort.selector);
        new WoodV3TwapFeed(full, WOOD, WETH, address(ethUsd), ETH_MAX_AGE, 65_535, MIN_V3_LIQUIDITY);

        // 65,536 + 1,800 truncates to 1,800 in 16 bits, which a one hour ring would pass.
        vm.expectRevert(WoodV3TwapFeed.RingTooShort.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, 67_336, MIN_V3_LIQUIDITY);
    }

    /// @notice A pool holding anything other than exactly {WOOD, WETH} is refused at construction.
    function test_constructor_refusesAPoolOfOtherTokens() public {
        address other = makeAddr("other");
        address[3] memory pools = [
            address(_newPool(WOOD, other, TICK)),
            address(_newPool(other, WETH, TICK)),
            address(_newPool(WETH, WETH, TICK))
        ];
        for (uint256 i = 0; i < pools.length; i++) {
            vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
            _feed(pools[i]);
        }
    }

    /// @notice A window under `MIN_WINDOW` is refused; exactly `MIN_WINDOW` deploys.
    function test_constructor_refusesAWindowBelowTheMinimum() public {
        uint32 min = feed.MIN_WINDOW();
        assertEq(min, 30 minutes);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, min, MIN_V3_LIQUIDITY);

        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, min - 1, MIN_V3_LIQUIDITY);
    }

    /// @notice A zero liquidity floor or a zero ETH/USD max age is refused.
    function test_constructor_refusesZeroBounds() public {
        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, 0);

        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, address(ethUsd), 0, WINDOW, MIN_V3_LIQUIDITY);
    }

    /// @notice An ETH/USD feed reporting more than 18 decimals is refused at construction.
    function test_constructor_refusesAnEthFeedAboveEighteenDecimals() public {
        address wide = address(new MockAggregatorV3(19, ETH_USD_X8));
        vm.expectRevert(WoodV3TwapFeed.InvalidParameter.selector);
        new WoodV3TwapFeed(address(pool), WOOD, WETH, wide, ETH_MAX_AGE, WINDOW, MIN_V3_LIQUIDITY);
    }
}

/// @notice The same feed against a real observation ring, written as fast as a pool can be.
contract WoodV3TwapFeedRingTest is WoodV3TwapFeedFixture {
    MockUniswapV3PoolRing internal ring;
    WoodV3TwapFeed internal feed;
    uint256 internal born;
    int24 internal wiggle;

    function setUp() public {
        vm.warp(1_800_000_000);
        born = vm.getBlockTimestamp();
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        ring = new MockUniswapV3PoolRing(WOOD, WETH, TICK, V3_LIQUIDITY);
        ring.increaseObservationCardinalityNext(RING);
        feed = _feed(address(ring));
    }

    /// @dev One tick-moving swap in every second, which is every write the pool allows.
    function _spam(MockUniswapV3PoolRing pool, uint256 secs) internal {
        for (uint256 i = 0; i < secs; i++) {
            vm.warp(vm.getBlockTimestamp() + 1);
            wiggle = wiggle == 0 ? int24(1) : int24(0);
            pool.swap(TICK + wiggle);
        }
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
    }

    /// @notice A ring of `window + 1` slots still serves the window after three windows of spam.
    function test_aRingOfWindowPlusOneSurvivesPerSecondSwaps() public {
        _spam(ring, 3 * uint256(WINDOW));

        assertEq(ring.writes(), 3 * uint256(WINDOW), "every second wrote");
        // Half the window sits one tick up, so the mean floors to TICK.
        assertApproxEqAbs(_answer(feed), ANSWER_X8, 1);
    }

    /// @notice Control: the same spam evicts a ring of exactly `window` slots, which the feed refuses.
    function test_control_perSecondSwapsEvictARingOfWindowSlots() public {
        MockUniswapV3PoolRing short = new MockUniswapV3PoolRing(WOOD, WETH, TICK, V3_LIQUIDITY);
        short.increaseObservationCardinalityNext(RING - 1);
        _spam(short, 3 * uint256(WINDOW));

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = WINDOW;
        vm.expectRevert(bytes("OLD"));
        short.observe(secondsAgos);

        vm.expectRevert(WoodV3TwapFeed.RingTooShort.selector);
        _feed(address(short));
    }

    /// @notice The feed starts answering exactly one window after the ring's oldest observation.
    function test_answersAWindowAfterTheOldestObservation() public {
        _spam(ring, uint256(WINDOW) - 1);
        vm.expectRevert(bytes("OLD"));
        feed.latestRoundData();

        _spam(ring, 1);
        assertApproxEqAbs(_answer(feed), ANSWER_X8, 1);
    }

    /// @notice Half the window at one tick and half a doubling higher answers their mean tick.
    function test_averagesATickThatMovedMidWindow() public {
        vm.warp(born + WINDOW / 2);
        ring.swap(TICK + TICKS_PER_DOUBLING);
        vm.warp(born + WINDOW);

        // Mean tick -132873. Either half alone answers 359,989 or 719,991.
        assertApproxEqAbs(_answer(feed), 509_106, 1);
    }
}

/// @notice The ledger prices WOOD off the feed: haircut, cap, and a dead pool as `NoWoodPrice`.
contract WoodV3TwapFeedLedgerTest is WoodV3TwapFeedFixture {
    uint256 internal constant CAP_X8 = 720_000;
    uint256 internal constant HAIRCUT_BPS = 8000;

    MockUniswapV3Pool internal pool;
    ExposureLedger internal ledger;

    function setUp() public {
        vm.warp(1_800_000_000);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        pool = _newPool(WOOD, WETH, TICK);
        WoodV3TwapFeed feed = _feed(address(pool));

        // The price path never calls sWOOD, so a codeless address stands in for it.
        ledger = new ExposureLedger(address(this), makeAddr("swood"), 7 days);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodHaircutBps(HAIRCUT_BPS);
        ledger.setWoodFeed(address(feed), 1);
    }

    /// @notice Ten days on, with a max delay of one second, the ledger still reads the feed.
    function test_ledgerReadsTheFeedWithNoKeeper() public {
        vm.warp(vm.getBlockTimestamp() + 10 days);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());

        assertEq(ledger.woodPriceX8(), (ANSWER_X8 * HAIRCUT_BPS) / 10_000);
    }

    /// @notice A feed above the cap is priced at the cap.
    function test_ledgerCapsAFeedAboveTheCap() public {
        ledger.setWoodUsdPrice(100_000);
        assertEq(ledger.woodPriceX8(), (100_000 * HAIRCUT_BPS) / 10_000);
    }

    /// @notice A pool that cannot serve the window reaches the ledger as `NoWoodPrice`.
    function test_ledgerSeesAnUnservableWindowAsNoWoodPrice() public {
        pool.setObserveReverts(true);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }
}
