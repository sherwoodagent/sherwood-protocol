// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWoodPoolFeed} from "../../script/DeployWoodPoolFeed.s.sol";
import {WoodPoolFeed} from "../../src/pricing/WoodPoolFeed.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";

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

    function setUp() public {
        // A real chain time: near zero every idle and staleness check clamps.
        vm.warp(1_700_000_000);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);
        uniPair = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
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

    // ─────────────────────────────── helpers ───────────────────────────────

    function _newV3Pool(address token0, address token1, int24 twapTick) internal returns (MockUniswapV3Pool p) {
        p = new MockUniswapV3Pool(token0, token1, 3000, 60, makeAddr("v3Factory"));
        p.setLiquidity(V3_LIQUIDITY);
        p.setTicks(twapTick, twapTick);
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
