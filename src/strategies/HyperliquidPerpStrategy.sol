// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L1Write, TimeInForce, NO_CLOID, FinalizeVariant} from "../hyperliquid/L1Write.sol";
import {L1Read, Position, SpotBalance, AccountMarginSummary} from "../hyperliquid/L1Read.sol";
import {HyperliquidBridge} from "../hyperliquid/HyperliquidBridge.sol";
import {ISyndicateGovernor} from "../interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "../interfaces/ISyndicateVault.sol";

/**
 * @title HyperliquidPerpStrategy
 * @notice On-chain perpetual trading strategy using HyperEVM precompiles.
 *
 *   USDC is pulled from the vault, bridged EVM→HC spot via Circle's
 *   CoreDepositWallet (`HyperliquidBridge.bridgeUsdcToSpot`), and moved
 *   onto HC perp margin via `L1Write.sendUsdClassTransfer`. The proposer
 *   then triggers trades (open long, close position, update stop loss)
 *   via updateParams().
 *
 *   Settlement: _settle() force-closes all positions, runs the perp→spot
 *   class transfer (using the precompile-read free margin amount, NOT the
 *   undocumented `uint64.max` sentinel), and pushes the strategy's current
 *   EVM USDC balance back to the vault — the governor's settle batch reads
 *   vault.totalAssets() right after, so the EVM push must happen here.
 *   sweepToVault() recovers any late HC arrivals (post-block bridge credits).
 *
 *   HyperCore registration: `_initialize()` writes `address(this)` to slot 0
 *   (`_hcSelf` from BaseStrategy). The CLI then calls
 *   `finalizeForHyperCore(0, FinalizeVariant.FirstStorageSlot, 0)` as a
 *   separate tx so HC reads slot 0 post-block and confirms the registration.
 *
 *   Position state is NOT tracked on-chain — L1Read.position2() is the source
 *   of truth. The proposer must check actual HyperCore state before acting.
 *
 *   NO off-chain keeper — all actions go through HyperCore precompiles.
 */
