// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "./IStrategy.sol";

/**
 * @title IHyperliquidPerpStrategy
 * @notice Interface for the Hyperliquid perpetual trading strategy.
 *         Uses HyperEVM precompiles for on-chain perp trading — no keeper.
 */
interface IHyperliquidPerpStrategy is IStrategy {
    // ── Events ──
    event PositionOpened(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, uint32 leverage);
    event PositionClosed(uint32 asset, uint64 limitPx, uint64 sz);
    event StopLossUpdated(uint64 triggerPx);
    event FundsParked(uint256 amount);
    event SettlePhase1Complete();
    event SettlePhase2Complete(uint256 amountReturned);
    event LeverageUpdated(uint32 asset, uint32 leverage);

    // ── Views ──

    /// @notice The asset (USDC) used for trading
    function asset() external view returns (address);

    /// @notice The amount deposited to perp margin
    function depositAmount() external view returns (uint256);

    /// @notice The minimum amount that must be returned on settlement
    function minReturnAmount() external view returns (uint256);

    /// @notice The perp asset index on Hyperliquid (e.g. 0 for BTC)
    function perpAssetIndex() external view returns (uint32);

    /// @notice The leverage multiplier
    function leverage() external view returns (uint32);

    /// @notice Whether a perp position is currently open
    function positionOpen() external view returns (bool);

    /// @notice Current settlement phase (NONE, CLOSING, SWEEPING)
    function settlePhase() external view returns (uint8);

    /// @notice Phase 2 of settlement: push USDC to vault after async transfer completes
    function sweepToVault() external;
}
