// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WoodPoolFeed} from "src/pricing/WoodPoolFeed.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {MockUniswapV2Pair} from "test/mocks/MockUniswapV2Pair.sol";
import {MockUniswapV3Pool} from "test/mocks/MockUniswapV3Pool.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

/// @dev The two legs, the ETH leg and the parameters every test in this file
///      shares. `uni` is the V2 pair and holds WOOD as token0; `v3` is the
///      Uniswap V3 pool and holds WOOD as token0 too; the flipped ordering is
///      built per-test with `_newPool(WETH, WOOD, ...)`.
abstract contract WoodPoolFeedFixture is Test {
    address internal constant WOOD = address(uint160(0xD00D));
    address internal constant WETH = address(uint160(0xE7E7));

    uint112 internal constant WOOD_RESERVE = 1e26; // 100M WOOD
    uint112 internal constant WETH_RESERVE = 240e18; // ~$720k at $3,000/ETH
    uint256 internal constant MIN_WETH = 100e18;
    uint128 internal constant MIN_V3_LIQUIDITY = 1e22;
    uint128 internal constant V3_LIQUIDITY = 2e22;
    uint256 internal constant WINDOW = 24 hours;
    uint256 internal constant MAX_SNAPSHOT_SPAN_SECONDS = 7 days;
    uint256 internal constant ETH_MAX_AGE = 24 hours;
    int256 internal constant ETH_USD_X8 = 3000e8;

    /// @dev `1.0001 ** tick` is WETH per WOOD when WOOD is the pool's token0.
    ///      The V2 pair stands at 240e18 / 1e26 = 2.4e-6 WETH per WOOD, which is
    ///      tick -129407; each factor of two is 6932 ticks. A tick is a 0.01%
    ///      step, so these land within half a tick of the round price and the
    ///      assertions against them are held to 0.1%, not to the wei.
    int24 internal constant TICK_TWICE_V2 = -122475; // ~$0.0144
    int24 internal constant TICK_HALF_V2 = -136339; // ~$0.0036
    int24 internal constant TICK_QUARTER_V2 = -143271; // ~$0.0018

    uint256 internal constant V2_ANSWER_X8 = 720_000;
    uint256 internal constant HALF_ANSWER_X8 = 360_000;
    uint256 internal constant QUARTER_ANSWER_X8 = 180_000;

    MockUniswapV2Pair internal uni;
    MockUniswapV3Pool internal v3;
    MockAggregatorV3 internal ethUsd;
    WoodPoolFeed internal feed;

    function _deployFeed() internal {
        vm.warp(1_800_000_000); // a real chain time, not forge's t = 1
        uni = new MockUniswapV2Pair(WOOD, WETH, WOOD_RESERVE, WETH_RESERVE);
        v3 = _newPool(WOOD, WETH, TICK_TWICE_V2);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        feed = new WoodPoolFeed(
            address(uni), address(v3), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, MIN_V3_LIQUIDITY
        );
    }

    /// @dev A pool deep enough to clear the floor, averaging at `twapTick`.
    function _newPool(address token0, address token1, int24 twapTick) internal returns (MockUniswapV3Pool p) {
        p = new MockUniswapV3Pool(token0, token1, 3000, 60, makeAddr("v3Factory"));
        p.setLiquidity(V3_LIQUIDITY);
        p.setTicks(twapTick, twapTick);
    }

    /// @dev Move time forward with the V2 pool trading and the ETH leg fresh: the
    ///      ordinary background against which a snapshot is taken. The V3 pool's
    ///      accumulator advances with the clock on its own.
    function _advance(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        uni.sync();
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
    }

    /// @dev Baseline, then a full window, then the second snapshot: the state in
    ///      which the feed answers at all.
    function _prime() internal {
        feed.update();
        _advance(WINDOW + 1);
        feed.update();
    }

    /// @dev `_prime()` for a second feed built inside a test: its snapshots are
    ///      its own, so the shared V2 pair has to be rolled again for it.
    function _primeOther(WoodPoolFeed other) internal {
        other.update();
        _advance(WINDOW + 1);
        other.update();
    }

    /// @dev Roll `other` one window on with `p`'s accumulator advanced by exactly
    ///      `delta`, so the V3 leg's next average is `delta / WINDOW` — the only
    ///      way to hand the leg a quotient with a remainder.
    function _rollV3Delta(WoodPoolFeed other, MockUniswapV3Pool p, int56 delta) internal {
        (int56 latest,) = other.latestPoolObservation();
        _advance(WINDOW);
        p.setTickCumulative(latest + delta);
        other.update();
    }

    /// @dev `_prime()` with the V3 leg's averaged delta chosen outright.
    function _primeV3Delta(WoodPoolFeed other, MockUniswapV3Pool p, int56 delta) internal {
        p.setTickCumulative(0);
        other.update();
        _rollV3Delta(other, p, delta);
    }

    function _answer() internal view returns (uint256) {
        (, int256 a,,,) = feed.latestRoundData();
        return uint256(a);
    }

    function _updatedAt() internal view returns (uint256) {
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        return updatedAt;
    }
}

