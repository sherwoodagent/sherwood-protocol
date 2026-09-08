// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWoodPoolFeed} from "../../script/DeployWoodPoolFeed.s.sol";
import {WoodPoolFeed} from "../../src/pricing/WoodPoolFeed.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";

/// @notice Drives the REAL `DeployWoodPoolFeed` against a real `WoodPoolFeed`,
///         the verbatim-accumulator V2 pair mock and a Chainlink-shaped feed.
///
/// @dev    THE PARAMS ARE PASSED, NOT SET IN THE ENVIRONMENT: `vm.setEnv` writes
///         the shared process environment, which forge does not roll back and
///         every parallel suite writes to.
contract DeployWoodPoolFeedTest is Test {
    ERC20Mock internal wood;
    ERC20Mock internal weth;
    MockUniswapV2Pair internal uniPair; // WOOD is token0
    MockUniswapV2Pair internal sushiPair; // WOOD is token1
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

    function setUp() public {
        // A real chain time: near zero every idle and staleness check clamps.
        vm.warp(1_700_000_000);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);
        uniPair = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
        sushiPair = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        ethUsdFeed = new MockAggregatorV3(8, ETH_USD_X8);
        script = new DeployWoodPoolFeed();
    }

    // ── The happy path ──

    function test_deploy_seatsEveryParameterAndPricesOnceTheKeeperHasRun() public {
        WoodPoolFeed feed = script.deploy(_params());

        assertEq(feed.pairA(), address(uniPair), "uni pair");
        assertEq(feed.pairB(), address(sushiPair), "sushi pair");
        assertEq(feed.wood(), address(wood), "wood");
        assertEq(feed.weth(), address(weth), "weth");
        assertEq(feed.window(), WINDOW, "window");
        assertEq(feed.minWethReserve(), MIN_WETH_RESERVE, "depth floor");

        // THE BASELINE IS NOT ENOUGH: one snapshot cannot span a window, so
        // `DeployPlanB`'s pre-flight 8 refuses until the keeper has run.
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();

        assertApproxEqRel(_primed(feed, uniPair, sushiPair), EXPECTED_WOOD_USD_X8, 0.01e18, "a sane USD spot");
    }

    /// @dev Which side of a pair holds WOOD is DERIVED by the constructor, and
    ///      reading the wrong accumulator yields the RECIPROCAL — a far larger
    ///      number, which `min` would hide if only one side were wrong. Both
    ///      pairs share an ordering in each half so nothing masks an inversion.
    function test_deploy_derivesTheWoodSideForEitherPairOrdering() public {
        MockUniswapV2Pair alt0 = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
        DeployWoodPoolFeed.Params memory p = _params();
        p.sushiPair = address(alt0);
        uint256 token0Both = _primed(script.deploy(p), uniPair, alt0);
        assertApproxEqRel(token0Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token0 in both");

        // Freshly built, so neither is idle past the pre-flight's 5m after the warp above.
        MockUniswapV2Pair alt1 = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        MockUniswapV2Pair alt2 = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        p = _params();
        p.uniPair = address(alt1);
        p.sushiPair = address(alt2);
        uint256 token1Both = _primed(script.deploy(p), alt1, alt2);
        assertApproxEqRel(token1Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token1 in both");
    }

    // ── Pre-flights ──

    function test_preflight_bites_whenAPairHoldsTheWrongTokens() public {
        sushiPair.setTokens(address(weth), address(new ERC20Mock("NOT", "NOT", 18)));
        vm.expectRevert(bytes("PRE-FLIGHT: pair does not hold exactly {WOOD, WETH}"));
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

    /// @dev The keeper's job: one full window later, with both pools trading, a
    ///      second snapshot rolls in and the feed answers.
    function _primed(WoodPoolFeed feed, MockUniswapV2Pair a, MockUniswapV2Pair b) internal returns (uint256) {
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        a.sync();
        b.sync();
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
        feed.update();

        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer);
    }

    function _params() internal view returns (DeployWoodPoolFeed.Params memory) {
        return DeployWoodPoolFeed.Params({
            uniPair: address(uniPair),
            sushiPair: address(sushiPair),
            wood: address(wood),
            weth: address(weth),
            ethUsdFeed: address(ethUsdFeed),
            window: WINDOW,
            ethUsdMaxAge: ETH_USD_MAX_AGE,
            minWethReserve: MIN_WETH_RESERVE
        });
    }
}
