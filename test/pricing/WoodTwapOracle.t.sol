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

    // ── THE PRODUCTION TRIPLE, AND WHY IT IS SHAPED THIS WAY ──
    //
    // The three parameters are cross-constrained:
    //
    //     ethUsdMaxDelay  <=  twapWindow  <=  maxTwapAge  <=  1 day
    //
    // and the binding constraint at the bottom is EMPIRICAL: the live 4663
    // ETH/USD feed was measured ~10.7 HOURS old while perfectly healthy, so any
    // `ethUsdMaxDelay` below that makes the USD leg permanently unavailable —
    // which under design revision 2 is a protocol halt, not a skipped ceiling.
    // 12 hours clears it with margin, and the window must then be at least 12
    // hours too (finding 4: a WOOD/ETH average taken over an hour and converted
    // by a half-day-old ETH quote splices two eras).
    //
    // The old fixture ran 1h / 6h / 2d, which BOTH the finding-4 and finding-5
    // invariants now reject — that combination is precisely the compounding
    // this change closes.
    uint256 internal constant WINDOW = 12 hours;
    uint256 internal constant MAX_AGE = 24 hours;
    uint256 internal constant ETH_DELAY = 12 hours;

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

        // Reaching the absolute floor takes TWO transactions, because the
        // window may not drop below `ethUsdMaxDelay` (finding 4). That
        // ordering requirement is the point, not an inconvenience.
        vm.startPrank(owner);
        oracle.setEthUsdMaxDelay(lo);
        oracle.setTwapWindow(lo);
        vm.stopPrank();
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

    // ── FINDING 5: the window and the age bound must be satisfiable ────────

    /// @notice `MAX_TWAP_WINDOW` was 3 days against a `MAX_SNAPSHOT_AGE_LIMIT`
    ///         of 1 day, so every window above a day was STRUCTURALLY
    ///         unavailable: `update()` refuses a second snapshot before the
    ///         window elapses, by which point the first is already older than
    ///         any legal `maxTwapAge`. The oracle reported unavailable forever
    ///         with no error to point at.
    function test_maxTwapWindow_cannotExceedTheSnapshotAgeLimit() public view {
        assertEq(
            oracle.MAX_TWAP_WINDOW(),
            oracle.MAX_SNAPSHOT_AGE_LIMIT(),
            "a window longer than the age bound can never be fresh"
        );
    }

    /// @notice The invariant is enforced from BOTH sides, so it cannot be
    ///         inverted by moving the other parameter.
    function test_setters_refuseToInvertWindowAndMaxAge() public {
        vm.startPrank(owner);

        // Window above the current age bound: refused.
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setTwapWindow(MAX_AGE + 1 hours);

        // Age bound below the current window: refused.
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setMaxTwapAge(WINDOW - 1 hours);

        // The legal moves are the ones that keep the chain ordered. `MAX_AGE`
        // is already the hard limit here, so the window may grow right up to
        // it — and no further.
        oracle.setTwapWindow(MAX_AGE);
        assertEq(oracle.twapWindow(), MAX_AGE, "a window equal to the age bound is legal");
        vm.stopPrank();
    }

    /// @notice The constructor enforces the same triple. A deploy could
    ///         otherwise seat a configuration no setter would ever accept, and
    ///         nothing downstream revalidates it.
    function test_constructor_refusesAWindowLongerThanTheAgeBound() public {
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        new WoodTwapOracle(owner, address(pair), wood, weth, address(ethUsd), 20 hours, 12 hours, ETH_DELAY);
    }

    // ── FINDING 4: ETH/USD staleness must not compound ─────────────────────

    /// @notice The compound bound. `consult()` may serve a snapshot up to
    ///         `maxTwapAge` old converted by an ETH/USD answer up to
    ///         `ethUsdMaxDelay` old; at the old 7-day ceiling that admitted a
    ///         "current" WOOD/USD price assembled from data eight days stale.
    ///
    /// @dev    The ceiling must not be tightened below the MEASURED healthy
    ///         heartbeat either — 10.7 hours on the live 4663 feed — or the USD
    ///         leg is permanently unavailable and the protocol permanently
    ///         halted. Both directions are asserted, because both are bugs.
    function test_ethUsdDelayLimit_boundsCompoundStalenessWithoutBrickingTheFeed() public view {
        assertLe(oracle.MAX_ETH_USD_DELAY_LIMIT(), 1 days, "compound staleness must be bounded at ~2 days");
        assertGe(
            oracle.MAX_ETH_USD_DELAY_LIMIT(),
            12 hours,
            "must clear the 10.7h heartbeat measured on the live 4663 feed, with margin"
        );
    }

    /// @notice The USD leg may not be staler than the WOOD/ETH average it
    ///         converts. Enforced at CONFIGURATION time, so the alternative —
    ///         an oracle that silently reports unavailable forever — is
    ///         unreachable.
    function test_setters_refuseAnEthDelayLongerThanTheWindow() public {
        vm.startPrank(owner);

        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setEthUsdMaxDelay(WINDOW + 1);

        // And the window cannot be shortened under the delay from the other
        // side either.
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setTwapWindow(ETH_DELAY - 1);

        vm.stopPrank();
    }

    function test_constructor_refusesAnEthDelayLongerThanTheWindow() public {
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        new WoodTwapOracle(owner, address(pair), wood, weth, address(ethUsd), 1 hours, MAX_AGE, 12 hours);
    }

    /// @notice The runtime half: even if the configured delay were somehow
    ///         looser than the window, the read itself takes `min(delay,
    ///         window)` and refuses.
    function test_consult_refusesAnEthAnswerOlderThanTheWindow() public {
        _primeWindow();

        // One second inside the window: still priced.
        ethUsd.setUpdatedAt(vm.getBlockTimestamp() - (WINDOW - 1));
        (, bool ok) = oracle.consult();
        assertTrue(ok, "an ETH answer inside the averaging window is usable");

        // One second outside it: refused.
        ethUsd.setUpdatedAt(vm.getBlockTimestamp() - (WINDOW + 1));
        (, bool stillOk) = oracle.consult();
        assertFalse(stillOk, "an ETH answer older than the window splices two eras");
    }

    // ── FINDING 8: the extrapolated tail is bounded against the SPAN ───────

    /// @notice The old guard compared `idle` to `maxTwapAge`, which is
    ///         `>= twapWindow` by construction — so a pair that had not traded
    ///         for the WHOLE window passed it and produced a "TWAP" that was
    ///         100% extrapolated at spot, exactly reproducing the manipulable
    ///         quantity while still reporting `ok == true`. Exact accumulator
    ///         arithmetic is not a defence when every input is spot.
    function test_update_refusesATailWorthMoreThanAFractionOfTheWindow() public {
        uint256 limit = WINDOW / oracle.MAX_IDLE_SPAN_DIVISOR();

        // A tail at exactly the bound is accepted.
        pair.touch();
        vm.warp(vm.getBlockTimestamp() + limit);
        assertTrue(oracle.update(), "a tail at exactly the bound is fine");

        // One second more is refused — and note this is FAR below `maxTwapAge`,
        // which is what the old guard compared against.
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        pair.touch();
        oracle.update();
        vm.warp(vm.getBlockTimestamp() + limit + 1);
        assertLt(limit + 1, oracle.maxTwapAge(), "the old bound would have let this through");
        assertFalse(oracle.update(), "a tail past the bound must not be snapshotted");
    }

    /// @notice The concrete attack the bound closes: a pair idle across the
    ///         whole window, whose "average" is just whatever spot the last
    ///         swap set. `update()` must refuse to record it at all.
    function test_update_refusesAFullyExtrapolatedSnapshot() public {
        pair.touch();
        oracle.update();

        // Idle for the entire averaging window: every wei of the second
        // snapshot's contribution would be filled in at CURRENT spot.
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        assertLe(WINDOW, oracle.maxTwapAge(), "this is the shape the old guard admitted");
        assertFalse(oracle.update(), "a 100%-extrapolated snapshot is refused");

        // And nothing was recorded, so `consult()` stays unavailable rather
        // than serving the spot reading.
        (, bool ok) = oracle.consult();
        assertFalse(ok, "no completed window from a refused snapshot");
    }

    // ── validatePair ──

    function test_validatePair_catchesAPairThatStoppedBeingThePair() public {
        assertTrue(oracle.validatePair(), "the wired pair is usable at setup");
        pair.setTokens(weth, makeAddr("imposter"));
        assertFalse(oracle.validatePair(), "a re-pointed pair must not validate");
    }
}
