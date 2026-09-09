// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CLFixture} from "./ConcentratedLiquidityStrategy.t.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";

/// @notice 6.9–6.12 — settlement: full unwind, all-or-revert on every leg, fee conversion.
abstract contract SettleFixture is CLFixture {
    /// @dev Credit the live position with fees, funding the position manager so
    ///      the collect can pay out. `fee0` is the vault asset, `fee1` the
    ///      volatile leg (the fixture's pool has the vault asset as token0).
    function _accrueFees(uint256 fee0, uint256 fee1) internal {
        if (fee0 != 0) usdg.mint(address(posm), fee0);
        if (fee1 != 0) nvda.mint(address(posm), fee1);
        posm.accrueFees(strategy.tokenId(), uint128(fee0), uint128(fee1));
    }

    function _debtShares() internal view returns (uint128) {
        return morpho.position(marketId, address(strategy)).borrowShares;
    }

    function _collateral() internal view returns (uint128) {
        return morpho.position(marketId, address(strategy)).collateral;
    }

    /// @dev Snapshot of everything a failed settle must leave alone.
    function _assertUntouched(uint256 tid, uint128 debtBefore, uint128 collateralBefore) internal view {
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed), "state advanced");
        assertEq(strategy.tokenId(), tid, "token id cleared");
        assertFalse(posm.isBurned(tid), "position burned");
        assertEq(_debtShares(), debtBefore, "debt moved");
        assertEq(_collateral(), collateralBefore, "collateral moved");
    }

    /// @dev Accrued interest on the clone's debt, read after a storage-side accrual.
    function _interest() internal returns (uint256) {
        morpho.accrueInterest(mp);
        return morpho.market(marketId).totalBorrowAssets - BORROW;
    }

    /// @dev Re-seat the clone at the tightest LTV init allows, converting `swapFractionBps` of the
    ///      borrow into the volatile leg.
    function _maxLtvStrategy(uint256 swapFractionBps) internal {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.borrowAmount = (COLLATERAL * (9_150 - strategy.MIN_LLTV_BUFFER_BPS())) / 10_000;
        p.swapFractionBps = swapFractionBps;
        strategy = _newStrategy(p);
        status.set(1, 1, address(strategy));
        vm.prank(address(vaultStub));
        usdg.approve(address(strategy), type(uint256).max);
    }

    /// @dev NVDA to 1e-4 of fair, pool anchor and adapter agreeing; spot and TWAP ticks untouched.
    function _loseTheVolatileLeg() internal {
        adapter.setRate(address(nvda), address(usdg), (100 * 1e18 / 1e12) / 10_000);
        pool.setSqrtPriceX96(uint160(1e7) * uint160(2 ** 96));
    }

    function _assertCloneEmptyAndUnwound() internal view {
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "not settled");
        assertEq(_debtShares(), 0, "debt outstanding");
        assertEq(_collateral(), 0, "collateral not withdrawn");
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset stranded");
        assertEq(nvda.balanceOf(address(strategy)), 0, "volatile leg stranded");
        assertEq(spUsdg.balanceOf(address(strategy)), 0, "wrapper shares stranded");
    }
}