contract WoodPoolFeedTest is WoodPoolFeedFixture {
    function setUp() public {
        _deployFeed();
    }

    function test_pricesTheTwoPoolsInUsdAtEightDecimals() public {
        _prime();
        assertEq(feed.decimals(), 8, "the ledger normalises against this");
        // 240 WETH per 100M WOOD at $3,000/ETH = $0.0072, and the V3 pool sits
        // above it, so the V2 pair is the mark.
        assertApproxEqRel(_answer(), V2_ANSWER_X8, 1e13, "the pools' price, converted through ETH/USD");
    }

    /// @notice A 100x spike held three minutes is BOUNDED BY ITS TIME SHARE of
    ///         the window, not eliminated. An arithmetic-mean TWAP carries
    ///         `(spike - 1) * held / window`: at 100x for 3 minutes in a 24h
    ///         window that is +20.6%. `update()` is permissionless, so an
    ///         attacker picks the moment the roll happens and the spike lands
    ///         inside the averaged interval — which is what this reproduces.
    ///         The governance cap and the haircut are the controls on the rest.
    function test_aHundredXSpikeHeldThreeMinutesMovesTheAnswerByAtMostItsTimeShareOfTheWindow() public {
        _prime();
        uint256 before = _answer();

        // The V2 pool pushed 100x, held three minutes, then put back, so the
        // spike sits INSIDE the interval the next snapshot averages over. It
        // stays the lower leg throughout, so the V3 pool never masks it.
        uni.setReserves(WOOD_RESERVE / 100, WETH_RESERVE);
        vm.warp(vm.getBlockTimestamp() + 3 minutes);
        uni.setReserves(WOOD_RESERVE, WETH_RESERVE);

        _advance(WINDOW + 1);
        feed.update();

        uint256 answer = _answer();
        assertLe(answer, (before * 121) / 100, "3 minutes of 100x buys at most its share of the window");
        assertGt(answer, (before * 119) / 100, "and it is NOT eliminated -- the bound is real, not vacuous");
    }

    /// @notice The three minutes above are A CHOSEN HOLD, NOT THE CHEAPEST ONE.
    ///         A single spike trade, left standing, is booked for the WHOLE span
    ///         up to the next interaction — and `update()` itself is such an
    ///         interaction, because it syncs. One trade plus an `update()` five
    ///         minutes later buys 300s of the window: +34%, with no second trade
    ///         and no cooperation. Nothing bounds the span a sync books; only the
    ///         window's own arithmetic dilutes it.
    function test_aSpikeLeftIdleUntilTheNextSnapshotCountsForTheWholeIdleSpan() public {
        _prime();
        uint256 before = _answer();

        // ONE trade, then nothing: no restoring trade, no keeper co-operation,
        // no second touch of the pair.
        uni.setReserves(WOOD_RESERVE / 100, WETH_RESERVE);

        vm.warp(vm.getBlockTimestamp() + 300);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
        feed.update(); // syncs the pair: 300s at 100x lands in the accumulator

        // Arbitrage puts the pool back, and the rest of the window is ordinary.
        uni.setReserves(WOOD_RESERVE, WETH_RESERVE);
        _advance(WINDOW + 1);
        feed.update();

        uint256 answer = _answer();
        assertGt(answer, (before * 133) / 100, "300s of 100x is worth its full time share");
        assertLt(answer, (before * 136) / 100, "and no more than that -- the share is arithmetic");
    }

    /// @notice The V3 leg manipulated alone cannot raise the answer AT ALL, even
    ///         at 100x held for a WHOLE window: the answer is the LOWER of the
    ///         two legs.
    function test_theV3LegManipulatedAloneCannotRaiseTheAnswer() public {
        _prime();
        uint256 before = _answer();

        v3.setTicks(0, 0); // 1 WETH per WOOD, ~400,000x the real price
        _advance(WINDOW + 1);
        feed.update(); // the manipulated average is snapshotted in full

        assertEq(_answer(), before, "the cheaper leg sets the mark");
    }

    /// @notice And the V2 leg manipulated alone cannot raise it either, which is
    ///         the same claim taken from the other side: with the V3 pool the
    ///         lower leg, a 100x in the V2 pair moves nothing.
    function test_theV2LegManipulatedAloneCannotRaiseTheAnswer() public {
        v3.setTicks(TICK_HALF_V2, TICK_HALF_V2);
        _prime();
        assertApproxEqRel(_answer(), HALF_ANSWER_X8, 1e15, "control: the V3 pool is the mark");

        uni.setReserves(WOOD_RESERVE / 100, WETH_RESERVE);
        _advance(WINDOW + 1);
        feed.update();

        assertApproxEqRel(_answer(), HALF_ANSWER_X8, 1e15, "the cheaper leg still sets the mark");
    }

    /// @notice A crash IS tracked: the min follows the market down, which is the
    ///         direction where a stale mark over-values guardian bonds.
    function test_aSustainedCrashInTheV3PoolIsTracked() public {
        _prime();
        assertApproxEqRel(_answer(), V2_ANSWER_X8, 1e13, "control: the V2 pair is the mark");

        v3.setTicks(TICK_QUARTER_V2, TICK_QUARTER_V2);
        _advance(WINDOW + 1);
        feed.update();

        assertApproxEqRel(_answer(), QUARTER_ANSWER_X8, 1e15, "the lower leg is what the mark follows");
    }

    /// @notice The V3 leg is averaged over the span between the two snapshots,
    ///         which `update()` rolls no sooner than a whole window apart.
    function test_theV3LegIsAveragedOverExactlyTheConfiguredWindow() public {
        assertEq(feed.window(), feed.MIN_WINDOW(), "this fixture sits exactly on the minimum window");

        v3.setTicks(TICK_HALF_V2, TICK_HALF_V2);
        _prime();
        assertApproxEqRel(_answer(), HALF_ANSWER_X8, 1e15, "the V3 average at the configured window");
    }

    /// @notice A V3 pool below its in-range-liquidity floor makes the feed
    ///         unavailable, exactly as a V2 pair below its WETH floor does.
    function test_aV3PoolBelowTheLiquidityFloorMakesTheFeedUnavailable() public {
        _prime();
        v3.setLiquidity(MIN_V3_LIQUIDITY);
        _answer(); // control: the floor is INCLUSIVE, so exactly at it still answers

        v3.setLiquidity(MIN_V3_LIQUIDITY - 1);
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice An `observe` the pool refuses cannot take the price down: reads
    ///         are served from stored snapshots, so only the NEXT snapshot is
    ///         lost, and losing it is a loud revert in `update()` (v1 audit F2).
    function test_anObserveThatRevertsCannotMakeTheFeedUnavailable() public {
        _prime();
        uint256 before = _answer();

        v3.setObserveReverts(true);
        assertEq(_answer(), before, "the stored snapshots still price WOOD");

        _advance(WINDOW + 1);
        vm.expectRevert(bytes("OLD"));
        feed.update();
    }

    /// @notice Above tick 443,637 the square of `sqrtRatioX96` no longer fits in
    ///         256 bits, and the wide branch is what keeps that arithmetic in
    ///         range instead of panicking.
    function test_aTickAboveTheSquaringBoundIsPricedThroughTheWideBranch() public {
        _primeV3Delta(feed, v3, int56(500_000) * int56(uint56(WINDOW)));
        // Such a tick prices WOOD far above the V2 pair, so `min` still marks the
        // pair; the claim here is that the V3 leg returns at all.
        assertApproxEqRel(_answer(), V2_ANSWER_X8, 1e13, "the wide branch prices a tick past the squaring bound");
    }

    /// @notice A NEGATIVE mean tick with a remainder rounds toward NEGATIVE
    ///         INFINITY, as Uniswap's own oracle library does. Truncating
    ///         division rounds it up instead, reporting WOOD one whole tick more
    ///         expensive than the pool actually held it.
    function test_aNegativeMeanTickRoundsTowardNegativeInfinity() public {
        int56 span = int56(uint56(WINDOW));

        _primeV3Delta(feed, v3, int56(TICK_HALF_V2) * span);
        uint256 atTick = _answer();

        // One below an exact multiple: the quotient is inexact and negative.
        _rollV3Delta(feed, v3, int56(TICK_HALF_V2) * span - 1);
        uint256 justBelow = _answer();

        _rollV3Delta(feed, v3, int56(TICK_HALF_V2 - 1) * span);
        uint256 atTickBelow = _answer();

        assertEq(justBelow, atTickBelow, "a negative remainder is a whole tick down");
        assertLt(justBelow, atTick, "and that is genuinely below the truncated answer");
    }

    /// @notice A POSITIVE remainder still truncates, which is already rounding
    ///         toward negative infinity: the correction must not fire on it.
    function test_aPositiveMeanTickIsNotRoundedDown() public {
        _prime();
        int56 span = int56(uint56(WINDOW));

        // A positive mean tick prices WOOD above WETH, far above the V2 pair, so
        // read the V3 leg through a pool whose tokens are flipped instead: WOOD
        // as token1 makes a positive tick the cheap direction.
        MockUniswapV3Pool flipped = _newPool(WETH, WOOD, -TICK_HALF_V2);
        WoodPoolFeed flippedFeed = new WoodPoolFeed(
            address(uni), address(flipped), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, MIN_V3_LIQUIDITY
        );

        _primeV3Delta(flippedFeed, flipped, int56(-TICK_HALF_V2) * span);
        (, int256 atTick,,,) = flippedFeed.latestRoundData();

        _rollV3Delta(flippedFeed, flipped, int56(-TICK_HALF_V2) * span + 1);
        (, int256 justAbove,,,) = flippedFeed.latestRoundData();

        assertEq(uint256(justAbove), uint256(atTick), "a positive remainder truncates, it is not pushed a tick down");
    }

    /// @notice Which side of the V3 pool holds WOOD is DERIVED, and the leg is
    ///         put in the V2 pair's orientation either way: a pool quoting
    ///         `WOOD per WETH` gives the same USD answer as its mirror.
    function test_theV3LegIsOrientedFromThePoolsOwnTokenOrdering() public {
        v3.setTicks(TICK_HALF_V2, TICK_HALF_V2);
        _prime();
        uint256 woodIsToken0 = _answer();

        MockUniswapV3Pool flipped = _newPool(WETH, WOOD, -TICK_HALF_V2);
        WoodPoolFeed flippedFeed = new WoodPoolFeed(
            address(uni), address(flipped), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, MIN_V3_LIQUIDITY
        );
        _primeOther(flippedFeed);
        (, int256 answer,,,) = flippedFeed.latestRoundData();

        assertApproxEqRel(uint256(answer), woodIsToken0, 1e14, "the mirrored pool prices WOOD identically");
        assertApproxEqRel(uint256(answer), HALF_ANSWER_X8, 1e15, "and both are the pool's real price");
    }

    /// @notice A pool below the depth floor makes the feed unavailable rather
    ///         than pricing off a pool too thin to mean anything.
    function test_aPoolBelowTheDepthFloorMakesTheFeedUnavailable() public {
        _prime();
        _answer(); // control: it answers while both pools are deep

        uni.setReserves(WOOD_RESERVE, uint112(MIN_WETH - 1));
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice The floor binds at SNAPSHOT time too, not only at read time: a
    ///         pool below it contributes nothing to the average, so its price
    ///         cannot be booked and then read back after the depth is restored.
    function test_aPoolBelowTheDepthFloorCannotBeSnapshot() public {
        _prime();
        uint256 before = _answer();
        (,,, uint256 primedAt,) = feed.latestRoundData();

        // `uni` is thin for a full window, then deep again, so the read-time
        // gate is satisfied when the answer is taken.
        uni.setReserves(WOOD_RESERVE, uint112(MIN_WETH - 1));
        _advance(WINDOW + 1);
        feed.update();
        uni.setReserves(WOOD_RESERVE, WETH_RESERVE);

        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, primedAt, "the thin pool's snapshot never rolled");
        assertEq(_answer(), before, "so its price never entered the average");
    }

    /// @notice `updatedAt` is the OLDER of the two legs. Both roll together, so
    ///         the snapshot is what dates the reading — a consumer's staleness
    ///         bound binds on it, never on the block.
    function test_updatedAtIsTheOlderOfTheTwoLegs() public {
        _prime();
        uint256 snapshotAt = vm.getBlockTimestamp();
        assertEq(_updatedAt(), snapshotAt, "the snapshot dates the reading");

        vm.warp(vm.getBlockTimestamp() + 6 hours);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());

        assertEq(_updatedAt(), snapshotAt, "an unrolled leg never dates the reading forward");
        assertLt(_updatedAt(), vm.getBlockTimestamp(), "and it is genuinely behind the block");
    }

    /// @notice Liveness does NOT depend on the pool trading. `update()` syncs
    ///         the pair itself, and a sync accumulates the standing price over
    ///         the elapsed span and restamps the pair, so a pool nobody has
    ///         traded all day still snapshots and `updatedAt` still advances.
    function test_theFeedStaysFreshAcrossWindowsInWhichThePoolNeverTrades() public {
        _prime();
        uint256 lastUpdatedAt = _updatedAt();

        for (uint256 i = 0; i < 3; ++i) {
            // Nobody trades. `update()`'s own sync is what rolls the snapshot.
            vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
            ethUsd.setUpdatedAt(vm.getBlockTimestamp());
            feed.update();

            uint256 updatedAt = _updatedAt();
            assertEq(updatedAt, vm.getBlockTimestamp(), "the idle pool rolled, so nothing lags");
            assertGt(updatedAt, lastUpdatedAt, "and the reading advanced this window");
            lastUpdatedAt = updatedAt;
        }

        assertApproxEqRel(_answer(), V2_ANSWER_X8, 1e13, "idleness alone never staled the feed");
    }

    function test_isUnavailableUntilAFullWindowHasBeenSpanned() public {
        feed.update();
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();

        _advance(WINDOW - 1 hours);
        feed.update(); // too early: the window has not elapsed
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    /// @notice Two snapshots further apart than `MAX_SNAPSHOT_SPAN` are too
    ///         stale an average to serve, even though the window is satisfied
    ///         and each snapshot is individually well formed.
    function test_aSnapshotSpanAboveTheCeilingMakesTheFeedUnavailable() public {
        feed.update();
        _advance(MAX_SNAPSHOT_SPAN_SECONDS + 1);
        feed.update();

        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    function test_aStaleEthLegMakesTheFeedUnavailable() public {
        _prime();
        vm.warp(vm.getBlockTimestamp() + ETH_MAX_AGE + 1);
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    function test_aNonPositiveEthAnswerMakesTheFeedUnavailable() public {
        _prime();
        ethUsd.setAnswer(0);
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();
    }

    function test_constructorRefusesAWindowBelowTwentyFourHours() public {
        vm.expectRevert(WoodPoolFeed.InvalidParameter.selector);
        new WoodPoolFeed(
            address(uni), address(v3), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW - 1, MIN_WETH, MIN_V3_LIQUIDITY
        );
    }

    function test_constructorRefusesTheSameVenueTwice() public {
        vm.expectRevert(WoodPoolFeed.InvalidParameter.selector);
        new WoodPoolFeed(
            address(uni), address(uni), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, MIN_V3_LIQUIDITY
        );
    }

    function test_constructorRefusesAZeroV3LiquidityFloor() public {
        vm.expectRevert(WoodPoolFeed.InvalidParameter.selector);
        new WoodPoolFeed(address(uni), address(v3), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, 0);
    }

    /// @notice Which side of each venue holds WOOD is DERIVED, so a venue holding
    ///         anything else cannot be wired with a hand-supplied flag.
    function test_constructorRefusesAPairThatDoesNotHoldWoodAndWeth() public {
        uni.setTokens(WETH, makeAddr("notWood"));

        vm.expectRevert(WoodPoolFeed.InvalidParameter.selector);
        new WoodPoolFeed(
            address(uni), address(v3), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, MIN_V3_LIQUIDITY
        );
    }

    function test_constructorRefusesAV3PoolThatDoesNotHoldWoodAndWeth() public {
        MockUniswapV3Pool wrong = _newPool(WETH, makeAddr("notWood"), TICK_HALF_V2);

        vm.expectRevert(WoodPoolFeed.InvalidParameter.selector);
        new WoodPoolFeed(
            address(uni), address(wrong), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, MIN_V3_LIQUIDITY
        );
    }

    function test_updateIsPermissionless() public {
        feed.update();
        _advance(WINDOW + 1);
        vm.prank(makeAddr("anyone"));
        feed.update();
        assertGt(_answer(), 0, "anyone may keep the feed fresh");
    }
}

/// @dev The only sWOOD reads the ledger makes.
contract WoodPoolFeedMockSwood {
    mapping(address => uint256) public guardianStake;

    function coolDownPeriod() external pure returns (uint256) {
        return 7 days;
    }

    function slashableStakeAt(address guardian, uint256) external view returns (uint256) {
        return guardianStake[guardian];
    }

    function setStake(address guardian, uint256 amount) external {
        guardianStake[guardian] = amount;
    }
}

/// @dev The USDG-side asset feed `coverageUsd` reads on the propose path.
contract WoodPoolFeedAssetFeed {
    int256 public answer = 1e8;
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @dev `WoodPoolFeed` wired at the ledger through the ordinary `setWoodFeed`
///      path, with nothing else changed: the ledger has no branch for it.
contract WoodPoolFeedLedgerTest is WoodPoolFeedFixture {
    uint256 internal constant CAP_X8 = 1e8; // $1, far above the pools' $0.0072
    /// @dev MUST EXCEED `WINDOW`. `updatedAt` only advances when a snapshot
    ///      rolls, which is at most once per window, so a `maxDelay` at or below
    ///      the window halts every price read between rolls. The extra 2h is the
    ///      keeper's cadence slack, the same bound `DeployPlanB` pre-flights.
    uint256 internal constant FEED_MAX_DELAY = WINDOW + 2 hours;

    ExposureLedger internal ledger;
    WoodPoolFeedMockSwood internal swood;
    WoodPoolFeedAssetFeed internal assetFeed;
    address internal owner = makeAddr("owner");
    address internal usdgAsset;

    function setUp() public {
        _deployFeed();
        _prime();

        swood = new WoodPoolFeedMockSwood();
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        assetFeed = new WoodPoolFeedAssetFeed();
        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));

        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodFeed(address(feed), FEED_MAX_DELAY);
        ledger.setAssetFeed(usdgAsset, address(assetFeed), 365 days);
        vm.stopPrank();
    }

    function test_theLedgerPricesWoodOffThePoolFeed() public view {
        assertApproxEqRel(ledger.woodPriceX8(), V2_ANSWER_X8, 1e13, "one feed, read through setWoodFeed");
    }

    /// @notice A pool below the depth floor makes the feed unavailable, and the
    ///         propose path halts on the ledger's existing no-price error rather
    ///         than sizing a bond off a pool too thin to price.
    function test_aPoolBelowTheDepthFloorHaltsTheProposePath() public {
        assertGt(ledger.proposerBondWood(usdgAsset, 1_000e6), 0, "control: the bond sizes normally");

        uni.setReserves(WOOD_RESERVE, uint112(MIN_WETH - 1));

        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.proposerBondWood(usdgAsset, 1_000e6);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }

    /// @notice A V3 pool whose observation ring can no longer serve the window
    ///         does NOT halt the propose path: the leg is priced off snapshots
    ///         the feed already took, so the ring cannot starve it (v1 audit F2).
    function test_aV3RingThatCannotServeTheWindowDoesNotHaltTheProposePath() public {
        v3.setObserveReverts(true);

        assertApproxEqRel(ledger.woodPriceX8(), V2_ANSWER_X8, 1e13, "the ring cannot take the price down");
        assertGt(ledger.proposerBondWood(usdgAsset, 1_000e6), 0, "and the propose path still sizes a bond");
    }

    /// @notice A reading older than the ledger's own `maxDelay` is rejected
    ///         exactly as a stale Chainlink round is, and recovers the moment
    ///         the keeper snapshots again.
    function test_aReadingOlderThanMaxDelayIsRejected() public {
        // A window plus the cadence slack still prices: `updatedAt` advances
        // only when a snapshot rolls, so anything tighter would halt the
        // protocol between rolls rather than catch a stale feed.
        vm.warp(vm.getBlockTimestamp() + FEED_MAX_DELAY);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp()); // isolate the WOOD leg
        assertApproxEqRel(ledger.woodPriceX8(), V2_ANSWER_X8, 1e13, "still inside maxDelay");

        vm.warp(vm.getBlockTimestamp() + 1);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();

        _advance(1);
        feed.update();
        assertApproxEqRel(ledger.woodPriceX8(), V2_ANSWER_X8, 1e13, "a fresh snapshot restores pricing");
    }

    /// @notice Swapping the pool feed for a plain Chainlink aggregator is ONE
    ///         `setWoodFeed` call and no code change: the ledger reads the same
    ///         `AggregatorV3` surface either way.
    function test_swappingInAPlainAggregatorIsOneCall() public {
        MockAggregatorV3 chainlink = new MockAggregatorV3(8, 0.05e8);

        vm.prank(owner);
        ledger.setWoodFeed(address(chainlink), FEED_MAX_DELAY);

        assertEq(ledger.woodPriceX8(), 0.05e8, "the aggregator prices it with nothing else touched");
    }

    /// @notice The cap still bounds the pool feed: the market may lower the WOOD
    ///         price and never raise it.
    function test_theCapStillBindsThePoolFeed() public {
        vm.prank(owner);
        ledger.setWoodUsdPrice(1e5); // below the pools' ~7.2e5

        assertEq(ledger.woodPriceX8(), 1e5, "the cap truncates whatever the pools say");
    }
}
