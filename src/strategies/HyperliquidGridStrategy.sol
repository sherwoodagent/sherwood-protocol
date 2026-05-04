// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {L1Write, TimeInForce, NO_CLOID, FinalizeVariant} from "../hyperliquid/L1Write.sol";
import {L1Read, Position, SpotBalance, AccountMarginSummary} from "../hyperliquid/L1Read.sol";

/**
 * @title HyperliquidGridStrategy
 * @notice On-chain grid trading strategy using HyperEVM precompiles.
 *
 *   USDC is pulled from the vault and parked on HyperCore margin via
 *   L1Write.sendUsdClassTransfer(). The proposer (keeper EOA) drives
 *   the grid by calling updateParams() every 60s with batch orders.
 *
 *   Action types:
 *     - ACTION_PLACE_GRID: place batch of GTC limit orders
 *     - ACTION_CANCEL_ALL: cancel all open orders for an asset (CLOIDs in calldata)
 *     - ACTION_CANCEL_AND_PLACE: atomic cancel + place (rebalance)
 *
 *   Settlement: _settle() walks the on-chain CLOID mirror to cancel every
 *   resting GTC grid order before force-closing all positions and requesting
 *   the async USD transfer back to spot. sweepToVault() pushes USDC back to
 *   the vault when it arrives.
 *
 *   Live NAV: _positionValue() reports HyperCore perp account equity via
 *   L1Read.accountMarginSummary, so the vault can mark shares to market and
 *   accept deposits / withdrawals while the proposal is active.
 *
 *   HyperCore note: contract addresses (unlike EOAs) need explicit
 *   registration before bridged-token transfers auto-credit HC spot.
 *   `_initialize` finalizes the clone with HC using `FirstStorageSlot` by
 *   transiently swapping slot 0 (which `BaseStrategy.initialize` has just
 *   set to `_vault`) to `address(this)`, firing the precompile, then
 *   restoring the original `_vault` value. HC only reads slot 0 once at
 *   finalize time, so the swap is invisible to subsequent vault reads.
 *   This closes the slot-0-mismatch bug where ERC-1167 clones registered
 *   with the *vault* address (a UUPS proxy contract, not the strategy)
 *   and HC silently rejected USDC auto-credits, surfacing as
 *   `HyperCoreSpotCreditFailed` at execute time.
 *
 *   For non-default deployments (non-USDC tokens, alternate variants), the
 *   proposer can still call `finalizeForHyperCore(...)` post-init to fire
 *   an additional registration with custom params.
 */
