// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

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
        // The real `TierRegistry` answers false for an unregistered address; the
        // permissive mock answers TRUE for `address(0)` unless told otherwise,
        // which would let an ungated Morpho binding pass here and brick init,
        // execute and rerange on a real deployment.
        tierRegistry.setDenied(address(0), true);
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

        // Levered amounts under a config that names no Morpho surface — the
        // fields would otherwise be stored and silently never used.
        p = _unleveredParams();
        p.collateralAmount = COLLATERAL;
        p.borrowAmount = BORROW;
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

    /// @dev The venue guards still bind in unlevered mode: only the Morpho and
    ///      collateral-token bindings are mode-gated, and `address(0)` is denied
    ///      here, so an ungated binding would fail this init rather than pass it.
    function test_unlevered_initStillBindsTheVenueCounterparties() public {
        tierRegistry.setDenied(address(posm), true);

        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_unleveredParams());
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, address(posm), address(tierRegistry)
            )
        );
        s.initialize(v, proposer, data);
    }

    // ── Lifecycle ──

    function test_unlevered_executeMintsFromLpAmountAndTouchesNoMorpho() public {
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        uint256 borrowedBefore = morpho.market(marketId).totalBorrowAssets;

        _executeUnlevered();

        assertEq(uint256(unlevered.state()), uint256(BaseStrategy.State.Executed));
        assertGt(unlevered.tokenId(), 0, "no position minted");
        assertEq(vaultBefore - usdg.balanceOf(address(vaultStub)), LP_AMOUNT, "pulled something other than lpAmount");
        // The pin is that no Morpho surface exists to reach, not a zero read on
        // the fixture's own market — the clone can never appear in that one.
        assertEq(address(unlevered.morpho()), address(0), "a Morpho surface was bound");
        assertEq(morpho.market(marketId).totalBorrowAssets, borrowedBefore, "the market's borrow side moved");
    }

    /// @dev A levered execute still reports the borrow and the posted collateral
    ///      in the same slots — the unlevered `collateral` reuse must not move them.
    function test_levered_positionOpenedStillReportsBorrowAndCollateral() public {
        // `setUp` points the proposal at the unlevered clone; the levered one is
        // the subject here.
        status.set(1, 1, address(strategy));
        vm.recordLogs();
        _execute();

        (uint256 borrowed, uint256 collateral) = _positionOpenedCapital();
        assertEq(borrowed, BORROW, "borrowed slot");
        assertEq(collateral, morpho.position(marketId, address(strategy)).collateral, "collateral slot");
    }

    /// @dev Without this the unlevered family's deployed notional appears in no
    ///      event on any path and is unreconstructable from logs.
    function test_unlevered_positionOpenedReportsLpAmountAsCapital() public {
        vm.recordLogs();
        _executeUnlevered();

        (uint256 borrowed, uint256 collateral) = _positionOpenedCapital();
        assertEq(borrowed, 0, "unlevered position reports a borrow");
        assertEq(collateral, LP_AMOUNT, "deployed notional is not in the log");
    }

    /// @dev Decodes the non-indexed tail of the one `PositionOpened` in the
    ///      recorded logs; asserting topic1 alone would pass on any amounts.
    function _positionOpenedCapital() internal returns (uint256 borrowed, uint256 collateral) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("PositionOpened(address,uint256,int24,int24,uint128,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (,,, borrowed, collateral) = abi.decode(logs[i].data, (int24, int24, uint128, uint256, uint256));
            return (borrowed, collateral);
        }
        revert("no PositionOpened emitted");
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
        assertEq(address(unlevered.morpho()), address(0), "a Morpho surface was bound");
    }
}
