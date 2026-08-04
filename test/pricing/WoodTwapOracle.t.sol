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
    // ONE cross-constraint, and it is finding 5: `twapWindow <= maxTwapAge`. A
    // longer window can never be fresh, because `update()` will not roll a
    // second snapshot until the window has elapsed.
    //
    // `ethUsdMaxDelay` is INDEPENDENT, bounded only by
    // `MAX_ETH_USD_DELAY_LIMIT`, and here it is deliberately set LONGER than
    // the window — 24h against 1h. That is the shape production runs, and it is
    // the ACCEPTED RISK: the live 4663 ETH/USD feed was measured ~10.7 HOURS
    // old WHILE HEALTHY, so tying the delay to the window would force a ~12h
    // averaging window and cost the oracle half a day of crash tracking. An
    // earlier revision of this file ran 12h/24h/12h for exactly that reason,
    // and it was the wrong trade (owner decision 2026-08-02).
    uint256 internal constant WINDOW = 1 hours;
    uint256 internal constant MAX_AGE = 12 hours;
    uint256 internal constant ETH_DELAY = 24 hours;

    /// @dev 10.7 hours, the age of the live 4663 ETH/USD answer when it was
    ///      read on 2026-08-01 in a perfectly healthy state. Every bound on the
    ///      USD leg has to clear this or the oracle is unavailable in normal
    ///      operation.
    uint256 internal constant MEASURED_ETH_HEARTBEAT = 38_520;

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

    /// @notice `MAX_ETH_USD_DELAY_LIMIT` is now the ONLY bound on the USD leg's
    ///         staleness tolerance, so it has to actually hold.
    ///
    /// @dev    Untested before this revision, when the tighter
    ///         `ethUsdMaxDelay <= twapWindow` rule masked it — that rule is
    ///         gone, and this ceiling is what stops an operator disabling the
    ///         staleness check outright by passing a decade. Zero is refused at
    ///         the other end: it would make the USD leg unavailable always.
    function test_setEthUsdMaxDelay_rejectsZeroAndOverLimit() public {
        uint256 limit = oracle.MAX_ETH_USD_DELAY_LIMIT();

        vm.prank(owner);
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setEthUsdMaxDelay(0);

        vm.prank(owner);
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setEthUsdMaxDelay(limit + 1);

        vm.prank(owner);
        oracle.setEthUsdMaxDelay(limit);
        assertEq(oracle.ethUsdMaxDelay(), limit, "the ceiling itself is settable");
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

        // Age bound below the current window: refused from the other side.
        vm.expectRevert(IWoodTwapOracle.InvalidParameter.selector);
        oracle.setMaxTwapAge(WINDOW - 1 minutes);

        // The legal moves are the ones that keep the pair ordered: the window
        // may grow right up to the age bound, and no further.
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

    // ── FINDING 4: an ACCEPTED risk, deliberately not eliminated ───────────
    //
    // The two legs are NOT contemporaneous. The WOOD/ETH average is
    // near-real-time; the ETH/USD answer may be up to one heartbeat old, and
    // the live 4663 feed was measured 10.7 HOURS old WHILE HEALTHY. During an
    // ETH drawdown inside that heartbeat the pair ratio rises while the stale,
    // pre-drawdown ETH price is still the multiplier, so WOOD/USD reads high by
    // roughly the ETH move — with NO attacker capital involved.
    //
    // The obvious remedy (require the ETH answer to be no older than
    // `twapWindow`) is unsatisfiable against that heartbeat: it forces a ~12h
    // window, and a 12h window means half a day of blindness to a WOOD crash.
    // That is strictly worse — unbounded in magnitude, fixed in duration —
    // than a bounded overstatement. So the constraint is DROPPED, and the
    // exposure is carried by two controls that already exist: the ledger's
    // price cap truncates anything above it, and `woodHaircutBps` pre-funds an
    // allowance below it. Owner decision 2026-08-02.

    /// @notice The delay ceiling is bounded ABOVE (compound staleness) and
    ///         BELOW (the measured heartbeat). Both directions are bugs.
    ///
    /// @dev    `consult()` may serve a snapshot up to `maxTwapAge` old
    ///         converted by an answer up to `ethUsdMaxDelay` old; at the old
    ///         7-day ceiling that admitted a "current" price assembled from
    ///         data eight days stale. Tightening it below 10.7 hours would make
    ///         the USD leg permanently unavailable on a HEALTHY feed, which
    ///         under design revision 2 is a protocol halt.
    function test_ethUsdDelayLimit_boundsCompoundStalenessWithoutBrickingTheFeed() public view {
        assertLe(oracle.MAX_ETH_USD_DELAY_LIMIT(), 1 days, "compound staleness must be bounded at ~2 days");
        assertGe(
            oracle.MAX_ETH_USD_DELAY_LIMIT(),
            12 hours,
            "must clear the 10.7h heartbeat measured on the live 4663 feed, with margin"
        );
    }

    /// @notice THE CONFIGURATION THE DROPPED CONSTRAINT WOULD HAVE FORBIDDEN,
    ///         and the one production runs: a SHORT averaging window (1h)
    ///         alongside a LONG ETH/USD staleness bound (24h).
    ///
    /// @dev    This is the whole point of the owner's decision. Tying the two
    ///         together would have made this combination unconfigurable and
    ///         forced the window up to ~12h, surrendering the crash tracking
    ///         the oracle exists to provide. Asserted through the constructor
    ///         AND both setters, since the constraint previously lived in all
    ///         three.
    function test_aShortWindowCoexistsWithALongEthUsdDelay() public {
        // Via the constructor.
        WoodTwapOracle fresh =
            new WoodTwapOracle(owner, address(pair), wood, weth, address(ethUsd), 1 hours, MAX_AGE, 24 hours);
        assertEq(fresh.twapWindow(), 1 hours);
        assertEq(fresh.ethUsdMaxDelay(), 24 hours, "the delay may exceed the window");

        // Via the setters, in both orders — neither direction may refuse.
        vm.startPrank(owner);
        fresh.setEthUsdMaxDelay(1 hours);
        fresh.setTwapWindow(2 hours);
        fresh.setEthUsdMaxDelay(24 hours); // raise the delay far above the window
        assertEq(fresh.ethUsdMaxDelay(), 24 hours);
        fresh.setTwapWindow(1 hours); // and shrink the window back under it
        assertEq(fresh.twapWindow(), 1 hours);
        vm.stopPrank();
    }

    /// @notice The accepted exposure, made concrete and pinned: an ETH/USD
    ///         answer OLDER than the averaging window still prices.
    ///
    /// @dev    Pinned as a test so that re-introducing the constraint is a
    ///         deliberate, visible act rather than a silent tightening. The
    ///         answer here is ~10.7 hours old against a 1-hour window — the
    ///         MEASURED healthy state of the live feed, not a degraded one — so
    ///         a version of this contract that refused it would be unavailable
    ///         in normal operation.
    function test_consult_acceptsAnEthAnswerOlderThanTheWindow() public {
        _primeWindow();

        ethUsd.setUpdatedAt(vm.getBlockTimestamp() - MEASURED_ETH_HEARTBEAT);
        assertGt(MEASURED_ETH_HEARTBEAT, WINDOW, "the fixture must actually exercise the accepted case");
        (uint256 priceX8, bool ok) = oracle.consult();
        assertTrue(ok, "a healthy-but-slow ETH heartbeat must NOT make the oracle unavailable");
        assertGt(priceX8, 0);

        // It is still bounded: past `ethUsdMaxDelay` the answer is refused.
        ethUsd.setUpdatedAt(vm.getBlockTimestamp() - (ETH_DELAY + 1));
        (, bool stillOk) = oracle.consult();
        assertFalse(stillOk, "the delay ceiling is what bounds it, not the window");
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

    // ── audit #181 finding 22, applied to this contract ──

    /// @dev Rebuilds the fixture against a hostile ETH/USD feed and primes a
    ///      completed window. Pair and every other parameter match `setUp`'s,
    ///      so any behaviour difference is attributable to the feed alone.
    function _oracleWithFeed(address feed) internal returns (WoodTwapOracle o) {
        MockUniswapV2Pair p = new MockUniswapV2Pair(weth, wood, RESERVE_WETH, RESERVE_WOOD);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        p.touch();
        o = new WoodTwapOracle(owner, address(p), wood, weth, feed, WINDOW, MAX_AGE, ETH_DELAY);
        p.touch();
        o.update();
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        p.touch();
        o.update();
    }

    /// @notice A feed answering with FEWER than five words must report
    ///         unavailable, not revert.
    ///
    ///         This is the shape a typed `try ... returns (uint80, int256,
    ///         uint256, uint256, uint80)` cannot survive: the call SUCCEEDS, so
    ///         `catch` is never entered, and the revert lands afterwards while
    ///         ABI-decoding the too-short returndata. `consult`'s documented
    ///         contract is that a sick feed costs it its answer, so a revert
    ///         here would propagate into the ledger's price path instead.
    function test_ethUsdLeg_shortReturndata_reportsUnavailableInsteadOfReverting() public {
        WoodTwapOracle o = _oracleWithFeed(address(new ShortReturndataFeed()));
        (uint256 priceX8, bool ok) = o.consult();
        assertFalse(ok, "a feed returning 3 words must read unavailable");
        assertEq(priceX8, 0, "and price zero");
    }

    /// @notice A feed answering with the right length but DIRTY high bits in
    ///         the `uint80` slots must still price normally.
    ///
    ///         The narrow `uint80`s are the trap: the ABI decoder rejects a
    ///         word whose unused high bits are not clean padding, so the old
    ///         typed decode reverted uncatchably on this input. Decoding every
    ///         slot as `uint256`/`int256` accepts any 32-byte word, and both
    ///         round-id fields are unused anyway — so the correct outcome is
    ///         not merely "no revert" but a fully healthy price.
    function test_ethUsdLeg_dirtyPaddedRoundIds_stillPrices() public {
        WoodTwapOracle o = _oracleWithFeed(address(new DirtyPaddedFeed()));
        (uint256 priceX8, bool ok) = o.consult();
        assertTrue(ok, "dirty padding in the unused round-id words must not deny an answer");

        uint256 expected = (uint256(RESERVE_WETH) * uint256(ETH_USD_ANSWER)) / uint256(RESERVE_WOOD);
        assertApproxEqRel(priceX8, expected, 1e12, "and the price must be the ordinary one");
    }

    /// @notice A feed reporting absurd `decimals()` must report unavailable,
    ///         not revert on `10 ** decimals` overflow.
    ///
    ///         `_ethUsdFeedDecimals` is captured once at construction and is a
    ///         `uint8`, so 200 is representable.
    ///
    ///         MUTATION-CHECKED, AND THE RESULT CORRECTED AN ASSUMPTION:
    ///         restoring the typed-`try` version fails this test with
    ///         `panic 0x11`, NOT with a graceful `ok == false`. The `try` never
    ///         protected the exponentiation — `catch` covers the external call
    ///         only, never the success-block body, which runs in the calling
    ///         contract's own frame. So this bound closes a second,
    ///         pre-existing uncatchable-revert path rather than compensating
    ///         for one the `staticcall` rewrite introduced.
    function test_ethUsdLeg_absurdFeedDecimals_reportsUnavailableInsteadOfReverting() public {
        WoodTwapOracle o = _oracleWithFeed(address(new AbsurdDecimalsFeed()));
        (uint256 priceX8, bool ok) = o.consult();
        assertFalse(ok, "a feed claiming 200 decimals must read unavailable");
        assertEq(priceX8, 0, "and price zero");
    }
}

/// @notice Answers `latestRoundData()` with three words instead of five.
contract ShortReturndataFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0x80, 1)
            mstore(0xa0, 186755036180)
            mstore(0xc0, timestamp())
            return(0x80, 0x60)
        }
    }
}

/// @notice Answers with five full words, but with garbage in the high bits of
///         the two `uint80` round-id slots — valid for a `uint256` decode,
///         fatal for a `uint80` one.
contract DirtyPaddedFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0x80, not(0)) // roundId: every bit set
            mstore(0xa0, 186755036180) // answer
            mstore(0xc0, timestamp()) // startedAt
            mstore(0xe0, timestamp()) // updatedAt
            mstore(0x100, not(0)) // answeredInRound: every bit set
            return(0x80, 0xa0)
        }
    }
}

/// @notice A well-formed feed that claims 200 decimals, so `10 ** decimals`
///         would overflow.
contract AbsurdDecimalsFeed {
    function decimals() external pure returns (uint8) {
        return 200;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 186755036180, block.timestamp, block.timestamp, 1);
    }
}
