// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {CLFixture} from "./ConcentratedLiquidityStrategy.t.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";

/// @notice 6.9–6.12 — settlement, partial settlement, sweep, fee conversion.
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

contract ConcentratedLiquidityStrategyPartialSettleTest is SettleFixture {
    // ── 6.10 Partial settlement: each failure combination ──

    /// @dev Repay short: the unwound position yields less than the outstanding
    ///      debt. Settlement must take the deliverable maximum and complete.
    ///      Adversary framing: reverting here would hand whoever can create the
    ///      shortfall a veto over the vault's whole settlement path.
    function test_settle_repayShortEmitsAndDoesNotRevert() public {
        _execute();
        // No fees: interest has accrued, so proceeds cannot cover principal+interest.
        vm.warp(vm.getBlockTimestamp() + 30 days);

        vm.recordLogs();
        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "settle did not complete");
        assertGt(_debtShares(), 0, "test did not actually create a shortfall");
        assertTrue(_sawSettlementIncomplete(), "SettlementIncomplete not emitted");
    }

    /// @dev Withdraw short: debt clears but the collateral cannot come out.
    function test_settle_withdrawShortEmitsAndDoesNotRevert() public {
        _execute();
        _accrueFees(1_000e6, 0);
        morpho.setCollateralWithdrawCap(1); // any real withdrawal is refused

        vm.recordLogs();
        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "settle did not complete");
        assertEq(_debtShares(), 0, "debt should have cleared");
        assertGt(_collateral(), 0, "test did not actually strand collateral");
        assertTrue(_sawSettlementIncomplete(), "SettlementIncomplete not emitted");
    }

    /// @dev Both short at once.
    function test_settle_bothShortEmitsAndDoesNotRevert() public {
        _execute();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        morpho.setCollateralWithdrawCap(1);

        vm.recordLogs();
        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertGt(_debtShares(), 0, "no debt shortfall");
        assertGt(_collateral(), 0, "no collateral shortfall");
        assertTrue(_sawSettlementIncomplete(), "SettlementIncomplete not emitted");
    }

    /// @dev An adapter that cannot quote must not revert SETTLE. Entry fails
    ///      closed; the exit degrades, because settle is the vault's only exit.
    function test_settle_unquotableAdapterDoesNotRevert() public {
        _execute();
        _accrueFees(0, 100e18);
        // Clearing the reverse rate makes both quote() and swap() revert.
        adapter.setRate(address(nvda), address(usdg), 0);

        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "settle reverted on a dead adapter");
        assertGt(nvda.balanceOf(address(strategy)), 0, "volatile leg should be left for sweep");
    }

    /// @dev The wrapper is a THIRD PARTY on the settlement path. `spUSDG` and
    ///      its class gate redemption behind pauses, caps and queues that this
    ///      proposal cannot influence — so a paused wrapper must cost this
    ///      proposal a stranded residue, never the vault its only exit.
    ///      A typed `redeem` here would let whoever operates the wrapper freeze
    ///      vault-wide redemption by pausing their own product.
    function test_settle_pausedWrapperRedeemDoesNotRevert() public {
        _execute();
        _accrueFees(1_000e6, 0);
        spUsdg.setRedeemPaused(true);

        vm.recordLogs();
        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "a paused wrapper vetoed settlement");
        assertEq(_debtShares(), 0, "debt should have cleared");
        assertEq(_collateral(), 0, "collateral should have left Morpho");
        assertGt(spUsdg.balanceOf(address(strategy)), 0, "test did not actually strand shares");
        assertTrue(_sawSettlementIncomplete(), "stranded shares reported as a complete settlement");
    }

    /// @dev The residue `sweep()` can recover must not be narrower than the one
    ///      `_settle` can create. Morpho's collateral is ZERO here — the shares
    ///      already left it — so a retry gated on Morpho's balance would never
    ///      fire and the shares would sit on the clone forever.
    function test_sweep_recoversWrapperSharesOnceRedeemResumes() public {
        _execute();
        _accrueFees(1_000e6, 0);
        spUsdg.setRedeemPaused(true);
        _settle();

        uint256 stranded = spUsdg.balanceOf(address(strategy));
        assertGt(stranded, 0, "precondition: shares stranded");
        assertEq(_collateral(), 0, "precondition: Morpho holds nothing to key a retry off");

        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        spUsdg.setRedeemPaused(false);

        vm.prank(keeper); // anyone
        strategy.sweep();

        assertEq(spUsdg.balanceOf(address(strategy)), 0, "shares not recovered");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore, "vault did not receive the redeemed collateral");
    }

    /// @dev A wrapper that will serve PART of the balance should serve that part
    ///      now rather than failing whole and deferring everything to `sweep()`.
    function test_settle_cappedWrapperRedeemTakesTheServablePart() public {
        _execute();
        _accrueFees(1_000e6, 0);
        uint256 posted = _collateral();
        spUsdg.setRedeemCap(posted / 4);

        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        uint256 left = spUsdg.balanceOf(address(strategy));
        assertGt(left, 0, "cap should have left a remainder");
        assertLt(left, posted, "the servable quarter was not taken");
    }

    /// @dev `accrueInterest` calls the market's IRM, and the IRM address is part
    ///      of the proposer-supplied `MarketParams`. Left typed, a proposer
    ///      could name an IRM that reverts and hold the vault's exit hostage.
    function test_settle_revertingIrmDoesNotVetoSettlement() public {
        _execute();
        _accrueFees(1_000e6, 0);
        irm.setReverting(true);

        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "a reverting IRM vetoed settlement");
    }

    /// @dev The unwind is four typed position-manager calls; any of them
    ///      reverting used to take the whole settlement with it. Here `collect`
    ///      cannot pay out, which is the realistic shape of that failure.
    function test_settle_failedUnwindDoesNotVetoSettlement() public {
        _execute();
        uint256 tid = strategy.tokenId();
        // Credit fees the position manager was never funded for, so `collect`
        // tries to transfer more than it holds.
        posm.accrueFees(tid, uint128(1_000_000e6), 0);

        vm.recordLogs();
        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "a failed unwind vetoed settlement");
        assertEq(strategy.tokenId(), tid, "token id cleared despite the unwind failing");
        assertFalse(posm.isBurned(tid), "position reported burned after a failed unwind");
    }

    /// @dev And the unwind is retried by `sweep()`, not abandoned — the whole
    ///      point of keeping `tokenId` set above.
    function test_sweep_retriesTheUnwind() public {
        _execute();
        uint256 tid = strategy.tokenId();
        posm.accrueFees(tid, uint128(1_000_000e6), 0);
        _settle();
        assertEq(strategy.tokenId(), tid, "precondition: position still held");

        // Fund the position manager so the collect can now pay out.
        usdg.mint(address(posm), 1_000_000e6);

        vm.prank(keeper);
        strategy.sweep();

        assertEq(strategy.tokenId(), 0, "unwind not retried");
        assertTrue(posm.isBurned(tid), "position not burned on retry");
    }

    function _sawSettlementIncomplete() internal returns (bool) {
        bytes32 sig = keccak256("SettlementIncomplete(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
    }
}

