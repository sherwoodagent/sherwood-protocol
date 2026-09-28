// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWoodPoolFeed} from "../../script/DeployWoodPoolFeed.s.sol";
import {ForkWoodFeedFixture} from "../../script/robinhood-mainnet/ForkWoodFeedFixture.sol";
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
/// @notice The mixin is abstract; this makes it concrete and reaches its internals.
contract DeployWoodPoolFeedHarness is DeployWoodPoolFeed {
    function exposed_feedAnswers(address feed) external view returns (bool) {
        return _feedAnswers(feed);
    }

    function exposed_spotWoodUsdX8(Params memory p, address pair) external view returns (uint256) {
        return _spotWoodUsdX8(p, pair);
    }

    function exposed_requireCapAboveSpot(uint256 capX8, uint256 spotX8) external pure {
        _requireCapAboveSpot(capX8, spotX8);
    }
}

/// @dev Every `deploy` is pranked as the script: `_c3Factory` bootstraps the CREATE3
///      factory at `msg.sender` and `c3.deploy` is `onlyOwner`, called by the script
///      itself. A second harness owns a different factory, which is how one test can
///      mint more than one feed off one salt.
contract DeployWoodPoolFeedTest is Test {
    ERC20Mock internal wood;
    ERC20Mock internal weth;
    MockUniswapV2Pair internal uniPair; // WOOD is token0
    MockUniswapV3Pool internal v3Pool; // WOOD is token0
    MockUniswapV3Factory internal v3Factory;
    MockAggregatorV3 internal ethUsdFeed;
    DeployWoodPoolFeedHarness internal script;

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

    function setUp() public {
        // A real chain time: near zero every idle and staleness check clamps.
        vm.warp(1_700_000_000);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);
        uniPair = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
        v3Factory = new MockUniswapV3Factory();
        v3Pool = _newV3Pool(address(wood), address(weth), V3_TWAP_TICK);
        ethUsdFeed = new MockAggregatorV3(8, ETH_USD_X8);
        script = new DeployWoodPoolFeedHarness();
    }

    // ── The happy path ──

    function test_deploy_seatsEveryParameterAndPricesOnceTheKeeperHasRun() public {
        WoodPoolFeed feed = _deploy(script, _params());

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
        assertFalse(script.exposed_feedAnswers(address(feed)), "a baseline is not an answer");

        assertApproxEqRel(_primed(feed, uniPair), EXPECTED_WOOD_USD_X8, 0.01e18, "a sane USD spot");
        assertTrue(script.exposed_feedAnswers(address(feed)), "the gate opens once the feed prices");
    }

    /// @dev Which side of each venue holds WOOD is DERIVED by the constructor,
    ///      and reading the wrong side yields the RECIPROCAL — a far larger
    ///      number, which `min` would hide if only one leg were wrong. Both
    ///      orderings are deployed, and in each the V3 pool is mirrored with the
    ///      V2 pair so nothing masks an inversion.
    function test_deploy_derivesTheWoodSideForEitherVenueOrdering() public {
        uint256 token0Both = _primed(_deploy(script, _params()), uniPair);
        assertApproxEqRel(token0Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token0 in both");

        // Freshly built, so the pair is not idle past the pre-flight's 5m.
        MockUniswapV2Pair alt = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        DeployWoodPoolFeed.Params memory p = _params();
        p.uniPair = address(alt);
        p.v3Pool = address(_newV3Pool(address(weth), address(wood), -V3_TWAP_TICK));
        uint256 token1Both = _primed(_deploy(script, p), alt);
        assertApproxEqRel(token1Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token1 in both");
    }

    /// @notice A resumed run adopts the feed at its CREATE3 address and takes no
    ///         second baseline — another `update()` would roll a primed feed's
    ///         snapshot for no reason.
    function test_deploy_secondRunAdoptsTheFeedAndDoesNotSnapshotAgain() public {
        WoodPoolFeed feed = _deploy(script, _params());
        _primed(feed, uniPair);

        // A full window on, so an `update()` inside `deploy` WOULD roll the snapshot.
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        uniPair.sync();
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
        (, uint32 tsBefore) = feed.latestObservation();

        WoodPoolFeed again = _deploy(script, _params());

        assertEq(address(again), address(feed), "the same CREATE3 address");
        (, uint32 afterTs) = feed.latestObservation();
        assertEq(afterTs, tsBefore, "no second baseline on a resumed run");
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

    /// @dev THE READ THE FEED'S V3 LEG MAKES. A pool that will not serve the
    ///      live accumulator deploys a feed whose `update()` reverts, i.e. no
    ///      WOOD price at all once the standing snapshots age out.
    function test_preflight_bites_whenTheV3PoolWillNotServeObserve() public {
        v3Pool.setObserveReverts(true);
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool does not serve observe([0])"));
        script.deploy(_params());
    }

    /// @dev A pool that answers the selector but not the contract fails the same
    ///      way: what the pre-flight asserts is a usable reading, not a response.
    function test_preflight_bites_whenTheV3PoolAnswersObserveMalformed() public {
        v3Pool.setObserveShortArray(true);
        vm.expectRevert(bytes("PRE-FLIGHT: V3 pool does not serve observe([0])"));
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

    /// @notice The cap the ledger bounds the governance WOOD price with is refused
    ///         outside [1.25x, 2x] of spot, in either direction.
    function test_preflight_capMustSitBetween125And200PercentOfSpot() public {
        uint256 spot = script.exposed_spotWoodUsdX8(_params(), address(uniPair));
        assertApproxEqRel(spot, EXPECTED_WOOD_USD_X8, 0.01e18, "the spot the band is measured against");

        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_PRICE_CAP_X8 is below 1.25x spot"));
        script.exposed_requireCapAboveSpot((spot * 125) / 100 - 1, spot);

        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_PRICE_CAP_X8 is above 2x spot"));
        script.exposed_requireCapAboveSpot(spot * 2 + 1, spot);

        vm.expectRevert(bytes("PRE-FLIGHT: WOOD spot is zero"));
        script.exposed_requireCapAboveSpot(spot, 0);

        script.exposed_requireCapAboveSpot((spot * 150) / 100, spot);
    }

    // ── The fork fixture ──

    /// @notice A fixture feed on mainnet would price every guardian bond off a number
    ///         the deployer wrote, so the constructor refuses 4663 outright.
    function test_forkFixture_refusesRobinhoodMainnet() public {
        uint256 spot = script.exposed_spotWoodUsdX8(_params(), address(uniPair));
        vm.chainId(4663);
        vm.expectRevert(bytes("ForkWoodFeedFixture: refused on 4663"));
        new ForkWoodFeedFixture(spot);
    }

    function test_forkFixture_refusesAZeroPrice() public {
        vm.expectRevert(bytes("ForkWoodFeedFixture: price is zero"));
        new ForkWoodFeedFixture(0);
    }

    /// @notice The fork's WOOD price is the derived spot, answers immediately (no
    ///         window to wait out) and stays fresh across the warps a governance
    ///         traversal needs.
    function test_forkFixture_answersTheDerivedSpotAndStaysFresh() public {
        uint256 spot = script.exposed_spotWoodUsdX8(_params(), address(uniPair));
        ForkWoodFeedFixture fixtureFeed = new ForkWoodFeedFixture(spot);

        assertEq(fixtureFeed.decimals(), 8, "8 decimals, like WoodPoolFeed");
        assertTrue(script.exposed_feedAnswers(address(fixtureFeed)), "the stage gate opens at once");

        (, int256 answer,, uint256 updatedAt,) = fixtureFeed.latestRoundData();
        assertEq(uint256(answer), spot, "the derived spot, not an invented number");
        assertEq(updatedAt, vm.getBlockTimestamp(), "updatedAt is now");

        vm.warp(vm.getBlockTimestamp() + 30 days);
        (,,, updatedAt,) = fixtureFeed.latestRoundData();
        assertEq(updatedAt, vm.getBlockTimestamp(), "still fresh after time travel");
    }

    /// @dev The gate is a probe, not an assumption: a zero address and a codeless one
    ///      both answer false rather than reverting the ceremony.
    function test_feedAnswers_isFalseForAnAddressWithNoFeed() public view {
        assertFalse(script.exposed_feedAnswers(address(0)), "zero address");
        assertFalse(script.exposed_feedAnswers(address(0xBEEF)), "no code");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev `deploy` bootstraps the Create3Factory at `msg.sender` and then calls
    ///      `c3.deploy` as the SCRIPT, so the broadcaster stand-in is the script itself.
    function _deploy(DeployWoodPoolFeedHarness s, DeployWoodPoolFeed.Params memory p) internal returns (WoodPoolFeed) {
        vm.prank(address(s));
        return s.deploy(p);
    }

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
