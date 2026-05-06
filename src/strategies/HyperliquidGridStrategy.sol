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
 *   HyperCore note: ERC-1167 clone addresses need explicit HC registration
 *   before ERC-20 USDC transfers auto-credit HC spot. The CLI calls
 *   `finalizeForHyperCore(0, FinalizeVariant.Create, deployerNonce)` as a
 *   separate tx immediately after `initialize()`. HC verifies the clone via
 *   CREATE address derivation (keccak256(rlp(deployer, nonce))) from its own
 *   EVM history — no storage manipulation needed.
 */
contract HyperliquidGridStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Events ──
    event GridOrderPlaced(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, uint128 cloid);
    event GridOrderCancelled(uint32 asset, uint128 cloid);
    event FundsParked(uint256 amount);
    event Settled();
    event FundsSwept(uint256 amount);
    event HyperCoreFinalized(uint64 token, FinalizeVariant variant, uint64 createNonce);

    // ── Errors ──
    error InvalidAmount();
    error InvalidAction();
    error DepositAmountTooLarge();
    error NotSweepable();
    error TooManyOrders(uint256 actual, uint256 max);
    error OrderTooLarge(uint256 actual, uint256 max);
    error AssetNotWhitelisted(uint32 asset);

    // ── Action types ──
    uint8 constant ACTION_PLACE_GRID = 1;
    uint8 constant ACTION_CANCEL_ALL = 2;
    uint8 constant ACTION_CANCEL_AND_PLACE = 3;

    // ── Limits ──
    uint32 constant MAX_ASSETS = 32;

    // ── Storage (per-clone) ──
    IERC20 public asset;
    uint256 public depositAmount;
    /// @notice The intended leverage for HyperCore positions opened by this strategy.
    /// @dev Off-chain keepers MUST set this leverage on HyperCore via the exchange
    ///      API (`updateLeverage`) before the proposal opens. There is no CoreWriter
    ///      action for leverage (Hyperliquid's spec defines actions 1-15 only), so
    ///      the value here is a covenant the keeper must honor — guardians review
    ///      by inspecting HyperCore state via `L1Read.position2`.
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
    ///         bridged-token transfers auto-credit HC spot. Set only by
    ///         `finalizeForHyperCore`, which the CLI auto-calls in a separate
    ///         tx immediately after `initialize()` (see
    ///         `cli/src/commands/strategy-template.ts`).
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

        // HC registration is intentionally NOT done here.
        //
        // ICoreWriter.sendRawAction emits a RawAction event that HyperCore
        // processes asynchronously — after the EVM block completes. The
        // slot-0 swap trick (swap _vault → address(this), fire finalize,
        // restore) was written assuming HC reads slot 0 at call time, but HC
        // reads it from the post-block state, where the slot has already been
        // restored to _vault. The clone ends up registered under the vault's
        // address, not its own, so USDC auto-credits never land and
        // _execute() reverts with HyperCoreSpotCreditFailed.
        //
        // Correct path: FinalizeVariant.Create — HC verifies
        //   keccak256(rlp(deployer, createNonce)) == address(this)
        // using its own EVM state history; no storage read is needed.
        // The CLI calls finalizeForHyperCore(0, Create, deployerNonce) as a
        // separate tx immediately after initialize(). hyperCoreFinalized is
        // set to true there, not here.
    }

    /**
     * @notice Register this clone with HyperCore so that USDC ERC-20 transfers
     *         auto-credit the HC spot account. MUST be called once after
     *         `initialize()` and before the proposal that triggers `_execute()`.
     *
     *         For ERC-1167 clones deployed via the SyndicateFactory CLI:
     *           finalizeForHyperCore(0, FinalizeVariant.Create, deployerNonce)
     *         HC verifies keccak256(rlp(deployer, createNonce)) == address(this)
     *         using its own EVM history — no storage manipulation needed.
     *
     * @param token        HyperCore token index (USDC = 0).
     * @param variant      Deployment-method variant:
     *                       Create (0)            — ERC-1167 clone (use this)
     *                       FirstStorageSlot (1)  — contract whose slot 0 == address(this)
     *                       CustomStorageSlot (2) — UUPS / custom proxy
     * @param createNonce  Deployer nonce at clone creation time
     *                     (only used for the Create variant; pass 0 otherwise).
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

        // L1Read (precompile 0x...0801) returns a pre-block HC state snapshot.
        // ERC-20 auto-credit for registered contracts is processed by HC AFTER
        // the EVM block completes, so spotAfter always equals spotBefore within
        // the same tx — any delta check would always fire. The guard is gone.
        // Safety: if HC registration somehow failed, USDC stays on the strategy
        // EVM address and settle()/sweepToVault() returns it to the vault.
        _pullFromVault(address(asset), amountIn);

        uint64 ntl = uint64(amountIn);

        // Leverage is set off-chain via the exchange API before the proposal opens.
        // See `leverage` storage NatSpec.
        L1Write.sendUsdClassTransfer(ntl, true);

        emit FundsParked(amountIn);
    }

    /// @dev Routes a mid-proposal LP deposit into the live HC perp account.
    ///      The vault has already pushed `assets` USDC to this address before
    ///      calling here. HC auto-credits spot (registration done at init), so
    ///      a single class transfer moves the funds to perp margin immediately.
    ///      The keeper sees the expanded margin and places additional orders via
    ///      updateParams — no leverage re-push needed (leverage is per-asset, not
    ///      account-wide).
    function _onLiveDeposit(uint256 assets) internal override {
        if (assets == 0) return;
        if (assets > type(uint64).max) revert DepositAmountTooLarge();
        L1Write.sendUsdClassTransfer(uint64(assets), true);
        emit FundsParked(assets);
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
    /// @dev    The class transfer amount is read from the precompile at settle
    ///         time (pre-IOC-close equity). After IOC fills, any residual perp
    ///         balance (due to slippage vs mark price) can be swept via
    ///         initiateReturn(). USDC arrives async — call sweepToVault() after.
    function _settle() internal override {
        for (uint256 i = 0; i < assetIndices.length; i++) {
            uint32 ai = assetIndices[i];
            _cancelAllTrackedOrders(ai);
            // Force-close LONG: reduce-only sell at min price
            L1Write.sendLimitOrder(ai, false, 1, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
            // Force-close SHORT: reduce-only buy at max price
            L1Write.sendLimitOrder(ai, true, type(uint64).max, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
        }

        // Read the exact perp equity from the precompile (accountValue is in
        // USDC-6-decimal, same denomination as sendUsdClassTransfer's ntl param).
        // Avoids passing type(uint64).max, which is undocumented as a "sweep all"
        // sentinel in HyperCore's class transfer protocol and risks stranding funds.
        // If precompile is unavailable (non-HyperEVM env), skip gracefully —
        // sendUsdClassTransfer would be a no-op there anyway.
        _initiateClassTransfer();

        settled = true;
        emit Settled();
    }

    /// @notice Re-initiate the perp→spot class transfer for any residual perp
    ///         balance left after IOC fill slippage at settlement.
    /// @dev    Permissionless: funds only flow to HC spot (same address), no
    ///         diversion possible. Call this if sweepToVault keeps returning 0
    ///         after settlement — it means some equity remains in perp.
    function initiateReturn() external {
        if (!settled) revert NotSweepable();
        _initiateClassTransfer();
    }

    /// @dev Reads current perp free margin (accountValue - marginUsed) via precompile
    ///      and sends a class transfer (perp→spot) for that amount. Using accountValue
    ///      alone would include margin locked by any still-open positions — HyperCore
    ///      rejects class transfers that exceed withdrawable margin rather than filling
    ///      partially, so we subtract marginUsed to stay within the withdrawable bound.
    ///      No-ops when the precompile is unavailable or when free margin <= 0.
    function _initiateClassTransfer() internal {
        (bool ok, bytes memory ret) = L1Read.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.ACCOUNT_MARGIN_SUMMARY_GAS}(
            abi.encode(uint32(0), address(this))
        );
        if (!ok || ret.length < 128) return;
        AccountMarginSummary memory s = abi.decode(ret, (AccountMarginSummary));
        if (s.accountValue <= 0) return;
        // marginUsed ≤ accountValue for solvent accounts; int64 cast is safe because
        // marginUsed > int64.max would require ~$9.2T in perp positions.
        int64 freeMargin = s.accountValue - int64(s.marginUsed);
        if (freeMargin <= 0) return;
        L1Write.sendUsdClassTransfer(uint64(freeMargin), false);
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
}
