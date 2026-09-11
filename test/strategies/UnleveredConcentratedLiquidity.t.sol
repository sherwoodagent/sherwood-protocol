// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CLFixture} from "./ConcentratedLiquidityStrategy.t.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {MarketParams} from "../../src/vendor/morpho/IMorpho.sol";

/// @notice Unlevered mode: `morpho == address(0)` funds the mint from `lpAmount`
///         and never reaches the Morpho surface, where a typed call would revert
///         undecodably.
contract UnleveredConcentratedLiquidityTest is CLFixture {
    uint256 constant LP_AMOUNT = 40_000e6;

    ConcentratedLiquidityStrategy unlevered;

    function setUp() public override {
        super.setUp();
        unlevered = _newStrategy(_unleveredParams());
        status.set(1, 1, address(unlevered));
        vm.prank(address(vaultStub));
        usdg.approve(address(unlevered), type(uint256).max);
    }

    /// @dev No Morpho address and an empty market declaration, which is what the
    ///      mode fork requires: a stray reach for the surface is a call to zero.
    function _unleveredParams() internal view returns (ConcentratedLiquidityStrategy.InitParams memory p) {
        p = _defaultParams();
        p.morpho = address(0);
        p.marketParams = MarketParams({
            loanToken: address(0), collateralToken: address(0), oracle: address(0), irm: address(0), lltv: 0
        });
        p.collateralAmount = 0;
        p.borrowAmount = 0;
        p.lpAmount = LP_AMOUNT;
    }

    function _executeUnlevered() internal {
        vm.prank(address(vaultStub));
        unlevered.execute();
    }

    function _settleUnlevered() internal {
        vm.prank(address(vaultStub));
        unlevered.settle();
    }

    // ── Mode matrix ──

    function test_unlevered_initSetsTheModeFromMorphoAlone() public view {
        assertFalse(unlevered.levered(), "unlevered clone reports levered");
        assertTrue(strategy.levered(), "levered clone reports unlevered");
        assertEq(unlevered.lpAmount(), LP_AMOUNT);
        assertEq(unlevered.borrowAmount(), 0);
    }

    function test_unlevered_initRejectsAMixedConfig() public {
        // lpAmount alongside a borrow.
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.lpAmount = LP_AMOUNT;
        _expectInitRevert(ConcentratedLiquidityStrategy.MixedModeConfig.selector, p);

        // A Morpho surface named by a config that will never touch it.
        p = _unleveredParams();
        p.morpho = address(morpho);
        _expectInitRevert(ConcentratedLiquidityStrategy.MixedModeConfig.selector, p);

        // A market declaration named by a config that will never touch it.
        p = _unleveredParams();
        p.marketParams = mp;
        _expectInitRevert(ConcentratedLiquidityStrategy.MixedModeConfig.selector, p);

        // Neither mode funded at all.
        p = _unleveredParams();
        p.lpAmount = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidAmount.selector, p);
    }

    /// @dev The half-levered guard this mode fork replaced still answers.
    function test_unlevered_initRejectsAHalfLeveredConfig() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.borrowAmount = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidAmount.selector, p);
    }

    // ── Lifecycle ──

    function test_unlevered_executeMintsFromLpAmountAndTouchesNoMorpho() public {
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));

        _executeUnlevered();

        assertEq(uint256(unlevered.state()), uint256(BaseStrategy.State.Executed));
        assertGt(unlevered.tokenId(), 0, "no position minted");
        assertEq(vaultBefore - usdg.balanceOf(address(vaultStub)), LP_AMOUNT, "pulled something other than lpAmount");
        assertEq(morpho.position(marketId, address(unlevered)).collateral, 0, "posted collateral");
        assertEq(morpho.position(marketId, address(unlevered)).borrowShares, 0, "borrowed");
    }

    function test_unlevered_settleClosesSwapsAndPushesEverythingHome() public {
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        _executeUnlevered();
        _settleUnlevered();

        assertEq(uint256(unlevered.state()), uint256(BaseStrategy.State.Settled));
        assertEq(unlevered.tokenId(), 0, "position not burned");
        assertEq(nvda.balanceOf(address(unlevered)), 0, "volatile leg left on the clone");
        assertEq(usdg.balanceOf(address(unlevered)), 0, "asset left on the clone");
        assertApproxEqRel(usdg.balanceOf(address(vaultStub)), vaultBefore, 0.02e18, "funds did not come home");
    }

    /// @dev A permissionless rerange runs on the same path in both modes, so the
    ///      unlevered clone must survive one without reaching the Morpho surface.
    function test_unlevered_rerangeReplacesThePositionTouchingNoMorpho() public {
        _executeUnlevered();
        uint256 first = unlevered.tokenId();

        pool.setTicks(850, 850);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(keeper);
        unlevered.rerange();

        assertTrue(unlevered.tokenId() != first, "position not replaced");
        assertEq(morpho.position(marketId, address(unlevered)).collateral, 0, "rerange reached Morpho");
    }
}