/// @notice The last-resort release path for a residue that can never be
///         converted. Deliberately separate from `sweep()`.
contract ConcentratedLiquidityStrategyReleaseTest is SettleFixture {
    function test_releaseUnconvertible_beforeSettlementReverts() public {
        _execute();
        vm.expectRevert(ConcentratedLiquidityStrategy.NotSettled.selector);
        strategy.releaseUnconvertible();
    }

    /// @dev `sweep()` must NOT do this itself: pushing on every sweep would move
    ///      the residue somewhere this contract can no longer sell it, throwing
    ///      away the conversion that a later `sweep()` would have made.
    function test_sweep_leavesUnconvertibleResidueRecoverable() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setRate(address(nvda), address(usdg), 0);
        _settle();

        vm.prank(keeper);
        strategy.sweep();

        assertGt(nvda.balanceOf(address(strategy)), 0, "sweep foreclosed the conversion");
    }

    /// @dev Conversion is attempted FIRST every time, so a caller who reaches
    ///      for the hatch during an outage that would have cleared gets the
    ///      conversion instead of the release.
    function test_releaseUnconvertible_prefersConversion() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setRate(address(nvda), address(usdg), 0);
        _settle();

        adapter.setRate(address(nvda), address(usdg), 100 * 1e18 / 1e12); // outage clears
        uint256 vaultUsdgBefore = usdg.balanceOf(address(vaultStub));

        vm.prank(keeper);
        uint256 released = strategy.releaseUnconvertible();

        assertEq(released, 0, "released unconverted despite a working adapter");
        assertEq(nvda.balanceOf(address(vaultStub)), 0, "volatile leg pushed unconverted");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultUsdgBefore, "conversion proceeds not delivered");
    }

    /// @dev The case it exists for: an adapter that will never quote this pair
    ///      again. Without this the residue sits on the clone permanently —
    ///      nothing here can move a token that is neither the vault asset nor
    ///      swappable, whereas the vault carries an owner-gated `rescueERC20`.
    function test_releaseUnconvertible_handsResidueToTheVault() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setRate(address(nvda), address(usdg), 0);
        _settle();

        uint256 stranded = nvda.balanceOf(address(strategy));
        assertGt(stranded, 0, "precondition: residue stranded");

        vm.prank(keeper); // anyone
        uint256 released = strategy.releaseUnconvertible();

        assertEq(released, stranded, "released amount mismatch");
        assertEq(nvda.balanceOf(address(strategy)), 0, "residue still on the clone");
        assertEq(nvda.balanceOf(address(vaultStub)), stranded, "vault did not receive the residue");
    }
}

