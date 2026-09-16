// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WoodPoolFeed} from "src/pricing/WoodPoolFeed.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {MockUniswapV2Pair} from "test/mocks/MockUniswapV2Pair.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

/// @dev The two pools, the ETH leg and the parameters every test in this file
///      shares. `uni` holds WOOD as token0 and `sushi` as token1, so both
///      accumulator sides are exercised by the fixture itself.
abstract contract WoodPoolFeedFixture is Test {
    address internal constant WOOD = address(uint160(0xD00D));
    address internal constant WETH = address(uint160(0xE7E7));

    uint112 internal constant WOOD_RESERVE = 1e26; // 100M WOOD
    uint112 internal constant WETH_RESERVE = 240e18; // ~$720k at $3,000/ETH
    uint256 internal constant MIN_WETH = 100e18;
    uint256 internal constant WINDOW = 24 hours;
    uint256 internal constant ETH_MAX_AGE = 24 hours;
    int256 internal constant ETH_USD_X8 = 3000e8;

    MockUniswapV2Pair internal uni;
    MockUniswapV2Pair internal sushi;
    MockAggregatorV3 internal ethUsd;
    WoodPoolFeed internal feed;

    function _deployFeed() internal {
        vm.warp(1_800_000_000); // a real chain time, not forge's t = 1
        uni = new MockUniswapV2Pair(WOOD, WETH, WOOD_RESERVE, WETH_RESERVE);
        sushi = new MockUniswapV2Pair(WETH, WOOD, WETH_RESERVE, WOOD_RESERVE);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        feed =
            new WoodPoolFeed(address(uni), address(sushi), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH);
    }

    /// @dev Move time forward with both pools trading and the ETH leg fresh: the
    ///      ordinary background against which a snapshot is taken.
    function _advance(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        uni.sync();
        sushi.sync();
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
    }

    /// @dev Baseline, then a full window, then the second snapshot: the state in
    ///      which the feed answers at all.
    function _prime() internal {
        feed.update();
        _advance(WINDOW + 1);
        feed.update();
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
        // 240 WETH per 100M WOOD at $3,000/ETH = $0.0072.
        assertApproxEqRel(_answer(), 720_000, 1e13, "the pools' price, converted through ETH/USD");
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

        // Both pools pushed 100x at once, held three minutes, then put back, so
        // the spike sits INSIDE the interval the next snapshot averages over.
        uni.setReserves(WOOD_RESERVE / 100, WETH_RESERVE);
        sushi.setReserves(WETH_RESERVE, WOOD_RESERVE / 100);
        vm.warp(vm.getBlockTimestamp() + 3 minutes);
        uni.setReserves(WOOD_RESERVE, WETH_RESERVE);
        sushi.setReserves(WETH_RESERVE, WOOD_RESERVE);

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

        // ONE trade, in both pools, then nothing: no restoring trade, no keeper
        // co-operation, no second touch of the pair.
        uni.setReserves(WOOD_RESERVE / 100, WETH_RESERVE);
        sushi.setReserves(WETH_RESERVE, WOOD_RESERVE / 100);

        vm.warp(vm.getBlockTimestamp() + 300);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
        feed.update(); // syncs both pairs: 300s at 100x lands in the accumulator

        // Arbitrage puts the pools back, and the rest of the window is ordinary.
        uni.setReserves(WOOD_RESERVE, WETH_RESERVE);
        sushi.setReserves(WETH_RESERVE, WOOD_RESERVE);
        _advance(WINDOW + 1);
        feed.update();

        uint256 answer = _answer();
        assertGt(answer, (before * 133) / 100, "300s of 100x is worth its full time share");
        assertLt(answer, (before * 136) / 100, "and no more than that -- the share is arithmetic");
    }

    /// @notice One pool manipulated alone cannot raise the answer AT ALL, even
    ///         when it is held long enough for that pool's own average to move:
    ///         the answer is the LOWER of the two.
    function test_onePoolManipulatedAloneCannotRaiseTheAnswer() public {
        _prime();
        uint256 before = _answer();

        sushi.setReserves(WETH_RESERVE, WOOD_RESERVE / 100); // 100x, in sushi only
        _advance(WINDOW + 1);
        feed.update();

        assertEq(_answer(), before, "the cheaper pool sets the mark");
    }

    /// @notice A crash IS tracked: the min follows the market down, which is the
    ///         direction where a stale mark over-values guardian bonds.
    function test_aSustainedCrashInOnePoolIsTracked() public {
        _prime();
        uint256 before = _answer();

        sushi.setReserves(WETH_RESERVE, WOOD_RESERVE * 4); // WOOD 4x cheaper in sushi
        _advance(WINDOW + 1);
        feed.update();

        assertApproxEqRel(_answer(), before / 4, 1e13, "the lower pool is what the mark follows");
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

    /// @notice `updatedAt` is the OLDER of the two snapshots, so a consumer's
    ///         staleness bound binds on whichever pool was refreshed last.
    function test_updatedAtIsTheOlderOfTheTwoSnapshots() public {
        _prime();
        uint256 primedAt = _updatedAt();

        // `sushi` sits under the depth floor for a whole window, so only `uni`'s
        // snapshot rolls; its depth is restored before the reading is taken.
        sushi.setReserves(uint112(MIN_WETH - 1), WOOD_RESERVE);
        _advance(WINDOW + 1);
        feed.update();
        uint256 uniSnapshot = vm.getBlockTimestamp();
        sushi.setReserves(WETH_RESERVE, WOOD_RESERVE);

        assertGt(uniSnapshot, primedAt, "control: the deep pool did roll");
        assertEq(_updatedAt(), primedAt, "the older snapshot dates the reading");
        assertLt(_updatedAt(), uniSnapshot, "and it is genuinely behind the newer one");
    }

    /// @notice Liveness does NOT depend on both pools trading. `update()` syncs
    ///         each pair itself, and a sync accumulates the standing price over
    ///         the elapsed span and restamps the pair, so a pool nobody has
    ///         traded all day still snapshots and `updatedAt` still advances.
    ///         Three windows of one-sided trading leave the feed answering.
    function test_theFeedStaysFreshAcrossWindowsInWhichOnlyOnePoolTrades() public {
        _prime();
        uint256 lastUpdatedAt = _updatedAt();

        for (uint256 i = 0; i < 3; ++i) {
            // Only `uni` trades. `sushi` is untouched for the entire window;
            // `update()`'s own sync is what still rolls its snapshot.
            vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
            uni.sync();
            ethUsd.setUpdatedAt(vm.getBlockTimestamp());
            feed.update();

            uint256 updatedAt = _updatedAt();
            assertEq(updatedAt, vm.getBlockTimestamp(), "the idle pool rolled too, so neither lags");
            assertGt(updatedAt, lastUpdatedAt, "and the reading advanced this window");
            lastUpdatedAt = updatedAt;
        }

        assertApproxEqRel(_answer(), 720_000, 1e13, "idleness alone never staled the feed");
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
        new WoodPoolFeed(address(uni), address(sushi), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW - 1, MIN_WETH);
    }

    function test_constructorRefusesTheSamePoolTwice() public {
        vm.expectRevert(WoodPoolFeed.InvalidParameter.selector);
        new WoodPoolFeed(address(uni), address(uni), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH);
    }

    /// @notice Which side of each pair holds WOOD is DERIVED, so a pair holding
    ///         anything else cannot be wired with a hand-supplied flag.
    function test_constructorRefusesAPairThatDoesNotHoldWoodAndWeth() public {
        sushi.setTokens(WETH, makeAddr("notWood"));

        vm.expectRevert(WoodPoolFeed.InvalidParameter.selector);
        new WoodPoolFeed(address(uni), address(sushi), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH);
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
        assertApproxEqRel(ledger.woodPriceX8(), 720_000, 1e13, "one feed, read through setWoodFeed");
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

    /// @notice A reading older than the ledger's own `maxDelay` is rejected
    ///         exactly as a stale Chainlink round is, and recovers the moment
    ///         the keeper snapshots again.
    function test_aReadingOlderThanMaxDelayIsRejected() public {
        // A window plus the cadence slack still prices: `updatedAt` advances
        // only when a snapshot rolls, so anything tighter would halt the
        // protocol between rolls rather than catch a stale feed.
        vm.warp(vm.getBlockTimestamp() + FEED_MAX_DELAY);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp()); // isolate the WOOD leg
        assertApproxEqRel(ledger.woodPriceX8(), 720_000, 1e13, "still inside maxDelay");

        vm.warp(vm.getBlockTimestamp() + 1);
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();

        _advance(1);
        feed.update();
        assertApproxEqRel(ledger.woodPriceX8(), 720_000, 1e13, "a fresh snapshot restores pricing");
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
