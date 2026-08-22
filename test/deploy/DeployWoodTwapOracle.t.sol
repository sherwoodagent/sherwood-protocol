// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployWoodTwapOracle} from "../../script/DeployWoodTwapOracle.s.sol";
import {WoodTwapOracle} from "../../src/pricing/WoodTwapOracle.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";

/// @notice Drives the REAL `DeployWoodTwapOracle` against a real
///         `WoodTwapOracle`, the verbatim-accumulator V2 pair mock and a real
///         Chainlink-shaped feed.
///
/// @dev    THE PARAMS ARE PASSED, NOT SET IN THE ENVIRONMENT. `vm.setEnv` writes
///         the shared process environment, which forge does not roll back
///         between tests and which every parallel suite writes to — the sibling
///         Plan B suite lost all nine of its tests to exactly that race. The
///         script's `run()` is the thin env adapter; `deploy()` takes the struct,
///         so nothing here is shared. `deploy()` also deliberately does not write
///         `chains/{chainId}.json`, so this suite leaves no junk address book
///         behind.
contract DeployWoodTwapOracleTest is Test {
    // Both 18 decimals, matching chain 4663 — the oracle does no decimals
    // normalisation, which `_preflightPair` pins.
    ERC20Mock internal wood;
    ERC20Mock internal weth;
    MockUniswapV2Pair internal pair;
    MockAggregatorV3 internal ethUsdFeed;
    DeployWoodTwapOracle internal script;

    address internal owner = makeAddr("owner");

    // 116.4 WETH against 49.27M WOOD — the live 4663 reserves, so the spot the
    // script prints is the real number an operator would size a cap from.
    uint112 constant WETH_RESERVE = 116.396212703118945372e18;
    uint112 constant WOOD_RESERVE = 49_271_055.055302626679454585e18;
    // $1871.99688, 8 decimals, as read from the live feed.
    int256 constant ETH_USD_X8 = 187_199_689_958;

    uint256 constant TWAP_WINDOW = 1 hours;
    uint256 constant MAX_TWAP_AGE = 6 hours;
    uint256 constant ETH_USD_MAX_DELAY = 1 days;

    function setUp() public {
        // A non-trivial start time: the idle and staleness checks both subtract
        // from `block.timestamp`, and near timestamp 0 every age clamps to 0 and
        // the guards would pass vacuously.
        vm.warp(1_700_000_000);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);
        // token0 = WETH, token1 = WOOD — the live ordering on 4663.
        pair = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        ethUsdFeed = new MockAggregatorV3(8, ETH_USD_X8);

        // The accumulator is zero until the pair has ticked once, and
        // `validatePair()` requires it non-zero. One elapsed second is enough.
        vm.warp(block.timestamp + 1);
        pair.touch();

        script = new DeployWoodTwapOracle();
    }

    // ── The happy path ──

    function test_deploy_seatsEveryConstructorParameterAndLaysTheBaseline() public {
        WoodTwapOracle oracle = script.deploy(_params());

        assertEq(oracle.owner(), owner, "deployed straight to the final owner, not handed off");
        assertEq(oracle.pair(), address(pair), "pair");
        assertEq(oracle.wood(), address(wood), "wood");
        assertEq(oracle.weth(), address(weth), "weth");
        assertEq(oracle.ethUsdFeed(), address(ethUsdFeed), "ethUsdFeed");
        assertEq(oracle.twapWindow(), TWAP_WINDOW, "twapWindow");
        assertEq(oracle.maxTwapAge(), MAX_TWAP_AGE, "maxTwapAge");
        assertEq(oracle.ethUsdMaxDelay(), ETH_USD_MAX_DELAY, "ethUsdMaxDelay");
        // token0 is WETH here, so the oracle must have derived this from the
        // pair rather than from argument order.
        assertFalse(oracle.woodIsToken0(), "token ordering is derived from the pair");
        assertTrue(oracle.validatePair(), "validatePair");

        (, uint32 ts) = oracle.latestObservation();
        assertEq(ts, uint32(block.timestamp), "the script lays the baseline snapshot itself");
    }

    /// @dev THE BASELINE IS NOT ENOUGH, and the script's printed runbook says so.
    ///      One snapshot leaves `previousObservation` empty, so `consult()` still
    ///      reports unavailable and `DeployPlanB`'s pre-flight 8 still refuses —
    ///      which is what forces an operator to actually run the keeper instead
    ///      of assuming the deploy primed it.
    function test_deploy_leavesTheOracleUnpricedUntilTheKeeperRuns() public {
        WoodTwapOracle oracle = script.deploy(_params());

        (, bool ok) = oracle.consult();
        assertFalse(ok, "one snapshot cannot span a window");

        // The keeper's job: a second snapshot a full window later.
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        pair.touch();
        assertTrue(oracle.update(), "the keeper's snapshot must roll in");

        (uint256 priceX8, bool ok2) = oracle.consult();
        assertTrue(ok2, "two snapshots a window apart price WOOD");
        // 116.396e18 / 49_271_055e18 * 1871.99688 ~= $0.00442, i.e. ~442_2xx at 8dp.
        assertApproxEqRel(priceX8, 442_239, 0.01e18, "the composed price must track the live reserves");
    }

    // ── Pre-flights ──

    /// @dev THE CHECK THIS SCRIPT EXISTS FOR. A pool that has stopped trading
    ///      still passes `validatePair()`, so the constructor accepts it happily
    ///      and `update()` then no-ops forever against
    ///      `idle * MAX_IDLE_SPAN_DIVISOR > twapWindow`. That is the dominant
    ///      failure on a fork, where the pool stops trading at the fork point.
    function test_preflight_bites_whenThePairIsTooIdleForTheWindow() public {
        // twapWindow / 20 = 180s. Push idle just past it.
        vm.warp(block.timestamp + 181);

        vm.expectRevert(
            bytes(
                "PRE-FLIGHT: pair too idle for this TWAP_WINDOW - update() would no-op forever. "
                "The pool must trade at least every twapWindow/20 seconds. On a fork/vnet the pool "
                "does not trade at all: generate swaps, or wire a Chainlink WOOD feed instead."
            )
        );
        script.deploy(_params());
    }

    /// @dev The paired passing case, so the bound is pinned from both sides
    ///      rather than only proven to fire eventually.
    function test_preflight_passes_atTheIdleBoundary() public {
        vm.warp(block.timestamp + 179);
        script.deploy(_params());
    }

    function test_preflight_bites_whenThePairHoldsTheWrongTokens() public {
        pair.setTokens(address(weth), address(new ERC20Mock("NOT", "NOT", 18)));

        vm.expectRevert(bytes("PRE-FLIGHT: pair does not hold exactly {WOOD, WETH}"));
        script.deploy(_params());
    }

    /// @dev `consult()` multiplies the pair's RAW UQ112x112 ratio by ETH/USD with
    ///      no decimals normalisation anywhere, so a mismatched pair would price
    ///      WOOD off by orders of magnitude while every other check passed.
    ///      Nothing in the oracle asserts this, which is why the script does.
    function test_preflight_bites_whenWoodAndWethDecimalsDiffer() public {
        ERC20Mock wood6 = new ERC20Mock("WOOD", "WOOD", 6);
        MockUniswapV2Pair p6 = new MockUniswapV2Pair(address(weth), address(wood6), WETH_RESERVE, WOOD_RESERVE);
        vm.warp(block.timestamp + 1);
        p6.touch();

        DeployWoodTwapOracle.Params memory p = _params();
        p.pair = address(p6);
        p.wood = address(wood6);

        vm.expectRevert(bytes("PRE-FLIGHT: WOOD and WETH decimals differ - the oracle does not normalise them"));
        script.deploy(p);
    }

    /// @dev The constructor reads the ETH feed's `decimals()` and nothing else,
    ///      so an oracle deployed against a dead feed constructs cleanly and then
    ///      reports unavailable with nothing on-chain explaining why.
    function test_preflight_bites_whenTheEthFeedIsAlreadyStale() public {
        vm.warp(block.timestamp + ETH_USD_MAX_DELAY + 1);
        // Keep the pair fresh so the idle guard is not what fires.
        pair.touch();

        vm.expectRevert(bytes("PRE-FLIGHT: ETH/USD feed is already staler than ETH_USD_MAX_DELAY"));
        script.deploy(_params());
    }

    function test_preflight_bites_whenTheEthFeedAnswerIsNotPositive() public {
        ethUsdFeed.setAnswer(0);

        vm.expectRevert(bytes("PRE-FLIGHT: ETH/USD feed answer is not positive"));
        script.deploy(_params());
    }

    function test_preflight_bites_whenTheWindowExceedsTheAgeBound() public {
        DeployWoodTwapOracle.Params memory p = _params();
        p.twapWindow = MAX_TWAP_AGE + 1 hours;

        vm.expectRevert(bytes("PRE-FLIGHT: TWAP_WINDOW exceeds MAX_TWAP_AGE"));
        script.deploy(p);
    }

    function test_preflight_bites_whenTheWindowIsBelowTheFloor() public {
        DeployWoodTwapOracle.Params memory p = _params();
        p.twapWindow = 59 minutes;

        vm.expectRevert(bytes("PRE-FLIGHT: TWAP_WINDOW below MIN_TWAP_WINDOW (1h)"));
        script.deploy(p);
    }

    function test_preflight_bites_whenThePairIsUnset() public {
        DeployWoodTwapOracle.Params memory p = _params();
        p.pair = address(0);

        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_WETH_V2_PAIR unset"));
        script.deploy(p);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _params() internal view returns (DeployWoodTwapOracle.Params memory) {
        return DeployWoodTwapOracle.Params({
            pair: address(pair),
            wood: address(wood),
            weth: address(weth),
            ethUsdFeed: address(ethUsdFeed),
            twapWindow: TWAP_WINDOW,
            maxTwapAge: MAX_TWAP_AGE,
            ethUsdMaxDelay: ETH_USD_MAX_DELAY,
            owner: owner
        });
    }
}
