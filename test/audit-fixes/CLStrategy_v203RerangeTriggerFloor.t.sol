// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CLFixture} from "../strategies/ConcentratedLiquidityStrategy.t.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";

/// @notice Calls `rerange()` `n` times in one transaction.
contract RerangeLooper {
    function loop(ConcentratedLiquidityStrategy s, uint256 n) external {
        for (uint256 i; i < n; ++i) {
            s.rerange();
        }
    }
}

/// @notice Audit 2026-10-01 V2-03: a one-spacing trigger floor and the refusal of an unchanged derived
///         range keep the rerange budget from being spent in one transaction, clamped range or not.
contract CLStrategy_v203RerangeTriggerFloorTest is CLFixture {
    function _policyParams(int24 lower, int24 upper, int24 half, uint256 triggerBps, uint256 minInterval)
        internal
        view
        returns (ConcentratedLiquidityStrategy.InitParams memory p)
    {
        p = _defaultParams();
        p.tickLower = lower;
        p.tickUpper = upper;
        p.maxTwapDeviationBps = 1_000;
        p.rerange = ConcentratedLiquidityStrategy.RerangePolicy({
            halfWidthTicks: half,
            triggerBps: triggerBps,
            minInterval: minInterval,
            maxReranges: 20,
            slippageBps: 1_000,
            swapFractionBps: 5_000
        });
    }

    function _deployExecuted(ConcentratedLiquidityStrategy.InitParams memory p, int24 twap)
        internal
        returns (ConcentratedLiquidityStrategy s, RerangeLooper looper)
    {
        s = _newStrategy(p);
        status.set(1, 1, address(s));
        vm.prank(address(vaultStub));
        usdg.approve(address(s), type(uint256).max);
        pool.setTicks(twap, twap);
        vm.prank(address(vaultStub));
        s.execute();
        looper = new RerangeLooper();
    }

    function _assertSecondSameTxRerangeReverts(ConcentratedLiquidityStrategy s, RerangeLooper looper) internal {
        looper.loop(s, 1);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTriggerNotReached.selector);
        looper.loop(s, 1);
        assertEq(s.rerangeCount(), 1, "one rerange per transaction");
    }

    /// @notice TWAP 11 (not spacing-aligned) at the old minimum policy 200 x 50: one rerange, not twenty.
    function test_unalignedTwap_minPolicy_secondSameTxRerangeReverts() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployExecuted(_policyParams(-200, 200, 200, 50, 0), 11);
        _assertSecondSameTxRerangeReverts(s, looper);
    }

    /// @notice TWAP 11 with a 4x larger trigger (200 x 200): still one rerange per transaction.
    function test_unalignedTwap_largerTrigger_secondSameTxRerangeReverts() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployExecuted(_policyParams(-200, 200, 200, 200, 0), 11);
        _assertSecondSameTxRerangeReverts(s, looper);
    }

    /// @notice A narrow initial band whose computed threshold is zero no longer admits a zero-travel rerange.
    function test_narrowInitialBand_zeroTravelFirstRerangeReverts() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) = _deployExecuted(_policyParams(-10, 10, 200, 50, 0), 0);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTriggerNotReached.selector);
        looper.loop(s, 1);
        assertEq(s.rerangeCount(), 0);
    }

    /// @notice Honest use: each time the TWAP travels at least one spacing past the floor, a rerange succeeds.
    function test_honestRerangeAfterTwapTravelSucceeds() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployExecuted(_policyParams(-200, 200, 200, 50, 0), 0);
        pool.setTicks(15, 15);
        looper.loop(s, 1);
        assertEq(s.rerangeCount(), 1);
        (int24 lower, int24 upper) = (s.tickLower(), s.tickUpper());
        int24 mid = (lower + upper) / 2;
        pool.setTicks(mid + 10, mid + 10);
        looper.loop(s, 1);
        assertEq(s.rerangeCount(), 2, "a later, honest rerange still runs");
    }

    /// @notice Whatever the TWAP's offset within a spacing, at most one rerange lands per transaction.
    function testFuzz_atMostOneRerangePerTransaction(uint8 offset, bool negative) public {
        int24 off = int24(uint24(bound(offset, 0, uint256(uint24(TICK_SPACING)) - 1)));
        int24 twap = negative ? -(20 + off) : 20 + off;
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployExecuted(_policyParams(-200, 200, 200, 50, 0), twap);
        _assertSecondSameTxRerangeReverts(s, looper);
    }

    /// @dev A spacing-60 pool for the same pair, so a clamped range stays spacing-aligned like a real one.
    function _spacing60Pool() internal returns (MockUniswapV3Pool p) {
        p = new MockUniswapV3Pool(address(usdg), address(nvda), 3000, 60, factory);
        p.setLiquidity(POOL_LIQUIDITY);
        p.setSqrtPriceX96(FAIR_SQRT_PRICE_X96);
        factoryMock.register(address(usdg), address(nvda), 3000, address(p));
    }

    function _deployClamped(int24 half, uint256 triggerBps, int24 twap)
        internal
        returns (ConcentratedLiquidityStrategy s, RerangeLooper looper)
    {
        MockUniswapV3Pool p60 = _spacing60Pool();
        ConcentratedLiquidityStrategy.InitParams memory params = _policyParams(-60_000, 60_000, half, triggerBps, 0);
        params.pool = address(p60);
        s = _newStrategy(params);
        status.set(1, 1, address(s));
        vm.prank(address(vaultStub));
        usdg.approve(address(s), type(uint256).max);
        p60.setTicks(twap, twap);
        vm.prank(address(vaultStub));
        s.execute();
        looper = new RerangeLooper();
    }

    /// @notice Full-range policy at a realistic TWAP (-216,400): the clamped range repeats, and is refused.
    function test_clampedFullRangePolicy_secondSameTxRerangeReverts() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployClamped(template.MAX_HALF_WIDTH_TICKS(), 1_000, -216_400);
        _assertSecondSameTxRerangeReverts(s, looper);
    }

    /// @notice One-sided clamp (half-width 700k, TWAP +216,400, 1% trigger): one rerange per transaction.
    function test_clampedOneSided_secondSameTxRerangeReverts() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) = _deployClamped(700_000, 100, 216_400);
        _assertSecondSameTxRerangeReverts(s, looper);
    }

    /// @notice Clamped configurations (large half-width, TWAP far from zero): at most one rerange per transaction.
    function testFuzz_clampedAtMostOneRerangePerTransaction(int24 half, uint16 triggerBps, int24 twap, bool negative)
        public
    {
        half = int24(bound(half, 690_000, template.MAX_HALF_WIDTH_TICKS()));
        int24 t = int24(bound(twap, 150_000, 250_000));
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployClamped(half, bound(triggerBps, 1, 10_000), negative ? -t : t);
        _assertSecondSameTxRerangeReverts(s, looper);
    }

    /// @notice Control: a non-zero minInterval stops the second rerange on its own.
    function test_control_nonZeroIntervalStopsSecondRerange() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployExecuted(_policyParams(-200, 200, 200, 50, 60), 11);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTooSoon.selector);
        looper.loop(s, 1);
        vm.warp(vm.getBlockTimestamp() + 60);
        looper.loop(s, 1);
        assertEq(s.rerangeCount(), 1);
    }

    /// @notice Control: the default 80% trigger refuses a rerange while price sits inside the range.
    function test_control_priceInsideRangeReverts() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) =
            _deployExecuted(_policyParams(-200, 200, 200, 8_000, 0), 11);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTriggerNotReached.selector);
        looper.loop(s, 1);
    }
}
