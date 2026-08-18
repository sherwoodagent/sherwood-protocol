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

        vm.prank(address(vaultStub)); // vault-only since the cohort-accounting fix
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

        vm.prank(address(vaultStub));
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
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.NotSettled.selector);
        strategy.releaseUnconvertible();
    }

    /// @notice VAULT-ONLY, for the same reason `sweep()` is. The hatch converts
    ///         before it releases, so it can push VAULT ASSET home — a second
    ///         door onto the balance delta `SyndicateVault._payCohortShare`
    ///         splits, and a delta measures everything only if it is the only
    ///         door. Called directly the exited cohort is credited nothing and
    ///         the arrival lifts the stayers' price instead, unrepairably.
    /// @dev    The permissionless property is unchanged where it is load-bearing:
    ///         `SyndicateVault.releaseUnconvertible(strategy)` is open to anyone
    ///         and drives this. Only the unmeasured door is gone.
    function test_releaseUnconvertible_isVaultOnly() public {
        _execute();
        _accrueFees(0, 100e18);
        adapter.setRate(address(nvda), address(usdg), 0);
        _settle();

        vm.prank(keeper);
        vm.expectRevert(BaseStrategy.NotVault.selector);
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

        vm.prank(address(vaultStub));
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

        vm.prank(address(vaultStub));
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

        vm.prank(address(vaultStub)); // vault-only since the cohort-accounting fix
        uint256 released = strategy.releaseUnconvertible();

        assertEq(released, stranded, "released amount mismatch");
        assertEq(nvda.balanceOf(address(strategy)), 0, "residue still on the clone");
        assertEq(nvda.balanceOf(address(vaultStub)), stranded, "vault did not receive the residue");
    }
}

contract ConcentratedLiquidityStrategySweepTest is SettleFixture {
    // ── 6.11 Sweep ──

    function test_sweep_beforeSettlementReverts() public {
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.NotSettled.selector);
        strategy.sweep();

        _execute();
        vm.prank(address(vaultStub));
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

        vm.prank(address(vaultStub)); // vault-only since the cohort-accounting fix
        strategy.sweep();

        assertEq(_collateral(), 0, "residue not recovered");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore, "vault did not receive the residue");
    }

    function test_sweep_isIdempotent() public {
        _execute();
        _accrueFees(1_000e6, 0);
        _settle();

        // Nothing left to move; must not revert.
        vm.prank(address(vaultStub));
        uint256 first = strategy.sweep();
        vm.prank(address(vaultStub));
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

        vm.prank(address(vaultStub));
        strategy.sweep();

        assertEq(nvda.balanceOf(address(strategy)), 0, "leg still unconverted");
        assertGt(usdg.balanceOf(address(vaultStub)), vaultBefore, "converted residue not returned");
    }
}

