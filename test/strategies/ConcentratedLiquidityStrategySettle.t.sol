// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
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
    /// @dev Snapshot of everything a failed settle must leave alone.
    function _assertUntouched(uint256 tid, uint128 debtBefore, uint128 collateralBefore) internal view {
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed), "state advanced");
        assertEq(strategy.tokenId(), tid, "token id cleared");
        assertFalse(posm.isBurned(tid), "position burned");
        assertEq(_debtShares(), debtBefore, "debt moved");
        assertEq(_collateral(), collateralBefore, "collateral moved");
    }

    /// @notice Proceeds short of the debt: settle reverts with the typed shortfall
    ///         rather than repaying what it can and stranding the collateral.
    function test_settle_revertsWhenProceedsCannotCoverDebt() public {
        _execute();
        uint256 tid = strategy.tokenId();
        (uint128 d, uint128 c) = (_debtShares(), _collateral());
        // No fees: interest has accrued, so proceeds cannot cover principal+interest.
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.prank(address(vaultStub));
        vm.expectPartialRevert(ConcentratedLiquidityStrategy.ProceedsBelowDebt.selector);
        strategy.settle();

        _assertUntouched(tid, d, c);
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

    /// @notice An adapter that cannot quote the volatile leg reverts settle (no floor, no swap).
    function test_settle_revertsOnUnquotableAdapter() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setRate(address(nvda), address(usdg), 0);

        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.QuoteUnavailable.selector);
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
