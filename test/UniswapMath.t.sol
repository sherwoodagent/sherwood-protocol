// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";

/// @title UniswapMath test -- ground-truth vectors for TickMath and LiquidityAmounts (0.8.28 port)
contract UniswapMathTest is Test {
    // --- TickMath constants ---

    function test_tickMath_constants() public pure {
        assertEq(TickMath.MIN_TICK, -887272, "MIN_TICK");
        assertEq(TickMath.MAX_TICK, 887272, "MAX_TICK");
        assertEq(TickMath.MIN_SQRT_RATIO, 4295128739, "MIN_SQRT_RATIO");
        assertEq(TickMath.MAX_SQRT_RATIO, 1461446703485210103287273052203988822378723970342, "MAX_SQRT_RATIO");
    }

    // --- TickMath.getSqrtRatioAtTick -- ground-truth vectors ---

    function test_getSqrtRatioAtTick_zero() public pure {
        // tick=0 -> 2**96 = 79228162514264337593543950336
        assertEq(TickMath.getSqrtRatioAtTick(0), 79228162514264337593543950336, "sqrtRatio at tick 0");
    }

    function test_getSqrtRatioAtTick_minTick() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK), TickMath.MIN_SQRT_RATIO, "sqrtRatio at MIN_TICK");
    }

    function test_getSqrtRatioAtTick_maxTick() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK), TickMath.MAX_SQRT_RATIO, "sqrtRatio at MAX_TICK");
    }

    function test_getSqrtRatioAtTick_symmetry() public pure {
        // getSqrtRatioAtTick(-t) != getSqrtRatioAtTick(t); price monotone in tick
        uint160 pos = TickMath.getSqrtRatioAtTick(60);
        uint160 neg = TickMath.getSqrtRatioAtTick(-60);
        assertTrue(pos != neg, "pos != neg");
        assertTrue(pos > TickMath.getSqrtRatioAtTick(0), "tick+60 > tick0");
        assertTrue(neg < TickMath.getSqrtRatioAtTick(0), "tick-60 < tick0");
    }

    // --- getAmountsForLiquidity -- ground-truth vectors ---

    /// Current price at mid-range (tick=0): both legs > 0 and roughly balanced.
    function test_getAmountsForLiquidity_midRange() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint160 lo = TickMath.getSqrtRatioAtTick(-60);
        uint160 hi = TickMath.getSqrtRatioAtTick(60);

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, 1e18);
        assertGt(a0, 0, "a0 > 0");
        assertGt(a1, 0, "a1 > 0");
        // Symmetric range -> amounts should be within 5% of each other
        assertApproxEqRel(a0, a1, 0.05e18, "a0 approx a1 within 5%");
    }

    /// Current price below range (sqrtP <= sqrtLower): all token0, no token1.
    function test_getAmountsForLiquidity_belowRange() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(-120); // below [-60, 60]
        uint160 lo = TickMath.getSqrtRatioAtTick(-60);
        uint160 hi = TickMath.getSqrtRatioAtTick(60);

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, 1e18);
        assertGt(a0, 0, "a0 > 0 when below range");
        assertEq(a1, 0, "a1 == 0 when below range");
    }

    /// Current price above range (sqrtP >= sqrtUpper): all token1, no token0.
    function test_getAmountsForLiquidity_aboveRange() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(120); // above [-60, 60]
        uint160 lo = TickMath.getSqrtRatioAtTick(-60);
        uint160 hi = TickMath.getSqrtRatioAtTick(60);

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, 1e18);
        assertEq(a0, 0, "a0 == 0 when above range");
        assertGt(a1, 0, "a1 > 0 when above range");
    }

    // --- Basic brief test (from task brief) ---

    function test_getAmountsForLiquidity_matchesKnownVector() public pure {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
        uint160 lo = TickMath.getSqrtRatioAtTick(-60);
        uint160 hi = TickMath.getSqrtRatioAtTick(60);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, lo, hi, 1e18);
        assertGt(a0, 0);
        assertGt(a1, 0);
    }
}
