// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WoodTwapOracle} from "../../src/pricing/WoodTwapOracle.sol";
import {IWoodTwapOracle} from "../../src/interfaces/IWoodTwapOracle.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @title WoodTwapOracleTest
/// @notice Unit tests for the TWAP source that bounds the WOOD governance price.
///
/// @dev    EVERY "UNAVAILABLE" CASE IS A TEST, because unavailable is the safe
///         state this design leans on: the ledger skips its ceiling and falls
///         through to the maintained fallback. A bug that made the oracle
///         confidently return a wrong number instead of `ok == false` is the
///         only way this contract can hurt the protocol, so the negative space
///         is tested at least as hard as the happy path.
///
/// @dev    Reserves mirror the live pair measured 2026-08-01 — 117.296 WETH
///         against 48,359,980.69 WOOD, i.e. WOOD at ~2.4256e-6 ETH — so the
///         expected prices below are the real ones, and a decimal or
///         token-ordering error shows up as an implausible number rather than
///         an abstract mismatch.
contract WoodTwapOracleTest is Test {
    MockUniswapV2Pair internal pair;
    MockAggregatorV3 internal ethUsd;
    WoodTwapOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal wood = makeAddr("wood");
    address internal weth = makeAddr("weth");

    uint112 internal constant RESERVE_WETH = 117_296_418_796_053_125_833;
    uint112 internal constant RESERVE_WOOD = 48_359_980_690_381_159_358_792_759;

    /// @dev $1,867.55, the live 4663 ETH/USD answer on 2026-08-01.
    int256 internal constant ETH_USD_ANSWER = 186_755_036_180;

    uint256 internal constant WINDOW = 1 hours;
    uint256 internal constant MAX_AGE = 6 hours;
    /// @dev The live 4663 ETH/USD feed was measured ~10 hours old while healthy,
    ///      so a tight delay here would make the USD leg permanently
    ///      unavailable. See `MAX_ETH_USD_DELAY_LIMIT` in the oracle.
    uint256 internal constant ETH_DELAY = 2 days;

    function setUp() public {
        // Start the clock somewhere realistic. Forge begins at `block.timestamp
        // == 1`, which leaves no room to express "this feed was last updated
        // ETH_DELAY ago" without underflowing — and warping backwards later is
        // a no-op on this forge version, so the headroom has to exist up front.
        vm.warp(365 days);

        // WETH is token0 on the live pair; keep that ordering so `woodIsToken0`
        // is exercised in the configuration production actually uses.
        pair = new MockUniswapV2Pair(weth, wood, RESERVE_WETH, RESERVE_WOOD);
        ethUsd = new MockAggregatorV3(8, ETH_USD_ANSWER);
        ethUsd.setUpdatedAt(block.timestamp);

        // Give the pair a non-zero accumulator: the constructor refuses a pool
        // that has never traded, which is the V3-empty-shell class of mistake.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.touch();

        oracle = new WoodTwapOracle(owner, address(pair), wood, weth, address(ethUsd), WINDOW, MAX_AGE, ETH_DELAY);
    }

    // ── helpers ──

    /// @dev Advance time, keep the pair interacting, and roll two snapshots in
    ///      so `consult()` has a completed window. Kept as a helper because the
    ///      spacing rule (a snapshot only lands once `twapWindow` has elapsed)
    ///      is easy to get subtly wrong in each test.
    function _primeWindow() internal {
        pair.touch();
        oracle.update();
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        pair.touch();
        oracle.update();
    }

    function _freshenEthFeed() internal {
        ethUsd.setUpdatedAt(vm.getBlockTimestamp());
    }

    // ── happy path ──

    function test_consult_pricesWoodAgainstTheLiveReserveRatio() public {
        _primeWindow();
        _freshenEthFeed();

        (uint256 priceX8, bool ok) = oracle.consult();
        assertTrue(ok, "a completed window with a fresh feed must price");

        // 1 WOOD = RESERVE_WETH / RESERVE_WOOD ETH, times $1,867.55, at 8dp.
        uint256 expected = (uint256(RESERVE_WETH) * uint256(ETH_USD_ANSWER)) / uint256(RESERVE_WOOD);
        assertApproxEqRel(priceX8, expected, 1e12, "WOOD/USD must track the reserve ratio");

        // ~$0.00453. Pinned as an absolute band as well, because a token
        // ordering or decimal slip still satisfies a self-referential formula.
        assertGt(priceX8, 400_000, "price implausibly low - check token ordering");
        assertLt(priceX8, 500_000, "price implausibly high - check token ordering");
    }

    function test_update_isPermissionless() public {
        pair.touch();
        vm.prank(keeper);
        assertTrue(oracle.update(), "any address must be able to snapshot");
    }

    // ── the spacing rule ──

    function test_update_noOpsBeforeTheWindowElapses() public {
        pair.touch();
        oracle.update();

        vm.warp(vm.getBlockTimestamp() + WINDOW - 10);
        pair.touch();
        assertFalse(oracle.update(), "a second snapshot inside the window must not land");

        (, bool ok) = oracle.consult();
        assertFalse(ok, "no completed window yet");
    }

    /// @dev The reason `update()` no-ops instead of reverting: a griefer calling
    ///      one block ahead of the keeper must not be able to fail the keeper's
    ///      transaction, because a failing keeper is how the oracle goes stale.
    function test_update_earlyCallDoesNotRevertTheCaller() public {
        pair.touch();
        oracle.update();
        vm.prank(keeper);
        assertFalse(oracle.update(), "must report not-recorded rather than revert");
    }

    // ── unavailability, i.e. the safe state ──

    function test_consult_unavailableBeforeAnyWindowCompletes() public {
        pair.touch();
        oracle.update();
        (uint256 p, bool ok) = oracle.consult();
        assertFalse(ok, "one observation is not a window");
        assertEq(p, 0, "an unavailable read must not carry a price");
    }

    function test_consult_unavailableWhenTheSnapshotGoesStale() public {
        _primeWindow();
        vm.warp(vm.getBlockTimestamp() + MAX_AGE + 1);
        _freshenEthFeed();

        (, bool ok) = oracle.consult();
        assertFalse(ok, "a snapshot older than maxTwapAge must not price");
    }

    function test_consult_unavailableWhenEthFeedIsStale() public {
        _primeWindow();
        ethUsd.setUpdatedAt(vm.getBlockTimestamp() - ETH_DELAY - 1);

        (, bool ok) = oracle.consult();
        assertFalse(ok, "the USD leg cannot be reconstructed from pair data alone");
    }

    function test_consult_unavailableWhenEthFeedIsNonPositive() public {
        _primeWindow();
        _freshenEthFeed();
        ethUsd.setAnswer(0);

        (, bool ok) = oracle.consult();
        assertFalse(ok, "a non-positive ETH answer must not price");
    }

    /// @dev Serving a stale-but-wide average is not conservative, merely old.
    ///      A keeper outage produces exactly this shape, so it is refused.
    function test_consult_unavailableWhenTheSpanExceedsTheHardCap() public {
        pair.touch();
        oracle.update();
        vm.warp(vm.getBlockTimestamp() + oracle.MAX_TWAP_SPAN() + 1 hours);
        pair.touch();
        oracle.update();
        _freshenEthFeed();

        (, bool ok) = oracle.consult();
        assertFalse(ok, "a span beyond MAX_TWAP_SPAN must not price");
    }

    /// @dev The quiet-pair hazard: `update()` fills the gap since the pair's
    ///      last interaction at CURRENT SPOT, so on an idle pair the "average"
    ///      degrades into a spot reading — the manipulable quantity — while
    ///      still looking healthy. Refused rather than tolerated.
    function test_update_refusesWhenThePairHasGoneQuiet() public {
        pair.touch();
        oracle.update();
        vm.warp(vm.getBlockTimestamp() + MAX_AGE + 1 hours);

        assertFalse(oracle.update(), "an idle pair must not be snapshotted");
    }

    // ── construction guards ──

    function test_constructor_rejectsAPairHoldingOtherTokens() public {
        MockUniswapV2Pair wrong = new MockUniswapV2Pair(weth, makeAddr("other"), RESERVE_WETH, RESERVE_WOOD);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        wrong.touch();

        vm.expectRevert(IWoodTwapOracle.PairNotUsable.selector);
        new WoodTwapOracle(owner, address(wrong), wood, weth, address(ethUsd), WINDOW, MAX_AGE, ETH_DELAY);
    }

    /// @dev The V3 empty-shell class of mistake: an address that resolves and
    ///      answers every getter, holding nothing. Its accumulator is zero, so
    ///      whatever spot the first swap sets would become the "TWAP".
    function test_constructor_rejectsANeverTradedPool() public {
        MockUniswapV2Pair empty = new MockUniswapV2Pair(weth, wood, RESERVE_WETH, RESERVE_WOOD);

        vm.expectRevert(IWoodTwapOracle.PairNotUsable.selector);
        new WoodTwapOracle(owner, address(empty), wood, weth, address(ethUsd), WINDOW, MAX_AGE, ETH_DELAY);
    }

    function test_constructor_derivesTokenOrderingFromThePair() public view {
        assertFalse(oracle.woodIsToken0(), "WOOD is token1 on the live pair shape");
    }

    // ── setters ──

    function test_setTwapWindow_rejectsOutOfBounds() public {
        uint256 lo = oracle.MIN_TWAP_WINDOW();
        uint256 hi = oracle.MAX_TWAP_WINDOW();

        vm.prank(owner);
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setTwapWindow(lo - 1);

        vm.prank(owner);
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setTwapWindow(hi + 1);

        vm.prank(owner);
        oracle.setTwapWindow(lo);
        assertEq(oracle.twapWindow(), lo, "an in-bounds window must be accepted");
    }

    function test_setMaxTwapAge_rejectsZeroAndOverLimit() public {
        uint256 limit = oracle.MAX_SNAPSHOT_AGE_LIMIT();

        vm.prank(owner);
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setMaxTwapAge(0);

        vm.prank(owner);
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setMaxTwapAge(limit + 1);
    }

    function test_setters_areOwnerOnly() public {
        vm.prank(keeper);
        vm.expectRevert();
        oracle.setTwapWindow(2 hours);
    }

    // ── validatePair ──

    function test_validatePair_catchesAPairThatStoppedBeingThePair() public {
        assertTrue(oracle.validatePair(), "the wired pair is usable at setup");
        pair.setTokens(weth, makeAddr("imposter"));
        assertFalse(oracle.validatePair(), "a re-pointed pair must not validate");
    }
}