contract HyperliquidPerpStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Events ──
    event PositionOpened(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, uint32 leverage);
    event PositionClosed(uint32 asset, uint64 limitPx, uint64 sz);
    event StopLossUpdated(uint64 triggerPx);
    event FundsParked(uint256 amount);
    event Settled();
    event FundsSwept(uint256 amount);
    event HyperCoreFinalized(uint64 token, FinalizeVariant variant, uint64 createNonce);
    event ReturnsInitiated();

    // ── Errors ──
    error InvalidAmount();
    error InvalidAction();
    error DepositAmountTooLarge();
    error NotSweepable();
    error MaxTradesExceeded();
    error PositionTooLarge(uint256 actual, uint256 max);
    error AlreadyFinalized();
    error NotAuthorized();

    // ── Action types ──
    // Legacy single-asset actions (use perpAssetIndex from storage):
    uint8 constant ACTION_OPEN_LONG = 1;
    uint8 constant ACTION_CLOSE_POSITION = 2;
    uint8 constant ACTION_UPDATE_STOP_LOSS = 3; // reduce-only sell (for longs)
    uint8 constant ACTION_OPEN_SHORT = 4;
    uint8 constant ACTION_UPDATE_STOP_LOSS_SHORT = 5; // reduce-only buy (for shorts)
    // Multi-asset actions (assetIndex in calldata — one clone trades any perp):
    uint8 constant ACTION_OPEN_LONG_MULTI = 6; // (action, assetIndex, limitPx, sz, stopLossPx, stopLossSz)
    uint8 constant ACTION_OPEN_SHORT_MULTI = 7; // same encoding
    uint8 constant ACTION_CLOSE_MULTI = 8; // (action, assetIndex, isBuy, limitPx, sz)

    // ── CLOID constant for stop-loss tracking ──
    // Single fixed CLOID — only one GTC stop-loss is ever live at a time.
    // Each new stop-loss cancels the current one before placing a replacement.
    // Assumes HyperCore allows CLOID reuse after cancellation.
    uint128 constant STOP_LOSS_CLOID_BASE = 0x53544F504C4F53530000000000000000; // "STOPLOSS" prefix
    uint128 constant STOP_LOSS_CLOID = STOP_LOSS_CLOID_BASE + 1;

    // ── Storage (per-clone) ──
    IERC20 public asset;
    uint256 public depositAmount;
    uint32 public perpAssetIndex;
    /// @notice The intended leverage for HyperCore positions opened by this strategy.
    /// @dev Off-chain keepers MUST set this leverage on HyperCore via the exchange
    ///      API (`updateLeverage`) before the proposal opens. The contract cannot
    ///      enforce this on chain — there is no CoreWriter action for leverage
    ///      (Hyperliquid's spec defines actions 1-15 only). Guardians review by
    ///      inspecting HyperCore state via `L1Read.position2` against this covenant.
    uint32 public leverage;
    bool public hasActiveStopLoss; // Whether a GTC stop-loss is currently live
    bool public settled; // Whether _settle() has been called
    /// @notice True once this contract has been registered with HyperCore so
    ///         bridged-token transfers auto-credit HC spot. Set only by
    ///         `finalizeForHyperCore`, which the CLI auto-calls in a separate
    ///         tx immediately after `initialize()` for grid; for perp, the
    ///         CLI calls it as part of the propose flow.
    bool public hyperCoreFinalized;
    /// @notice True once the HC drain (force-close + perp→spot + spot→EVM
    ///         bridge) has been triggered. Set by `initiateReturn()` (proposer
    ///         pre-settle) or by `_settle()` defensively. Idempotent.
    bool public returnsInitiated;
    /// @notice Block number of the last `recoverHcResiduals()` call. See grid.
    uint256 public lastRecoverBlock;
    /// @notice High-water mark of USDC committed to HC but not yet observed
    ///         on HC by the precompile (in 6-decimal USDC units). See grid
    ///         for full rationale — covers both inbound and outbound cross-
    ///         block transit windows. Reconciled in `_positionValue` via
    ///         `HyperliquidBridge.CORE_ACCOUNT_FEE_TOLERANCE`.
    uint256 public inFlightToHc;
    /// @dev Cumulative USDC pushed back to the vault across all sweepToVault() calls.
    ///      Off-chain accounting only — does not gate withdrawals.
    uint256 public cumulativeSwept;
    uint256 public maxPositionSize; // Max USDC in a single position (on-chain risk cap)
    uint32 public maxTradesPerDay; // Rate limit on trading actions per day
    uint32 public tradesToday; // Counter for today's trades
    uint256 public lastTradeReset; // Timestamp of last daily counter reset
    // Multi-asset tracking: all asset indices that have been traded via
    // ACTION_OPEN_*_MULTI. _settle() iterates this to close positions on
    // ALL assets, not just perpAssetIndex. Bounded by maxTradesPerDay.
    uint32[] public tradedAssets;
    mapping(uint32 => bool) public assetTraded; // dedup guard

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Hyperliquid Perp";
    }

    /// @notice Decode: (address asset, uint256 depositAmount, uint32 perpAssetIndex, uint32 leverage, uint256 maxPositionSize, uint32 maxTradesPerDay)
    /// @dev depositAmount_ == 0 means "use the vault's full asset balance at execute time" (dynamic-all mode).
    function _initialize(bytes calldata data) internal override {
        (
            address asset_,
            uint256 depositAmount_,
            uint32 perpAssetIndex_,
            uint32 leverage_,
            uint256 maxPositionSize_,
            uint32 maxTradesPerDay_
        ) = abi.decode(data, (address, uint256, uint32, uint32, uint256, uint32));

        if (asset_ == address(0)) revert ZeroAddress();
        if (depositAmount_ > type(uint64).max) revert DepositAmountTooLarge();
        if (leverage_ == 0 || leverage_ > 50) revert InvalidAmount();
        if (maxPositionSize_ == 0) revert InvalidAmount();
        if (maxTradesPerDay_ == 0) revert InvalidAmount();

        asset = IERC20(asset_);
        depositAmount = depositAmount_;
        perpAssetIndex = perpAssetIndex_;
        leverage = leverage_;
        maxPositionSize = maxPositionSize_;
        maxTradesPerDay = maxTradesPerDay_;
    }

    /// @notice Pull USDC from vault, transfer to perp margin via precompile
    /// @dev In dynamic-all mode (depositAmount == 0) the vault's current asset
    ///      balance is pulled in full. The uint64.max cap still applies to the
    ///      HyperCore transfer amount.
    function _execute() internal override {
        uint256 amountIn = depositAmount;
        if (amountIn == 0) {
            amountIn = IERC20(asset).balanceOf(vault());
        }
        if (amountIn == 0) revert InvalidAmount();
        if (amountIn > type(uint64).max) revert DepositAmountTooLarge();

        _pullFromVault(address(asset), amountIn);

        // Bridge EVM → HC spot via Circle's CoreDepositWallet. Without this,
        // HC spot stays empty and the class-transfer below is a no-op.
        HyperliquidBridge.bridgeUsdcToSpot(asset, amountIn);

        uint64 ntl = uint64(amountIn);

        // Leverage is set off-chain via the exchange API before the proposal opens.
        // See `leverage` storage NatSpec.
        // Note: Circle's CoreDepositWallet charges a 1 USDC new-account fee on
        // first deposit per HC address, so this class transfer can be dropped
        // by HC if it exceeds the actually-landed spot. Recover via
        // `moveSpotToPerp()` 1+ block later.
        L1Write.sendUsdClassTransfer(ntl, true);

        // Track in-flight bridge (see grid for rationale).
        inFlightToHc += amountIn;

        emit FundsParked(amountIn);
    }

    /**
     * @notice Register this clone with HyperCore so that bridged USDC ERC-20
     *         transfers auto-credit the HC spot account. MUST be called once
     *         after `initialize()` and before the proposal that triggers
     *         `_execute()`.
     *
     *         Standard call for SyndicateFactory CLI clones:
     *           finalizeForHyperCore(0, FinalizeVariant.FirstStorageSlot, 0)
     *         BaseStrategy.initialize() writes `address(this)` to slot 0
     *         (`_hcSelf`). HC reads slot 0 post-block, confirms it equals
     *         the contract address, and completes registration.
     *
     * @param token        HyperCore token index (USDC = 0).
     * @param variant      FinalizeVariant enum (Create / FirstStorageSlot / CustomStorageSlot).
     * @param createNonce  Deployer nonce (Create variant only; pass 0 for FirstStorageSlot).
     */
    function finalizeForHyperCore(uint64 token, FinalizeVariant variant, uint64 createNonce) external onlyProposer {
        if (hyperCoreFinalized) revert AlreadyFinalized();
        L1Write.sendFinalizeEvmContract(token, variant, createNonce);
        hyperCoreFinalized = true;
        emit HyperCoreFinalized(token, variant, createNonce);
    }

    /// @notice Proposer-driven trading actions via precompiles
    /// @dev Decode format depends on action type:
    ///   action=1: (uint8 action, uint64 limitPx, uint64 sz, uint64 stopLossPx, uint64 stopLossSz)
    ///   action=2: (uint8 action, uint64 limitPx, uint64 sz)
    ///   action=3: (uint8 action, uint64 triggerPx, uint64 sz)
    /// @dev Notional check (#255 D-2 / S-H11): HL convention is
    ///      `szDecimals + pxDecimals = 6` for every perp asset, so
    ///      `sz * limitPx / 1e6` always yields notional in USDC-6-decimal units
    ///      regardless of the asset's specific szDecimals. This identity holds
    ///      for ALL HyperCore perps; if HL ever changes the convention, every
    ///      `approxUsd` site below must switch to per-asset divisors.
    function _updateParams(bytes calldata data) internal override {
        if (data.length < 32) revert InvalidAction();
        uint8 action = abi.decode(data[:32], (uint8));

        // Daily trade counter — every recognised action counts as a trade.
        if (action >= ACTION_OPEN_LONG) {
            if (block.timestamp / 1 days != lastTradeReset / 1 days) {
                tradesToday = 0;
                lastTradeReset = block.timestamp;
            }
            tradesToday++;
            if (tradesToday > maxTradesPerDay) revert MaxTradesExceeded();
        }

        if (action == ACTION_OPEN_LONG) {
            (, uint64 limitPx, uint64 sz, uint64 stopLossPx, uint64 stopLossSz) =
                abi.decode(data, (uint8, uint64, uint64, uint64, uint64));

            // On-chain position size check (approximate: sz * limitPx in 6-decimal USDC units)
            uint256 approxUsd = uint256(sz) * uint256(limitPx) / 1e6;
            if (approxUsd > maxPositionSize) revert PositionTooLarge(approxUsd, maxPositionSize);

            _cancelCurrentStopLoss();

            // Place IOC buy order (market-like)
            L1Write.sendLimitOrder(perpAssetIndex, true, limitPx, sz, false, TimeInForce.Ioc, NO_CLOID);

            // Place GTC stop loss (reduce-only sell) with fixed CLOID
            L1Write.sendLimitOrder(
                perpAssetIndex, false, stopLossPx, stopLossSz, true, TimeInForce.Gtc, STOP_LOSS_CLOID
            );
            hasActiveStopLoss = true;

            emit PositionOpened(perpAssetIndex, true, limitPx, sz, leverage);
            emit StopLossUpdated(stopLossPx);
        } else if (action == ACTION_CLOSE_POSITION) {
            (, uint64 limitPx, uint64 sz) = abi.decode(data, (uint8, uint64, uint64));

            _cancelCurrentStopLoss();

            // Place reduce-only IOC sell to close position
            L1Write.sendLimitOrder(perpAssetIndex, false, limitPx, sz, true, TimeInForce.Ioc, NO_CLOID);

            emit PositionClosed(perpAssetIndex, limitPx, sz);
        } else if (action == ACTION_UPDATE_STOP_LOSS) {
            // NOTE: action=3 is for LONG positions only (reduce-only sell).
            // For shorts, use ACTION_UPDATE_STOP_LOSS_SHORT (action=5).
            // If the wrong action is sent, HyperCore's reduce-only flag will
            // reject the order (a reduce-only sell with no long position is a no-op).
            // Position direction is NOT tracked on-chain — the proposer/agent
            // is responsible for sending the correct action type.
            (, uint64 triggerPx, uint64 sz) = abi.decode(data, (uint8, uint64, uint64));

            _cancelCurrentStopLoss();

            // Place new GTC stop loss (reduce-only sell) with fixed CLOID
            L1Write.sendLimitOrder(perpAssetIndex, false, triggerPx, sz, true, TimeInForce.Gtc, STOP_LOSS_CLOID);
            hasActiveStopLoss = true;

            emit StopLossUpdated(triggerPx);
        } else if (action == ACTION_OPEN_SHORT) {
            (, uint64 limitPx, uint64 sz, uint64 stopLossPx, uint64 stopLossSz) =
                abi.decode(data, (uint8, uint64, uint64, uint64, uint64));

            // On-chain position size check
            uint256 approxUsd = uint256(sz) * uint256(limitPx) / 1e6;
            if (approxUsd > maxPositionSize) revert PositionTooLarge(approxUsd, maxPositionSize);

            _cancelCurrentStopLoss();

            // Place IOC sell order (market-like short entry) - isBuy=false, reduceOnly=false
            L1Write.sendLimitOrder(perpAssetIndex, false, limitPx, sz, false, TimeInForce.Ioc, NO_CLOID);

            // Place GTC stop loss (reduce-only buy to close short) with fixed CLOID
            L1Write.sendLimitOrder(perpAssetIndex, true, stopLossPx, stopLossSz, true, TimeInForce.Gtc, STOP_LOSS_CLOID);
            hasActiveStopLoss = true;

            emit PositionOpened(perpAssetIndex, false, limitPx, sz, leverage);
            emit StopLossUpdated(stopLossPx);
        } else if (action == ACTION_UPDATE_STOP_LOSS_SHORT) {
            (, uint64 triggerPx, uint64 sz) = abi.decode(data, (uint8, uint64, uint64));

            _cancelCurrentStopLoss();

            // Place new GTC stop loss for SHORT position (reduce-only BUY) with fixed CLOID.
            // isBuy=true closes the short; triggerPx is above current price.
            L1Write.sendLimitOrder(perpAssetIndex, true, triggerPx, sz, true, TimeInForce.Gtc, STOP_LOSS_CLOID);
            hasActiveStopLoss = true;

            emit StopLossUpdated(triggerPx);
        } else if (action == ACTION_OPEN_LONG_MULTI || action == ACTION_OPEN_SHORT_MULTI) {
            // Multi-asset open: assetIndex is in the calldata, not storage.
            // Decode: (action, assetIndex, limitPx, sz, stopLossPx, stopLossSz)
            (, uint32 ai, uint64 limitPx, uint64 sz, uint64 stopLossPx, uint64 stopLossSz) =
                abi.decode(data, (uint8, uint32, uint64, uint64, uint64, uint64));

            // On-chain position size check
            uint256 approxUsd = uint256(sz) * uint256(limitPx) / 1e6;
            if (approxUsd > maxPositionSize) revert PositionTooLarge(approxUsd, maxPositionSize);

            _cancelCurrentStopLoss();

            bool isBuy = (action == ACTION_OPEN_LONG_MULTI);
            // IOC entry order
            L1Write.sendLimitOrder(ai, isBuy, limitPx, sz, false, TimeInForce.Ioc, NO_CLOID);
            // GTC stop-loss (reduce-only, opposite direction)
            L1Write.sendLimitOrder(ai, !isBuy, stopLossPx, stopLossSz, true, TimeInForce.Gtc, STOP_LOSS_CLOID);
            hasActiveStopLoss = true;

            // Track this asset for multi-asset settlement
            if (!assetTraded[ai]) {
                assetTraded[ai] = true;
                tradedAssets.push(ai);
            }
            perpAssetIndex = ai;

            emit PositionOpened(ai, isBuy, limitPx, sz, leverage);
            emit StopLossUpdated(stopLossPx);
        } else if (action == ACTION_CLOSE_MULTI) {
            // Multi-asset close: assetIndex + direction in calldata.
            // isBuy=true closes a short (buy back), isBuy=false closes a long (sell).
            // Decode: (action, assetIndex, isBuy, limitPx, sz)
            (, uint32 ai, bool isBuy, uint64 limitPx, uint64 sz) =
                abi.decode(data, (uint8, uint32, bool, uint64, uint64));

            _cancelCurrentStopLoss();

            // Reduce-only close on the specified asset and direction
            L1Write.sendLimitOrder(ai, isBuy, limitPx, sz, true, TimeInForce.Ioc, NO_CLOID);

            emit PositionClosed(ai, limitPx, sz);
        } else {
            revert InvalidAction();
        }
    }

    /// @notice TWO-PATH SETTLEMENT — Path 2 (governor-called).
    ///         See `HyperliquidGridStrategy._settle` for the design rationale.
    /// @dev    If `initiateReturn()` was NOT called pre-settle, fall back to
    ///         a defensive in-call HC drain. The recommended flow is to call
    ///         `initiateReturn()` (path 1) at least one block BEFORE
    ///         `settleProposal` so HC has time to bridge USDC back to EVM
    ///         and `_pushAllToVault` reports the realized NAV correctly.
    function _settle() internal override {
        if (!returnsInitiated) {
            _drainHC();
            returnsInitiated = true;
            emit ReturnsInitiated();
        }
        _pushAllToVault(address(asset));
        settled = true;
        emit Settled();
    }

    /// @notice TWO-PATH SETTLEMENT — Path 1 (proposer-driven async drain).
    ///         See `HyperliquidGridStrategy.initiateReturn` for full rationale.
    /// @dev    Auth: proposer always; anyone after proposal duration expired.
    /// @dev    HYPE GAS: spot→EVM consumes HC HYPE. Proposer must fund the
    ///         strategy's HC HYPE balance for the bridge to succeed. If
    ///         HYPE is missing pre-settle, retry via `initiateReturn()`
    ///         after funding; post-settle, retry via `recoverHcResiduals()`.
    function initiateReturn() external {
        if (_state != State.Executed) revert NotExecuted();
        if (returnsInitiated) return;

        if (msg.sender != proposer()) {
            ISyndicateGovernor gov = ISyndicateGovernor(ISyndicateVault(vault()).governor());
            uint256 pid = gov.getActiveProposal(vault());
            ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
            if (block.timestamp < p.executedAt + p.strategyDuration) revert NotAuthorized();
        }

        _drainHC();
        returnsInitiated = true;
        emit ReturnsInitiated();
    }

    /// @dev Cancel stop-loss, force-close all traded assets (or fall back to
    ///      `perpAssetIndex` for legacy single-asset proposals), and queue
    ///      perp→spot + spot→EVM bridges. Three callers:
    ///      - `initiateReturn` (path 1, proposer pre-settle)
    ///      - `_settle` (path 2 defensive fallback when path 1 was skipped)
    ///      - `recoverHcResiduals` (post-settle retry for HC residuals)
    function _drainHC() internal {
        _cancelCurrentStopLoss();

        if (tradedAssets.length > 0) {
            for (uint256 i = 0; i < tradedAssets.length; i++) {
                uint32 ai = tradedAssets[i];
                L1Write.sendLimitOrder(ai, false, 1, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
                L1Write.sendLimitOrder(ai, true, type(uint64).max, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
            }
        } else {
            L1Write.sendLimitOrder(perpAssetIndex, false, 1, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
            L1Write.sendLimitOrder(
                perpAssetIndex, true, type(uint64).max, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID
            );
        }

        _initiateReturn();
    }

    /// @notice Post-settle recovery for HC residuals. Re-fires the full HC
    ///         drain (cancel stop-loss + force-close + perp→spot + spot→EVM
    ///         bridge) so funds stranded on HC after settle can be recovered.
    ///         Use after IOC slippage left residual margin, or after funding
    ///         the strategy's HC HYPE balance to retry a previously no-op'd
    ///         spot→EVM bridge leg. See `HyperliquidGridStrategy.recoverHcResiduals`
    ///         for full design rationale.
    /// @dev    Gated to `settled == true` so it cannot conflict with path-1
    ///         `initiateReturn()`. Permissionless: funds only flow to HC spot
    ///         or to the strategy's EVM address (then `sweepToVault()` →
    ///         vault). Repeatable.
    function recoverHcResiduals() external {
        if (!settled) revert NotSweepable();
        // Same-block idempotence — see grid. SPOT_BALANCE precompile is
        // pre-block; same-block re-calls would queue duplicate bridges.
        if (block.number == lastRecoverBlock) return;
        lastRecoverBlock = block.number;
        _drainHC();
    }

    /// @notice Push any latecomer USDC back to the vault after `_settle()`.
    /// @dev `_settle()` already pushes the strategy's current EVM balance.
    ///      `sweepToVault` exists for HC auto-credit dust that arrives AFTER
    ///      settle (HC bridge is async post-block). Idempotent on zero-balance.
    /// @dev Permissionless — funds only go to the vault, no diversion possible.
    /// @dev Closes #255 S-C6: minReturnAmount removed (was permanently locking funds on lossy strategies).
    function sweepToVault() external {
        if (!settled) revert NotSweepable();

        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) return;

        cumulativeSwept += bal;

        uint256 vaultBefore = IERC20(asset).balanceOf(vault());
        _pushAllToVault(address(asset));
        uint256 actualTransferred = IERC20(asset).balanceOf(vault()) - vaultBefore;

        emit FundsSwept(actualTransferred);
    }

    // ── L1Read-based view functions ──

    /// @notice Read the current perp position from HyperCore (source of truth).
    function getPosition() external view returns (Position memory pos) {
        return L1Read.position2(address(this), perpAssetIndex);
    }

    /// @notice Read the current USDC spot balance on HyperCore.
    function getSpotBalance() external view returns (SpotBalance memory balance) {
        return L1Read.spotBalance(address(this), 0);
    }

    /// @notice Read the account margin summary from HyperCore.
    function getMarginSummary() external view returns (AccountMarginSummary memory summary) {
        return L1Read.accountMarginSummary(0, address(this));
    }

    // ── Internal helpers ──

    /// @dev Cancel the current GTC stop-loss order if one is active.
    ///      Uses a single fixed CLOID — O(1) gas cost regardless of trade history.
    function _cancelCurrentStopLoss() internal {
        if (hasActiveStopLoss) {
            L1Write.sendCancelOrderByCloid(perpAssetIndex, STOP_LOSS_CLOID);
            hasActiveStopLoss = false;
        }
    }

    /// @notice Drain HC perp + HC spot back to the strategy's EVM USDC
    ///         balance. See `HyperliquidGridStrategy._initiateReturn` for
    ///         full design rationale (perp→spot class transfer + spot→EVM
    ///         bridge via Circle's CoreDepositWallet).
    /// @dev    HYPE GAS: spot→EVM consumes HC HYPE; if absent, that leg
    ///         no-ops on HC and `sweepToVault()` recovers EVM arrivals.
    ///         A HYPE-funded retry of `initiateReturn()` drains stuck spot.
    function _initiateReturn() internal {
        (bool ok, bytes memory ret) = L1Read.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.ACCOUNT_MARGIN_SUMMARY_GAS}(
            abi.encode(uint32(0), address(this))
        );

        (bool spotOk, bytes memory spotRet) = L1Read.SPOT_BALANCE_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.SPOT_BALANCE_GAS}(
            abi.encode(address(this), uint64(HyperliquidBridge.USDC_TOKEN_INDEX))
        );
        uint64 preSpot = 0;
        if (spotOk && spotRet.length >= 96) {
            SpotBalance memory sb = abi.decode(spotRet, (SpotBalance));
            preSpot = sb.total;
        }

        uint64 perpToSpot = 0;
        int64 preDrainAccountValue = 0;
        if (ok && ret.length >= 128) {
            AccountMarginSummary memory s = abi.decode(ret, (AccountMarginSummary));
            preDrainAccountValue = s.accountValue;
            if (s.accountValue > 0) {
                int64 freeMargin = s.accountValue - int64(s.marginUsed);
                if (freeMargin > 0) {
                    perpToSpot = uint64(freeMargin);
                    L1Write.sendUsdClassTransfer(perpToSpot, false);
                }
            }
        }

        uint64 totalSpotWei = preSpot + perpToSpot * HyperliquidBridge.PERP_TO_SPOT_WEI;
        HyperliquidBridge.bridgeUsdcSpotToEvm(totalSpotWei);

        // Outbound in-transit high-water mark — see grid for rationale.
        uint256 preDrainPerpVal = preDrainAccountValue > 0 ? uint256(int256(preDrainAccountValue)) : 0;
        uint256 preDrainSpotVal = uint256(preSpot) / HyperliquidBridge.PERP_TO_SPOT_WEI;
        uint256 preDrainHcTotal = preDrainPerpVal + preDrainSpotVal;
        if (preDrainHcTotal > inFlightToHc) inFlightToHc = preDrainHcTotal;
    }

    /// @inheritdoc BaseStrategy
    /// @dev See `HyperliquidGridStrategy._positionValue` for full design.
    ///      Live NAV sums HC perp + HC spot + EVM, then chooses between
    ///      observable and the high-water mark via `CORE_ACCOUNT_FEE_TOLERANCE`:
    ///      gap ≤ tolerance → trust observable (Circle-fee steady state); gap
    ///      ≫ tolerance → fall back to `inFlightToHc` (genuine in-transit).
    function _positionValue() internal view override returns (uint256, bool) {
        (bool success, bytes memory ret) = L1Read.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.ACCOUNT_MARGIN_SUMMARY_GAS}(
            abi.encode(uint32(0), address(this))
        );
        uint256 perpVal = 0;
        if (success && ret.length >= 128) {
            AccountMarginSummary memory s = abi.decode(ret, (AccountMarginSummary));
            if (s.accountValue > 0) perpVal = uint256(int256(s.accountValue));
        }

        (bool spotOk, bytes memory spotRet) = L1Read.SPOT_BALANCE_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.SPOT_BALANCE_GAS}(
            abi.encode(address(this), uint64(HyperliquidBridge.USDC_TOKEN_INDEX))
        );
        uint256 spotVal = 0;
        if (spotOk && spotRet.length >= 96) {
            SpotBalance memory sb = abi.decode(spotRet, (SpotBalance));
            spotVal = uint256(sb.total) / HyperliquidBridge.PERP_TO_SPOT_WEI;
        }

        uint256 evmBal = IERC20(asset).balanceOf(address(this));
        uint256 observable = perpVal + spotVal + evmBal;

        if (observable + HyperliquidBridge.CORE_ACCOUNT_FEE_TOLERANCE >= inFlightToHc) {
            return (observable, true);
        }
        return (inFlightToHc, true);
    }

    /// @notice Move all HC spot USDC to perp margin via class transfer.
    ///         See grid for full rationale — recovers from Circle's first-
    ///         deposit fee dropping the original class transfer in `_execute`.
    /// @dev    Proposer-only; `Executed` state required.
    function moveSpotToPerp() external onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        (bool ok, bytes memory ret) = L1Read.SPOT_BALANCE_PRECOMPILE_ADDRESS.staticcall{gas: L1Read.SPOT_BALANCE_GAS}(
            abi.encode(address(this), uint64(HyperliquidBridge.USDC_TOKEN_INDEX))
        );
        if (!ok || ret.length < 96) return;
        SpotBalance memory sb = abi.decode(ret, (SpotBalance));
        if (sb.total == 0) return;
        uint64 perpAmount = sb.total / HyperliquidBridge.PERP_TO_SPOT_WEI;
        if (perpAmount == 0) return;
        L1Write.sendUsdClassTransfer(perpAmount, true);
    }
}
