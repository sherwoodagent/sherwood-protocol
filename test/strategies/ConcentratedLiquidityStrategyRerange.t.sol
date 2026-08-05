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

    /// @dev The ceiling check alone does NOT make this "only risk-reducing".
    ///      `updateParams` is `onlyProposer` in `Executed`, and `settleProposal`
    ///      is proposer-callable an hour after execute — so a proposal voters
    ///      reviewed at a tight settlement band could be widened to the ceiling
    ///      by its own proposer and then settled through, into a sandwich they
    ///      control, with nobody reviewing the change. Raising must be refused
    ///      at every value, not merely above the ceiling.
    function test_updateParams_cannotWidenSlippageAfterApproval() public {
        _execute();
        uint256 approved = strategy.settleSlippageBps();
        assertEq(approved, 500, "fixture no longer approves 500 bps");

        vm.prank(proposer);
        vm.expectRevert(ConcentratedLiquidityStrategy.ImmutableParam.selector);
        strategy.updateParams(abi.encode(approved + 1, uint256(0)));

        // All the way to the ceiling — the value the bare ceiling check admits,
        // and the one the sandwich actually wants.
        uint256 ceiling = strategy.MAX_SLIPPAGE_BPS();
        vm.prank(proposer);
        vm.expectRevert(ConcentratedLiquidityStrategy.ImmutableParam.selector);
        strategy.updateParams(abi.encode(ceiling, uint256(0)));

        assertEq(strategy.settleSlippageBps(), approved, "settlement band widened after approval");
    }

    /// @dev And the rule is a RATCHET, not a comparison against the initial
    ///      value: once tightened, the old band is no longer reachable either.
    function test_updateParams_slippageRatchetsDownOnly() public {
        _execute();

        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint256(100), uint256(0)));
        assertEq(strategy.settleSlippageBps(), 100, "tightening was refused");

        vm.prank(proposer);
        vm.expectRevert(ConcentratedLiquidityStrategy.ImmutableParam.selector);
        strategy.updateParams(abi.encode(uint256(101), uint256(0)));

        // Equal is not a widening, so it stays admissible.
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint256(100), uint256(7 days)));
        assertEq(strategy.settleSlippageBps(), 100);
        assertEq(strategy.settleDeadline(), 7 days, "deadline is not gated by the slippage ratchet");
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
        // Execute stamps `lastRerangeAt`, so the hour is measured from there.
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTooSoon.selector);
        strategy.rerange();
    }

    /// @dev The interval is documented as running "since execute or the last
    ///      rerange", and the FIRST rerange is the case where those differ.
    ///      Left unstamped at execute, `lastRerangeAt` stays 0 and every
    ///      timestamp on a live chain clears `0 + minInterval` trivially — so a
    ///      keeper could rerange in execute's own block. Warping to just before
    ///      and just after the boundary pins that the clock starts at execute
    ///      rather than at the epoch.
    function test_rerange_firstRerangeIsClockedFromExecute() public {
        _execute();
        uint256 executedAt = vm.getBlockTimestamp();
        assertEq(strategy.lastRerangeAt(), executedAt, "rerange clock not anchored at execute");

        _moveToTrigger();

        // One second short of the approved interval.
        vm.warp(executedAt + 1 hours - 1);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTooSoon.selector);
        strategy.rerange();

        // And admissible the moment it elapses.
        vm.warp(executedAt + 1 hours);
        vm.prank(keeper);
        strategy.rerange();
        assertEq(strategy.rerangeCount(), 1, "rerange did not become admissible at the boundary");
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

    /// @notice PASHOV 2026-08 FINDING #17, PINNED AS AN OPEN EXPOSURE.
    /// @dev    This test asserts the BUG, deliberately. `_execute` ends with
    ///         `_requireWithinPoolShare` on the actually-minted liquidity;
    ///         `rerange` re-mints through the same `_mintPosition` and does
    ///         not, so the approved cap binds only on the first mint.
    ///
    ///         The enforcement was written and WITHDRAWN — see the block in
    ///         `rerange()`. Reverting there has two permanent failure paths (a
    ///         structurally over-cap `halfWidthTicks` policy bricks every
    ///         future rerange; and `pool.liquidity()` reading zero after
    ///         `_closePosition` bricks it on a live pool where the strategy is
    ///         the only in-range LP — a branch these mocks cannot reach, since
    ///         `MockPositionManager.decreaseLiquidity` never touches the mock
    ///         pool's settable `liquidity`). Trading an over-cap position for a
    ///         permanently frozen one is not a fix.
    ///
    ///         Kept executable so the exposure is visible rather than
    ///         forgotten: when the bind-time fix lands, this test should FLIP
    ///         to expecting `PositionExceedsPoolShareCap`.
    function test_rerange_overPoolShareCapStillLands_openFinding17() public {
        _execute();
        uint256 tidBefore = strategy.tokenId();
        (,,,,,,, uint128 live,,,,) = posm.positions(tidBefore);
        assertGt(live, 0, "fixture minted nothing, the cap could not bind");

        _warpPastInterval();
        _moveToTrigger();

        // The venue can now carry only a tenth of what this position alone is,
        // i.e. far past `MAX_POOL_SHARE_BPS`.
        pool.setLiquidity(live);

        vm.prank(keeper);
        strategy.rerange();

        assertEq(strategy.rerangeCount(), 1, "rerange is currently unguarded by the pool-share cap");
        assertTrue(strategy.tokenId() != tidBefore, "the position was re-minted over the cap");
    }

    function test_rerange_atThePoolShareCapSucceeds() public {
        _execute();
        (,,,,,,, uint128 live,,,,) = posm.positions(strategy.tokenId());

        _warpPastInterval();
        _moveToTrigger();

        // Ten times the position is exactly the 10% cap. A shade above it, so
        // the mock's sqrt rounding cannot decide the assertion.
        pool.setLiquidity(uint128(uint256(live) * 10 + 1_000));

        vm.prank(keeper);
        strategy.rerange();
        assertEq(strategy.rerangeCount(), 1, "rerange refused at a share the cap admits");
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

    /// @dev A band that is perfectly legitimate mid-domain still runs past
    ///      `MAX_TICK` once the TWAP sits near the top of the pool's range.
    ///      Unclamped, `center + half` produces a tick the pool cannot accept —
    ///      and in `int24` it can overflow outright, which would REVERT and
    ///      brick `rerange()` permanently for a policy init already accepted.
    ///      The derived range must stay inside the domain and stay non-empty at
    ///      both extremes.
    function test_derivedRange_clampsToTheTickDomain() public {
        _execute();

        int24 maxTick = strategy.MAX_TICK();
        int24 minTick = strategy.MIN_TICK();

        pool.setTicks(maxTick - 100, maxTick - 100);
        (int24 lower, int24 upper) = strategy.derivedRange();
        assertLe(upper, maxTick, "upper ran past the tick domain");
        assertEq(upper % TICK_SPACING, 0, "clamped upper not aligned");
        assertLt(lower, upper, "clamped range collapsed");

        pool.setTicks(minTick + 100, minTick + 100);
        (lower, upper) = strategy.derivedRange();
        assertGe(lower, minTick, "lower ran past the tick domain");
        assertEq(lower % TICK_SPACING, 0, "clamped lower not aligned");
        assertLt(lower, upper, "clamped range collapsed");
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

/// @notice The single-sided LP configuration — `swapFractionBps == 0`, which
///         `_requireValidBounds` accepts as `<= BPS_DENOMINATOR` and which is
///         precisely how a proposal for a range sitting entirely on one side of
///         spot is expressed.
/// @dev    `_rebalanceToTarget` skips the quote when nothing of `otherToken` is
///         held, so `otherValue` stays 0 — and the SELL branch is still reached
///         in that state, because `targetOtherValue > otherValue` is `0 > 0`.
///         The proportional conversion then divides by `otherValue` BEFORE the
///         `toSwap == 0` guard, so the whole call panics 0x12. That is an
///         undecodable revert of `execute()` with the proposer's bond already
///         locked, and of permissionless `rerange()` on any position holding
///         only the vault asset.
contract ConcentratedLiquidityStrategySingleSidedTest is CLFixture {
    /// @dev Replaces the fixture's clone with one configured to buy none of the
    ///      volatile leg, re-binding the active proposal and the vault approval
    ///      so `execute()` reaches the code under test rather than the guards.
    function _useSingleSidedStrategy() internal {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.swapFractionBps = 0;
        p.rerange.swapFractionBps = 0;
        strategy = _newStrategy(p);
        status.set(1, 1, address(strategy));
        vm.prank(address(vaultStub));
        usdg.approve(address(strategy), type(uint256).max);
    }

    function test_execute_singleSidedConfigDoesNotPanic() public {
        _useSingleSidedStrategy();

        _execute();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed), "execute did not complete");
        assertGt(strategy.tokenId(), 0, "no position minted");
        // And it genuinely stayed single-sided rather than being rescued by a
        // swap: nothing of the volatile leg was bought.
        assertEq(nvda.balanceOf(address(strategy)), 0, "single-sided config bought the volatile leg");
    }

    /// @dev The same divisor, reached from the permissionless entry point. Fee
    ///      income in the VAULT ASSET is what hands the re-mint a non-zero asset
    ///      balance against a zero `otherToken` balance — the exact state the
    ///      sell branch divides by zero in.
    function test_rerange_singleSidedConfigDoesNotPanic() public {
        _useSingleSidedStrategy();
        _execute();

        usdg.mint(address(posm), 1_000e6);
        posm.accrueFees(strategy.tokenId(), uint128(1_000e6), 0);
        assertEq(nvda.balanceOf(address(strategy)), 0, "fixture did not produce a one-legged position");

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        pool.setTicks(850, 850);

        vm.prank(keeper);
        strategy.rerange();

        assertEq(strategy.rerangeCount(), 1, "rerange did not complete");
    }
}
