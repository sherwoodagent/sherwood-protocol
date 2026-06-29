// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "./IStrategy.sol";

/// @title ILeveragedAerodromeCLStrategy
/// @notice External surface for the leveraged Aerodrome CL strategy.
///         The strategy borrows cbBTC + WETH against USDC collateral on Moonwell
///         and deploys the borrowed tokens into an Aerodrome Slipstream CL position
///         staked in the AERO gauge.
///
///         Functions marked "Task 3.x" are planned but not yet implemented — they
///         will be added in subsequent tasks and will revert `NotImplemented` until then.
interface ILeveragedAerodromeCLStrategy is IStrategy {
    // ─────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────

    /// @notice Stub functions are not yet implemented (reverts until the task ships it).
    error NotImplemented();
    /// @notice `targetLtvBps > maxLtvBps`.
    error TargetLtvExceedsMax();
    /// @notice `minHealthBps < 10500`.
    error MinHealthTooLow();
    /// @notice Fee recipient is zero-address while a fee bps is non-zero.
    error FeeRecipientRequired();
    /// @notice `maxLtvBps` ≥ Moonwell USDC collateral factor.
    error MaxLtvExceedsCF();
    /// @notice `Comptroller.markets(mUsdc)` call failed or returned short data.
    error ComptrollerCallFailed();
    /// @notice Post-operation LTV exceeds `maxLtvBps`, or Moonwell reports a shortfall.
    /// @param ltvBps    Actual LTV in bps at the time of the check.
    /// @param limitBps  The `maxLtvBps` cap that was exceeded.
    error UnhealthyPosition(uint256 ltvBps, uint256 limitBps);
    /// @notice `deleverage()` called while the position is at/above `minHealthBps` (no-op when safe).
    error HealthyNoDeleverage();
    /// @notice Deposit / redeem outside the governance window.
    error NotInExecutedState();
    /// @notice Caller is not an authorized depositor.
    error Unauthorized();

    // ─────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────

    /// @notice Emitted when the levered CL position is first opened.
    event PositionOpened(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @notice Emitted on position settlement.
    event PositionClosed(uint256 indexed tokenId, uint256 proceedsUsdc);

    /// @notice Emitted when a depositor enters the strategy.
    event StrategyDeposit(address indexed depositor, uint256 assetsUsdc, uint256 sharesOut);

    /// @notice Emitted when a depositor redeems from the strategy.
    event StrategyRedeem(address indexed redeemer, uint256 sharesIn, uint256 assetsUsdc);

    /// @notice Emitted when management or performance fees are crystallized.
    event FeesCrystallized(uint256 managementFeeShares, uint256 performanceFeeShares);

    // ─────────────────────────────────────────────────────────────
    // Task 3.1 — Skeleton: NAV + positions
    // ─────────────────────────────────────────────────────────────

    /// @notice Oracle NAV of the whole levered book, in USDC (6dp).
    ///         Pre-deploy (no active position): face value of idle USDC in vault + strategy.
    ///         Post-deploy: oracle-priced via `LeveragedAeroValuation.netEquityUsdc` — fail-closed.
    function nav() external view returns (uint256);

    // ─────────────────────────────────────────────────────────────
    // Task 3.5 — Deposit / Redeem (oracle-priced deposit; proportional redeem)
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit `assetsUsdc` of USDC into the strategy (oracle-priced share mint).
    ///         Caller must have approved this contract for at least `assetsUsdc`.
    ///         Only callable while the parent proposal is Executed.
    ///         Crystallizes fees on the pre-deposit NAV before minting shares.
    function deposit(uint256 assetsUsdc, address receiver) external returns (uint256 sharesOut);

    /// @notice Redeem `shares` from the strategy (proportional unwind; oracle-free).
    ///         Crystallizes fees before unwinding.
    function redeem(uint256 shares, address receiver) external returns (uint256 assetsOut);

    // ─────────────────────────────────────────────────────────────
    // Task 3.6 — Management: deployIdle, compound, rerange, adjustLeverage
    // ─────────────────────────────────────────────────────────────

    /// @notice Deploy idle USDC sitting in the strategy into the levered position.
    ///         Must end within LTV / health bounds. Proposer-only.
    function deployIdle() external;

    /// @notice Collect AERO rewards, swap to USDC, re-deploy into the position. Proposer-only.
    function compound() external;

    /// @notice Remove the existing CL position, mint a new one at current tick + new range. Proposer-only.
    /// @param newTickLower New lower tick (tickSpacing-aligned).
    /// @param newTickUpper New upper tick (tickSpacing-aligned).
    function rerange(int24 newTickLower, int24 newTickUpper) external;

    /// @notice Borrow / repay to retarget the LTV to `targetLtvBps_`. Proposer-only.
    ///         Collateral is untouched; lever-UP adds the borrowed delta to the CL position
    ///         (`minLiq` slippage), lever-DOWN unwinds + repays (residual rebalancing bounded by
    ///         `minOut`). Reverts `TargetLtvExceedsMax` if `targetLtvBps_ > maxLtvBps`.
    function adjustLeverage(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut) external;

    // ─────────────────────────────────────────────────────────────
    // Task 3.7 — Health: deleverage (permissionless)
    // ─────────────────────────────────────────────────────────────

    /// @notice Permissionless: partially unwind the position to restore health ≥ `minHealthBps`.
    ///         Reverts `HealthyNoDeleverage` unless current health < `minHealthBps`. `minOut` bounds
    ///         any residual rebalancing swap.
    function deleverage(uint256 minOut) external;

    // ─────────────────────────────────────────────────────────────
    // Task 3.8 — Rescue
    // ─────────────────────────────────────────────────────────────

    /// @notice Sweep a stuck token back to the vault. Owner-only; blocked for
    ///         collateral / borrow tokens while the position is open.
    function rescueToVault(address token) external;

    // ─────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────

    function usdc() external view returns (address);
    function mUsdc() external view returns (address);
    function mCbBTC() external view returns (address);
    function mWeth() external view returns (address);
    function cbBTC() external view returns (address);
    function weth() external view returns (address);
    function pool() external view returns (address);
    function gauge() external view returns (address);
    function npm() external view returns (address);
    function swapRouter() external view returns (address);
    function comptroller() external view returns (address);
    function tickSpacing() external view returns (int24);

    function targetLtvBps() external view returns (uint16);
    function maxLtvBps() external view returns (uint16);
    function minHealthBps() external view returns (uint16);
    function maxSlippageBps() external view returns (uint16);
    function usdcCollateralFactorBps() external view returns (uint16);

    function managementFeeBps() external view returns (uint16);
    function performanceFeeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);

    function tokenId() external view returns (uint256);
    function posTickLower() external view returns (int24);
    function posTickUpper() external view returns (int24);
}
