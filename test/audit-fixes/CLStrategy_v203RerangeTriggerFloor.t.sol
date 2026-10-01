// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CLFixture} from "../strategies/ConcentratedLiquidityStrategy.t.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";

/// @notice Calls `rerange()` `n` times in one transaction.
contract RerangeLooper {
    function loop(ConcentratedLiquidityStrategy s, uint256 n) external {
        for (uint256 i; i < n; ++i) {
            s.rerange();
        }
    }
}

/// @notice Audit 2026-10-01 V2-03: a rerange policy whose trigger threshold rounds to zero
///         ticks is refused at init, so the rerange budget cannot be spent on demand.
contract CLStrategy_v203RerangeTriggerFloorTest is CLFixture {
    int24 constant T = 10;

    function _policyParams(int24 half, uint256 triggerBps, uint256 minInterval)
        internal
        view
        returns (ConcentratedLiquidityStrategy.InitParams memory p)
    {
        p = _defaultParams();
        p.tickLower = -half;
        p.tickUpper = half;
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

    function _deployExecuted(int24 half, uint256 triggerBps, uint256 minInterval)
        internal
        returns (ConcentratedLiquidityStrategy s, RerangeLooper looper)
    {
        s = _newStrategy(_policyParams(half, triggerBps, minInterval));
        status.set(1, 1, address(s));
        vm.prank(address(vaultStub));
        usdg.approve(address(s), type(uint256).max);
        pool.setTicks(T, T);
        vm.prank(address(vaultStub));
        s.execute();
        looper = new RerangeLooper();
    }

    /// @notice Half-width x triggerBps below 10_000 floors the threshold to zero ticks and is refused.
    function test_init_zeroTickTriggerThresholdReverts() public {
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, _policyParams(200, 49, 0));
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, _policyParams(60, 166, 0));
    }

    /// @notice The boundary is inclusive: 200 x 50 = 10_000 is a one-tick threshold and is admitted.
    function test_init_oneTickTriggerThresholdSucceeds() public {
        ConcentratedLiquidityStrategy s = _newStrategy(_policyParams(200, 50, 0));
        assertEq(s.rerangePolicy().triggerBps, 50);
    }

    /// @notice Control: with a one-tick threshold a second same-transaction rerange reverts.
    function test_control_nonZeroThresholdStopsSecondRerange() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) = _deployExecuted(200, 50, 0);
        looper.loop(s, 1);
        assertEq(s.rerangeCount(), 1);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTriggerNotReached.selector);
        looper.loop(s, 1);
    }

    /// @notice Control: a non-zero minInterval stops the second rerange on its own.
    function test_control_nonZeroIntervalStopsSecondRerange() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) = _deployExecuted(200, 50, 60);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTooSoon.selector);
        looper.loop(s, 1);
        vm.warp(vm.getBlockTimestamp() + 60);
        looper.loop(s, 1);
        assertEq(s.rerangeCount(), 1);
    }

    /// @notice Control: the default 80% trigger refuses a rerange while price sits inside the range.
    function test_control_priceInsideRangeReverts() public {
        (ConcentratedLiquidityStrategy s, RerangeLooper looper) = _deployExecuted(200, 8_000, 0);
        vm.expectRevert(ConcentratedLiquidityStrategy.RerangeTriggerNotReached.selector);
        looper.loop(s, 1);
    }
}