contract ConcentratedLiquidityStrategySweepTest is SettleFixture {
    // ── 6.11 Sweep ──

    function test_sweep_beforeSettlementReverts() public {
        vm.expectRevert(ConcentratedLiquidityStrategy.NotSettled.selector);
        strategy.sweep();

        _execute();
        vm.expectRevert(ConcentratedLiquidityStrategy.NotSettled.selector);
        strategy.sweep();
    }

    /// @dev Permissionless and one-directional — out of the clone, into the
    ///      vault it was always owed to.
    function test_sweep_recoversResidueOnceConditionsImprove() public {
        _execute();
        _accrueFees(1_000e6, 0);
        morpho.setCollateralWithdrawCap(1);
        _settle();

        uint128 stranded = _collateral();
        assertGt(stranded, 0, "test did not strand collateral");

        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        morpho.setCollateralWithdrawCap(type(uint256).max); // conditions recover

        vm.prank(keeper); // anyone
        strategy.sweep();

        assertEq(_collateral(), 0, "residue not recovered");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore, "vault did not receive the residue");
    }

    function test_sweep_isIdempotent() public {
        _execute();
        _accrueFees(1_000e6, 0);
        _settle();

        // Nothing left to move; must not revert.
        vm.prank(keeper);
        uint256 first = strategy.sweep();
        vm.prank(keeper);
        uint256 second = strategy.sweep();

        assertEq(first, 0, "nothing should have been swept");
        assertEq(second, 0, "nothing should have been swept");
    }

    function test_sweep_convertsLeftoverVolatileLeg() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setRate(address(nvda), address(usdg), 0); // conversion unavailable at settle
        _settle();
        assertGt(nvda.balanceOf(address(strategy)), 0, "precondition: leg left unconverted");

        // Adapter recovers.
        adapter.setRate(address(nvda), address(usdg), 100 * 1e18 / 1e12);
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));

        vm.prank(keeper);
        strategy.sweep();

        assertEq(nvda.balanceOf(address(strategy)), 0, "leg still unconverted");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore, "converted residue not returned");
    }
}
