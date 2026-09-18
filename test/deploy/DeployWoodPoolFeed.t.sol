// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWoodPoolFeed, GrowV3Cardinality} from "../../script/DeployWoodPoolFeed.s.sol";
import {WoodPoolFeed} from "../../src/pricing/WoodPoolFeed.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";

/// @notice Drives the REAL `DeployWoodPoolFeed` against a real `WoodPoolFeed`,
///         the verbatim-accumulator V2 pair mock, a Uniswap V3 pool mock and a
///         Chainlink-shaped feed.
///
/// @dev    THE PARAMS ARE PASSED, NOT SET IN THE ENVIRONMENT: `vm.setEnv` writes
///         the shared process environment, which forge does not roll back and
///         every parallel suite writes to.
contract DeployWoodPoolFeedTest is Test {
    ERC20Mock internal wood;
    ERC20Mock internal weth;
    MockUniswapV2Pair internal uniPair; // WOOD is token0
    MockUniswapV3Pool internal v3Pool; // WOOD is token0
    MockUniswapV3Factory internal v3Factory;
    MockAggregatorV3 internal ethUsdFeed;
    DeployWoodPoolFeed internal script;

    // The live 4663 reserves and ETH/USD round, so the spot the script prints is
    // the real number an operator would size `WOOD_PRICE_CAP_X8` from.
    uint112 constant WETH_RESERVE = 116.396212703118945372e18;
    uint112 constant WOOD_RESERVE = 49_271_055.055302626679454585e18;
    int256 constant ETH_USD_X8 = 187_199_689_958; // $1871.99688
    uint256 constant EXPECTED_WOOD_USD_X8 = 442_239; // ~$0.00442

    uint256 constant WINDOW = 24 hours;
    uint256 constant ETH_USD_MAX_AGE = 1 days;
    uint256 constant MIN_WETH_RESERVE = 10e18;
    uint128 constant MIN_V3_LIQUIDITY = 1e22;
    uint128 constant V3_LIQUIDITY = 2.128e22;
    /// @dev `1.0001 ** tick` is WETH per WOOD with WOOD as token0. This tick is
    ///      ~4.8e-6, twice the live V2 reserves' ~2.3624e-6, so the V3 leg is
    ///      deliberately NOT the mark: the spot the script prints and the USD
    ///      answer both stay the V2 pair's.
    int24 constant V3_TWAP_TICK = -122475;
    uint24 constant V3_FEE = 3000;
    /// @dev The largest N `GrowV3Cardinality` will broadcast, and the ceiling
    ///      `requiredCardinality` reports against: every slot is initialised
    ///      inside the call, so a bigger ask cannot fit in one transaction.
    uint16 constant MAX_GROW_PER_TX = 1_400;

    function setUp() public {
        // A real chain time: near zero every idle and staleness check clamps.
        vm.warp(1_700_000_000);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);
        uniPair = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
        v3Factory = new MockUniswapV3Factory();
        v3Pool = _newV3Pool(address(wood), address(weth), V3_TWAP_TICK);
        ethUsdFeed = new MockAggregatorV3(8, ETH_USD_X8);
        script = new DeployWoodPoolFeed();
    }

    // ── The happy path ──

    function test_deploy_seatsEveryParameterAndPricesOnceTheKeeperHasRun() public {
        WoodPoolFeed feed = script.deploy(_params());

        assertEq(feed.pairA(), address(uniPair), "uni pair");
        assertEq(feed.pool(), address(v3Pool), "v3 pool");
        assertEq(feed.wood(), address(wood), "wood");
        assertEq(feed.weth(), address(weth), "weth");
        assertEq(feed.window(), WINDOW, "window");
        assertEq(feed.minWethReserve(), MIN_WETH_RESERVE, "depth floor");
        assertEq(feed.minV3Liquidity(), MIN_V3_LIQUIDITY, "v3 depth floor");

        // THE BASELINE IS NOT ENOUGH: one snapshot cannot span a window, so
        // `DeployPlanB`'s pre-flight 8 refuses until the keeper has run.
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();

        assertApproxEqRel(_primed(feed, uniPair), EXPECTED_WOOD_USD_X8, 0.01e18, "a sane USD spot");
    }

    /// @dev Which side of each venue holds WOOD is DERIVED by the constructor,
    ///      and reading the wrong side yields the RECIPROCAL — a far larger
    ///      number, which `min` would hide if only one leg were wrong. Both
    ///      orderings are deployed, and in each the V3 pool is mirrored with the
    ///      V2 pair so nothing masks an inversion.
    function test_deploy_derivesTheWoodSideForEitherVenueOrdering() public {
        uint256 token0Both = _primed(script.deploy(_params()), uniPair);
        assertApproxEqRel(token0Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token0 in both");

        // Freshly built, so the pair is not idle past the pre-flight's 5m.
        MockUniswapV2Pair alt = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        DeployWoodPoolFeed.Params memory p = _params();
        p.uniPair = address(alt);
        p.v3Pool = address(_newV3Pool(address(weth), address(wood), -V3_TWAP_TICK));
        uint256 token1Both = _primed(script.deploy(p), alt);
        assertApproxEqRel(token1Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token1 in both");
    }

    // ── Pre-flights ──

    function test_preflight_bites_whenAPairHoldsTheWrongTokens() public {
        uniPair.setTokens(address(weth), address(new ERC20Mock("NOT", "NOT", 18)));
        vm.expectRevert(bytes("PRE-FLIGHT: pair does not hold exactly {WOOD, WETH}"));
        script.deploy(_params());
    }

    function test_preflight_bites_whenTheV3PoolHoldsTheWrongTokens() public {
        DeployWoodPoolFeed.Params memory p = _params();
        p.v3Pool = address(_newV3Pool(address(weth), address(new ERC20Mock("NOT", "NOT", 18)), V3_TWAP_TICK));
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool does not hold exactly {WOOD, WETH}"));
        script.deploy(p);
    }

    function test_preflight_bites_whenTheV3PoolIsBelowItsLiquidityFloor() public {
        v3Pool.setLiquidity(MIN_V3_LIQUIDITY - 1);
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool is below MIN_V3_LIQUIDITY"));
        script.deploy(_params());
    }

    function test_preflight_bites_whenAPairHasAZeroReserve() public {
        uniPair.setReserves(WOOD_RESERVE, 0);
        vm.expectRevert(bytes("PRE-FLIGHT: pair has a zero reserve"));
        script.deploy(_params());
    }

    function test_preflight_bites_whenAPairIsBelowTheDepthFloor() public {
        uniPair.setReserves(WOOD_RESERVE, uint112(MIN_WETH_RESERVE - 1));
        vm.expectRevert(bytes("PRE-FLIGHT: pair is below MIN_WETH_RESERVE"));
        script.deploy(_params());
    }

    /// @dev THE CHECK THIS SCRIPT EXISTS FOR. A pool that has stopped trading
    ///      constructs a feed happily and then averages its last spot forever.
    function test_preflight_bites_whenAPairHasNotTradedWithinMaxIdle() public {
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1);
        vm.expectRevert(
            bytes(
                "PRE-FLIGHT: pair has no trade in the last 5m - no live market is standing behind "
                "it. On a fork/vnet the pool does not trade at all: generate swaps, or wire a plain "
                "Chainlink-shaped WOOD feed instead."
            )
        );
        script.deploy(_params());
    }

    /// @dev THE CHECK THE CEREMONY'S CARDINALITY STEP EXISTS FOR. The live 4663
    ///      pool reports `observationCardinality` 1, which cannot span 24h: the
    ///      feed would deploy and then revert from every read.
    function test_preflight_bites_whenTheV3PoolCannotSpanTheWindow() public {
        v3Pool.setObserveReverts(true);
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool cannot span TWAP_WINDOW"));
        script.deploy(_params());
    }

    /// @dev A pool that answers the selector but not the contract fails the same
    ///      way: what the pre-flight asserts is a usable window, not a response.
    function test_preflight_bites_whenTheV3PoolAnswersObserveMalformed() public {
        v3Pool.setObserveShortArray(true);
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool cannot span TWAP_WINDOW"));
        script.deploy(_params());
    }

    function test_preflight_bites_whenTheV3PoolKeyIsMissing() public {
        DeployWoodPoolFeed.Params memory p = _params();
        p.v3Pool = address(0);
        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL unset"));
        script.deploy(p);
    }

    /// @dev One venue booked twice is one leg, not two: the `min` that makes the
    ///      feed manipulation-resistant would compare a number with itself.
    function test_preflight_bites_whenBothLegsAreTheSameAddress() public {
        DeployWoodPoolFeed.Params memory p = _params();
        p.v3Pool = p.uniPair;
        vm.expectRevert(bytes("PRE-FLIGHT: the V2 pair and the V3 pool are the same address"));
        script.deploy(p);
    }

    /// @dev A staticcall to an address with no code SUCCEEDS with empty
    ///      returndata, so without this check the first decode fails with a bare
    ///      panic and an operator who fat-fingered the book learns nothing.
    function test_preflight_bites_whenTheV3PoolAddressHasNoCode() public {
        DeployWoodPoolFeed.Params memory p = _params();
        p.v3Pool = makeAddr("notAPool");
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool has no code"));
        script.deploy(p);
    }

    /// @dev THE WRONG-DEPLOYMENT CASE. Chain 4663 carries two Uniswap V3
    ///      deployments, and the canonical factory's WOOD/WETH pools are empty.
    ///      Booking a pool from one deployment against the other factory is an
    ///      operator error no shape check catches — and picking the wrong venue
    ///      silently removes the two-leg `min` the feed leans on.
    function test_preflight_bites_whenTheFactoryDoesNotVouchForTheBookedPool() public {
        MockUniswapV3Factory other = new MockUniswapV3Factory();
        MockUniswapV3Pool otherPool = new MockUniswapV3Pool(address(wood), address(weth), V3_FEE, 60, address(other));
        other.register(address(wood), address(weth), V3_FEE, address(otherPool));

        DeployWoodPoolFeed.Params memory p = _params();
        p.v3Factory = address(other);
        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL is not the factory's pool for (WOOD, WETH, fee)"));
        script.deploy(p);
    }

    /// @dev And the other direction: a pool the factory vouches for but which
    ///      names someone else as its own factory is the same disagreement.
    function test_preflight_bites_whenThePoolNamesADifferentFactory() public {
        v3Pool.setFactory(makeAddr("someOtherDeployment"));
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool does not name WOOD_WETH_UNISWAP_V3_FACTORY as its factory"));
        script.deploy(_params());
    }

    function test_preflight_bites_whenTheV3FactoryKeyIsMissing() public {
        DeployWoodPoolFeed.Params memory p = _params();
        p.v3Factory = address(0);
        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_FACTORY unset"));
        script.deploy(p);
    }

    /// @dev A ring of length one answers `observe` with SPOT rather than
    ///      reverting, so the window check alone passes on a pool with no history
    ///      at all. The gate is on the CURRENT cardinality, which is why the
    ///      ceremony grows the ring and then waits for writes.
    function test_preflight_bites_whenTheV3RingHoldsOnlyTheLiveObservation() public {
        v3Pool.setObservationCardinality(1);
        vm.expectRevert(
            bytes("PRE-FLIGHT: V3 pool has no observation history (cardinality < 2); grow the ring and wait for writes")
        );
        script.deploy(_params());
    }

    // ── The cardinality derivation and its per-transaction bound ──

    /// @dev The knob is SECONDS BETWEEN WRITES, not seconds per block: the ring
    ///      advances only in blocks that touch the pool. At the measured ~880s
    ///      cadence a 24h window needs 99 observations, not 86,400.
    function test_requiredCardinality_countsWritesAndNotBlocks() public view {
        (uint16 n, bool capped) = script.requiredCardinality(24 hours, 880);
        assertEq(n, 109, "ceil(86400/880) = 99, plus 10 slack");
        assertFalse(capped, "well inside one transaction");
    }

    /// @dev A ring longer than one transaction can initialise is capped and SAID
    ///      SO, because it is a different claim: the remedy is several grows, not
    ///      a smaller ring. An uncapped 86,410 is ~1.47e9 gas and reverts.
    function test_requiredCardinality_capsAtWhatOneTransactionCanInitialise() public view {
        (uint16 n, bool capped) = script.requiredCardinality(24 hours, 1);
        assertEq(n, MAX_GROW_PER_TX, "the per-transaction bound");
        assertTrue(capped, "the bound is flagged as a different claim");
    }

    function test_requiredCardinality_isCeilingDivisionPlusSlack() public view {
        (uint16 n, bool capped) = script.requiredCardinality(24 hours, 100);
        assertEq(n, 874, "86400/100 + 10 slack");
        assertFalse(capped, "well inside one transaction");

        // Ceiling, not truncation: 86400/70 is 1234.28, and a ring of 1234
        // observations is one write short of the window.
        (uint16 odd,) = script.requiredCardinality(24 hours, 70);
        assertEq(odd, 1_245, "ceil(86400/70) + 10 slack");
    }

    function test_requiredCardinality_refusesAZeroWriteInterval() public {
        vm.expectRevert(bytes("PRE-FLIGHT: V3_WRITE_INTERVAL_SECONDS zero"));
        script.requiredCardinality(24 hours, 0);
    }

    // ── MIN_V3_LIQUIDITY is narrowed, not truncated ──

    /// @dev The dangerous direction: `uint128(2**128)` is ZERO, i.e. the floor
    ///      an operator asked to RAISE would silently disappear.
    function test_minV3Liquidity_refusesAValueAboveTheUint128Width() public {
        vm.expectRevert(bytes("PRE-FLIGHT: MIN_V3_LIQUIDITY above uint128"));
        script.toMinV3Liquidity(uint256(type(uint128).max) + 1);
    }

    function test_minV3Liquidity_acceptsTheWidthItself() public view {
        assertEq(script.toMinV3Liquidity(type(uint128).max), type(uint128).max, "the boundary is inclusive");
        assertEq(script.toMinV3Liquidity(MIN_V3_LIQUIDITY), MIN_V3_LIQUIDITY, "the deploy default");
    }

    // ── GrowV3Cardinality ──

    /// @dev THE STEP RAISES A TARGET, NOT THE RING. `observationCardinality` is
    ///      what `observe` can actually serve, and it catches up one slot at a
    ///      time as the pool is written to — which is why the ceremony has to
    ///      leave time between this step and the feed deploy, and why asserting
    ///      the ring itself grew here would pin the misconception the script's
    ///      own console output warns against.
    function test_grow_raisesTheTargetAndNotTheRingItself() public {
        GrowV3Cardinality grower = new GrowV3Cardinality();
        (,,, uint16 ringBefore, uint16 targetBefore,,) = v3Pool.slot0();
        assertLt(targetBefore, 200, "control: the target really was below");

        grower.grow(address(v3Pool), 200);

        (,,, uint16 ring, uint16 target,,) = v3Pool.slot0();
        assertEq(target, 200, "the growth target rose");
        assertEq(ring, ringBefore, "the ring itself did NOT grow: it fills as the pool is traded");
    }

    /// @dev Monotonic upstream, so a re-run of the ceremony step is a no-op
    ///      rather than a revert — an operator can repeat it safely. Asserted as
    ///      NO CALL, because a monotonic setter makes "called and ignored"
    ///      indistinguishable from "not called" by state alone.
    function test_grow_isANoOpWhenTheTargetIsAlreadyThatHigh() public {
        GrowV3Cardinality grower = new GrowV3Cardinality();
        grower.grow(address(v3Pool), 1_000);
        assertEq(v3Pool.cardinalityGrowCalls(), 1, "the first ask reached the pool");

        grower.grow(address(v3Pool), 600);
        assertEq(v3Pool.cardinalityGrowCalls(), 1, "a repeat below the standing target broadcasts nothing");
    }

    /// @dev And the same once the ring has actually filled: a pool already
    ///      serving that much history is not asked to pay for more.
    function test_grow_isANoOpWhenTheRingIsAlreadyThatLong() public {
        GrowV3Cardinality grower = new GrowV3Cardinality();
        v3Pool.setObservationCardinality(65_535);
        grower.grow(address(v3Pool), 600);

        (,,, uint16 ring,,,) = v3Pool.slot0();
        assertEq(ring, 65_535, "never shrunk");
        assertEq(v3Pool.cardinalityGrowCalls(), 0, "nothing broadcast");
    }

    function test_grow_refusesATargetAboveTheUint16Ceiling() public {
        GrowV3Cardinality grower = new GrowV3Cardinality();
        vm.expectRevert(bytes("PRE-FLIGHT: V3_CARDINALITY above the uint16 ceiling (65535)"));
        grower.grow(address(v3Pool), 65_536);
    }

    /// @dev THE BOUND THAT ACTUALLY BINDS. Every new slot is initialised inside
    ///      `increaseObservationCardinalityNext` at ~22.4k gas, so the grower pays
    ///      the whole ring up front and a 65,535 ask is ~1.47e9 gas: a
    ///      transaction no node will accept. The script refuses it here rather
    ///      than printing it as a remedy.
    function test_grow_refusesATargetOneTransactionCannotInitialise() public {
        GrowV3Cardinality grower = new GrowV3Cardinality();
        grower.grow(address(v3Pool), MAX_GROW_PER_TX); // control: the bound is inclusive
        assertEq(v3Pool.cardinalityGrowCalls(), 1, "the bound itself is broadcast");

        vm.expectRevert(
            bytes("PRE-FLIGHT: V3_CARDINALITY above what one transaction can initialise (1400); grow in steps")
        );
        grower.grow(address(v3Pool), uint256(MAX_GROW_PER_TX) + 1);
    }

    function test_grow_refusesAnUnsetTargetOrPool() public {
        GrowV3Cardinality grower = new GrowV3Cardinality();

        vm.expectRevert(bytes("PRE-FLIGHT: V3_CARDINALITY unset"));
        grower.grow(address(v3Pool), 0);

        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL unset"));
        grower.grow(address(0), 600);

        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool has no code"));
        grower.grow(makeAddr("notAPool"), 600);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev Built AND vouched for: the pre-flight resolves provenance through the
    ///      factory's `getPool`, so a pool that is not registered is exactly the
    ///      wrong-deployment case rather than a fixture oversight.
    function _newV3Pool(address token0, address token1, int24 twapTick) internal returns (MockUniswapV3Pool p) {
        p = new MockUniswapV3Pool(token0, token1, V3_FEE, 60, address(v3Factory));
        p.setLiquidity(V3_LIQUIDITY);
        p.setTicks(twapTick, twapTick);
        v3Factory.register(token0, token1, V3_FEE, address(p));
    }

    /// @dev The keeper's job: one full window later, with the pair trading, a
    ///      second snapshot rolls in and the feed answers. The V3 leg is live and
    ///      needs no keeper.
    function _primed(WoodPoolFeed feed, MockUniswapV2Pair a) internal returns (uint256) {
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        a.sync();
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
        feed.update();

        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer);
    }

    function _params() internal view returns (DeployWoodPoolFeed.Params memory) {
        return DeployWoodPoolFeed.Params({
            uniPair: address(uniPair),
            v3Pool: address(v3Pool),
            v3Factory: address(v3Factory),
            wood: address(wood),
            weth: address(weth),
            ethUsdFeed: address(ethUsdFeed),
            window: WINDOW,
            ethUsdMaxAge: ETH_USD_MAX_AGE,
            minWethReserve: MIN_WETH_RESERVE,
            minV3Liquidity: MIN_V3_LIQUIDITY
        });
    }
}
