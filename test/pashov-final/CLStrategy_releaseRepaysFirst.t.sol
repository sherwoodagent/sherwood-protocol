// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {SettleFixture} from "../strategies/ConcentratedLiquidityStrategySettle.t.sol";

/// @title ConcentratedLiquidityStrategy — the escape hatch that removed the
///        repayment's working capital (finding #10)
/// @notice TWO permissionless post-settlement recovery paths, and they were not
///         symmetric. `sweep()` repays Morpho before pushing to the vault;
///         `releaseUnconvertible()` pushed without repaying.
///
///         That is not merely a missing step. `_repayAndWithdraw` funds the
///         repayment from this clone's OWN asset balance, and the push sends
///         every wei of that balance away — so a bare release REMOVES the
///         resource the repayment needs. A later `sweep()` reads `held == 0`,
///         takes neither repay branch, and the collateral stays locked behind
///         debt nothing can clear.
///
///         THE ADVERSARY IS FUNDED. Asset arrives on a settled clone in
///         trickles, and `sweep()` is designed to be called repeatedly to
///         accumulate enough to repay. A Morpho liquidator front-runs each
///         attempt with a bare release, for gas, and keeps the position
///         permanently unable to repay until it is liquidated and they take the
///         incentive.
///
///         AND THE VAULT PAYS TOO. `hasUnvaluedResidue()` is true while Morpho
///         holds collateral, and the vault refuses ALL deposits while any
///         settled strategy reports that — so this is a vault-wide deposit
///         freeze anyone can hold open, against a lock whose safety argument is
///         that every unvaluable shape is unwindable by the permissionless
///         `sweep()`.
contract PashovFinalCLReleaseRepaysTest is SettleFixture {
    address internal liquidator = makeAddr("morphoLiquidator");

    /// @dev Settle with debt outstanding and collateral still posted, then put
    ///      asset on the clone — the trickle a `sweep()` would repay with.
    ///      Interest accrued over 30 days is what makes the unwound position
    ///      fall short of principal + interest.
    function _settleShortWithAssetOnClone(uint256 trickle) internal {
        _execute();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _settle();

        assertGt(_debtShares(), 0, "precondition: no debt shortfall to repay");
        assertGt(_collateral(), 0, "precondition: no collateral at risk");

        usdg.mint(address(strategy), trickle);
    }

    // ── the defect ──

    /// @notice THE FRONT-RUN. A bare release lands one block before the honest
    ///         `sweep()`, taking the asset the repayment needed. The sweep then
    ///         has nothing to repay with, and the collateral never comes home.
    ///
    ///         Before the fix this asserted the opposite: the vault received the
    ///         trickle, the debt was untouched, and the collateral sat in Morpho
    ///         accruing interest with no path out.
    function test_releaseThenSweepStillClearsTheDebtAndFreesTheCollateral() public {
        _settleShortWithAssetOnClone(20_000e6);

        vm.prank(liquidator); // permissionless — anyone, and someone is paid to
        strategy.releaseUnconvertible();

        vm.prank(keeper);
        strategy.sweep();

        assertEq(_debtShares(), 0, "debt survived the release-then-sweep sequence");
        assertEq(_collateral(), 0, "collateral still stranded in Morpho");
    }

    /// @notice The same sequence read from the vault's side. The collateral has
    ///         to arrive as VALUE, not merely leave Morpho — a release that
    ///         exported the trickle and abandoned the position would satisfy a
    ///         balance-only check while losing the principal.
    function test_releaseThenSweepReturnsMoreThanTheTrickleItExported() public {
        _settleShortWithAssetOnClone(20_000e6);
        // Baseline AFTER settle: measuring from before `_execute` would fold in
        // the vault paying the collateral out, and the delta would net to less
        // than the trickle even on a perfect recovery.
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));

        vm.prank(liquidator);
        strategy.releaseUnconvertible();
        vm.prank(keeper);
        strategy.sweep();

        assertGt(
            usdg.balanceOf(address(vaultStub)) - vaultBefore,
            20_000e6,
            "vault got back only the trickle -- the collateral never converted"
        );
    }

    /// @notice THE VAULT-WIDE HARM. `hasUnvaluedResidue()` gates deposits for the
    ///         whole vault, not just this clone. If a bare release can strand the
    ///         collateral, it can hold every LP's deposit shut indefinitely.
    function test_releaseDoesNotHoldTheVaultDepositLockOpen() public {
        _settleShortWithAssetOnClone(20_000e6);
        assertTrue(strategy.hasUnvaluedResidue(), "precondition: the lock is on");

        vm.prank(liquidator);
        strategy.releaseUnconvertible();
        vm.prank(keeper);
        strategy.sweep();

        assertFalse(strategy.hasUnvaluedResidue(), "deposit lock held open by a bare release");
    }

    /// @notice REPEATED front-running must not win either. The liquidator's
    ///         strategy is to release on every trickle, not once — so the
    ///         property has to hold across an interleaved sequence, not just a
    ///         single pair of calls.
    function test_repeatedReleasesCannotKeepThePositionUnrepayable() public {
        _settleShortWithAssetOnClone(5_000e6);

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(liquidator);
            strategy.releaseUnconvertible();
            usdg.mint(address(strategy), 5_000e6); // the next trickle
        }
        // AND THE LAST ONE. Leaving a trickle un-drained here would hand
        // `sweep()` the working capital the attack is defined by taking, and the
        // test would pass against the unfixed contract -- which it did, until
        // this call was added.
        vm.prank(liquidator);
        strategy.releaseUnconvertible();

        vm.prank(keeper);
        strategy.sweep();

        assertEq(_debtShares(), 0, "four releases kept the debt alive");
        assertEq(_collateral(), 0, "four releases kept the collateral stranded");
    }

    // ── the fix must not overreach ──

    /// @notice A release with NOTHING to repay is unchanged. `_repayAndWithdraw`
    ///         is a no-op against a cleared position, so the hatch keeps working
    ///         for the case it was actually built for: an `otherToken` residue on
    ///         a fully-settled clone.
    function test_releaseStillExportsUnconvertibleResidueWhenNoDebtRemains() public {
        _execute();
        _accrueFees(1_000e6, 0);
        _settle();
        assertEq(_debtShares(), 0, "precondition: this case has no debt");

        // The residue lands AFTER a clean settle -- an LP fee that converted
        // late -- and the adapter has since stopped quoting the pair, which is
        // the permanent-outage case this hatch exists for. Staging it before
        // settle instead would make settle itself fall short and leave debt,
        // which is the OTHER case (covered above).
        nvda.mint(address(strategy), 100e18);
        adapter.setRate(address(nvda), address(usdg), 0);
        assertGt(nvda.balanceOf(address(strategy)), 0, "precondition: nothing stranded to release");

        vm.prank(keeper);
        uint256 released = strategy.releaseUnconvertible();

        assertGt(released, 0, "the escape hatch stopped escaping");
        assertEq(nvda.balanceOf(address(strategy)), 0, "residue left on the clone");
    }

    /// @notice Still idempotent. The added repay must not make a second call
    ///         revert on an already-cleared position — the hatch is
    ///         permissionless and callable at any time, so a revert would be a
    ///         griefing surface of its own.
    ///
    ///         Asserts the SECOND call's own return, not merely the end state:
    ///         an end-state check after a `sweep()` holds even if the second
    ///         release moved something it should not have, so it pins no-revert
    ///         and nothing else.
    function test_releaseRemainsIdempotent() public {
        _settleShortWithAssetOnClone(20_000e6);

        vm.prank(liquidator);
        strategy.releaseUnconvertible();
        vm.prank(keeper);
        uint256 secondRelease = strategy.releaseUnconvertible();
        assertEq(secondRelease, 0, "second release found something left to export");

        vm.prank(keeper);
        strategy.sweep();

        assertEq(_debtShares(), 0, "debt survived");
        assertEq(_collateral(), 0, "collateral survived");
    }

    // ── the partial outcome must stay visible ──

    /// @notice A release that repays only PART of the debt must say so, on the
    ///         same terms `sweep()` does. Without the event a partial recovery
    ///         is indistinguishable off-chain from a complete one — and this is
    ///         the path an attacker calls, so the partial outcome is precisely
    ///         the one monitoring needs.
    ///
    ///         The trickle here is deliberately far below what is owed, so
    ///         `_repayAndWithdraw` takes the deliverable-maximum branch and
    ///         leaves both legs outstanding.
    function test_partialReleaseEmitsSettlementIncomplete() public {
        _settleShortWithAssetOnClone(1e6); // nowhere near the debt

        vm.recordLogs();
        vm.prank(liquidator);
        strategy.releaseUnconvertible();

        (bool seen, uint256 debtRemaining, uint256 collateralRemaining) = _lastSettlementIncomplete();
        assertTrue(seen, "partial release reported as a complete recovery");
        assertGt(debtRemaining, 0, "debt cleared -- this case is not the partial one");
        assertGt(collateralRemaining, 0, "collateral freed -- this case is not the partial one");
        // Non-vacuity: the event has to report the strand that actually exists,
        // not a stale or zeroed pair.
        assertGt(_debtShares(), 0, "precondition drifted: nothing was left outstanding");
    }

    /// @notice The mirror. A release that clears everything must NOT emit — an
    ///         event that fires unconditionally carries no information.
    function test_completeReleaseDoesNotEmitSettlementIncomplete() public {
        _execute();
        _accrueFees(1_000e6, 0);
        _settle();
        assertEq(_debtShares(), 0, "precondition: this case has no debt");
        assertEq(_collateral(), 0, "precondition: this case has no collateral left");

        nvda.mint(address(strategy), 100e18);
        adapter.setRate(address(nvda), address(usdg), 0);

        vm.recordLogs();
        vm.prank(keeper);
        strategy.releaseUnconvertible();

        (bool seen,,) = _lastSettlementIncomplete();
        assertFalse(seen, "clean release reported as incomplete");
    }

    /// @dev Scans recorded logs for `SettlementIncomplete` and decodes it.
    ///      Local rather than shared: the fixture's own helper returns a bare
    ///      boolean, and the values are what makes the assertion above
    ///      non-vacuous.
    function _lastSettlementIncomplete()
        internal
        returns (bool seen, uint256 debtRemaining, uint256 collateralRemaining)
    {
        bytes32 sig = keccak256("SettlementIncomplete(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) {
                (debtRemaining, collateralRemaining) = abi.decode(logs[i].data, (uint256, uint256));
                seen = true;
            }
        }
    }
}
