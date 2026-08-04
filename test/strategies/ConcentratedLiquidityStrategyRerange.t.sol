// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CLFixture} from "./ConcentratedLiquidityStrategy.t.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";

/// @notice 6.4 — only risk-reducing parameters are tunable after execution.
contract ConcentratedLiquidityStrategyTunablesTest is CLFixture {
    function test_updateParams_proposerRetunesSlippage() public {
        _execute();
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint256(250), uint256(0)));
        assertEq(strategy.settleSlippageBps(), 250);
    }

    function test_updateParams_nonProposerReverts() public {
        _execute();
        vm.prank(keeper);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.updateParams(abi.encode(uint256(250), uint256(0)));
    }

    function test_updateParams_beforeExecuteReverts() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.updateParams(abi.encode(uint256(250), uint256(0)));
    }

    function test_updateParams_afterSettleReverts() public {
        _execute();
        _settle();
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.updateParams(abi.encode(uint256(250), uint256(0)));
    }

    function test_updateParams_slippageAboveCeilingReverts() public {
        _execute();
        uint256 tooHigh = strategy.MAX_SLIPPAGE_BPS() + 1;
        vm.prank(proposer);
        vm.expectRevert(ConcentratedLiquidityStrategy.InvalidBound.selector);
        strategy.updateParams(abi.encode(tooHigh, uint256(0)));
    }

    /// @dev The range, the pool, and every rerange-policy field are unreachable
    ///      from `updateParams` BY CONSTRUCTION — the decoder accepts exactly two
    ///      uint256s, so there is no encoding that names them. This pins that
    ///      structural claim: the immutable fields are unchanged after an update,
    ///      and a longer payload does not smuggle anything through.
    function test_updateParams_cannotReachRangeOrPolicy() public {
        _execute();
        int24 lowerBefore = strategy.tickLower();
        int24 upperBefore = strategy.tickUpper();
        address poolBefore = address(strategy.pool());
        ConcentratedLiquidityStrategy.RerangePolicy memory policyBefore = strategy.rerangePolicy();

        // A payload carrying extra words decodes its first two and ignores the
        // rest — abi.decode does not fail on trailing data.
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint256(250), uint256(0), int24(500), address(0xdead), uint256(9_999)));

        assertEq(strategy.tickLower(), lowerBefore, "range moved");
        assertEq(strategy.tickUpper(), upperBefore, "range moved");
        assertEq(address(strategy.pool()), poolBefore, "pool moved");

        ConcentratedLiquidityStrategy.RerangePolicy memory policyAfter = strategy.rerangePolicy();
        assertEq(policyAfter.halfWidthTicks, policyBefore.halfWidthTicks, "half-width moved");
        assertEq(policyAfter.triggerBps, policyBefore.triggerBps, "trigger moved");
        assertEq(policyAfter.minInterval, policyBefore.minInterval, "interval moved");
        assertEq(policyAfter.maxReranges, policyBefore.maxReranges, "cap moved");
        assertEq(policyAfter.slippageBps, policyBefore.slippageBps, "rerange slippage moved");
    }
}