/// @notice The recovery paths must FIT the ceiling the vault calls them under.
/// @dev    Both entry points are now vault-only, so every recovery runs through
///         `SyndicateVault._recoverResidueVia`'s `call{gas: _SWEEP_GAS}` —
///         1,500,000. Before that change a keeper could call the template
///         directly with unbounded gas, so the ceiling never bound the heavy
///         path. If a reachable shape exceeds it the residue is UNRECOVERABLE:
///         the vault ignores the call's result, so an out-of-gas clone simply
///         recovers nothing, stays counted, and holds the deposit gate until it
///         is pruned and burned.
///
///         A FLOOR, NOT THE BOUND. Every vendor this path touches is a mock
///         here — Morpho, the position manager, the swap adapter, the ERC-4626
///         wrapper — so these numbers bound the TEMPLATE'S OWN logic and nothing
///         else. A mock cannot falsify an assumption about what live Morpho
///         charges; it only agrees. The measurement against real venues lives in
///         `ConcentratedLiquidityVaultE2EFork.t.sol::_releaseUnconvertible`,
///         which is where `_SWEEP_GAS`'s natspec request is actually answered.
///         What this suite is good for is catching a REGRESSION: a new leg added
///         to either path shows up here immediately and cheaply, without an RPC.
contract ConcentratedLiquidityStrategyRecoveryGasTest is SettleFixture {
    /// @dev Mirrors `SyndicateVault._SWEEP_GAS`, which is private and so cannot
    ///      be read from here. If that constant is ever lowered this pin goes
    ///      stale in the permissive direction, so it is quoted by name in the
    ///      vault's own natspec as the thing that measures it.
    uint256 internal constant SWEEP_GAS = 1_500_000;

    /// @dev Every leg of `releaseUnconvertible` armed at once: a wrapper balance
    ///      whose redemption is REFUSED (so the redeem is attempted AND the raw
    ///      collateral push fires — the two are mutually exclusive on a working
    ///      wrapper, and this is the branch that runs both), an `otherToken`
    ///      residue with a live adapter (so the swap really executes rather than
    ///      declining), and an idle `asset` balance. That is: redeem attempt +
    ///      swap + three `_pushAllToVault` calls.
    function _armHeaviestReleaseShape() internal {
        _execute();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _settle();

        // Real shares, minted through the wrapper rather than `deal`-ed in, so
        // the balance the push moves is one the wrapper agrees exists.
        usdg.mint(address(this), 50_000e6);
        usdg.approve(address(spUsdg), 50_000e6);
        spUsdg.deposit(50_000e6, address(strategy));
        spUsdg.setRedeemPaused(true);
        nvda.mint(address(strategy), 100e18);
        usdg.mint(address(strategy), 20_000e6);
    }

    function test_releaseUnconvertible_fitsTheVaultsGasCeiling() public {
        _armHeaviestReleaseShape();

        uint256 before = gasleft();
        vm.prank(address(vaultStub));
        strategy.releaseUnconvertible();
        uint256 used = before - gasleft();

        // NON-VACUITY: the heavy legs must actually have run. A shape that
        // pushed nothing would "fit" trivially.
        assertEq(usdg.balanceOf(address(strategy)), 0, "asset push did not fire");
        assertEq(nvda.balanceOf(address(strategy)), 0, "otherToken push did not fire");
        assertEq(spUsdg.balanceOf(address(strategy)), 0, "collateral push did not fire");

        emit log_named_uint("releaseUnconvertible gas", used);
        assertLt(used, SWEEP_GAS, "the hatch cannot run under the vault's ceiling");
    }

    function test_sweep_fitsTheVaultsGasCeiling() public {
        _armHeaviestReleaseShape();

        uint256 before = gasleft();
        vm.prank(address(vaultStub));
        strategy.sweep();
        uint256 used = before - gasleft();

        assertEq(usdg.balanceOf(address(strategy)), 0, "asset push did not fire");
        emit log_named_uint("sweep gas", used);
        assertLt(used, SWEEP_GAS, "sweep cannot run under the vault's ceiling");
    }

    /// @notice HEADROOM, stated as a number rather than left implicit. The
    ///         measurement above only says "fits today"; this says by how much,
    ///         so a future leg added to either path fails here loudly instead of
    ///         silently eating the margin.
    function test_recoveryPathsKeepMeaningfulHeadroom() public {
        _armHeaviestReleaseShape();

        uint256 before = gasleft();
        vm.prank(address(vaultStub));
        strategy.releaseUnconvertible();
        uint256 used = before - gasleft();

        // An eighth of the ceiling, against mocked vendors. Deliberately far
        // tighter than "fits": the real cost is a multiple of this, and PR #249
        // adds `_repayAndWithdraw` to this same path (Morpho accrue + repay +
        // withdraw + a second wrapper redeem). A pin at the ceiling itself would
        // hold right up until the fork suite failed instead.
        assertLt(used, SWEEP_GAS / 8, "template-side cost grew - re-measure on the fork before assuming it still fits");
    }
}
