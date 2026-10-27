// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WoodPoolFeed} from "src/pricing/WoodPoolFeed.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {MockUniswapV2Pair} from "test/mocks/MockUniswapV2Pair.sol";
import {MockUniswapV3PoolRing} from "test/mocks/MockUniswapV3PoolRing.sol";
import {MockAggregatorV3} from "test/mocks/MockAggregatorV3.sol";

/// @dev The only sWOOD reads the ledger makes.
contract RingAttackSwood {
    mapping(address => uint256) public guardianStake;

    function coolDownPeriod() external pure returns (uint256) {
        return 7 days;
    }

    function slashableStakeAt(address guardian, uint256) external view returns (uint256) {
        return guardianStake[guardian];
    }
}

contract RingAttackAssetFeed {
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice v1 audit F2. The V3 pool's observation ring is written by ANY swapper,
///         so a backward-looking `observe([window])` is only as deep as the
///         fastest writer allows. The leg reads accumulators at snapshot time
///         instead, and these tests hold it to that against a REAL ring.
contract WoodPoolFeedRingAttackTest is Test {
    address internal constant WOOD = address(uint160(0xD00D));
    address internal constant WETH = address(uint160(0xE7E7));

    uint112 internal constant WOOD_RESERVE = 1e26;
    uint112 internal constant WETH_RESERVE = 240e18;
    uint256 internal constant MIN_WETH = 100e18;
    uint128 internal constant MIN_V3_LIQUIDITY = 1e22;
    uint128 internal constant V3_LIQUIDITY = 2e22;
    uint256 internal constant WINDOW = 24 hours;
    uint256 internal constant ETH_MAX_AGE = 24 hours;
    int256 internal constant ETH_USD_X8 = 3000e8;

    /// @dev Half the V2 pair's price, so the V3 leg is the one `min` marks and
    ///      an assertion on the answer is an assertion on THIS leg.
    int24 internal constant TICK = -136_339;
    uint256 internal constant V3_ANSWER_X8 = 360_000;

    uint256 internal constant CAP_X8 = 1e8;
    uint256 internal constant FEED_MAX_DELAY = WINDOW + 2 hours;

    /// @dev `RobinhoodParams.V3_WRITE_INTERVAL_SECONDS` as the deleted ceremony
    ///      measured it, and the ring it sized from that: ceil(86400/880) + 10.
    uint256 internal constant WRITE_INTERVAL = 880;
    uint16 internal constant CEREMONY_CARDINALITY = 109;

    MockUniswapV2Pair internal uni;
    MockUniswapV3PoolRing internal v3;
    MockAggregatorV3 internal ethUsd;
    WoodPoolFeed internal feed;
    ExposureLedger internal ledger;
    address internal owner = makeAddr("owner");
    address internal usdgAsset;

    int24 internal wiggle;

    function setUp() public {
        vm.warp(1_800_000_000);

        uni = new MockUniswapV2Pair(WOOD, WETH, WOOD_RESERVE, WETH_RESERVE);
        v3 = new MockUniswapV3PoolRing(WOOD, WETH, TICK, V3_LIQUIDITY);
        ethUsd = new MockAggregatorV3(8, ETH_USD_X8);
        v3.increaseObservationCardinalityNext(CEREMONY_CARDINALITY);

        feed = new WoodPoolFeed(
            address(uni), address(v3), WOOD, WETH, address(ethUsd), ETH_MAX_AGE, WINDOW, MIN_WETH, MIN_V3_LIQUIDITY
        );

        // Organic history at the measured cadence, keeper running alongside.
        feed.update();
        for (uint256 i = 0; i < 130; i++) {
            _tick(WRITE_INTERVAL);
        }
        feed.update();

        ledger = new ExposureLedger(owner, address(new RingAttackSwood()), 28 days);
        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodFeed(address(feed), FEED_MAX_DELAY);
        ledger.setAssetFeed(usdgAsset, address(new RingAttackAssetFeed()), 365 days);
        vm.stopPrank();
    }

    /// @dev One block: time moves, the V2 keeper's pair accrues, the ETH leg is
    ///      republished, and ONE swap moves the V3 tick by a single step.
    function _tick(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        uni.sync();
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
        wiggle = wiggle == 0 ? int24(1) : int24(0);
        v3.swap(TICK + wiggle);
    }

    function _answer() internal view returns (uint256) {
        (, int256 a,,,) = feed.latestRoundData();
        return uint256(a);
    }

    /// @dev The ring cannot serve `window` any more, which is what made the leg
    ///      unavailable before the fix.
    function _assertRingCannotServeTheWindow() internal {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = uint32(WINDOW);
        vm.expectRevert(bytes("OLD"));
        v3.observe(secondsAgos);
    }

    /// @notice CONTROL. The ring the deleted ceremony sized, filled at the
    ///         measured cadence, serves the window and prices WOOD.
    function test_control_theCeremonySizedRingServesTheWindow() public view {
        assertEq(v3.observationCardinality(), CEREMONY_CARDINALITY, "the ring reached its target");
        assertEq(
            v3.ringSpan(),
            uint32((CEREMONY_CARDINALITY - 1) * WRITE_INTERVAL),
            "span = (cardinality - 1) writes at the measured cadence"
        );
        assertGt(v3.ringSpan(), WINDOW, "and that clears the window");
        assertApproxEqRel(_answer(), V3_ANSWER_X8, 1e15, "the V3 leg is the mark");
    }

    /// @notice THE FINDING, INVERTED. 109 dust swaps evict every honest
    ///         observation and `observe([window])` dies with it — and the feed
    ///         answers anyway, at the pool's true average, because the leg is
    ///         priced off accumulator readings the attacker cannot reach.
    function test_dustSwapsEvictTheRingAndTheFeedStillAnswers() public {
        uint256 before = _answer();
        uint256 writesBefore = v3.writes();

        // One swap per second. No privileges, no size: only the TICK has to move.
        for (uint256 i = 0; i < CEREMONY_CARDINALITY; i++) {
            _tick(1);
        }
        assertEq(v3.writes() - writesBefore, CEREMONY_CARDINALITY, "109 observations, 109 swaps");
        assertEq(v3.ringSpan(), uint32(CEREMONY_CARDINALITY - 1), "the ring now reaches 108 seconds back");
        _assertRingCannotServeTheWindow();

        assertEq(_answer(), before, "an evicted ring is not the feed's history");
        assertApproxEqRel(before, V3_ANSWER_X8, 1e15, "and the answer is the pool's true mean tick");

        // Every WOOD-priced path stays open, `ChallengeGame.file`'s among them.
        assertGt(ledger.woodPriceX8(), 0, "the ledger prices WOOD");
        assertGt(ledger.proposerBondWood(usdgAsset, 1_000e6), 0, "propose sizes a bond");
        assertEq(ledger.slashableBondUsd(makeAddr("someGuardian")), 0, "and file reads a bond basis, not a revert");
    }

    /// @notice The KEEPER survives it too: a whole window in which the attacker
    ///         owns the ring at both ends still snapshots, and the average that
    ///         roll produces is the pool's true mean tick.
    function test_theFeedRollsAcrossAWindowTheAttackerKeepsEvicting() public {
        for (uint256 i = 0; i < 300; i++) {
            _tick(1);
        }
        for (uint256 i = 0; i < 98; i++) {
            _tick(WRITE_INTERVAL);
        }
        for (uint256 i = 0; i < 300; i++) {
            _tick(1);
        }

        feed.update();
        _assertRingCannotServeTheWindow();
        assertApproxEqRel(_answer(), V3_ANSWER_X8, 1e15, "the rolled average is the pool's own");
    }

    /// @notice WHY A BIGGER RING WAS NEVER THE ANSWER. `Oracle.write` dedupes on
    ///         the block TIMESTAMP, so N slots span at most N-1 SECONDS against a
    ///         writer that swaps every second — and N is a `uint16`, so the
    ///         longest ring anyone can pay for reaches 18h12m, under MIN_WINDOW.
    function test_noRingCanServeTheWindowAgainstAPerSecondWriter() public {
        uint16 n = 200;
        v3.increaseObservationCardinalityNext(n);
        for (uint256 i = 0; i < 400; i++) {
            _tick(1);
        }
        assertEq(v3.observationCardinality(), n, "grown");
        assertEq(v3.ringSpan(), uint32(n - 1), "N slots, one per second, N-1 seconds of reach");

        // Same second, second swap: no new slot. Sub-second blocks buy the
        // honest side nothing.
        uint256 writesBefore = v3.writes();
        v3.swap(TICK + 7);
        v3.swap(TICK + 8);
        assertEq(v3.writes(), writesBefore, "one observation per SECOND, not per block");

        assertLt(uint256(type(uint16).max) - 1, feed.MIN_WINDOW(), "65,534 s < 24 h");
    }
}
