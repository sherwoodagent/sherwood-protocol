// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SettleFixture} from "../strategies/ConcentratedLiquidityStrategySettle.t.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {Market} from "../../src/vendor/morpho/IMorpho.sol";

/**
 * @title Finding #8 — a dust repay shortfall must not strand ALL the collateral
 * @notice `_repayAndWithdraw` gated the collateral withdrawal on
 *         `borrowShares == 0`, a condition strictly stronger than the one
 *         Morpho itself enforces (`LTV <= LLTV`). So a position that came back
 *         a few units short of its accrued interest — an ordinary market
 *         outcome, no attacker — kept its ENTIRE posted collateral locked at
 *         Morpho behind a trivial residual debt.
 *
 *         It is unrecoverable afterwards: the partial repay leaves the clone
 *         with a zero asset balance, so `sweep()`'s `held != 0` branch never
 *         runs, no repay is attempted, and the withdrawal stays gated forever.
 *         Only a third party volunteering to repay someone else's dust unblocks
 *         it. Downstream, the near-total loss trips `settleProposal`'s drawdown
 *         floor, pinning the proposal in `Executed` with every LP exit frozen.
 *
 * @dev    The fixture's oracle is a codeless `makeAddr`, so the price is mocked
 *         here. 1:1 (1e36) matches the fixture's fee-free 1:1 collateral
 *         wrapper, so `collateral` and `debt` are directly comparable in
 *         asset units.
 */
contract CLStrategyPartialCollateralRecoveryTest is SettleFixture {
    uint256 constant ORACLE_PRICE_1TO1 = 1e36;

    /// @dev The fixture exposes debt in SHARES; the health rule is in assets.
    function _debtAssets() internal view returns (uint256) {
        uint128 shares = morpho.position(marketId, address(strategy)).borrowShares;
        if (shares == 0) return 0;
        Market memory m = morpho.market(marketId);
        return (uint256(shares) * uint256(m.totalBorrowAssets)) / uint256(m.totalBorrowShares);
    }

    function _mockOraclePrice() internal {
        address oracle = mp.oracle;
        // `mockCall` needs a callee with code; the fixture's oracle is an EOA.
        vm.etch(oracle, hex"00");
        vm.mockCall(oracle, abi.encodeWithSignature("price()"), abi.encode(ORACLE_PRICE_1TO1));
    }

    /// @notice THE FINDING. 30 days of interest with no fee income leaves the
    ///         unwound position a little short of the debt. Before the fix the
    ///         whole 100,000 of collateral stayed at Morpho; after it, only the
    ///         slice the residual debt actually needs to stay healthy does.
    function test_repayShortfallStrandsOnlyTheCollateralTheDebtRequires() public {
        _mockOraclePrice();
        _execute();
        // No fees: interest accrues, so proceeds cannot cover principal+interest.
        vm.warp(vm.getBlockTimestamp() + 30 days);

        _settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled), "settle did not complete");

        uint256 debt = _debtAssets();
        assertGt(debt, 0, "test did not actually create a shortfall");

        uint256 collateralLeft = _collateral();

        // The health-preserving floor: at a 1:1 price, keeping the position at
        // or under the lltv needs `debt / lltv` of collateral. Anything the
        // strategy leaves ABOVE that (plus the safety buffer) was strandable
        // value it failed to return.
        uint256 minHealthy = (debt * 1e18) / mp.lltv;
        assertGe(collateralLeft, minHealthy, "withdrew so much the position is unhealthy");

        // The finding itself: the residual must be proportional to the DUST
        // DEBT, not to the whole position. A 2x headroom over the strict
        // minimum comfortably accommodates the buffer while still failing hard
        // against the pre-fix behaviour (which left all of COLLATERAL).
        assertLt(collateralLeft, minHealthy * 2, "collateral stranded far beyond what the debt requires");
        assertLt(collateralLeft, COLLATERAL / 10, "the bulk of the collateral is still stranded");
    }

    /// @notice The guard against over-correcting: the partial withdrawal must
    ///         never leave the position liquidatable. A fix that simply
    ///         withdrew everything would pass the test above's lower bound only
    ///         by accident, so this asserts Morpho's own health rule directly
    ///         on the post-settle position.
    function test_partialWithdrawalLeavesThePositionHealthy() public {
        _mockOraclePrice();
        _execute();
        vm.warp(vm.getBlockTimestamp() + 30 days);

        _settle();

        uint256 debt = _debtAssets();
        if (debt == 0) return; // nothing to keep healthy

        uint256 maxBorrow = ((_collateral() * ORACLE_PRICE_1TO1) / ORACLE_PRICE_1TO1) * mp.lltv / 1e18;
        assertGe(maxBorrow, debt, "position left above its liquidation threshold");
    }

    /// @notice The zero-debt path is untouched: a fully repaid position still
    ///         returns 100% of its collateral in one go.
    function test_fullRepayStillWithdrawsAllCollateral() public {
        _mockOraclePrice();
        _execute();
        _accrueFees(1_000e6, 0);

        _settle();

        assertEq(_debtAssets(), 0, "debt should have cleared");
        assertEq(_collateral(), 0, "full repay must still free all collateral");
    }
}
