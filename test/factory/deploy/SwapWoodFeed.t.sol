// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SwapWoodFeed} from "script/robinhood-mainnet/SwapWoodFeed.s.sol";
import {RobinhoodParams} from "script/robinhood-mainnet/RobinhoodParams.sol";
import {WoodV3TwapFeed} from "src/pricing/WoodV3TwapFeed.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {MockUniswapV2Pair} from "test/mocks/MockUniswapV2Pair.sol";
import {MockUniswapV3Pool} from "test/mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3PoolRing} from "test/mocks/MockUniswapV3PoolRing.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

contract DecimalsToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

contract V3FactoryStub {
    address public pool;

    function setPool(address pool_) external {
        pool = pool_;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

contract SwapWoodFeedTest is Test {
    uint32 internal constant WINDOW = RobinhoodParams.WOOD_TWAP_WINDOW;
    uint16 internal constant RING = RobinhoodParams.WOOD_TWAP_RING;
    /// @dev 1.2e-6 WETH per WOOD at $3,000/ETH: the feed answers 359,989 and V2 spot 360,000.
    int24 internal constant TICK = -136_339;
    uint256 internal constant FEED_X8 = 359_989;
    uint112 internal constant WOOD_RESERVE = 1e26;
    uint112 internal constant WETH_RESERVE = 120e18;

    SwapWoodFeed internal script;
    DecimalsToken internal wood;
    DecimalsToken internal weth;
    MockUniswapV3PoolRing internal pool;
    V3FactoryStub internal factory;
    MockUniswapV2Pair internal pair;
    MockAggregatorV3 internal ethUsd;
    ExposureLedger internal ledger;
    SwapWoodFeed.Params internal p;

    function setUp() public {
        vm.warp(1_800_000_000);
        script = new SwapWoodFeed();
        wood = new DecimalsToken(18);
        weth = new DecimalsToken(18);
        ethUsd = new MockAggregatorV3(8, 3000e8);
        pair = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);

        factory = new V3FactoryStub();
        pool = _newRing();
        factory.setPool(address(pool));

        // The script's own calls reach the ledger, so the script owns it here.
        ledger = new ExposureLedger(address(script), makeAddr("swood"), 7 days);
        vm.startPrank(address(script));
        ledger.setWoodUsdPrice(1_385_172);
        ledger.setWoodHaircutBps(5000);
        vm.stopPrank();

        p = SwapWoodFeed.Params({
            pool: address(pool),
            factory: address(factory),
            wood: address(wood),
            weth: address(weth),
            ethUsdFeed: address(ethUsd),
            v2Pair: address(pair),
            ledger: address(ledger)
        });
    }

    function _newRing() internal returns (MockUniswapV3PoolRing ring) {
        ring = new MockUniswapV3PoolRing(address(wood), address(weth), TICK, 2e22);
        ring.setFactory(address(factory));
    }

    function _newFeed() internal returns (WoodV3TwapFeed) {
        return new WoodV3TwapFeed(
            p.pool,
            p.wood,
            p.weth,
            p.ethUsdFeed,
            RobinhoodParams.ETH_USD_MAX_AGE,
            WINDOW,
            uint128(RobinhoodParams.MIN_V3_LIQUIDITY)
        );
    }

    /// @dev The ring grown, the feed minted, and a window gone by: the state `swap` expects.
    function _warmFeed() internal returns (WoodV3TwapFeed feed) {
        script.growRingTo(p.pool, RING);
        feed = _newFeed();
        vm.warp(vm.getBlockTimestamp() + WINDOW);
    }

    /// @dev One tick-moving swap in each of the next `n` seconds.
    function _swaps(MockUniswapV3PoolRing ring, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.warp(vm.getBlockTimestamp() + 1);
            (, int24 tick,,,,,) = ring.slot0();
            ring.swap(tick == TICK ? TICK + 1 : TICK);
        }
    }

    // ── growRing ──

    /// @notice The ring target is raised to 3,660 in calls of at most 1,000 slots.
    function test_growRing_reachesTheTargetAThousandSlotsPerCall() public {
        MockUniswapV3Pool counted = new MockUniswapV3Pool(address(wood), address(weth), 3000, 60, address(factory));
        counted.setObservationCardinality(1);

        script.growRingTo(address(counted), RING);

        assertEq(counted.observationCardinalityNext(), RING);
        // 2 -> 1002 -> 2002 -> 3002 -> 3660: the mock's target starts at 2.
        assertEq(counted.cardinalityGrowCalls(), 4);
    }

    /// @notice A ring already at the target is left alone.
    function test_growRing_sendsNothingAtTheTarget() public {
        MockUniswapV3Pool counted = new MockUniswapV3Pool(address(wood), address(weth), 3000, 60, address(factory));
        counted.setObservationCardinality(RING);

        script.growRingTo(address(counted), RING);

        assertEq(counted.cardinalityGrowCalls(), 0);
    }

    // ── preflightFeed ──

    /// @notice A grown ring over a booked pool with matching decimals and a live ETH leg passes.
    function test_preflightFeed_passesOnAGrownRing() public {
        script.growRingTo(p.pool, RING);
        script.preflightFeed(p);
    }

    /// @notice WOOD and WETH of different decimals are refused: the feed would be off by 10^diff.
    function test_preflightFeed_refusesMismatchedDecimals() public {
        script.growRingTo(p.pool, RING);
        p.wood = address(new DecimalsToken(6));
        vm.expectRevert(bytes("PRE-FLIGHT: WOOD and WETH decimals differ - the feed does not normalise them"));
        script.preflightFeed(p);
    }

    /// @notice A pool that names another factory is refused.
    function test_preflightFeed_refusesAPoolOfAnotherFactory() public {
        script.growRingTo(p.pool, RING);
        pool.setFactory(makeAddr("otherFactory"));
        vm.expectRevert(bytes("PRE-FLIGHT: the pool names a different factory"));
        script.preflightFeed(p);
    }

    /// @notice A pool the booked factory does not return from `getPool` is refused.
    function test_preflightFeed_refusesAPoolTheFactoryDoesNotKnow() public {
        script.growRingTo(p.pool, RING);
        factory.setPool(makeAddr("theRealPool"));
        vm.expectRevert(bytes("PRE-FLIGHT: the booked factory does not know this pool"));
        script.preflightFeed(p);
    }

    /// @notice In-range liquidity under the floor is refused; exactly the floor passes.
    function test_preflightFeed_refusesAPoolBelowTheLiquidityFloor() public {
        script.growRingTo(p.pool, RING);
        pool.setLiquidity(uint128(RobinhoodParams.MIN_V3_LIQUIDITY));
        script.preflightFeed(p);

        pool.setLiquidity(uint128(RobinhoodParams.MIN_V3_LIQUIDITY) - 1);
        vm.expectRevert(bytes("PRE-FLIGHT: pool is below MIN_V3_LIQUIDITY"));
        script.preflightFeed(p);
    }

    /// @notice A non-positive ETH/USD answer is refused.
    function test_preflightFeed_refusesADeadEthLeg() public {
        script.growRingTo(p.pool, RING);
        ethUsd.setAnswer(0);
        vm.expectRevert(bytes("PRE-FLIGHT: ETH/USD answer is not positive"));
        script.preflightFeed(p);
    }

    /// @notice An ETH/USD round past the max age is refused; exactly the max age passes.
    function test_preflightFeed_refusesAStaleEthLeg() public {
        script.growRingTo(p.pool, RING);
        uint256 published = vm.getBlockTimestamp();
        vm.warp(published + RobinhoodParams.ETH_USD_MAX_AGE);
        script.preflightFeed(p);

        vm.warp(published + RobinhoodParams.ETH_USD_MAX_AGE + 1);
        vm.expectRevert(bytes("PRE-FLIGHT: ETH/USD round is too old"));
        script.preflightFeed(p);
    }

    /// @notice A ring target of exactly the window is refused; one more slot passes.
    function test_preflightFeed_refusesARingTargetBelowWindowPlusOne() public {
        script.growRingTo(p.pool, uint16(WINDOW));
        vm.expectRevert(bytes("PRE-FLIGHT: ring target below window + 1 - run growRing"));
        script.preflightFeed(p);

        script.growRingTo(p.pool, uint16(WINDOW) + 1);
        script.preflightFeed(p);
    }

    /// @notice A ring that wrapped at three slots is refused until its index reaches the last slot.
    function test_preflightFeed_refusesARingThatWrappedSmall() public {
        pool.increaseObservationCardinalityNext(3);
        _swaps(pool, 3);
        (,, uint16 index, uint16 length,,,) = pool.slot0();
        assertEq(index, 0, "wrapped back to slot 0");
        assertEq(length, 3);

        script.growRingTo(p.pool, RING);
        assertFalse(script.ringCannotEvict(p.pool));
        vm.expectRevert(bytes("PRE-FLIGHT: the ring wrapped at a smaller size - wait until it expands"));
        script.preflightFeed(p);

        _swaps(pool, 2);
        assertTrue(script.ringCannotEvict(p.pool), "on the last slot the next write expands");
        script.preflightFeed(p);
    }

    /// @notice A ring that is still filling, or already longer than the window, cannot evict.
    function test_ringCannotEvict_whileFillingAndOnceFull() public {
        assertFalse(script.ringCannotEvict(p.pool), "the target is still 1");

        script.growRingTo(p.pool, RING);
        assertTrue(script.ringCannotEvict(p.pool), "length 1, index on its last slot");

        _swaps(pool, 5);
        (,, uint16 index, uint16 length,,,) = pool.slot0();
        assertEq(length, RING);
        assertEq(index, 5);
        assertTrue(script.ringCannotEvict(p.pool), "longer than the window");
    }

    /// @notice A ring that expanded to five slots and is still filling them cannot evict.
    function test_ringCannotEvict_whileFillingAnIntermediateSize() public {
        pool.increaseObservationCardinalityNext(5);
        _swaps(pool, 2);
        (,, uint16 index, uint16 length,,,) = pool.slot0();
        assertEq(length, 5);
        assertEq(index, 2, "two of five slots written, not on the last");

        script.growRingTo(p.pool, RING);
        assertTrue(script.ringCannotEvict(p.pool));
    }

    // ── shadow run ──

    /// @notice The shadow read reports each feed's answer, 0 for one that reverts, and V2 spot.
    function test_readBoth_reportsAnAnsweringFeedAndZeroForADeadOne() public {
        WoodV3TwapFeed feed = _warmFeed();
        MockAggregatorV3 oldFeed = new MockAggregatorV3(8, 451_300);

        (uint256 oldX8, uint256 newX8, uint256 spotX8) = script.readBoth(p, address(oldFeed), address(feed));
        assertEq(oldX8, 451_300);
        assertApproxEqAbs(newX8, FEED_X8, 1);
        assertEq(spotX8, 360_000);

        pool.setLiquidity(1);
        (oldX8, newX8,) = script.readBoth(p, address(oldFeed), address(feed));
        assertEq(oldX8, 451_300);
        assertEq(newX8, 0);
    }

    // ── swap ──

    /// @notice The swap wires the feed and seats the cap at twice its answer.
    function test_swap_wiresTheFeedAndSeatsTheCapAtTwiceItsAnswer() public {
        WoodV3TwapFeed feed = _warmFeed();

        uint256 capX8 = script.swapFeed(p, feed);

        assertApproxEqAbs(capX8, 2 * FEED_X8, 2);
        assertEq(ledger.woodUsdPriceX8(), capX8);
        // min(cap, feed) is the feed, at the 50% haircut.
        assertApproxEqAbs(ledger.woodPriceX8(), FEED_X8 / 2, 1);
    }

    /// @notice Before the pool's oldest observation is a window old the swap is refused.
    function test_swap_refusesAFeedThatDoesNotAnswerYet() public {
        script.growRingTo(p.pool, RING);
        WoodV3TwapFeed feed = _newFeed();
        _swaps(pool, 1);

        vm.expectRevert(
            bytes("PRE-FLIGHT: the feed does not answer yet - one window after the pool's oldest observation")
        );
        script.swapFeed(p, feed);
    }

    /// @notice A TWAP more than 10% from V2 spot refuses the swap; 8% passes.
    function test_swap_refusesWhenTheFeedAndV2SpotDisagree() public {
        WoodV3TwapFeed feed = _warmFeed();

        pair.setReserves(WOOD_RESERVE, (WETH_RESERVE * 112) / 100);
        vm.expectRevert(bytes("PRE-FLIGHT: the feed's TWAP and V2 spot disagree - a pump or a fall is in progress"));
        script.swapFeed(p, feed);

        pair.setReserves(WOOD_RESERVE, (WETH_RESERVE * 88) / 100);
        vm.expectRevert(bytes("PRE-FLIGHT: the feed's TWAP and V2 spot disagree - a pump or a fall is in progress"));
        script.swapFeed(p, feed);

        pair.setReserves(WOOD_RESERVE, (WETH_RESERVE * 108) / 100);
        script.swapFeed(p, feed);
    }

    /// @notice A feed whose window, ETH/USD age or liquidity floor is not the booked one is refused.
    function test_swap_refusesAFeedWithOtherNumbers() public {
        script.growRingTo(p.pool, RING);
        uint256 age = RobinhoodParams.ETH_USD_MAX_AGE;
        uint128 floor = uint128(RobinhoodParams.MIN_V3_LIQUIDITY);
        WoodV3TwapFeed[3] memory others = [
            new WoodV3TwapFeed(p.pool, p.wood, p.weth, p.ethUsdFeed, age, 30 minutes, floor),
            new WoodV3TwapFeed(p.pool, p.wood, p.weth, p.ethUsdFeed, age + 1, WINDOW, floor),
            new WoodV3TwapFeed(p.pool, p.wood, p.weth, p.ethUsdFeed, age, WINDOW, floor - 1)
        ];
        vm.warp(vm.getBlockTimestamp() + WINDOW);

        for (uint256 i = 0; i < others.length; i++) {
            vm.expectRevert(bytes("PRE-FLIGHT: the feed's parameters are not the booked ones"));
            script.swapFeed(p, others[i]);
        }
    }

    /// @notice A feed over another pool, token or ETH/USD feed than the booked one is refused.
    function test_swap_refusesAFeedOverOtherAddresses() public {
        WoodV3TwapFeed feed = _warmFeed();
        address other = makeAddr("other");
        SwapWoodFeed.Params[4] memory books = [p, p, p, p];
        books[0].pool = other;
        books[1].wood = other;
        books[2].weth = other;
        books[3].ethUsdFeed = other;

        for (uint256 i = 0; i < books.length; i++) {
            vm.expectRevert(bytes("PRE-FLIGHT: the feed's parameters are not the booked ones"));
            script.swapFeed(books[i], feed);
        }
    }

    /// @notice A ring that wrapped small before it was grown refuses the swap, even with a feed deployed.
    function test_swap_refusesARingThatWrappedSmall() public {
        pool.increaseObservationCardinalityNext(3);
        _swaps(pool, 3);
        script.growRingTo(p.pool, RING);
        WoodV3TwapFeed feed = _newFeed();

        vm.expectRevert(bytes("PRE-FLIGHT: the ring wrapped at a smaller size - wait until it expands"));
        script.swapFeed(p, feed);
    }

    /// @notice An address with no code is refused before anything is read from it.
    function test_swap_refusesAnAddressWithNoFeed() public {
        _warmFeed();
        WoodV3TwapFeed none = WoodV3TwapFeed(makeAddr("noFeed"));
        vm.expectRevert(bytes("PRE-FLIGHT: no feed at WOOD_USD_TWAP_FEED - run deployFeed"));
        script.swapFeed(p, none);
    }

    /// @notice Only the ledger's owner can swap: from anyone else the ledger refuses the call.
    function test_swap_needsTheLedgerOwner() public {
        WoodV3TwapFeed feed = _warmFeed();
        vm.prank(address(script));
        ledger.transferOwnership(makeAddr("safe"));
        vm.prank(makeAddr("safe"));
        ledger.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(script)));
        script.swapFeed(p, feed);
    }
}