/// @notice 6.5–6.8 — rerange admissibility, determinism, invariants, griefing bound.
contract ConcentratedLiquidityStrategyRerangeTest is CLFixture {
    /// @dev Default range is [-1000, 1000], midpoint 0, half-range 1000, trigger
    ///      80% — so price must travel 800 ticks from the midpoint. The TWAP
    ///      deviation bound is 100 bps, so spot must stay within 100 ticks of the
    ///      TWAP; both are moved together.
    function _moveToTrigger() internal {
        pool.setTicks(850, 850);
    }

    function _warpPastInterval() internal {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
    }

    // ── 6.5 Admissibility, one test per condition ──

    function test_rerange_beforeExecuteReverts() public {
        _moveToTrigger();
        vm.expectRevert(ConcentratedLiquidityStrategy.NotExecutedForRerange.selector);
        strategy.rerange();
    }

    function test_rerange_afterSettleReverts() public {
        _execute();
        _settle();
        _moveToTrigger();
        _warpPastInterval();
        vm.expectRevert(ConcentratedLiquidityStrategy.NotExecutedForRerange.selector);
        strategy.rerange();
    }

    function test_rerange_beforeTriggerReverts() public {
        _execute();
        _warpPastInterval();
        pool.setTicks(100, 100); // only 100 ticks from midpoint, trigger needs 800
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTriggerNotReached.selector);
        strategy.rerange();
    }

    function test_rerange_insideMinIntervalReverts() public {
        _execute();
        _moveToTrigger();
        // No warp: execute stamped `lastRerangeAt` at 0, but the interval is
        // measured from it, so at t=0 the hour has not elapsed.
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTooSoon.selector);
        strategy.rerange();
    }

    function test_rerange_spotOutsideTwapBoundReverts() public {
        _execute();
        _warpPastInterval();
        pool.setTicks(1000, 850); // 150 ticks apart, bound is 100
        vm.expectRevert(ConcentratedLiquidityStrategy.SpotOutsideTwapBound.selector);
        strategy.rerange();
    }

    function test_rerange_pastCapReverts() public {
        _execute();
        uint256 cap = strategy.rerangePolicy().maxReranges;
        for (uint256 i = 0; i < cap; i++) {
            _warpPastInterval();
            // Relative, not absolute: each rerange re-centres the range on the
            // current tick, so a fixed tick that was past the trigger before is
            // sitting at the new midpoint afterwards.
            _resetTriggerRelativeToRange();
            vm.prank(keeper);
            strategy.rerange();
        }
        assertEq(strategy.rerangeCount(), cap);

        _warpPastInterval();
        _resetTriggerRelativeToRange();
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeCapReached.selector);
        strategy.rerange();
    }

    /// @dev Put the TWAP 85% of the way to the current range's boundary.
    function _resetTriggerRelativeToRange() internal {
        int24 lower = strategy.tickLower();
        int24 upper = strategy.tickUpper();
        int24 mid = (lower + upper) / 2;
        int24 half = (upper - lower) / 2;
        int24 target = mid + (half * 85) / 100;
        pool.setTicks(target, target);
    }

    // ── 6.6 Determinism ──

    function test_rerange_isPermissionless() public {
        _execute();
        _warpPastInterval();
        _moveToTrigger();
        vm.prank(keeper); // not the proposer, not the vault
        strategy.rerange();
        assertEq(strategy.rerangeCount(), 1);
    }

    /// @dev The caller's identity is not an input to the derivation. Two
    ///      different senders in identical state must produce the same range,
    ///      which is what makes removing the permission safe.
    function test_rerange_twoCallersOneRange() public {
        _execute();
        _warpPastInterval();
        _moveToTrigger();

        uint256 snap = vm.snapshotState();

        vm.prank(keeper);
        strategy.rerange();
        (int24 lowerA, int24 upperA) = (strategy.tickLower(), strategy.tickUpper());

        vm.revertToState(snap);

        vm.prank(proposer);
        strategy.rerange();
        (int24 lowerB, int24 upperB) = (strategy.tickLower(), strategy.tickUpper());

        assertEq(lowerA, lowerB, "lower differs by caller");
        assertEq(upperA, upperB, "upper differs by caller");
    }

    /// @dev The `public view` derivation must equal what `rerange()` actually
    ///      mints, or a caller cannot simulate the result before sending.
    function test_rerange_viewDerivationMatchesMint() public {
        _execute();
        _warpPastInterval();
        _moveToTrigger();

        (int24 predictedLower, int24 predictedUpper) = strategy.derivedRange();
        vm.prank(keeper);
        strategy.rerange();

        assertEq(strategy.tickLower(), predictedLower, "lower diverged from prediction");
        assertEq(strategy.tickUpper(), predictedUpper, "upper diverged from prediction");
    }

    function test_derivedRange_isSpacingAlignedAndCentered() public {
        _execute();
        _warpPastInterval();
        pool.setTicks(855, 855); // deliberately not a multiple of spacing 10
        (int24 lower, int24 upper) = strategy.derivedRange();
        assertEq(lower % TICK_SPACING, 0, "lower not aligned");
        assertEq(upper % TICK_SPACING, 0, "upper not aligned");
        assertLt(lower, upper, "range empty");
    }

    /// @dev Negative ticks are where a truncating-toward-zero snap silently
    ///      produces a range an off-chain simulation cannot reproduce.
    function test_derivedRange_snapsCorrectlyBelowZero() public {
        _execute();
        _warpPastInterval();
        pool.setTicks(-855, -855);
        (int24 lower, int24 upper) = strategy.derivedRange();
        assertEq(lower % TICK_SPACING, 0, "lower not aligned");
        assertEq(upper % TICK_SPACING, 0, "upper not aligned");
        assertLe(lower, -855 - 1000 + TICK_SPACING, "lower snapped the wrong way");
        assertLt(lower, upper);
    }

    // ── 6.7 Invariants ──

    function test_rerange_leavesBorrowAndCollateralUntouched() public {
        _execute();
        uint128 debtBefore = morpho.position(marketId, address(strategy)).borrowShares;
        uint128 collateralBefore = morpho.position(marketId, address(strategy)).collateral;

        _warpPastInterval();
        _moveToTrigger();
        vm.prank(keeper);
        strategy.rerange();

        assertEq(morpho.position(marketId, address(strategy)).borrowShares, debtBefore, "debt moved");
        assertEq(morpho.position(marketId, address(strategy)).collateral, collateralBefore, "collateral moved");
    }

    /// @dev A rerange REPLACES the position — the clone must never hold two.
    function test_rerange_replacesRatherThanAdds() public {
        _execute();
        uint256 oldTokenId = strategy.tokenId();

        _warpPastInterval();
        _moveToTrigger();
        vm.prank(keeper);
        strategy.rerange();

        uint256 newTokenId = strategy.tokenId();
        assertTrue(newTokenId != oldTokenId, "token id unchanged");
        assertTrue(posm.isBurned(oldTokenId), "old position not burned");

        (,,,,,,, uint128 oldLiquidity,,,,) = posm.positions(oldTokenId);
        assertEq(oldLiquidity, 0, "old position still holds liquidity");
        (,,,,,,, uint128 newLiquidity,,,,) = posm.positions(newTokenId);
        assertGt(newLiquidity, 0, "new position empty");
    }

    function test_rerange_incrementsCount() public {
        _execute();
        assertEq(strategy.rerangeCount(), 0);
        _warpPastInterval();
        _moveToTrigger();
        vm.prank(keeper);
        strategy.rerange();
        assertEq(strategy.rerangeCount(), 1);
    }

    /// @dev At the cap the position must stay settleable, not become stuck.
    ///
    ///      The position is funded ENTIRELY by the borrow, so its principal
    ///      alone can never repay principal-plus-interest — what closes that gap
    ///      in a real market-making position is fee income, and a test that
    ///      grants none is asserting against a strategy that never earned
    ///      anything. Fees are credited here for exactly that reason. The
    ///      shortfall path, where they are NOT enough, is pinned separately as
    ///      the deliverable-maximum behaviour it is meant to be.
    function test_rerange_atCapPositionStaysSettleable() public {
        _execute();
        uint256 cap = strategy.rerangePolicy().maxReranges;
        for (uint256 i = 0; i < cap; i++) {
            _warpPastInterval();
            _resetTriggerRelativeToRange();
            vm.prank(keeper);
            strategy.rerange();
        }

        _accrueFees(1_000e6);

        _settle();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertEq(morpho.position(marketId, address(strategy)).borrowShares, 0, "debt outstanding");
        assertEq(morpho.position(marketId, address(strategy)).collateral, 0, "collateral stranded");
    }

    /// @dev Credit the live position with `amount` of vault-asset fees, funding
    ///      the position manager so the collect can actually pay out.
    function _accrueFees(uint256 amount) internal {
        usdg.mint(address(posm), amount);
        posm.accrueFees(strategy.tokenId(), uint128(amount), 0);
    }

    // ── 6.8 Griefing bound ──

    /// @dev Decision 4a's whole claim is that the worst case is bounded and
    ///      readable before the vote: `maxReranges x (swap cost + slippage
    ///      floor)`. This pins it — after burning every permitted rerange at the
    ///      worst admissible execution, the position's remaining liquidity is
    ///      still within that bound, and the cap is what stops the bleed.
    function test_rerange_griefingIsBoundedByTheCap() public {
        _execute();
        (,,,,,,, uint128 liquidityAtStart,,,,) = posm.positions(strategy.tokenId());

        uint256 cap = strategy.rerangePolicy().maxReranges;
        uint256 slippageBps = strategy.rerangePolicy().slippageBps;

        for (uint256 i = 0; i < cap; i++) {
            _warpPastInterval();
            _resetTriggerRelativeToRange();
            vm.prank(keeper);
            strategy.rerange();
        }

        (,,,,,,, uint128 liquidityAtEnd,,,,) = posm.positions(strategy.tokenId());

        // Each rerange can shed at most `slippageBps` of value; compounding that
        // `cap` times is the ceiling a voter prices. Compared multiplicatively
        // rather than as a flat sum, because each round trip is proportional.
        uint256 worstCaseRemainingBps = 10_000;
        for (uint256 i = 0; i < cap; i++) {
            worstCaseRemainingBps = (worstCaseRemainingBps * (10_000 - slippageBps)) / 10_000;
        }
        uint256 floorLiquidity = (uint256(liquidityAtStart) * worstCaseRemainingBps) / 10_000;

        assertGe(uint256(liquidityAtEnd), floorLiquidity, "reranging bled more than the approved worst case");

        // And the cap genuinely binds: one more is refused.
        _warpPastInterval();
        _resetTriggerRelativeToRange();
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeCapReached.selector);
        strategy.rerange();
    }
}
