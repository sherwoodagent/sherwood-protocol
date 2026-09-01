// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {MarketParams} from "../../src/vendor/morpho/IMorpho.sol";

// Reuses the levered fixture wholesale: the same pool, adapter, registry and
// vault stub serve both modes, which is itself part of the claim under test —
// unlevered is a configuration of the SAME template, not a sibling contract.
import "./ConcentratedLiquidityStrategy.t.sol";

/// @notice Unlevered-mode coverage for `ConcentratedLiquidityStrategy`.
///
/// THE STRONGEST "NEVER CALLS MORPHO" PIN AVAILABLE: the unlevered clone is
/// initialized with `morpho == address(0)` and an all-zero market declaration,
/// so its config carries NO route to the fixture's MockMorpho at all. Any code
/// path that still reaches for the Morpho surface performs a typed call to
/// `address(0)` and reverts undecodably — a stray call cannot pass by luck,
/// because there is nothing wired that could answer it.
contract UnleveredConcentratedLiquidityTest is CLFixture {
    uint256 constant LP_AMOUNT = 50_000e6;

    ConcentratedLiquidityStrategy unlev;

    /// @dev The levered `_defaultParams()` with the whole Morpho surface
    ///      removed and `lpAmount` set — the minimal delta between modes, so a
    ///      test failure points at the mode fork rather than at fixture drift.
    function _unleveredParams() internal view returns (ConcentratedLiquidityStrategy.InitParams memory p) {
        p = _defaultParams();
        p.morpho = address(0);
        p.marketParams = MarketParams({
            loanToken: address(0),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });
        p.collateralAmount = 0;
        p.borrowAmount = 0;
        p.lpAmount = LP_AMOUNT;
    }

    function setUp() public override {
        super.setUp();
        unlev = _newStrategy(_unleveredParams());
        status.set(1, 1, address(unlev));
        vm.prank(address(vaultStub));
        usdg.approve(address(unlev), type(uint256).max);
    }

    function _executeUnlev() internal {
        vm.prank(address(vaultStub));
        unlev.execute();
    }

    function _settleUnlev() internal {
        vm.prank(address(vaultStub));
        unlev.settle();
    }

    // ── The mode matrix: every mixed config fails at init ──

    function test_init_mixedBorrowWithoutCollateralReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.collateralAmount = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidAmount.selector, p);
    }

    function test_init_mixedCollateralWithoutBorrowReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.borrowAmount = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidAmount.selector, p);
    }

    function test_init_lpAmountAlongsideBorrowReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.lpAmount = LP_AMOUNT;
        _expectInitRevert(ConcentratedLiquidityStrategy.MixedModeConfig.selector, p);
    }

    function test_init_unleveredWithZeroLpAmountReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _unleveredParams();
        p.lpAmount = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidAmount.selector, p);
    }

    function test_init_unleveredWithMorphoAddressReverts() public {
        // A Morpho named in a config that will never touch it invites review
        // of the wrong risk surface — rejected, not ignored.
        ConcentratedLiquidityStrategy.InitParams memory p = _unleveredParams();
        p.morpho = address(morpho);
        _expectInitRevert(ConcentratedLiquidityStrategy.MixedModeConfig.selector, p);
    }

    function test_init_unleveredWithMarketDeclarationReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _unleveredParams();
        p.marketParams.lltv = 0.915e18;
        _expectInitRevert(ConcentratedLiquidityStrategy.MixedModeConfig.selector, p);
    }

    function test_init_leveredWithZeroMorphoRevertsAsBefore() public {
        // The original ZeroAddress guard survives inside the levered arm —
        // same selector as before this change, pinned so the mode fork cannot
        // have re-labeled it.
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.morpho = address(0);
        _expectInitRevert(BaseStrategy.ZeroAddress.selector, p);
    }

    function test_init_unleveredSucceedsAndReadsUnlevered() public view {
        assertEq(unlev.levered(), false, "mode misread");
        assertEq(unlev.lpAmount(), LP_AMOUNT);
        assertEq(address(unlev.morpho()), address(0));
    }

    // ── Execute: pull lpAmount, mint, touch nothing else ──

    function test_execute_pullsExactlyLpAmountAndMints() public {
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        _executeUnlev();
        assertEq(uint256(unlev.state()), uint256(BaseStrategy.State.Executed));
        assertGt(unlev.tokenId(), 0, "no position minted");
        assertEq(vaultBefore - usdg.balanceOf(address(vaultStub)), LP_AMOUNT, "pulled != lpAmount");
        // The fixture's MockMorpho is live in this test process. The unlevered
        // clone must have left it untouched — a levered execute posts
        // collateral here, so a nonzero read means the mode fork leaked.
        assertEq(morpho.position(marketId, address(unlev)).collateral, 0, "touched Morpho");
        assertEq(morpho.position(marketId, address(unlev)).borrowShares, 0, "borrowed");
    }

    function test_execute_emitsZeroBorrowAndCollateral() public {
        // The event keeps its levered shape with the Morpho fields at zero —
        // downstream indexers read one schema for both modes.
        vm.expectEmit(true, false, false, false);
        emit ConcentratedLiquidityStrategy.PositionOpened(address(pool), 0, 0, 0, 0, 0, 0);
        _executeUnlev();
    }

    function test_execute_twapGateStillBinds() public {
        // The venue guards are mode-independent — same fixture idiom as the
        // levered `test_execute_spotOutsideTwapBoundReverts`.
        pool.setTicks(150, 0);
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.SpotOutsideTwapBound.selector);
        unlev.execute();
    }

    // ── Settle: unwind, convert, deliver — no repay stage ──

    function test_settle_deliversWithoutMorpho() public {
        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        _executeUnlev();
        _settleUnlev();
        assertEq(uint256(unlev.state()), uint256(BaseStrategy.State.Settled));
        assertEq(unlev.tokenId(), 0, "position not unwound");
        // Round trip through the mock venue is lossless at the fair price, so
        // settlement must return the full funding.
        assertGe(usdg.balanceOf(address(vaultStub)), vaultBefore, "funding not returned");
        assertEq(usdg.balanceOf(address(unlev)), 0, "proceeds stranded on clone");
    }

    // ── The residue views the vault's deposit gate probes ──
    //
    // These are the two grenades the mode fork defuses: unguarded, both views
    // would fail against address(0) — and the vault treats an unreadable probe
    // as "residue outstanding", holding the deposit gate shut with no error
    // surfaced anywhere. The pin is that they ANSWER, and answer false.

    function test_residueViews_answerFalseOnCleanSettledClone() public {
        _executeUnlev();
        _settleUnlev();
        assertEq(unlev.hasUndeliveredValue(), false, "phantom undelivered value");
        assertEq(unlev.hasUnvaluedResidue(), false, "phantom unvalued residue");
        assertEq(unlev.undeliveredValue(), 0);
    }

    function test_residueViews_seeAStrandedAssetBalance() public {
        _executeUnlev();
        _settleUnlev();
        // Donate a residue; the views must report it (and only through the
        // asset arm — no Morpho arm exists to consult).
        usdg.mint(address(unlev), 10_000e6);
        assertEq(unlev.hasUndeliveredValue(), true);
        assertEq(unlev.undeliveredValue(), 10_000e6);
    }

    function test_sweep_recoversResidueWithoutMorpho() public {
        _executeUnlev();
        _settleUnlev();
        usdg.mint(address(unlev), 10_000e6);
        uint256 before = usdg.balanceOf(address(vaultStub));
        vm.prank(address(vaultStub));
        uint256 swept = unlev.sweep();
        assertEq(swept, 10_000e6);
        assertEq(usdg.balanceOf(address(vaultStub)) - before, 10_000e6);
    }

    function test_releaseUnconvertible_ignoresZeroCollateralToken() public {
        // The last unguarded IERC20(address(0)) site. Strand some otherToken
        // so the hatch has real work; it must do that work and skip the
        // nonexistent collateral leg rather than reverting on it.
        _executeUnlev();
        _settleUnlev();
        nvda.mint(address(unlev), 1e18);
        adapter.setRate(address(nvda), address(usdg), 0); // conversion dead → hatch path
        vm.prank(address(vaultStub));
        unlev.releaseUnconvertible();
        assertEq(nvda.balanceOf(address(unlev)), 0, "residue not handed off");
    }

    // ── Levered regression: the original mode is byte-identical ──

    function test_levered_positionOpenedFieldsUnchanged() public {
        // Pins the event VALUES for the levered clone, not just the shape —
        // this diff must not have moved what a levered execute reports.
        // This suite's setUp re-points the fixture's single active-proposal
        // slot at the unlevered clone; point it back for the levered run.
        status.set(1, 1, address(strategy));
        _execute();
        assertEq(strategy.levered(), true);
        assertGt(morpho.position(marketId, address(strategy)).collateral, 0);
        assertGt(morpho.position(marketId, address(strategy)).borrowShares, 0);
    }
}
