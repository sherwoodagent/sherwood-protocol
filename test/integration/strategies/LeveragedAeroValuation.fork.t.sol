// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {LeveragedAeroValuation} from "../../../src/strategies/LeveragedAeroValuation.sol";
import {ChainlinkReader} from "../../../src/libraries/ChainlinkReader.sol";
import {IAggregatorV3} from "../../../src/interfaces/IAggregatorV3.sol";
import {ICLPool, ICLGauge, ICLSwapRouter, INonfungiblePositionManager} from "../../../src/interfaces/ISlipstream.sol";
import {IMoonwellMarket, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {TickMath} from "../../../src/libraries/TickMath.sol";

/// @dev External wrapper so `vm.expectRevert` can intercept the internal-library reverts of
///      `LeveragedAeroValuation.netEquityUsdc`. An internal library call inlines into the caller
///      frame; `expectRevert` needs an external call boundary to catch it. Mirrors the
///      `ValuationHarness` in `test/LeveragedAeroValuation.t.sol`.
contract ForkValuationHarness {
    function netEquityUsdc(
        LeveragedAeroValuation.Config memory c,
        address strategy,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external view returns (uint256) {
        return LeveragedAeroValuation.netEquityUsdc(c, strategy, tickLower, tickUpper, liquidity);
    }
}

/// @title  LeveragedAeroValuationFork
/// @notice HEADLINE manipulation-resistance proof for the leveraged Aerodrome CL strategy's
///         oracle NAV, run against a REAL Aerodrome Slipstream pool + Moonwell book on a Tenderly
///         Base vnet. This is the single most important piece of evidence that the design defeats
///         the "mint cheap shares via tick-shove" attack:
///
///           (a) Tick-shove invariance -- shoving the pool tick moves a naive slot0-priced NAV
///               (>2%) but does NOT move the oracle NAV (<=0.5%). slot0-pricing IS shoveable; the
///               oracle design defeats it. THIS contrast is the load-bearing proof.
///           (b) Calm-gate fail-closed -- with the production gate, a large shove makes the whole
///               `netEquityUsdc` revert `CalmGateBreached` (spot vs TWAP > 500 ticks).
///           (c) Oracle fail-closed on the LIVE position -- feed staleness / sequencer down /
///               grace window each revert the WHOLE NAV via the `ChainlinkReader` guards.
///           (d) Realizable-exit bound -- a real partial unwind realizes USDC within 2% of the
///               oracle NAV's pro-rata mark (the oracle is a faithful, slightly-conservative mark).
///
///         The contract is itself an `IERC721Receiver` with a payable `receive()`: on this vnet a
///         `makeAddr` EOA is invoked as `onERC721Received` by the gauge's `safeTransferFrom` (and
///         reverts), so the unwind in (d) runs with `address(this)` as the position holder. The
///         `receive()` is required because Moonwell's mWETH `borrow` delivers NATIVE ETH to the
///         borrower (a plain contract would reject it). Tests (a)-(c) never withdraw the NFT, so
///         they use a `makeAddr` EOA actor.
///
///         Forks only if TENDERLY_FORK_RPC_URL is set; else every test skips and passes trivially:
///           forge test --match-path '*LeveragedAeroValuation.fork.t.sol' -vvv
contract LeveragedAeroValuationFork is LeveragedAeroForkBase, IERC721Receiver {
    uint256 internal constant PRINCIPAL = 50_000e6; // 50k USDC

    ForkValuationHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new ForkValuationHarness();
    }

    /// @dev Accept the gauge's `safeTransferFrom` of the CL NFT during the (d) unwind.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Accept the native ETH that Moonwell's mWETH `borrow` forwards to the borrower.
    receive() external payable {}

    // -------------------------------------------------------------------------
    // (a) Manipulation-resistance -- the load-bearing proof.
    // -------------------------------------------------------------------------

    /// @notice Shoving the pool tick moves a naive slot0-priced NAV but NOT the oracle NAV.
    /// @dev Uses a WIDE calm bound for THIS test so the calm-gate doesn't fire -- this isolates
    ///      the "oracle sqrtP vs slot0 sqrtP" property (the leg split). The feeds did not move,
    ///      only the pool tick did, so the oracle NAV must be stable while the naive NAV moves.
    ///      The shove is sized to push the pool tick fully past the position's lower band so the
    ///      slot0 leg split saturates to one-sided -- the regime where naive NAV drifts hardest
    ///      (measured ~2.75% on the live ts=100 cbBTC/WETH pool; see the task report for the probe).
    function test_a_tickShove_oracleNavInvariant_naiveNavMoves() public {
        if (_skip) return;

        address alice = makeAddr("alice");
        (uint256 tokenId, int24 tl, int24 tu, uint128 liq) = _openRealBook(alice, PRINCIPAL);
        assertGt(tokenId, 0, "open book failed");
        assertGt(liq, 0, "no liquidity");

        // Wide calm bound: isolate the oracle-vs-slot0 price property from the calm-gate.
        LeveragedAeroValuation.Config memory wideCfg = _cfg();
        wideCfg.calmDeviationTicks = type(uint16).max;

        uint256 navBefore = LeveragedAeroValuation.netEquityUsdc(wideCfg, alice, tl, tu, liq);
        uint256 naiveBefore = _naiveSlot0Nav(wideCfg, alice, tl, tu, liq);
        (, int24 tickBefore,,,,) = ICLPool(POOL).slot0();
        console2.log("navBefore (oracle, USDC 6dp):", navBefore);
        console2.log("naiveBefore (slot0, USDC 6dp):", naiveBefore);
        console2.logInt(tickBefore);

        // BOUNDED shove: sell WETH (token0) but stop the swap just below the position's lower
        // band via a sqrtPriceLimit. This pushes the slot0 split fully one-sided (saturating the
        // naive NAV) while keeping the tick move small (~2.1k ticks) so the wide-cfg calm bound
        // (uint16 max = 65535) still tolerates it -- without the bound the swap free-falls through
        // a liquidity gap to a ~138k-tick move, which even the widest uint16 gate would reject.
        int24 targetTick = tl - _belowBandTicks();
        int24 newTick = _shoveTickTo(targetTick);
        assertFalse(newTick == tickBefore, "tick did not move after shove");
        assertLt(newTick, tl, "shove did not push the tick below the position band");
        console2.logInt(newTick);

        uint256 navAfter = LeveragedAeroValuation.netEquityUsdc(wideCfg, alice, tl, tu, liq);
        uint256 naiveAfter = _naiveSlot0Nav(wideCfg, alice, tl, tu, liq);
        console2.log("navAfter (oracle, USDC 6dp):", navAfter);
        console2.log("naiveAfter (slot0, USDC 6dp):", naiveAfter);

        // CORE ASSERTION 1: oracle NAV is stable -- the feeds didn't move, only the pool tick.
        assertApproxEqRel(navAfter, navBefore, 0.005e18, "oracle NAV moved on tick-shove (>0.5%)");

        // CORE ASSERTION 2 (the contrast): the naive slot0 NAV moved meaningfully. THIS is the
        // proof that slot0-pricing IS tick-shoveable and the oracle design defeats it.
        uint256 naiveDrift = _absRelDiff(naiveAfter, naiveBefore);
        console2.log("naive |rel diff| (1e18):", naiveDrift);
        assertGt(naiveDrift, 0.02e18, "naive slot0 NAV did not move >2% -- shove too small to prove contrast");
    }

    // -------------------------------------------------------------------------
    // (b) Calm-gate fail-closed.
    // -------------------------------------------------------------------------

    /// @notice With the PRODUCTION calm gate (500 ticks), a large shove makes the whole
    ///         `netEquityUsdc` revert `CalmGateBreached` (spot vs TWAP deviation > 500).
    function test_b_calmGate_failsClosed_onLargeShove() public {
        if (_skip) return;

        address alice = makeAddr("alice");
        (uint256 tokenId, int24 tl, int24 tu, uint128 liq) = _openRealBook(alice, PRINCIPAL);
        assertGt(tokenId, 0, "open book failed");

        LeveragedAeroValuation.Config memory cfg = _cfg(); // production calmDeviationTicks = 500

        // Sanity: NAV is computable before the shove (gate not breached at rest).
        uint256 navOk = LeveragedAeroValuation.netEquityUsdc(cfg, alice, tl, tu, liq);
        assertGt(navOk, 0, "pre-shove NAV should be positive");

        // Shove large enough that |spotTick - twapTick| exceeds 500 (saturating past the band
        // drives spot ~100k+ ticks from the fresh-fork TWAP -- far past the 500-tick gate).
        int24 newTick = _shoveTick(_shoveSizeForCalmBreach(), true);
        console2.logInt(newTick);

        // Whole NAV must fail closed (the calm-gate runs first in netEquityUsdc).
        vm.expectRevert(LeveragedAeroValuation.CalmGateBreached.selector);
        harness.netEquityUsdc(cfg, alice, tl, tu, liq);
    }

    // -------------------------------------------------------------------------
    // (c) Oracle fail-closed on the LIVE position.
    // -------------------------------------------------------------------------

    /// @notice A stale BTC/USD feed reverts the WHOLE NAV (`ChainlinkReader.StaleOracle`).
    function test_c_failsClosed_onStaleBtcFeed() public {
        if (_skip) return;

        address alice = makeAddr("alice");
        (uint256 tokenId, int24 tl, int24 tu, uint128 liq) = _openRealBook(alice, PRINCIPAL);
        assertGt(tokenId, 0, "open book failed");

        LeveragedAeroValuation.Config memory c = _cfg();

        // Mock the BTC/USD feed to report data older than maxDelay -> StaleOracle.
        _mockFeedStale(c.cbBTCFeed, c.maxDelay);

        vm.expectRevert(ChainlinkReader.StaleOracle.selector);
        harness.netEquityUsdc(c, alice, tl, tu, liq);
    }

    /// @notice A "down" sequencer (answer == 1) reverts the WHOLE NAV (`SequencerDown`).
    function test_c_failsClosed_onSequencerDown() public {
        if (_skip) return;

        address alice = makeAddr("alice");
        (uint256 tokenId, int24 tl, int24 tu, uint128 liq) = _openRealBook(alice, PRINCIPAL);
        assertGt(tokenId, 0, "open book failed");

        LeveragedAeroValuation.Config memory c = _cfg();

        // answer == 1 ==> sequencer reported down.
        _mockSequencer(c.sequencerFeed, 1, block.timestamp - 7200);

        vm.expectRevert(ChainlinkReader.SequencerDown.selector);
        harness.netEquityUsdc(c, alice, tl, tu, liq);
    }

    /// @notice A just-restarted sequencer (within grace) reverts the WHOLE NAV
    ///         (`GracePeriodNotOver`).
    function test_c_failsClosed_withinGracePeriod() public {
        if (_skip) return;

        address alice = makeAddr("alice");
        (uint256 tokenId, int24 tl, int24 tu, uint128 liq) = _openRealBook(alice, PRINCIPAL);
        assertGt(tokenId, 0, "open book failed");

        LeveragedAeroValuation.Config memory c = _cfg();

        // up (answer == 0) but startedAt within the grace period -> GracePeriodNotOver.
        // ChainlinkReader reverts when block.timestamp - startedAt <= gracePeriod.
        _mockSequencer(c.sequencerFeed, 0, block.timestamp - 1);

        vm.expectRevert(ChainlinkReader.GracePeriodNotOver.selector);
        harness.netEquityUsdc(c, alice, tl, tu, liq);
    }

    // -------------------------------------------------------------------------
    // (d) Realizable-exit bound (done LAST).
    // -------------------------------------------------------------------------

    /// @notice Prove the oracle NAV is a faithful, slightly-conservative mark of a REAL exit:
    ///         partially unwind the book (fraction f = 25%) and assert the realized USDC out lands
    ///         within 2% of f*navBefore (exit slippage makes realized slightly UNDER the mark).
    ///         Also pre-stages the Phase-4 redeem path.
    /// @dev    The actor is `address(this)` (it implements `onERC721Received` + payable `receive`).
    ///         The unwind, ordered so each Moonwell health check passes:
    ///           0. Fold the open-time leftover WETH/cbBTC (the NPM mint never consumes the full
    ///              borrowed legs) into the USDC baseline, so the realized delta reflects ONLY the
    ///              unwind -- not a fixed open-over-borrow offset.
    ///           1. `gauge.withdraw(tokenId)` (unstake the NFT).
    ///           2. `redeemUnderlying(f*collateral)` FIRST -- frees USDC to fund the repays while
    ///              the book is still healthy (37.5k collateral vs 25k debt at f=25%). Redeeming
    ///              50%+ here would trip Moonwell's collateral-factor check, so f stays at 25%.
    ///           3. `decreaseLiquidity(f*liquidity)` + `collect` (free f of both legs).
    ///           4. `repayBorrow(f*cbDebt)` / `repayBorrow(f*wethDebt)` -- buy the EXACT repay
    ///              tokens from the freed USDC (no leg<->leg ping-pong, which over/under-shoots).
    ///           5. Sweep residual cbBTC/WETH to USDC.
    ///         realized = USDC(after) - USDC(baseline); compare to f*navBefore.
    function test_d_realizableExitBound() public {
        if (_skip) return;

        // Actor = address(this): the gauge `safeTransferFrom` on this vnet invokes the recipient's
        // onERC721Received, which a makeAddr EOA reverts on; address(this) implements it.
        address actor = address(this);
        (uint256 tokenId,,,) = _openRealBook(actor, PRINCIPAL);
        assertGt(tokenId, 0, "open book failed");

        // Read the position's actual ticks + liquidity (gauge holds the NFT; positions() readable).
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = INonfungiblePositionManager(NPM).positions(tokenId);
        assertGt(liq, 0, "no liquidity");

        LeveragedAeroValuation.Config memory cfg = _cfg();
        uint256 navBefore = LeveragedAeroValuation.netEquityUsdc(cfg, actor, tl, tu, liq);
        console2.log("navBefore (oracle, USDC 6dp):", navBefore);

        uint256 fBps = 2_500; // 25% exit (Moonwell collateral-factor headroom -- see @dev)

        // 0. Fold the open-time leftover legs into the USDC baseline (excludes the fixed offset).
        _swapAllToUsdc(WETH, actor);
        _swapAllToUsdc(CBBTC, actor);
        uint256 usdcStart = IERC20(USDC).balanceOf(actor);

        // 1. Unstake the NFT from the gauge (actor regains ownership).
        ICLGauge(GAUGE).withdraw(tokenId);

        // 2. Free f of the USDC collateral FIRST so the repays in step 4 can source USDC while the
        //    book is still healthy. underlying = cBal * exchangeRateStored / 1e18 (verbatim scale).
        uint256 cBal = ICToken(MUSDC).balanceOf(actor);
        uint256 rate = ICToken(MUSDC).exchangeRateStored();
        uint256 collateralUnderlying = (cBal * rate) / 1e18;
        uint256 redeemUsdc = (collateralUnderlying * fBps) / 10_000;
        require(ICToken(MUSDC).redeemUnderlying(redeemUsdc) == 0, "redeemUnderlying failed");

        // 3. Decrease f of liquidity and collect both freed legs to the actor.
        uint128 dLiq = uint128((uint256(liq) * fBps) / 10_000);
        INonfungiblePositionManager(NPM)
            .decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: dLiq, amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 600
                })
            );
        INonfungiblePositionManager(NPM)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId, recipient: actor, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
            );

        // 4. Repay f of each debt, buying the EXACT repay tokens from the freed USDC.
        uint256 cbRepay = (IMoonwellMarket(MCBBTC).borrowBalanceStored(actor) * fBps) / 10_000;
        uint256 wethRepay = (IMoonwellMarket(MWETH).borrowBalanceStored(actor) * fBps) / 10_000;

        _buyExactFromUsdc(CBBTC, cbRepay, actor);
        IERC20(CBBTC).approve(MCBBTC, cbRepay);
        require(IMoonwellMarket(MCBBTC).repayBorrow(cbRepay) == 0, "cbBTC repay failed");

        _buyExactFromUsdc(WETH, wethRepay, actor);
        IERC20(WETH).approve(MWETH, wethRepay);
        require(IMoonwellMarket(MWETH).repayBorrow(wethRepay) == 0, "WETH repay failed");

        // 5. Sweep any residual cbBTC / WETH dust back to USDC so the realized figure is in USDC.
        _swapAllToUsdc(CBBTC, actor);
        _swapAllToUsdc(WETH, actor);

        uint256 usdcEnd = IERC20(USDC).balanceOf(actor);
        uint256 realizedOut = usdcEnd - usdcStart; // net USDC freed by the partial unwind
        uint256 target = (navBefore * fBps) / 10_000;
        console2.log("realizedOut (USDC 6dp):", realizedOut);
        console2.log("target f*nav (USDC 6dp):", target);

        // Oracle NAV is a faithful, slightly-conservative mark: realized ~= f*nav within 2%
        // (exit slippage makes realized slightly under).
        assertApproxEqRel(realizedOut, target, 0.02e18, "realized exit deviated from oracle NAV mark (>2%)");
        // And conservative-or-fair: realized should not materially EXCEED the mark.
        assertLe(realizedOut, target + (target / 100), "realized exceeded oracle mark by >1% (mark too low)");
    }

    // -------------------------------------------------------------------------
    // Tunables -- shove sizes (override per real-pool depth if a fork shows a miss).
    // -------------------------------------------------------------------------

    /// @dev Ticks below the position's lower band to stop the BOUNDED shove in test (a). Just past
    ///      the band (default 50) makes the slot0 leg split fully one-sided (saturated naive NAV,
    ///      probe-measured ~2.75% drift) while the tick move stays ~2.1k ticks -- comfortably inside
    ///      the wide-cfg uint16 calm bound, so the oracle `netEquityUsdc` stays computable.
    function _belowBandTicks() internal pure virtual returns (int24) {
        return 50;
    }

    /// @dev WETH sold (UNBOUNDED) to push spot vs TWAP past the 500-tick production calm gate for
    ///      test (b). The band-crossing free-fall drives spot ~100k+ ticks from the fresh-fork TWAP
    ///      (probe-measured tick -266707 -> -405066 at 2000 WETH) -- far past the 500-tick gate.
    function _shoveSizeForCalmBreach() internal pure virtual returns (uint256) {
        return 2_000e18;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev |a - b| / max(a, b) scaled to 1e18 (a relative diff that tolerates either order).
    function _absRelDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        return ((hi - lo) * 1e18) / hi;
    }

    /// @dev BOUNDED tick-shove: sell WETH (token0) for cbBTC (token1) but stop the swap at the
    ///      sqrtPrice of `targetTick` via `sqrtPriceLimitX96`. Lets test (a) park the tick just
    ///      below the position band (saturating the slot0 leg split) without the unbounded
    ///      free-fall that `_shoveTick` would cause through the sub-band liquidity gap. Funds a
    ///      generous WETH amount; the price limit caps how much actually fills.
    function _shoveTickTo(int24 targetTick) internal returns (int24 newTick) {
        address swapper = makeAddr("bounded_swapper");
        uint256 wethIn = 5_000e18; // generous; the sqrtPriceLimit stops the fill at targetTick
        _fundWETH(swapper, wethIn);

        vm.startPrank(swapper);
        IERC20(WETH).approve(CL_ROUTER, wethIn);
        ICLSwapRouter(CL_ROUTER)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                    tokenIn: WETH, // token0
                    tokenOut: CBBTC, // token1
                    tickSpacing: TICK_SPACING,
                    recipient: swapper,
                    deadline: block.timestamp + 600,
                    amountIn: wethIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(targetTick)
                })
            );
        vm.stopPrank();

        (, newTick,,,,) = ICLPool(POOL).slot0();
    }

    /// @dev Force `feed.latestRoundData()` to report data older than `maxDelay` (StaleOracle).
    ///      Preserves a positive answer + a complete round so ONLY the staleness check fires.
    function _mockFeedStale(address feed, uint256 maxDelay) internal {
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = IAggregatorV3(feed).latestRoundData();
        uint256 staleTs = block.timestamp - maxDelay - 1; // strictly older than the bound
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(roundId, answer, staleTs, staleTs, answeredInRound)
        );
    }

    /// @dev Force the sequencer-uptime feed to a chosen (answer, startedAt). answer==1 => down;
    ///      answer==0 with startedAt within grace => GracePeriodNotOver.
    function _mockSequencer(address seqFeed, int256 answer, uint256 startedAt) internal {
        vm.mockCall(
            seqFeed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), answer, startedAt, startedAt, uint80(1))
        );
    }

    /// @dev Buy at least `outNeeded` of `tokenOut` by spending the actor's USDC via the token/USDC
    ///      ts=100 CL pool (exists for both WETH and cbBTC on Base). The router exposes only
    ///      `exactInputSingle`, so we swap USDC in capped chunks until covered; any overshoot is
    ///      swept back to USDC at the end of the unwind. No-op if already covered. Caller is the
    ///      actor (`address(this)`), so swaps originate here without a prank.
    function _buyExactFromUsdc(address tokenOut, uint256 outNeeded, address who) internal {
        uint256 guard;
        while (IERC20(tokenOut).balanceOf(who) < outNeeded) {
            uint256 usdcBal = IERC20(USDC).balanceOf(who);
            require(usdcBal > 0, "out of USDC to buy repay token");
            uint256 chunk = usdcBal > 5_000e6 ? 5_000e6 : usdcBal;
            IERC20(USDC).approve(CL_ROUTER, chunk);
            ICLSwapRouter(CL_ROUTER)
                .exactInputSingle(
                    ICLSwapRouter.ExactInputSingleParams({
                        tokenIn: USDC,
                        tokenOut: tokenOut,
                        tickSpacing: 100,
                        recipient: who,
                        deadline: block.timestamp + 600,
                        amountIn: chunk,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                );
            guard++;
            require(guard < 50, "buy loop stuck");
        }
    }

    /// @dev Swap `who`'s entire `token` balance into USDC via the token/USDC ts=100 CL pool.
    ///      Caller is the actor (`address(this)`); zero balance is a no-op.
    function _swapAllToUsdc(address token, address who) internal {
        uint256 bal = IERC20(token).balanceOf(who);
        if (bal == 0) return;
        IERC20(token).approve(CL_ROUTER, bal);
        ICLSwapRouter(CL_ROUTER)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: USDC,
                    tickSpacing: 100,
                    recipient: who,
                    deadline: block.timestamp + 600,
                    amountIn: bal,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }
}
