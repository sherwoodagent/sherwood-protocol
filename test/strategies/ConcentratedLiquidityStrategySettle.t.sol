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

    function _sawSettlementIncomplete() internal returns (bool) {
        bytes32 sig = keccak256("SettlementIncomplete(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
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