contract ConcentratedLiquidityStrategySettleTest is SettleFixture {
    // ── 6.9 Full settlement ──

    function test_settle_fullUnwindReturnsEverythingToVault() public {
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        _execute();
        _accrueFees(1_000e6, 0);

        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertEq(_debtShares(), 0, "debt outstanding");
        assertEq(_collateral(), 0, "collateral not withdrawn");
        (,,,,,,, uint128 liquidity,,,,) = posm.positions(1);
        assertEq(liquidity, 0, "liquidity not unwound");
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset stranded in strategy");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore - COLLATERAL, "vault did not receive proceeds");
    }

    function test_settle_afterARerangeStillFullyUnwinds() public {
        _execute();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        pool.setTicks(850, 850);
        vm.prank(keeper);
        strategy.rerange();

        _accrueFees(1_000e6, 0);
        _settle();

        assertEq(_debtShares(), 0, "debt outstanding");
        assertEq(_collateral(), 0, "collateral not withdrawn");
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset stranded");
    }

    function test_settle_burnsThePosition() public {
        _execute();
        uint256 tid = strategy.tokenId();
        _accrueFees(1_000e6, 0);
        _settle();
        assertTrue(posm.isBurned(tid), "position not burned");
        assertEq(strategy.tokenId(), 0, "token id not cleared");
    }

    // ── 6.12 Fees in the non-vault-asset token ──

    /// @dev Fee income accrues in BOTH tokens. The `otherToken` half is only
    ///      value to the vault if settlement converts it, so this pins that the
    ///      conversion happens and lands in what the vault receives.
    function test_settle_convertsNonVaultAssetFees() public {
        _execute();

        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        // 100 NVDA of fees; at the fixture rate that is 10_000 USDG.
        _accrueFees(0, 100e18);
        _settle();

        assertEq(nvda.balanceOf(address(strategy)), 0, "volatile leg left unconverted");
        uint256 received = usdg.balanceOf(address(vaultStub)) - vaultBefore;
        // The vault gets its collateral back plus the converted fees, net of the
        // borrow round trip.
        assertGt(received, COLLATERAL, "converted fees not included in proceeds");
    }
}

