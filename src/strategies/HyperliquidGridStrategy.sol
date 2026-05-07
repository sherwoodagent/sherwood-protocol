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
 * @title HyperliquidGridStrategy
 * @notice On-chain grid trading strategy using HyperEVM precompiles.
 *
 *   USDC is pulled from the vault, bridged EVM→HC spot via Circle's
 *   CoreDepositWallet (`HyperliquidBridge.bridgeUsdcToSpot`), and moved
 *   onto HC perp margin via `L1Write.sendUsdClassTransfer`. The proposer
 *   (keeper EOA) drives the grid by calling `updateParams()` every 60s
 *   with batch orders.
 *
 *   Action types:
 *     - ACTION_PLACE_GRID: place batch of GTC limit orders
 *     - ACTION_CANCEL_ALL: cancel all open orders for an asset (CLOIDs in calldata)
 *     - ACTION_CANCEL_AND_PLACE: atomic cancel + place (rebalance)
 *
 *   Settlement: _settle() walks the on-chain CLOID mirror to cancel every
 *   resting GTC grid order, force-closes all positions, runs the perp→spot
 *   class transfer, and pushes the strategy's current EVM USDC balance back
 *   to the vault — the governor's settle batch reads vault.totalAssets()
 *   right after, so the EVM push must happen here. sweepToVault() recovers
 *   any late HC arrivals (post-block bridge credits).
 *
 *   Live NAV: _positionValue() reports HyperCore perp account equity via
 *   L1Read.accountMarginSummary, so the vault can mark shares to market and
 *   accept deposits / withdrawals while the proposal is active.
 *
 *   HyperCore note: ERC-1167 clone addresses need explicit HC registration
 *   before ERC-20 USDC transfers auto-credit HC spot. `_initialize()` writes
 *   `address(this)` to slot 0 (`_hcSelf` from BaseStrategy). The CLI then
 *   calls `finalizeForHyperCore(0, FinalizeVariant.FirstStorageSlot, 0)` as
 *   a separate tx. HC reads slot 0 post-block, confirms it equals the
 *   contract address, and completes registration.
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
    event ReturnsInitiated();

    // ── Errors ──
    error InvalidAmount();
    error InvalidAction();
    error DepositAmountTooLarge();
    error NotSweepable();
    error TooManyOrders(uint256 actual, uint256 max);
    error OrderTooLarge(uint256 actual, uint256 max);
    error AssetNotWhitelisted(uint32 asset);
    error AlreadyFinalized();
    error NotAuthorized();

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
    /// @notice True once the HC drain (cancel + force-close + perp→spot +
    ///         spot→EVM bridge) has been triggered. Set by `initiateReturn()`
    ///         (proposer pre-settle) or by `_settle()` defensively. Idempotent.
    bool public returnsInitiated;
    /// @notice Block number of the last `recoverHcResiduals()` call. Same-
    ///         block re-calls are skipped to avoid HC double-queueing the
    ///         spot→EVM bridge for an amount that the precompile read sees
    ///         twice (`SPOT_BALANCE` returns pre-block state). Cross-block
    ///         retries see freshly-processed state and resume normally.
    uint256 public lastRecoverBlock;
    /// @notice High-water mark of USDC committed to HC but not yet observed
    ///         on HC by the precompile (in 6-decimal USDC units). Incremented
    ///         in `_execute` and `_onLiveDeposit` after each `bridgeUsdcToSpot`,
    ///         and bumped to `max(self, preDrainHcTotal)` inside `_initiateReturn`
    ///         to cover the outbound HC→EVM transit window. Grows monotonically
    ///         until the proposal lifecycle ends. `_positionValue` reconciles it
    ///         against observable HC + EVM via `HyperliquidBridge.CORE_ACCOUNT_FEE_TOLERANCE`.
    uint256 public inFlightToHc;

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
        // Slot 0 (`_hcSelf = address(this)`) is stamped by BaseStrategy.initialize
        // before this hook runs. HC's FirstStorageSlot finalize reads it post-block.
    }

    /**
     * @notice Register this clone with HyperCore so that USDC ERC-20 transfers
     *         auto-credit the HC spot account. MUST be called once after
     *         `initialize()` and before the proposal that triggers `_execute()`.
     *
     *         Standard call for SyndicateFactory CLI clones:
     *           finalizeForHyperCore(0, FinalizeVariant.FirstStorageSlot, 0)
     *         `_initialize()` already wrote `address(this)` to slot 0 (`_hcSelf`).
     *         HC reads slot 0 post-block, confirms it equals the contract address,
     *         and completes registration — no nonce math required.
     *
     * @param token        HyperCore token index (USDC = 0).
     * @param variant      Deployment-method variant:
     *                       Create (0)            — plain CREATE, pass deployer nonce
     *                       FirstStorageSlot (1)  — slot 0 == address(this) (use this)
     *                       CustomStorageSlot (2) — UUPS / custom proxy
     * @param createNonce  Deployer nonce (only used for the Create variant; pass 0 otherwise).
     */
    function finalizeForHyperCore(uint64 token, FinalizeVariant variant, uint64 createNonce) external onlyProposer {
        if (hyperCoreFinalized) revert AlreadyFinalized();
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

        _pullFromVault(address(asset), amountIn);

        // Bridge EVM → HC spot via Circle's CoreDepositWallet. The prior model
        // assumed HC auto-credits the strategy's HC spot when an ERC-20 lands
        // on its EVM address (after FirstStorageSlot registration), but every
        // ecosystem reference (Circle, hyper-evm-lib, across-protocol) bridges
        // explicitly. Without this call, HC spot stays empty and the
        // class-transfer below operates on zero balance.
        HyperliquidBridge.bridgeUsdcToSpot(asset, amountIn);

        uint64 ntl = uint64(amountIn);

        // Leverage is set off-chain via the exchange API before the proposal opens.
        // See `leverage` storage NatSpec.
        // Note: Circle's CoreDepositWallet charges a 1 USDC new-account fee on
        // first deposit per HC address, so the actual landed spot can be
        // (amountIn - 1e6) and HC drops this class transfer if it exceeds spot.
        // The proposer can call `moveSpotToPerp()` 1+ block later to recover by
        // class-transferring whatever actually landed.
        L1Write.sendUsdClassTransfer(ntl, true);

        // Track the in-flight bridge so vault NAV (`positionValue`) doesn't
        // under-report during the cross-block window before HC processes.
        inFlightToHc += amountIn;

        emit FundsParked(amountIn);
    }

    /// @dev Routes a mid-proposal LP deposit into the live HC perp account.
    ///      The vault has already pushed `assets` USDC to this address before
    ///      calling here. Bridge EVM → HC spot via Circle's CoreDepositWallet,
    ///      then class-transfer spot → perp. Subsequent deposits don't pay the
    ///      first-deposit fee (the HC account already exists), so the class
    ///      transfer for the full `assets` succeeds.
    function _onLiveDeposit(uint256 assets) internal override {
        if (assets == 0) return;
        if (assets > type(uint64).max) revert DepositAmountTooLarge();
        // Bridge new deposit's EVM USDC → HC spot, then move spot → perp.
        HyperliquidBridge.bridgeUsdcToSpot(asset, assets);
        L1Write.sendUsdClassTransfer(uint64(assets), true);
        inFlightToHc += assets;
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

    /// @notice TWO-PATH SETTLEMENT — Path 2 (governor-called).
    ///
    ///         If `initiateReturn()` was NOT called pre-settle, fall back to
    ///         a defensive in-call HC drain (same actions, same block — but
    ///         the EVM USDC won't be available to push to vault until HC
    ///         processes the bridges in the next block, so vault.totalAssets
    ///         will under-report). The recommended flow is:
    ///
    ///           Block N: proposer (or anyone after duration) calls
    ///                    `initiateReturn()` — queues HC drain.
    ///           Block N+1+: HC processes the perp→spot + spot→EVM actions,
    ///                       USDC arrives on the strategy's EVM address.
    ///           Block N+1+: governor calls `settleProposal` →
    ///                       strategy.settle() → `_pushAllToVault` correctly
    ///                       reports the realized NAV.
    ///
    /// @dev    If proposer never called `initiateReturn()` and `_settle()`
    ///         drains in the same block, push 0 to the vault (HC bridge is
    ///         async). `sweepToVault()` recovers the USDC once HC delivers.
    function _settle() internal override {
        if (!returnsInitiated) {
            _drainHC();
            returnsInitiated = true;
            emit ReturnsInitiated();
        }

        // Push current EVM USDC balance to the vault. Covers two cases:
        //   - HC registration failed: USDC never bridged, sits on EVM here.
        //   - Bridge completed in a prior block: USDC arrived on EVM, push it.
        // Late HC arrivals (post-block credits after settle) recovered via
        // `sweepToVault()`.
        _pushAllToVault(address(asset));

        settled = true;
        emit Settled();
    }

    /// @notice TWO-PATH SETTLEMENT — Path 1 (proposer-driven async drain).
    ///
    ///         Cancels all resting orders, force-closes perp positions, and
    ///         queues the perp→spot + spot→EVM bridges. HC processes these
    ///         post-block so USDC arrives on the strategy's EVM address in
    ///         the NEXT block (or later). After ≥1 block, the governor's
    ///         settle batch can call `strategy.settle()` and `_pushAllToVault`
    ///         will see the bridged USDC and push it to the vault — giving
    ///         the governor an accurate `vault.totalAssets()` for PnL.
    ///
    /// @dev    Auth: proposer can call anytime in `Executed`; anyone else
    ///         must wait until proposal duration has expired (so a stuck
    ///         proposer cannot block settlement). Read end-time from
    ///         governor's StrategyProposal struct.
    /// @dev    Idempotent: silent return if already initiated.
    /// @dev    HYPE GAS: per `HyperliquidBridge.bridgeUsdcSpotToEvm` NatSpec,
    ///         the spot→EVM leg consumes HC HYPE. The PROPOSER MUST FUND the
    ///         strategy's HC HYPE balance before `_execute` (or before this
    ///         call) so the bridge action lands on HC. If HYPE is absent,
    ///         spot→EVM no-ops and USDC stays on HC spot — pre-settle
    ///         recovery is a HYPE-funded retry of `initiateReturn()`;
    ///         post-settle recovery is `recoverHcResiduals()`.
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

    /// @dev Cancel resting orders, force-close all positions, and queue
    ///      perp→spot + spot→EVM bridges. Three callers:
    ///      - `initiateReturn` (path 1, proposer pre-settle)
    ///      - `_settle` (path 2 defensive fallback when path 1 was skipped)
    ///      - `recoverHcResiduals` (post-settle retry for HC residuals)
    function _drainHC() internal {
        for (uint256 i = 0; i < assetIndices.length; i++) {
            uint32 ai = assetIndices[i];
            _cancelAllTrackedOrders(ai);
            // Force-close LONG: reduce-only sell at min price.
            L1Write.sendLimitOrder(ai, false, 1, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
            // Force-close SHORT: reduce-only buy at max price.
            L1Write.sendLimitOrder(ai, true, type(uint64).max, type(uint64).max, true, TimeInForce.Ioc, NO_CLOID);
        }
        _initiateReturn();
    }

    /// @notice Post-settle recovery for HC residuals. Re-fires the full HC
    ///         drain (cancel + force-close + perp→spot + spot→EVM bridge) so
    ///         the proposer (or anyone) can recover funds stranded on HC
    ///         after settle. Two main use cases:
    ///
    ///           - IOC slippage: the initial force-close at settle didn't
    ///             fully fill (thin market, price impact). Residual perp
    ///             margin sits on HC. This call retries the close + drain.
    ///           - HYPE-funded retry: the spot→EVM `sendAsset` action
    ///             consumes HC HYPE; if the strategy's HC HYPE balance was
    ///             zero at settle time, the bridge no-op'd and USDC stayed
    ///             on HC spot. After topping up HYPE on HC, this call
    ///             re-attempts the spot→EVM bridge.
    ///
    /// @dev    Gated to `settled == true` so it cannot conflict with the
    ///         pre-settle path-1 `initiateReturn()`. Permissionless: funds
    ///         only flow to HC spot or to the strategy's EVM address (which
    ///         `sweepToVault()` then forwards to the vault). No diversion.
    /// @dev    Repeatable. Each call reads fresh precompile state (free
    ///         margin, spot balance) and queues HC actions for the current
    ///         residual amount. Reduce-only IOC force-close orders no-op on
    ///         HC when there's no position, so calling on a fully-drained
    ///         strategy is a cheap-ish no-op (only cancel-loop SLOADs).
    function recoverHcResiduals() external {
        if (!settled) revert NotSweepable();
        // Same-block idempotence: SPOT_BALANCE precompile returns pre-block
        // state, so a second call in the same block would queue another
        // spot→EVM bridge for the same amount. Wait for the next block to
        // see HC's processed state.
        if (block.number == lastRecoverBlock) return;
        lastRecoverBlock = block.number;
        _drainHC();
    }

    /// @notice Drain HC perp + HC spot back to the strategy's EVM USDC balance.
    ///         Queues two CoreWriter actions in order: (1) `sendUsdClassTransfer`
    ///         perp→spot for the current `freeMargin`, (2) `sendAsset` spot→EVM
    ///         for the COMBINED post-class-transfer spot balance. HC processes
    ///         them post-block in the same order — so step 2 sees the freshly-
    ///         class-transferred amount on top of any pre-existing HC spot.
    /// @dev    Reads pre-block state via precompiles (`ACCOUNT_MARGIN_SUMMARY`
    ///         + `SPOT_BALANCE`). HC processes actions sequentially per submitter,
    ///         so combining the pre-existing spot with the freshly moved perp
    ///         margin is the correct projected post-state.
    /// @dev    `accountValue - marginUsed` (perp 6-decimal) gives the
    ///         withdrawable amount with positions still open — HC rejects
    ///         class transfers exceeding withdrawable rather than partial-
    ///         filling. Multiplied by `PERP_TO_SPOT_WEI` (100) for the spot
    ///         8-decimal denomination of `sendAsset.amount`.
    /// @dev    HYPE GAS: per `HyperliquidBridge.bridgeUsdcSpotToEvm` NatSpec,
    ///         the spot→EVM leg consumes HC-side HYPE gas. If the strategy's
    ///         HC HYPE balance is zero, that action silently no-ops on HC and
    ///         USDC remains on HC spot — `sweepToVault()` retry recovers EVM
    ///         arrivals; HYPE-funded re-call of `initiateReturn()` recovers
    ///         the spot leftover.
    /// @dev    No-ops gracefully when precompiles are unavailable (non-
    ///         HyperEVM env / fork tests without etched precompiles).
    function _initiateReturn() internal {
        // Read pre-block perp account margin summary
        (bool ok, bytes memory ret) = L1Read.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.ACCOUNT_MARGIN_SUMMARY_GAS}(
            abi.encode(uint32(0), address(this))
        );

        // Pre-existing HC spot balance for USDC (token 0). Read defensively —
        // SPOT_BALANCE precompile address may be missing on non-HC envs.
        (bool spotOk, bytes memory spotRet) = L1Read.SPOT_BALANCE_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.SPOT_BALANCE_GAS}(
            abi.encode(address(this), uint64(HyperliquidBridge.USDC_TOKEN_INDEX))
        );
        uint64 preSpot = 0;
        if (spotOk && spotRet.length >= 96) {
            SpotBalance memory sb = abi.decode(spotRet, (SpotBalance));
            preSpot = sb.total;
        }

        // Compute perp→spot amount (6-decimal) and queue class transfer.
        // Also capture the full pre-drain perp account value (not just
        // free margin) for the outbound in-transit high-water mark.
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

        // Combined projected HC spot balance after class transfer
        // (8-decimal). Queue the spot→EVM bridge for the full amount.
        // perpToSpot * 100 cannot overflow uint64 unless perpToSpot >
        // ~1.8e17 (=$1.8e11 USDC), which is unreachable in practice.
        uint64 totalSpotWei = preSpot + perpToSpot * HyperliquidBridge.PERP_TO_SPOT_WEI;
        HyperliquidBridge.bridgeUsdcSpotToEvm(totalSpotWei);

        // Outbound in-transit high-water mark: the spot→EVM bridge is async
        // (HC processes post-block). Between this tx and HC's bridge ack, the
        // precompiles will report HC = 0 while EVM hasn't received yet. Lock
        // `inFlightToHc` to the pre-drain HC observable so NAV doesn't drop
        // to 0 in that gap. Once EVM USDC arrives, `_positionValue`'s
        // tolerance fallback (observable + HyperliquidBridge.CORE_ACCOUNT_FEE_TOLERANCE
        // >= inFlightToHc) brings NAV back to live observable.
        uint256 preDrainPerpVal = preDrainAccountValue > 0 ? uint256(int256(preDrainAccountValue)) : 0;
        uint256 preDrainSpotVal = uint256(preSpot) / HyperliquidBridge.PERP_TO_SPOT_WEI;
        uint256 preDrainHcTotal = preDrainPerpVal + preDrainSpotVal;
        if (preDrainHcTotal > inFlightToHc) inFlightToHc = preDrainHcTotal;
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

    /// @notice Push any latecomer USDC back to the vault after `_settle()`.
    /// @dev `_settle()` itself pushes the strategy's current EVM USDC balance
    ///      to the vault so the governor's settle batch sees correct NAV.
    ///      `sweepToVault` exists to handle HC auto-credit dust that arrives
    ///      AFTER settle (HC bridge is async post-block) — call any time the
    ///      strategy's EVM USDC balance is non-zero post-settle.
    /// @dev Permissionless — funds only go to the vault, no diversion possible.
    ///      Idempotent on zero-balance (no-op return) so it's safe to call
    ///      blindly without checking balance off-chain. The cumulative tracker
    ///      (`cumulativeSwept`) records totals for off-chain monitoring but
    ///      does not gate withdrawals.
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
    /// @dev Live NAV = HC perp + HC spot + EVM. Reconciles against
    ///      `inFlightToHc` via a Circle-fee-sized tolerance:
    ///
    ///        observable + tolerance >= inFlightToHc ? observable : inFlightToHc
    ///
    ///      Tolerance (1 USDC = `HyperliquidBridge.CORE_ACCOUNT_FEE_TOLERANCE`)
    ///      absorbs Circle's `DEFAULT_NEW_CORE_ACCOUNT_FEE` permanent strand
    ///      so the post-fee steady state trusts observable. A genuine cross-
    ///      block in-transit window (inbound `_execute`/`_onLiveDeposit` or
    ///      outbound `_initiateReturn`) opens a gap ≫ tolerance, so the
    ///      fallback returns `inFlightToHc` and NAV stays stable.
    ///
    ///      Always `valid=true` in `Executed` state. Vault has already pulled
    ///      funds in, and `valid=false` would degrade `totalAssets()` to the
    ///      queue-only path — deposits would revert with `DepositsLocked` and
    ///      the LP UI would brick. Conservatism (returning live `observable`
    ///      or the high-water mark) is always preferable to flagging invalid.
    function _positionValue() internal view override returns (uint256, bool) {
        // Read HC perp account margin
        (bool success, bytes memory ret) = L1Read.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.ACCOUNT_MARGIN_SUMMARY_GAS}(
            abi.encode(uint32(0), address(this))
        );
        uint256 perpVal = 0;
        if (success && ret.length >= 128) {
            AccountMarginSummary memory s = abi.decode(ret, (AccountMarginSummary));
            if (s.accountValue > 0) perpVal = uint256(int256(s.accountValue));
        }

        // Read HC spot balance for USDC (token=0). Convert spot wei (8-dec) →
        // perp/EVM units (6-dec) via `/ PERP_TO_SPOT_WEI`.
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
    /// @dev    Reads the strategy's current HC spot balance (8-decimal),
    ///         converts to perp 6-decimal, and queues a `sendUsdClassTransfer`
    ///         action. Recovers from:
    ///           - Circle's 1-USDC first-deposit fee dropping the original
    ///             class transfer in `_execute` (spot has 9, perp has 0).
    ///           - Any partial bridge / dust that landed on spot.
    ///         Repeatable. Each call queues a fresh class transfer for the
    ///         current spot balance.
    /// @dev    Proposer-only because timing matters (the class transfer must
    ///         be queued AFTER HC has processed the bridge, otherwise the
    ///         pre-block spot read is stale). Permissionless would also be
    ///         safe (funds stay within the strategy's HC account, no
    ///         diversion), but proposer-only keeps the responsibility clear.
    /// @dev    Same-block re-call is idempotent on intent but wasteful: the
    ///         second call would queue another class transfer for the same
    ///         pre-block spot read. Wait at least one block between calls.
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
