// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWoodPoolFeed} from "../../script/DeployWoodPoolFeed.s.sol";
import {ForkWoodFeedFixture} from "../../script/robinhood-mainnet/ForkWoodFeedFixture.sol";
import {WoodPoolFeed} from "../../src/pricing/WoodPoolFeed.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";

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

/// @notice Drives the REAL `DeployWoodPoolFeed` against a real `WoodPoolFeed`,
///         the verbatim-accumulator V2 pair mock and a Chainlink-shaped feed.
///
/// @dev    THE PARAMS ARE PASSED, NOT SET IN THE ENVIRONMENT: `vm.setEnv` writes
///         the shared process environment, which forge does not roll back and
///         every parallel suite writes to.
///
///         Every `deploy` is pranked as the script: `_c3Factory` bootstraps the
///         CREATE3 factory at `msg.sender` and `c3.deploy` is `onlyOwner`, called
///         by the script itself. A second harness owns a different factory, which
///         is how one test can mint more than one feed off one salt.
contract DeployWoodPoolFeedTest is Test {
    ERC20Mock internal wood;
    ERC20Mock internal weth;
    MockUniswapV2Pair internal uniPair; // WOOD is token0
    MockUniswapV2Pair internal sushiPair; // WOOD is token1
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

    function setUp() public {
        // A real chain time: near zero every idle and staleness check clamps.
        vm.warp(1_700_000_000);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);
        uniPair = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
        sushiPair = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        ethUsdFeed = new MockAggregatorV3(8, ETH_USD_X8);
        script = new DeployWoodPoolFeedHarness();
    }

    // ── The happy path ──

    function test_deploy_seatsEveryParameterAndPricesOnceTheKeeperHasRun() public {
        WoodPoolFeed feed = _deploy(script, _params());

        assertEq(feed.pairA(), address(uniPair), "uni pair");
        assertEq(feed.pairB(), address(sushiPair), "sushi pair");
        assertEq(feed.wood(), address(wood), "wood");
        assertEq(feed.weth(), address(weth), "weth");
        assertEq(feed.window(), WINDOW, "window");
        assertEq(feed.minWethReserve(), MIN_WETH_RESERVE, "depth floor");

        // THE BASELINE IS NOT ENOUGH: one snapshot cannot span a window, so the
        // stage gate holds the ceremony until the keeper has run.
        vm.expectRevert(WoodPoolFeed.PriceUnavailable.selector);
        feed.latestRoundData();
        assertFalse(script.exposed_feedAnswers(address(feed)), "a baseline is not an answer");

        assertApproxEqRel(_primed(feed, uniPair, sushiPair), EXPECTED_WOOD_USD_X8, 0.01e18, "a sane USD spot");
        assertTrue(script.exposed_feedAnswers(address(feed)), "the gate opens once the feed prices");
    }

    /// @dev Which side of a pair holds WOOD is DERIVED by the constructor, and
    ///      reading the wrong accumulator yields the RECIPROCAL — a far larger
    ///      number, which `min` would hide if only one side were wrong. Both
    ///      pairs share an ordering in each half so nothing masks an inversion.
    function test_deploy_derivesTheWoodSideForEitherPairOrdering() public {
        MockUniswapV2Pair alt0 = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
        DeployWoodPoolFeed.Params memory p = _params();
        p.sushiPair = address(alt0);
        uint256 token0Both = _primed(_deploy(new DeployWoodPoolFeedHarness(), p), uniPair, alt0);
        assertApproxEqRel(token0Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token0 in both");

        // Freshly built, so neither is idle past the pre-flight's 5m after the warp above.
        MockUniswapV2Pair alt1 = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        MockUniswapV2Pair alt2 = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        p = _params();
        p.uniPair = address(alt1);
        p.sushiPair = address(alt2);
        uint256 token1Both = _primed(_deploy(new DeployWoodPoolFeedHarness(), p), alt1, alt2);
        assertApproxEqRel(token1Both, EXPECTED_WOOD_USD_X8, 0.01e18, "WOOD as token1 in both");
    }

    /// @notice A resumed run adopts the feed at its CREATE3 address and takes no
    ///         second baseline — another `update()` would roll a primed feed's
    ///         snapshot for no reason.
    function test_deploy_secondRunAdoptsTheFeedAndDoesNotSnapshotAgain() public {
        WoodPoolFeed feed = _deploy(script, _params());
        _primed(feed, uniPair, sushiPair);

        // A full window on, so an `update()` inside `deploy` WOULD roll the snapshot.
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        uniPair.sync();
        sushiPair.sync();
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
        (, uint32 tsBefore) = feed.latestObservation(0);

        WoodPoolFeed again = _deploy(script, _params());

        assertEq(address(again), address(feed), "the same CREATE3 address");
        (, uint32 afterTs) = feed.latestObservation(0);
        assertEq(afterTs, tsBefore, "no second baseline on a resumed run");
    }

    // ── Pre-flights ──

    function test_preflight_bites_whenAPairHoldsTheWrongTokens() public {
        sushiPair.setTokens(address(weth), address(new ERC20Mock("NOT", "NOT", 18)));
        vm.expectRevert(bytes("PRE-FLIGHT: pair does not hold exactly {WOOD, WETH}"));
        _deploy(script, _params());
    }

    function test_preflight_bites_whenAPairHasAZeroReserve() public {
        uniPair.setReserves(WOOD_RESERVE, 0);
        vm.expectRevert(bytes("PRE-FLIGHT: pair has a zero reserve"));
        _deploy(script, _params());
    }

    function test_preflight_bites_whenAPairIsBelowTheDepthFloor() public {
        uniPair.setReserves(WOOD_RESERVE, uint112(MIN_WETH_RESERVE - 1));
        vm.expectRevert(bytes("PRE-FLIGHT: pair is below MIN_WETH_RESERVE"));
        _deploy(script, _params());
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
        _deploy(script, _params());
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