contract HyperliquidGridStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Events ──
    event GridOrderPlaced(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, uint128 cloid);
    event GridOrderCancelled(uint32 asset, uint128 cloid);
    event FundsParked(uint256 amount);
    event Settled();
    event FundsSwept(uint256 amount);
    event LeverageUpdated(uint32 asset, uint32 leverage);
    event HyperCoreFinalized(uint64 token, FinalizeVariant variant, uint64 createNonce);

    // ── Errors ──
    error InvalidAmount();
    error InvalidAction();
    error DepositAmountTooLarge();
    error NotSweepable();
    error TooManyOrders(uint256 actual, uint256 max);
    error OrderTooLarge(uint256 actual, uint256 max);
    error AssetNotWhitelisted(uint32 asset);
    error HyperCoreSpotCreditFailed(uint64 spotBefore, uint64 spotAfter, uint64 expectedIncrease);

    // ── Action types ──
    uint8 constant ACTION_PLACE_GRID = 1;
    uint8 constant ACTION_CANCEL_ALL = 2;
    uint8 constant ACTION_CANCEL_AND_PLACE = 3;

    // ── Limits ──
    uint32 constant MAX_ASSETS = 32;

    // ── Storage (per-clone) ──
    IERC20 public asset;
    uint256 public depositAmount;
    uint32 public leverage;
    /// @notice Per-order notional cap (USD, 6 decimals). Each individual GridOrder's
    ///         notional (sz * limitPx / 1e6) must be <= this value. This is NOT a
    ///         cumulative per-asset exposure cap — the keeper is trusted to compose
    ///         grids correctly. Per-order bound limits blast radius of a single bad
    ///         order (typo, fat-finger, compromised keeper) without constraining
    ///         legitimate grid layouts.
    uint256 public maxOrderSize;
    uint32 public maxOrdersPerTick;
    uint32[] public assetIndices;
    mapping(uint32 => bool) public isAssetWhitelisted;
    bool public settled;
    uint256 public cumulativeSwept;
    /// @notice True once this contract has been registered with HyperCore so
    ///         bridged-token transfers auto-credit HC spot. Set by either the
    ///         explicit `finalizeForHyperCore` proposer call, or the implicit
    ///         self-heal in `_execute()` on first run.
    bool public hyperCoreFinalized;

    /// @notice CLOIDs of resting GTC grid orders, tracked per asset. Maintained
    ///         on-chain so `_settle` can self-cancel without keeper assistance.
    ///         Updated on every place / cancel through `_updateParams`.
    mapping(uint32 => uint128[]) internal _liveCloids;
    /// @notice 1-based index into `_liveCloids[ai]` for swap-and-pop removal.
    ///         0 means the cloid is not currently tracked.
    mapping(uint32 => mapping(uint128 => uint256)) internal _liveCloidIndex;

    struct GridOrder {
        uint32 assetIndex;
        bool isBuy;
        uint64 limitPx;
        uint64 sz;
        uint128 cloid;
    }

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Hyperliquid Grid";
    }

    function _initialize(bytes calldata data) internal override {
        (
            address asset_,
            uint256 depositAmount_,
            uint32 leverage_,
            uint256 maxOrderSize_,
            uint32 maxOrdersPerTick_,
            uint32[] memory assetIndices_
        ) = abi.decode(data, (address, uint256, uint32, uint256, uint32, uint32[]));

        if (asset_ == address(0)) revert ZeroAddress();
        if (depositAmount_ > type(uint64).max) revert DepositAmountTooLarge();
        if (leverage_ == 0 || leverage_ > 50) revert InvalidAmount();
        if (maxOrderSize_ == 0) revert InvalidAmount();
        if (maxOrdersPerTick_ == 0) revert InvalidAmount();
        if (assetIndices_.length == 0) revert InvalidAmount();
        if (assetIndices_.length > MAX_ASSETS) revert InvalidAmount();

        asset = IERC20(asset_);
        depositAmount = depositAmount_;
        leverage = leverage_;
        maxOrderSize = maxOrderSize_;
        maxOrdersPerTick = maxOrdersPerTick_;
        for (uint256 i = 0; i < assetIndices_.length; i++) {
            uint32 ai = assetIndices_[i];
            if (isAssetWhitelisted[ai]) continue; // dedup
            assetIndices.push(ai);
            isAssetWhitelisted[ai] = true;
        }

        // HC FirstStorageSlot finalize: transiently swap slot 0 from `_vault`
        // (just written by BaseStrategy.initialize) to `address(this)` so HC's
        // self-attestation check passes, then restore. HC reads slot 0 once at
        // finalize time and registration is permanent — the post-restore value
        // is irrelevant to HC. Done at init (not execute) so the registration
        // is in place before the first proposal opens; eliminates the silent
        // mismatch that surfaced as HyperCoreSpotCreditFailed on prop #6.
        bytes32 saved;
        assembly {
            saved := sload(0)
            sstore(0, address())
        }
        L1Write.sendFinalizeEvmContract(0, FinalizeVariant.FirstStorageSlot, 0);
        assembly {
            sstore(0, saved)
        }
        hyperCoreFinalized = true;
        emit HyperCoreFinalized(0, FinalizeVariant.FirstStorageSlot, 0);
    }

    /**
     * @notice Override the default HyperCore finalization with non-default
     *         variant/token/createNonce. **Optional** — `_execute()` will
     *         self-heal on first run using safe defaults
     *         (`token=0`, `FirstStorageSlot`, `createNonce=0`) suitable for
     *         the canonical SyndicateFactory ERC-1167 clone case.
     *
     *         Call this BEFORE the proposal that triggers `_execute()` only
     *         if the deployment method differs from the default (e.g. plain
     *         CREATE or a custom storage layout) or if a non-USDC token
     *         needs to be finalized.
     *
     * @param token        HyperCore token index (USDC = 0).
     * @param variant      Deployment-method variant:
     *                       Create (1)            — contract deployed via plain CREATE
     *                       FirstStorageSlot (2)  — typical ERC-1167 clone (default)
     *                       CustomStorageSlot (3) — UUPS / custom proxy
     * @param createNonce  Deployer nonce when the contract was created
     *                     (only consulted for the Create variant; pass 0 otherwise).
     */
    function finalizeForHyperCore(uint64 token, FinalizeVariant variant, uint64 createNonce) external onlyProposer {
        L1Write.sendFinalizeEvmContract(token, variant, createNonce);
        hyperCoreFinalized = true;
        emit HyperCoreFinalized(token, variant, createNonce);
    }

    function _execute() internal override {
        uint256 amountIn = depositAmount;
        if (amountIn == 0) {
            amountIn = IERC20(asset).balanceOf(vault());
        }
        if (amountIn == 0) revert InvalidAmount();
        if (amountIn > type(uint64).max) revert DepositAmountTooLarge();

        // HC finalize already ran at init via the slot-0 swap — no self-heal
        // needed here. The spot-credit guard below catches any residual
        // misregistration before we hand USDC to HC.
        (uint64 spotBefore, bool preSpotOk) = _tryGetUsdcSpotTotal();

        _pullFromVault(address(asset), amountIn);

        uint64 ntl = uint64(amountIn);

        (uint64 spotAfter, bool postSpotOk) = _tryGetUsdcSpotTotal();
        // HyperCore tracks USDC at 8 decimals; HyperEVM USDC is 6 decimals
        // (evmExtraWeiDecimals = -2). A real credit grows HC spot by ntl HC-wei,
        // which is always >= ntl EVM-wei. This is a one-sided lower-bound
        // monotonicity check, not an exact reconciliation. Subtraction (after
        // the >= sanity) avoids uint64 overflow on `spotBefore + ntl`.
        if (preSpotOk && postSpotOk) {
            uint64 delta = spotAfter >= spotBefore ? spotAfter - spotBefore : 0;
            if (delta < ntl) {
                revert HyperCoreSpotCreditFailed(spotBefore, spotAfter, ntl);
            }
        }

        for (uint256 i = 0; i < assetIndices.length; i++) {
            L1Write.sendUpdateLeverage(assetIndices[i], true, leverage);
            emit LeverageUpdated(assetIndices[i], leverage);
        }

        L1Write.sendUsdClassTransfer(ntl, true);

        emit FundsParked(amountIn);
    }

    function _updateParams(bytes calldata data) internal override {
        if (data.length < 32) revert InvalidAction();
        uint8 action = abi.decode(data[:32], (uint8));

        if (action == ACTION_PLACE_GRID) {
            (, GridOrder[] memory orders) = abi.decode(data, (uint8, GridOrder[]));
            _placeOrders(orders);
        } else if (action == ACTION_CANCEL_ALL) {
            (, uint32 assetIndex, uint128[] memory cloids) = abi.decode(data, (uint8, uint32, uint128[]));
            _cancelOrders(assetIndex, cloids);
        } else if (action == ACTION_CANCEL_AND_PLACE) {
            (, uint32 assetIndex, uint128[] memory cloids, GridOrder[] memory orders) =
                abi.decode(data, (uint8, uint32, uint128[], GridOrder[]));
            _cancelOrders(assetIndex, cloids);
            _placeOrders(orders);
        } else {
            revert InvalidAction();
        }
    }

    /// @dev Notional check: HL convention is `szDecimals + pxDecimals = 6`, so
    ///      `sz * limitPx / 1e6` always yields notional in USDC-6-decimal units
    ///      regardless of the asset's specific szDecimals. This holds for ALL
    ///      perps on HyperCore.
    function _placeOrders(GridOrder[] memory orders) internal {
        if (orders.length > maxOrdersPerTick) revert TooManyOrders(orders.length, maxOrdersPerTick);
        for (uint256 i = 0; i < orders.length; i++) {
            GridOrder memory o = orders[i];
            if (!isAssetWhitelisted[o.assetIndex]) revert AssetNotWhitelisted(o.assetIndex);
            uint256 approxUsd = uint256(o.sz) * uint256(o.limitPx) / 1e6;
            if (approxUsd > maxOrderSize) revert OrderTooLarge(approxUsd, maxOrderSize);
            L1Write.sendLimitOrder(o.assetIndex, o.isBuy, o.limitPx, o.sz, false, TimeInForce.Gtc, o.cloid);
            _trackCloid(o.assetIndex, o.cloid);
            emit GridOrderPlaced(o.assetIndex, o.isBuy, o.limitPx, o.sz, o.cloid);
        }
    }

    function _cancelOrders(uint32 assetIndex, uint128[] memory cloids) internal {
        if (!isAssetWhitelisted[assetIndex]) revert AssetNotWhitelisted(assetIndex);
        for (uint256 i = 0; i < cloids.length; i++) {
            L1Write.sendCancelOrderByCloid(assetIndex, cloids[i]);
            _untrackCloid(assetIndex, cloids[i]);
            emit GridOrderCancelled(assetIndex, cloids[i]);
        }
    }

    /// @dev Idempotent: re-tracking an already-live cloid is a no-op so a keeper
    ///      that re-uses cloids does not corrupt the index map. NO_CLOID (0) is
    ///      the HL "no client id" sentinel and is intentionally untracked — only
    ///      cloids the keeper can later cancel are worth remembering.
    function _trackCloid(uint32 ai, uint128 cloid) internal {
        if (cloid == NO_CLOID) return;
        if (_liveCloidIndex[ai][cloid] != 0) return;
        _liveCloids[ai].push(cloid);
        _liveCloidIndex[ai][cloid] = _liveCloids[ai].length;
    }

    /// @dev Tolerant of unknown cloids (no-op) so the on-chain mirror stays in
    ///      sync even if the keeper sends spurious cancels. Swap-and-pop keeps
    ///      removal O(1).
    function _untrackCloid(uint32 ai, uint128 cloid) internal {
        uint256 idx = _liveCloidIndex[ai][cloid];
        if (idx == 0) return;
        uint128[] storage arr = _liveCloids[ai];
        uint256 last = arr.length;
        if (idx != last) {
            uint128 lastCloid = arr[last - 1];
            arr[idx - 1] = lastCloid;
            _liveCloidIndex[ai][lastCloid] = idx;
        }
        arr.pop();
        delete _liveCloidIndex[ai][cloid];
    }

    /// @notice Cancel every tracked GTC order, force-close all positions, and
    ///         request async USD transfer back to spot.
    /// @dev    Self-cancellation walks `_liveCloids[asset]` from the tail and
    ///         pops, so resting orders are guaranteed cancelled before the IOC
    ///         reduce-only sweep below — eliminating the prior race where a
    ///         resting buy could fill against the force-close at a stale price.
    ///         The keeper can still pre-cancel off-chain to save the on-chain
    ///         loop's gas, but it is no longer required for safety.
    /// @dev    USDC arrives async — call sweepToVault() in a separate tx after
    ///         arrival.
    function _settle() internal override {
        for (uint256 i = 0; i < assetIndices.length; i++) {
            uint32 ai = assetIndices[i];
            _cancelAllTrackedOrders(ai);
            // Force-close LONG: reduce-only sell at min price
            L1Write.sendLimitOrder(ai, false, 1, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
            // Force-close SHORT: reduce-only buy at max price
            L1Write.sendLimitOrder(ai, true, type(uint64).max, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
        }

        L1Write.sendUsdClassTransfer(type(uint64).max, false);
        settled = true;
        emit Settled();
    }

    /// @dev Drains `_liveCloids[ai]` by popping from the tail, so each cancel
    ///      costs one SLOAD + one SSTORE refund (no swap). Bounded by however
    ///      many orders the keeper placed; in normal operation the active grid
    ///      is `levelsPerSide * 2` per asset (~24 at default config).
    function _cancelAllTrackedOrders(uint32 ai) internal {
        uint128[] storage arr = _liveCloids[ai];
        uint256 len = arr.length;
        while (len > 0) {
            uint128 cloid = arr[len - 1];
            L1Write.sendCancelOrderByCloid(ai, cloid);
            delete _liveCloidIndex[ai][cloid];
            arr.pop();
            unchecked {
                len--;
            }
            emit GridOrderCancelled(ai, cloid);
        }
    }

    /// @notice Push USDC back to the vault after async transfer completes.
    /// @dev Permissionless — funds only go to the vault, no diversion possible.
    ///      Repeatable for partial async arrivals. NO minReturnAmount guard:
    ///      a strategy that loses money must still be able to return whatever
    ///      remains. The cumulative tracker (`cumulativeSwept`) records totals
    ///      for off-chain monitoring but does not gate withdrawals.
    /// @dev Closes #255 S-C6: minReturnAmount removed (was permanently locking funds on lossy strategies).
    function sweepToVault() external {
        if (!settled) revert NotSweepable();

        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) revert InvalidAmount();

        cumulativeSwept += bal;

        uint256 vaultBefore = IERC20(asset).balanceOf(vault());
        _pushAllToVault(address(asset));
        uint256 actualTransferred = IERC20(asset).balanceOf(vault()) - vaultBefore;

        emit FundsSwept(actualTransferred);
    }

    // ── L1Read-based view functions ──

    function getPosition(uint32 ai) external view returns (Position memory) {
        return L1Read.position2(address(this), ai);
    }

    function getSpotBalance() external view returns (SpotBalance memory) {
        return L1Read.spotBalance(address(this), 0);
    }

    function getMarginSummary() external view returns (AccountMarginSummary memory) {
        return L1Read.accountMarginSummary(0, address(this));
    }

    /// @notice Read the tracked GTC CLOIDs for an asset (introspection /
    ///         keeper reconciliation against `~/.sherwood/grid/onchain-state.json`).
    function liveCloids(uint32 assetIndex) external view returns (uint128[] memory) {
        return _liveCloids[assetIndex];
    }

    /// @notice Number of tracked GTC CLOIDs for an asset (cheaper than
    ///         decoding the full array off-chain).
    function liveCloidsLength(uint32 assetIndex) external view returns (uint256) {
        return _liveCloids[assetIndex].length;
    }

    /// @inheritdoc BaseStrategy
    /// @dev Live NAV reads HyperCore perp account equity (already in USDC 6
    ///      decimals — same denomination as the vault asset). On non-HyperEVM
    ///      chains or any environment where the precompile is absent (EOA
    ///      staticcall returns success=true with empty returndata, so we also
    ///      check `ret.length`), `valid=false` and the vault falls back to
    ///      queue-only behavior. Negative equity (severely underwater) returns
    ///      `(0, true)` rather than reverting — share-price math should clamp,
    ///      not blow up. EVM-side stranded USDC is not added here because the
    ///      Executed-state invariant is "all vault funds parked on HC".
    function _positionValue() internal view override returns (uint256, bool) {
        (bool success, bytes memory ret) = L1Read.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.ACCOUNT_MARGIN_SUMMARY_GAS}(
            abi.encode(uint32(0), address(this))
        );
        if (!success || ret.length < 128) return (0, false);
        AccountMarginSummary memory s = abi.decode(ret, (AccountMarginSummary));
        if (s.accountValue <= 0) return (0, true);
        return (uint256(int256(s.accountValue)), true);
    }

    /// @dev Reuses `L1Read`'s precompile address + 15k gas cap (a misbehaving
    ///      precompile consumes all forwarded gas on revert, so capping prevents
    ///      griefing). Tolerates short returndata so off-HyperEVM environments
    ///      (tests with no precompile etched at `0x...0801`) bypass the gate.
    function _tryGetUsdcSpotTotal() internal view returns (uint64 total, bool ok) {
        (bool success, bytes memory ret) = L1Read.SPOT_BALANCE_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.SPOT_BALANCE_GAS}(
            abi.encode(address(this), uint64(0))
        );
        if (!success || ret.length < 96) return (0, false);
        SpotBalance memory bal = abi.decode(ret, (SpotBalance));
        return (bal.total, true);
    }
}