/// @notice Settlement is all-or-revert: every leg that cannot complete reverts the
///         whole call, the clone's state is untouched, and the identical call is retried.
contract ConcentratedLiquidityStrategyAllOrRevertTest is SettleFixture {
    /// @notice Negative carry: no fees, a month of interest. Settle frees the shortfall from the
    ///         collateral and completes; the vault gets its capital back minus the interest.
    function test_settle_negativeCarry_deleveragesAndSettles() public {
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        _execute();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 interest = _interest();
        assertGt(interest, 0, "premise: interest accrued");
        uint256 swapsBefore = adapter.swapCalls();

        _settle();

        _assertCloneEmptyAndUnwound();
        assertGe(morpho.healthChecks(), 1, "the shortfall was freed with the debt open");
        assertEq(adapter.swapCalls() - swapsBefore, 1, "no extra swap: the collateral redeems to the asset");
        assertApproxEqAbs(usdg.balanceOf(address(vaultStub)), vaultBefore - interest, 1e6, "proceeds - debt");
    }

    /// @notice At max LTV with 90% of the borrow in a volatile leg that goes to ~0, no single
    ///         health-checked withdrawal can free the gap. One plain `settle()` converges anyway:
    ///         every pass but the last runs with the debt open, and the clone ends empty.
    function test_settle_negativeCarry_convergesPastTheSingleStepCeiling() public {
        _maxLtvStrategy(9_000);
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        _execute();
        _loseTheVolatileLeg();

        _settle();

        _assertCloneEmptyAndUnwound();
        uint256 passes = morpho.healthChecks();
        assertGe(passes, 2, "premise: past the single-step ceiling");
        assertEq(morpho.withdrawCollateralCalls(), passes + 1, "every deleverage pass was health-checked");
        uint256 proceeds = usdg.balanceOf(address(vaultStub)) + COLLATERAL - vaultBefore;
        assertGt(proceeds, 0, "nothing came back");
        assertLt(proceeds, COLLATERAL / 2, "premise: the volatile leg was lost");
    }

    /// @notice A debt past what the collateral supports frees nothing: `CollateralNotFreeable`,
    ///         with nothing moved.
    function test_settle_negativeCarry_revertsWhenEvenTheCollateralCannotCoverTheDebt() public {
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        // 1000%/yr for a year: the debt outgrows the collateral by an order of magnitude.
        irm.setRate(uint256(10e18) / 365 days);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertGt(_interest(), COLLATERAL, "premise: debt above the collateral");

        vm.prank(address(vaultStub));
        vm.expectPartialRevert(ConcentratedLiquidityStrategy.CollateralNotFreeable.selector);
        strategy.settle();

        _assertUntouched(tid, d, c);
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset moved");
    }

    /// @notice A wrapper whose exit fee eats more than each pass frees never lets the proceeds
    ///         reach the debt: the loop stops at `MAX_DELEVERAGE_PASSES` with a typed revert and
    ///         nothing moved, instead of running out of gas.
    function test_settle_deleverageLoopIsBoundedAndTyped() public {
        _maxLtvStrategy(9_000);
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        _loseTheVolatileLeg();
        // Freed collateral shrinks by (1 - fee) / lltv per pass; at 20% the series never covers the gap.
        spUsdg.setExitFeeBps(2_000);

        vm.prank(address(vaultStub));
        vm.expectPartialRevert(ConcentratedLiquidityStrategy.ProceedsBelowDebt.selector);
        strategy.settle();

        _assertUntouched(tid, d, c);
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset moved");
    }

    /// @notice The `settleSlippageBps` margin on the freed collateral absorbs a wrapper exit fee
    ///         inside the bound in a single pass.
    function test_settle_negativeCarry_marginCoversAWrapperExitFee() public {
        _execute();
        spUsdg.setExitFeeBps(100);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        _settle();

        _assertCloneEmptyAndUnwound();
        assertEq(morpho.healthChecks(), 1, "one pass");
    }

    /// @notice Control: a healthy position never enters the loop; one repay, one withdrawal with
    ///         the debt already cleared, one redeem.
    function test_settle_healthyPositiveCarry_neverEntersTheDeleverageLoop() public {
        _execute();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _accrueFees(1_000e6, 0);
        uint256 swapsBefore = adapter.swapCalls();

        _settle();

        _assertCloneEmptyAndUnwound();
        assertEq(morpho.repayCalls(), 1, "extra repay");
        assertEq(morpho.withdrawCollateralCalls(), 1, "extra withdrawal");
        assertEq(spUsdg.redeemCalls(), 1, "extra redeem");
        assertEq(adapter.swapCalls() - swapsBefore, 1, "extra swap");
        assertEq(morpho.healthChecks(), 0, "collateral withdrawn with debt open");
    }

    /// @notice The deleverage withdrawal runs with debt still open, so Morpho's health check
    ///         applies. At the tightest LTV init allows (LLTV - buffer) it still passes, because
    ///         the held proceeds are repaid before any collateral leaves.
    function test_settle_deleverageNeverLeavesMorphoUnhealthy() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.borrowAmount = (COLLATERAL * (9_150 - strategy.MIN_LLTV_BUFFER_BPS())) / 10_000;
        strategy = _newStrategy(p);
        status.set(1, 1, address(strategy));
        vm.prank(address(vaultStub));
        usdg.approve(address(strategy), type(uint256).max);
        _execute();
        vm.warp(vm.getBlockTimestamp() + 30 days);

        _settle();

        _assertCloneEmptyAndUnwound();
        assertGe(morpho.healthChecks(), 1, "the deleverage withdrawal was not health-checked");
    }

    /// @notice Between execute and settle no caller can move the Morpho collateral or the debt:
    ///         the proposer's only surface is `updateParams`, `rerange` is permissionless, and the
    ///         old `deleverageStep()` selector is gone.
    function test_noExternalEntryPointCanRelieveLtvAfterExecute() public {
        _execute();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint256(400), uint256(0)));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        pool.setTicks(850, 850);
        vm.prank(keeper);
        strategy.rerange();

        (bool ok, bytes memory ret) = address(strategy).call(abi.encodeWithSignature("deleverageStep()"));
        assertFalse(ok, "deleverageStep() still dispatches");
        assertEq(ret.length, 0, "not a typed revert: the selector does not exist");
        (ok,) = address(strategy).call(abi.encodeWithSignature("tokenId()"));
        assertTrue(ok, "control: a live selector dispatches");

        assertEq(_debtShares(), d, "debt moved");
        assertEq(_collateral(), c, "collateral moved");
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset parked on the clone");
    }

    /// @notice Collateral that cannot leave Morpho reverts settle.
    function test_settle_revertsWhenCollateralWithdrawalFails() public {
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        _accrueFees(1_000e6, 0);
        morpho.setCollateralWithdrawCap(1); // any real withdrawal is refused

        vm.prank(address(vaultStub));
        vm.expectRevert("MockMorpho: withdraw capped");
        strategy.settle();

        _assertUntouched(tid, d, c);
    }

    /// @notice Settle never asks the adapter for a quote: with `quote` reverting, the swap
    ///         fills at the TWAP-anchored pool floor and the clone ends empty.
    function test_settle_succeedsWhenTheAdapterCannotQuote() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setQuoteReverts(true);
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));

        vm.prank(address(vaultStub));
        strategy.settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "settled");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore, "proceeds delivered");
        assertEq(nvda.balanceOf(address(strategy)), 0, "volatile leg converted");
        assertEq(usdg.balanceOf(address(strategy)), 0, "clone holds nothing");
        assertEq(_debtShares(), 0, "debt cleared");
    }

    /// @notice The pool anchor is the settle floor: an unquotable adapter filling below it
    ///         still reverts settle.
    function test_settle_stillRevertsWhenTheFillIsBelowThePoolAnchor() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setQuoteReverts(true);
        adapter.setRate(address(nvda), address(usdg), (100 * 1e18 / 1e12) / 2);

        vm.prank(address(vaultStub));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.settle();
    }

    /// @notice A swap that fills below the floor reverts settle; the failure is not swallowed.
    function test_settle_revertsWhenTheSwapFillsBelowTheFloor() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setRate(address(nvda), address(usdg), (100 * 1e18 / 1e12) / 2);

        vm.prank(address(vaultStub));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.settle();
    }

    /// @notice The settle floor is the pool anchor at `settleSlippageBps` exactly: the requested
    ///         minOut equals it, a fill one wei under it reverts, one wei over it settles.
    function test_settle_floorBoundary_oneWeiBelowRevertsOneWeiAboveSettles() public {
        _execute();
        _accrueFees(0, 100e18);

        // Measure the volatile balance the strategy sells and the floor it asks for, then rewind.
        uint256 snap = vm.snapshotState();
        vm.prank(address(vaultStub));
        strategy.settle();
        uint256 amountIn = adapter.lastAmountIn();
        uint256 requested = adapter.lastAmountOutMin();
        vm.revertToState(snap);

        // NVDA is token1: divide by the price twice, fee first, slippage second.
        (uint160 sp,,,,,,) = pool.slot0();
        uint256 expected = Math.mulDiv(Math.mulDiv(amountIn, 1 << 96, sp), 1 << 96, sp);
        expected = (expected * (1e6 - POOL_FEE)) / 1e6;
        expected = (expected * (10_000 - strategy.settleSlippageBps())) / 10_000;
        assertGt(expected, 0, "premise: a priced floor");
        assertEq(requested, expected, "requested minOut is the pool anchor");

        adapter.setFixedAmountOut(expected - 1);
        vm.prank(address(vaultStub));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.settle();

        uint256 swapsBefore = adapter.swapCalls();
        adapter.setFixedAmountOut(expected + 1);
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(adapter.swapCalls(), swapsBefore + 1, "one settle swap");
        assertEq(adapter.lastAmountOutMin(), expected, "requested minOut at the boundary");
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "settled one wei over");
    }

    /// @notice D8: settle refuses to convert against a spot that is off the TWAP.
    function test_settle_revertsWhenSpotIsOutsideTheTwapBound() public {
        _execute();
        pool.setTicks(23_000, 0);

        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.SpotOutsideTwapBound.selector);
        strategy.settle();
    }

    /// @notice D8: an unreadable TWAP is the same refusal, not a skipped check.
    function test_settle_revertsWhenTheTwapIsUnreadable() public {
        _execute();
        pool.setObservationCardinality(1);

        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.TwapUnavailable.selector);
        strategy.settle();
    }

    /// @notice A paused ERC-4626 wrapper reverts settle with the wrapper's own reason;
    ///         the collateral is not stranded on the clone as unredeemed shares.
    function test_settle_revertsWhenWrapperRedemptionIsPaused() public {
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        _accrueFees(1_000e6, 0);
        spUsdg.setRedeemPaused(true);

        vm.prank(address(vaultStub));
        vm.expectRevert("MockERC4626Wrapper: redeem paused");
        strategy.settle();

        _assertUntouched(tid, d, c);
        assertEq(spUsdg.balanceOf(address(strategy)), 0, "wrapper shares stranded on the clone");
    }

    /// @notice A wrapper that serves only part of the balance reverts settle rather than
    ///         redeeming the servable part and stranding the rest.
    function test_settle_revertsWhenWrapperRedeemIsCapped() public {
        _execute();
        _accrueFees(1_000e6, 0);
        spUsdg.setRedeemCap(_collateral() / 4);

        vm.prank(address(vaultStub));
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxRedeem.selector);
        strategy.settle();
    }

    /// @notice A wrapper whose `redeem` silently clamps to a cap leaves shares on the clone;
    ///         settle reverts rather than committing `Settled` over them.
    function test_settle_revertsWhenTheWrapperRedeemClamps() public {
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        _accrueFees(1_000e6, 0);
        spUsdg.setRedeemCap(1_000e6);
        spUsdg.setRedeemClamps(true);

        vm.prank(address(vaultStub));
        vm.expectPartialRevert(ConcentratedLiquidityStrategy.StrategyHoldsTokens.selector);
        strategy.settle();

        _assertUntouched(tid, d, c);
        assertEq(spUsdg.balanceOf(address(strategy)), 0, "wrapper shares stranded on the clone");
    }

    /// @notice An adapter that pays the full quote but pulls only half of `amountIn` leaves the
    ///         volatile leg on the clone; settle reverts rather than committing `Settled` over it.
    function test_settle_revertsWhenTheAdapterLeavesTheVolatileLegBehind() public {
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        _accrueFees(1_000e6, 100e18);
        adapter.setPullBps(5_000);

        vm.prank(address(vaultStub));
        vm.expectPartialRevert(ConcentratedLiquidityStrategy.StrategyHoldsTokens.selector);
        strategy.settle();

        _assertUntouched(tid, d, c);
        assertEq(nvda.balanceOf(address(strategy)), 0, "volatile leg stranded on the clone");
    }

    /// @notice Control: with honest counterparties the check is inert and every checked
    ///         balance and the Morpho position are zero after settle.
    function test_settle_honestPathLeavesEveryCheckedBalanceAtZero() public {
        _execute();
        _accrueFees(1_000e6, 100e18);
        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset");
        assertEq(nvda.balanceOf(address(strategy)), 0, "volatile leg");
        assertEq(spUsdg.balanceOf(address(strategy)), 0, "wrapper shares");
        assertEq(_debtShares(), 0, "debt");
        assertEq(_collateral(), 0, "collateral");
        assertEq(strategy.tokenId(), 0, "position");
    }

    /// @notice `accrueInterest` is typed: a reverting IRM reverts settle.
    function test_settle_revertsOnRevertingIrm() public {
        _execute();
        // Interest must be pending, or the market never consults the IRM.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _accrueFees(1_000e6, 0);
        irm.setReverting(true);

        vm.prank(address(vaultStub));
        vm.expectRevert("MockIrm: reverting");
        strategy.settle();
    }

    /// @notice A position whose `collect` cannot pay out reverts settle; the position is kept.
    function test_settle_revertsWhenThePositionCannotBeUnwound() public {
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        // Credit fees the position manager was never funded for, so `collect`
        // tries to transfer more than it holds.
        posm.accrueFees(tid, uint128(1_000_000e6), 0);

        vm.prank(address(vaultStub));
        vm.expectRevert();
        strategy.settle();

        _assertUntouched(tid, d, c);
    }

    /// @notice The failed settle is retried, not recovered: once the condition clears the
    ///         identical call delivers everything.
    function test_settle_succeedsOnRetryOnceTheConditionClears() public {
        _execute();
        _accrueFees(1_000e6, 0);
        spUsdg.setRedeemPaused(true);
        vm.prank(address(vaultStub));
        vm.expectRevert("MockERC4626Wrapper: redeem paused");
        strategy.settle();

        spUsdg.setRedeemPaused(false);
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertEq(_debtShares(), 0, "debt outstanding");
        assertEq(_collateral(), 0, "collateral not withdrawn");
        assertEq(spUsdg.balanceOf(address(strategy)), 0, "shares stranded");
        assertEq(nvda.balanceOf(address(strategy)), 0, "volatile leg stranded");
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset stranded");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore, "vault did not receive the proceeds");
    }
}
