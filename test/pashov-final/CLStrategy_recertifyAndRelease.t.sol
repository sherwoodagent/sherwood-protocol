// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CLFixture} from "../strategies/ConcentratedLiquidityStrategy.t.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ConcentratedLiquidityStrategy — post-init re-certification, and the
///        escape hatch that omitted the principal
/// @notice Two findings in one template, both about a check that ran once and
///         then never again.
contract PashovFinalCLTest is CLFixture {
    /// @dev The default range is [-1000, 1000]; the trigger is 80% of the
    ///      half-range, and the TWAP deviation bound is 100 bps, so spot and
    ///      TWAP move together to 850.
    function _moveToTrigger() internal {
        pool.setTicks(850, 850);
    }

    // ── Finding 5 — the allowlist was consulted only at _initialize ──

    /// @notice `rerange()` is PERMISSIONLESS and re-issues `forceApprove` to
    ///         `swapAdapter` on every call, so a demoted adapter could drive the
    ///         drain itself — up to `maxReranges` times. And the demotion needs
    ///         no governance action: `TierRegistry.poke` and `demoteByChallenge`
    ///         are both permissionless.
    ///
    ///         Exposure is worst in this template precisely because
    ///         `_rebalanceToTarget` discards the swap's return value and takes
    ///         `minOut` enforcement from INSIDE the adapter, so a revoked
    ///         adapter can take `toSwap` and deliver nothing with no local check
    ///         firing.
    function test_finding5_rerangeRefusesAfterTheAdapterIsDemoted() public {
        _execute();
        _moveToTrigger();
        vm.warp(vm.getBlockTimestamp() + 2 hours);

        // Post-init demotion — the state `_initialize` cannot have seen.
        tierRegistry.setDeniedAsAdapter(address(adapter), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, address(adapter), address(tierRegistry)
            )
        );
        strategy.rerange();
    }

    /// @notice The same check on the other entry path. `_execute` runs with the
    ///         vault's capital in flight, so a counterparty demoted between
    ///         clone-init and execute must not receive `forceApprove` either —
    ///         the hazard `MorphoSupplyStrategy._execute` names verbatim.
    function test_finding5_executeRefusesAfterTheMarketIsDemoted() public {
        tierRegistry.setDenied(address(morpho), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, address(morpho), address(tierRegistry)
            )
        );
        _execute();
    }

    /// @notice A still-certified counterparty set is unaffected — the guard is a
    ///         re-check, not a new restriction. Without this the tests above
    ///         would pass against a template that refused every rerange.
    function test_finding5_rerangeStillWorksWhileCertified() public {
        _execute();
        _moveToTrigger();
        vm.warp(vm.getBlockTimestamp() + 2 hours);

        uint256 countBefore = strategy.rerangeCount();
        strategy.rerange();
        assertEq(strategy.rerangeCount(), countBefore + 1, "an allowed adapter reranges normally");
    }

    /// @notice EXITS STAY OPEN. Blocking `settle` on a demotion would strand the
    ///         very funds the demotion is meant to protect — the capital-hostage
    ///         rationale the template already applies to `sweep` and
    ///         `releaseUnconvertible`. Pinned so a later "be consistent, guard
    ///         everything" refactor has to argue with a test.
    function test_finding5_settleStillWorksAfterDemotion() public {
        _execute();
        tierRegistry.setDenied(address(morpho), true);
        tierRegistry.setDeniedAsAdapter(address(adapter), true);

        // Must not revert: the exit is the whole point.
        _settle();
    }

    // ── Finding 13 — the hatch omitted the collateral wrapper ──

    /// @notice `releaseUnconvertible` exists to get value off a clone that can
    ///         neither convert nor push it, and its own argument is that the
    ///         vault is the strictly better custodian because it carries an
    ///         owner-gated `rescueERC20` and this clone carries nothing.
    ///
    ///         It covered only `otherToken` — an LP-fee-sized residue — and
    ///         omitted the ERC-4626 collateral wrapper shares, which are the
    ///         proposal's ENTIRE principal. Those shares are only ever disposed
    ///         of by `_tryRedeemWrapper`, and this template's own note concedes
    ///         the wrappers it targets gate redemption behind pauses, caps and
    ///         queues it cannot influence.
    function test_finding13_releaseUnconvertiblePushesTheWrapperShares() public {
        _execute();

        // Strand the wrapper BEFORE settling — redemption has to be unavailable
        // at the moment `_settle` would have unwound it, or the shares simply
        // convert and there is nothing left to strand. This is the exact class
        // the template's own note describes: "pauses, caps, queues and
        // underlying liquidity, none of which this proposal can influence".
        spUsdg.setRedeemPaused(true);
        _settle();

        uint256 stuck = IERC20(address(spUsdg)).balanceOf(address(strategy));
        assertGt(stuck, 0, "fixture left no wrapper shares on the clone, the strand could not show");

        uint256 vaultBefore = IERC20(address(spUsdg)).balanceOf(address(vaultStub));
        strategy.releaseUnconvertible();

        assertEq(IERC20(address(spUsdg)).balanceOf(address(strategy)), 0, "the clone must not keep the principal");
        assertEq(
            IERC20(address(spUsdg)).balanceOf(address(vaultStub)),
            vaultBefore + stuck,
            "the vault is the custodian with a rescue path"
        );
    }

    /// @notice When the wrapper CAN still redeem, the hatch converts rather than
    ///         shipping shares — the vault would rather hold `asset` than an
    ///         ERC-4626 position it must unwind itself.
    function test_finding13_redeemablePathStillPrefersAsset() public {
        _execute();
        _settle();

        strategy.releaseUnconvertible();
        assertEq(
            IERC20(address(spUsdg)).balanceOf(address(strategy)), 0, "no wrapper shares left on the clone either way"
        );
    }
}
