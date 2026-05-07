// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Chainlink Data Streams verifier proxy interface
interface IVerifierProxy {
    function verify(bytes calldata signedReport) external payable returns (bytes memory verifierResponse);
}

/// @notice Decoded Chainlink Data Streams V3 report
struct ChainlinkReport {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 price;
    int192 bid;
    int192 ask;
}

/**
 * @title PortfolioStrategy
 * @notice Manages a weighted basket of tokens (e.g., tokenized stocks on Robinhood Chain).
 *         Buys tokens at target weights on execute, sells everything on settle.
 *         Supports rebalancing by the proposer — either sell-all/re-buy or
 *         delta-based using Chainlink Data Streams prices.
 *
 *   Execute: pull asset → swap to basket tokens at target weights
 *   Settle:  swap all basket tokens → push asset back to vault
 *
 *   Batch calls from governor:
 *     Execute: [asset.approve(strategy, totalAmount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 *
 *   Tunable params (proposer, Executed state):
 *     - targetWeightBps per token
 *     - maxSlippageBps
 *     - swapExtraData per token
 *
 *   Rebalancing (proposer, Executed state):
 *     - rebalance(): sell all, re-buy at current weights (simple)
 *     - rebalanceDelta(reports): use Chainlink prices, only swap deltas (gas efficient)
 */
contract PortfolioStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error InvalidAmount();
    error InvalidWeights();
    error LengthMismatch();
    error TooManyTokens();
    error SwapFailed();
    error RebalancingInProgress();
    error StalePrice();
    error InvalidSlippage();
    error QuoteUnavailable();
    error InvalidPriceDecimals();

    // ── Constants ──
    uint256 public constant MAX_BASKET_SIZE = 20;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant MAX_PRICE_AGE = 5 minutes;

    // ── Storage (per-clone) ──

    struct TokenAllocation {
        address token;
        uint256 targetWeightBps;
        uint256 tokenAmount;
        uint256 investedAmount;
    }

    address public asset;
    ISwapAdapter public swapAdapter;
    address public chainlinkVerifier;

    TokenAllocation[] internal _allocations;
    bytes[] internal _swapExtraData;

    uint256 public totalAmount;
    uint256 public maxSlippageBps;

    bool private _rebalancing;

    /// @notice Last verified Chainlink Data Streams price per token (raw oracle units).
    /// @dev    Populated by `rebalanceDelta` (in-loop write) and the standalone
    ///         `refreshPrices` helper. Read by `_positionValue` for live NAV.
    mapping(address token => uint256 price) public cachedPrice;

    /// @notice Wall-clock timestamp of the last cache write per token.
    mapping(address token => uint256 updatedAt) public cachedPriceUpdatedAt;

    /// @dev Cached `decimals()` of the vault asset, read once at init so
    ///      `_positionValue` doesn't need an external call per share-price read.
    uint8 internal _assetDecimals;

    /// @dev Cached `decimals()` per allocation, parallel to `_allocations`.
    uint8[] internal _tokenDecimals;

    /// @dev Declared per-allocation Chainlink feed decimals (raw oracle scale).
    ///      Required because Chainlink Data Streams reports for tokenized stocks
    ///      may use 1e8 while crypto pairs use 1e18 — we must not hard-code 1e18.
    uint8[] internal _priceDecimals;

    // ── Events ──
    event WeightsUpdated(address[] tokens, uint256[] oldWeights, uint256[] newWeights);
    event Rebalanced(
        address[] tokens,
        uint256[] oldWeights,
        uint256[] newWeights,
        uint256[] oldBalances,
        uint256[] newBalances,
        uint256 totalAssetValue
    );
    event RebalancedDelta(
        address[] tokens,
        uint256[] oldWeights,
        uint256[] newWeights,
        uint256[] oldBalances,
        uint256[] newBalances,
        uint256 totalAssetValue,
        uint256 swapsExecuted
    );

    /// @notice Emitted whenever the Chainlink price cache is refreshed (either
    ///         via the dedicated `refreshPrices` helper or as a side effect of
    ///         `rebalanceDelta`). Keepers / monitoring use this to observe the
    ///         live-NAV freshness gate.
    event PricesRefreshed(uint256 timestamp);

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Portfolio";
    }

    // ── Initialization ──

    /// @notice Decode: (address asset, address swapAdapter, address chainlinkVerifier,
    ///         address[] tokens, uint256[] weightsBps, uint256 totalAmount,
    ///         uint256 maxSlippageBps, bytes[] swapExtraData, uint8[] priceDecimals)
    /// @dev    `priceDecimals[i]` declares the raw Chainlink feed scale for
    ///         allocation `i` (typically 8 for tokenized stocks, 18 for crypto
    ///         pairs). Must be ≤ 36 to keep `10**(...)` math safe. Token decimals
    ///         are read once via `IERC20Metadata.decimals()` and cached so
    ///         `_positionValue` stays cheap.
    function _initialize(bytes calldata data) internal override {
        (
            address asset_,
            address swapAdapter_,
            address chainlinkVerifier_,
            address[] memory tokens,
            uint256[] memory weightsBps,
            uint256 totalAmount_,
            uint256 maxSlippageBps_,
            bytes[] memory swapExtraData_,
            uint8[] memory priceDecimals_
        ) = abi.decode(data, (address, address, address, address[], uint256[], uint256, uint256, bytes[], uint8[]));

        if (asset_ == address(0) || swapAdapter_ == address(0)) revert ZeroAddress();
        if (tokens.length == 0 || tokens.length > MAX_BASKET_SIZE) revert TooManyTokens();
        if (tokens.length != weightsBps.length || tokens.length != swapExtraData_.length) revert LengthMismatch();
        if (tokens.length != priceDecimals_.length) revert LengthMismatch();
        if (totalAmount_ == 0) revert InvalidAmount();
        if (maxSlippageBps_ == 0 || maxSlippageBps_ >= BPS_DENOMINATOR) revert InvalidSlippage();

        uint256 weightSum;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            // 36 ≈ max informally seen across Chainlink feeds; main guard is
            // against bogus calldata that would overflow `10 ** denom` math.
            if (priceDecimals_[i] > 36) revert InvalidPriceDecimals();
            weightSum += weightsBps[i];
            _allocations.push(
                TokenAllocation({token: tokens[i], targetWeightBps: weightsBps[i], tokenAmount: 0, investedAmount: 0})
            );
            _swapExtraData.push(swapExtraData_[i]);
            _tokenDecimals.push(IERC20Metadata(tokens[i]).decimals());
            _priceDecimals.push(priceDecimals_[i]);
        }
        if (weightSum != BPS_DENOMINATOR) revert InvalidWeights();

        asset = asset_;
        swapAdapter = ISwapAdapter(swapAdapter_);
        chainlinkVerifier = chainlinkVerifier_;
        totalAmount = totalAmount_;
        maxSlippageBps = maxSlippageBps_;
        _assetDecimals = IERC20Metadata(asset_).decimals();
    }

    // ── Execute: buy basket tokens ──

    function _execute() internal override {
        _pullFromVault(asset, totalAmount);
        _recordPrincipal(totalAmount);

        uint256 len = _allocations.length;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 allocation = (totalAmount * alloc.targetWeightBps) / BPS_DENOMINATOR;
            if (allocation == 0) continue;

            IERC20(asset).forceApprove(address(swapAdapter), allocation);
            uint256 minOut = _quoteMinOut(asset, alloc.token, allocation, _swapExtraData[i]);
            uint256 amountOut = swapAdapter.swap(asset, alloc.token, allocation, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

            alloc.tokenAmount = amountOut;
            alloc.investedAmount = allocation;
        }

        // Push any residual dust back to vault
        _pushAllToVault(asset);
    }

    // ── Settle: sell all basket tokens ──

    function _settle() internal override {
        uint256 len = _allocations.length;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 bal = IERC20(alloc.token).balanceOf(address(this));
            if (bal == 0) continue;

            IERC20(alloc.token).forceApprove(address(swapAdapter), bal);
            uint256 minOut = _quoteMinOut(alloc.token, asset, bal, _swapExtraData[i]);
            swapAdapter.swap(alloc.token, asset, bal, minOut, _swapExtraData[i]);

            alloc.tokenAmount = 0;
        }

        _pushAllToVault(asset);
    }

    // ── Update params ──

    /// @notice Update: (uint256[] newWeightsBps, uint256 newMaxSlippageBps, bytes[] newSwapExtraData)
    /// @dev Pass empty arrays / 0 to keep current values.
    function _updateParams(bytes calldata data) internal override {
        (uint256[] memory newWeightsBps, uint256 newMaxSlippageBps, bytes[] memory newSwapExtraData) =
            abi.decode(data, (uint256[], uint256, bytes[]));

        if (newWeightsBps.length > 0) {
            if (newWeightsBps.length != _allocations.length) revert LengthMismatch();
            uint256 weightSum;
            uint256[] memory oldWeights = new uint256[](newWeightsBps.length);
            address[] memory tokens = new address[](newWeightsBps.length);
            for (uint256 i; i < newWeightsBps.length; ++i) {
                tokens[i] = _allocations[i].token;
                oldWeights[i] = _allocations[i].targetWeightBps;
                weightSum += newWeightsBps[i];
                _allocations[i].targetWeightBps = newWeightsBps[i];
            }
            if (weightSum != BPS_DENOMINATOR) revert InvalidWeights();
            emit WeightsUpdated(tokens, oldWeights, newWeightsBps);
        }

        if (newMaxSlippageBps > 0) {
            if (newMaxSlippageBps >= BPS_DENOMINATOR) revert InvalidSlippage();
            maxSlippageBps = newMaxSlippageBps;
        }

        if (newSwapExtraData.length > 0) {
            if (newSwapExtraData.length != _allocations.length) revert LengthMismatch();
            for (uint256 i; i < newSwapExtraData.length; ++i) {
                _swapExtraData[i] = newSwapExtraData[i];
            }
        }
    }

    // ── Rebalancing ──

    /// @notice Simple rebalance: sell all positions, re-buy at current target weights.
    ///         Proposer-only, Executed state only.
    function rebalance() external onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        if (_rebalancing) revert RebalancingInProgress();
        _rebalancing = true;

        uint256 len = _allocations.length;

        // Snapshot before state for event
        address[] memory tokens = new address[](len);
        uint256[] memory oldWeights = new uint256[](len);
        uint256[] memory newWeights = new uint256[](len);
        uint256[] memory oldBalances = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            tokens[i] = _allocations[i].token;
            oldWeights[i] = _allocations[i].targetWeightBps;
            newWeights[i] = _allocations[i].targetWeightBps;
            oldBalances[i] = IERC20(_allocations[i].token).balanceOf(address(this));
        }

        // 1. Sell all positions back to asset
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 bal = IERC20(alloc.token).balanceOf(address(this));
            if (bal == 0) continue;

            IERC20(alloc.token).forceApprove(address(swapAdapter), bal);
            uint256 minOut = _quoteMinOut(alloc.token, asset, bal, _swapExtraData[i]);
            swapAdapter.swap(alloc.token, asset, bal, minOut, _swapExtraData[i]);
            alloc.tokenAmount = 0;
            alloc.investedAmount = 0;
        }

        // 2. Re-buy at current target weights
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 allocation = (assetBalance * alloc.targetWeightBps) / BPS_DENOMINATOR;
            if (allocation == 0) continue;

            IERC20(asset).forceApprove(address(swapAdapter), allocation);
            uint256 minOut = _quoteMinOut(asset, alloc.token, allocation, _swapExtraData[i]);
            uint256 amountOut = swapAdapter.swap(asset, alloc.token, allocation, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

            alloc.tokenAmount = amountOut;
            alloc.investedAmount = allocation;
        }

        // Snapshot after balances for event
        uint256[] memory newBalances = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            newBalances[i] = IERC20(_allocations[i].token).balanceOf(address(this));
        }

        _rebalancing = false;
        emit Rebalanced(tokens, oldWeights, newWeights, oldBalances, newBalances, assetBalance);
    }

    /// @dev Pre-rebalance snapshot bundle. Bundling the parallel arrays
    ///      lets the legacy compiler pass them around through a single
    ///      memory-pointer slot rather than spreading 4–6 separate
    ///      pointers across the stack of `rebalanceDelta`.
    struct DeltaSnapshot {
        address[] tokens;
        uint256[] oldWeights;
        uint256[] newWeights;
        uint256[] oldBalances;
        uint256[] prices;
        uint256[] currentValues;
    }

    /// @notice Delta-based rebalance using Chainlink Data Streams prices.
    ///         Only swaps the difference between current and target allocations.
    /// @param priceReports Signed Chainlink Data Streams reports (one per allocation, same order)
    /// @dev Heavy loop bodies extracted into `_sellOverweight`,
    ///      `_buyUnderweight`, and `_snapshotAllocations` so the legacy
    ///      compiler pipeline (forge coverage, no via_ir) doesn't trip
    ///      stack-too-deep on the per-iteration mix of storage struct reads
    ///      + external swap calls + memory array writes.
    function rebalanceDelta(bytes[] calldata priceReports) external onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        if (_rebalancing) revert RebalancingInProgress();
        _rebalancing = true;

        uint256 len = _allocations.length;
        if (priceReports.length != len) revert LengthMismatch();

        DeltaSnapshot memory snap = _snapshotAllocations(len);

        // 1. Verify prices and compute current portfolio value. Verified prices
        //    are cached so live NAV (`_positionValue`) stays fresh as a
        //    side effect of every rebalance.
        uint256 totalValue;
        uint256 nowTs = block.timestamp;
        for (uint256 i; i < len; ++i) {
            snap.prices[i] = _verifyPrice(priceReports[i]);
            snap.currentValues[i] = (snap.oldBalances[i] * snap.prices[i]) / PRICE_PRECISION;
            totalValue += snap.currentValues[i];
            address tok = _allocations[i].token;
            cachedPrice[tok] = snap.prices[i];
            cachedPriceUpdatedAt[tok] = nowTs;
        }
        emit PricesRefreshed(nowTs);
        // Include any asset balance already held (e.g. from previous partial rebalances).
        totalValue += IERC20(asset).balanceOf(address(this));

        // 2. Sell overweight positions.
        uint256 swapsExecuted;
        for (uint256 i; i < len; ++i) {
            if (_sellOverweight(i, totalValue, snap.currentValues[i], snap.prices[i])) ++swapsExecuted;
        }

        // 3. Buy underweight positions with available asset.
        for (uint256 i; i < len; ++i) {
            if (_buyUnderweight(i, totalValue, snap.currentValues[i], snap.prices[i])) ++swapsExecuted;
        }

        // 4. Update stored token amounts and snapshot post-balances.
        uint256[] memory newBalances = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 bal = IERC20(_allocations[i].token).balanceOf(address(this));
            _allocations[i].tokenAmount = bal;
            newBalances[i] = bal;
        }

        _rebalancing = false;
        emit RebalancedDelta(
            snap.tokens, snap.oldWeights, snap.newWeights, snap.oldBalances, newBalances, totalValue, swapsExecuted
        );
    }

    /// @dev Capture the pre-rebalance state of every allocation. Returns a
    ///      fully-formed snapshot — every array field is allocated even when
    ///      the price/value fields are populated later by the caller, so
    ///      there's no two-phase init footgun.
    function _snapshotAllocations(uint256 len) private view returns (DeltaSnapshot memory snap) {
        snap.tokens = new address[](len);
        snap.oldWeights = new uint256[](len);
        snap.newWeights = new uint256[](len);
        snap.oldBalances = new uint256[](len);
        snap.prices = new uint256[](len);
        snap.currentValues = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            address t = _allocations[i].token;
            uint256 w = _allocations[i].targetWeightBps;
            snap.tokens[i] = t;
            snap.oldWeights[i] = w;
            snap.newWeights[i] = w;
            snap.oldBalances[i] = IERC20(t).balanceOf(address(this));
        }
    }

    /// @dev If allocation `i` is overweight at `currentValue`, sell the
    ///      excess back to the asset using the chainlink-priced floor.
    ///      Returns true when a swap was executed.
    function _sellOverweight(uint256 i, uint256 totalValue, uint256 currentValue, uint256 price)
        private
        returns (bool)
    {
        uint256 targetValue = (totalValue * _allocations[i].targetWeightBps) / BPS_DENOMINATOR;
        if (currentValue <= targetValue) return false;
        uint256 tokensToSell = ((currentValue - targetValue) * PRICE_PRECISION) / price;
        address token = _allocations[i].token;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (tokensToSell > bal) tokensToSell = bal;
        if (tokensToSell == 0) return false;
        IERC20(token).forceApprove(address(swapAdapter), tokensToSell);
        // Apply slippage off the chainlink-priced expectation so an AMM
        // sandwich can't drift output below this floor.
        uint256 minOut =
            (((tokensToSell * price) / PRICE_PRECISION) * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        swapAdapter.swap(token, asset, tokensToSell, minOut, _swapExtraData[i]);
        return true;
    }

    /// @dev If allocation `i` is underweight at `currentValue`, buy the
    ///      deficit (capped at currently-available asset balance). Returns
    ///      true when a swap was executed.
    function _buyUnderweight(uint256 i, uint256 totalValue, uint256 currentValue, uint256 price)
        private
        returns (bool)
    {
        uint256 targetValue = (totalValue * _allocations[i].targetWeightBps) / BPS_DENOMINATOR;
        if (currentValue >= targetValue) return false;
        uint256 deficitValue = targetValue - currentValue;
        uint256 available = IERC20(asset).balanceOf(address(this));
        uint256 amountToSpend = deficitValue > available ? available : deficitValue;
        if (amountToSpend == 0) return false;
        IERC20(asset).forceApprove(address(swapAdapter), amountToSpend);
        uint256 minOut =
            (((amountToSpend * PRICE_PRECISION) / price) * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        uint256 amountOut = swapAdapter.swap(asset, _allocations[i].token, amountToSpend, minOut, _swapExtraData[i]);
        if (amountOut == 0) revert SwapFailed();
        return true;
    }

    // ── Slippage helper ──

    /// @dev Adapter-quote-driven minOut. Adapters with reliable quote() (e.g.
    ///      UniswapSwapAdapter against a real V3 pool) return the expected
    ///      output, off which we apply maxSlippageBps. Adapters whose quote()
    ///      returns 0 or reverts cannot guarantee slippage, so we revert with
    ///      `QuoteUnavailable`. The chainlink-priced `rebalanceDelta` path
    ///      bypasses this helper and computes its floor from signed feeds.
    function _quoteMinOut(address tokenIn, address tokenOut, uint256 amountIn, bytes memory extraData)
        internal
        returns (uint256)
    {
        try swapAdapter.quote(tokenIn, tokenOut, amountIn, extraData) returns (uint256 expected) {
            if (expected == 0) revert QuoteUnavailable();
            return (expected * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        } catch {
            revert QuoteUnavailable();
        }
    }

    // ── Chainlink price verification ──

    function _verifyPrice(bytes calldata signedReport) internal returns (uint256 price) {
        if (chainlinkVerifier == address(0)) revert ZeroAddress();

        bytes memory verifierResponse = IVerifierProxy(chainlinkVerifier).verify(signedReport);
        ChainlinkReport memory report = abi.decode(verifierResponse, (ChainlinkReport));

        if (block.timestamp > report.expiresAt) revert StalePrice();
        if (report.price <= 0) revert InvalidAmount();

        // Chainlink prices are int192 with the report's declared decimals (8 for
        // tokenized stocks, 18 for crypto pairs). The raw oracle units are
        // preserved here; decimal-correct scaling happens in `_positionValue`
        // using the per-allocation `_priceDecimals` declared at init.
        price = uint256(uint192(report.price));
    }

    /// @notice Verify a batch of signed Chainlink Data Streams reports and
    ///         refresh the live-NAV cache. Permissionless — caller pays LINK
    ///         at `verify` time but funds cannot be diverted (only effect is
    ///         cache writes). Designed to be called every ~3 minutes during
    ///         an active proposal so `_positionValue.valid` stays true within
    ///         the `MAX_PRICE_AGE` (5 min) freshness window.
    /// @param  reports Signed Chainlink Data Streams reports, parallel to
    ///                 `_allocations` (same order).
    function refreshPrices(bytes[] calldata reports) external {
        uint256 len = _allocations.length;
        if (reports.length != len) revert LengthMismatch();
        uint256 nowTs = block.timestamp;
        for (uint256 i; i < len; ++i) {
            uint256 price = _verifyPrice(reports[i]);
            address tok = _allocations[i].token;
            cachedPrice[tok] = price;
            cachedPriceUpdatedAt[tok] = nowTs;
        }
        emit PricesRefreshed(nowTs);
    }

    // ── View functions ──

    /// @notice Get all token allocations
    function getAllocations() external view returns (TokenAllocation[] memory) {
        return _allocations;
    }

    /// @notice Number of tokens in the basket
    function allocationCount() external view returns (uint256) {
        return _allocations.length;
    }

    /// @notice Get swap extra data for all tokens
    function getSwapExtraData() external view returns (bytes[] memory) {
        return _swapExtraData;
    }

    /// @notice Per-allocation price-feed decimals declared at init. Off-chain
    ///         keepers / UIs use this to know how to format the cached price.
    function getPriceDecimals() external view returns (uint8[] memory) {
        return _priceDecimals;
    }

    /// @notice Per-allocation token decimals snapshotted at init.
    function getTokenDecimals() external view returns (uint8[] memory) {
        return _tokenDecimals;
    }

    /// @notice Vault asset decimals snapshotted at init.
    function assetDecimals() external view returns (uint8) {
        return _assetDecimals;
    }

    // ── positionValue ──

    /// @inheritdoc BaseStrategy
    /// @dev Live NAV reads cached Chainlink Data Streams prices populated by
    ///      `refreshPrices` (or `rebalanceDelta`). Returns `valid=false` when
    ///      ANY allocation's cache is empty or stale (>`MAX_PRICE_AGE` old) —
    ///      vault then falls back to the async-redeem queue, which is the
    ///      safe default.
    ///
    ///      Decimal scaling (closes punch list D-3 / D-4):
    ///        value_in_asset_decimals
    ///          = balance * price * 10^assetDecimals
    ///            / 10^(tokenDecimals + priceDecimals)
    ///      The per-token `tokenDecimals` and `priceDecimals` are cached at
    ///      init; the vault asset's decimals are cached as `_assetDecimals`.
    function _positionValue() internal view override returns (uint256, bool) {
        uint256 len = _allocations.length;
        uint256 totalAssetValue;
        uint256 nowTs = block.timestamp;
        uint256 assetDec = uint256(_assetDecimals);

        for (uint256 i; i < len; ++i) {
            address token = _allocations[i].token;
            uint256 ts = cachedPriceUpdatedAt[token];
            if (ts == 0 || nowTs - ts > MAX_PRICE_AGE) return (0, false);

            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;

            uint256 price = cachedPrice[token];
            uint256 denom = uint256(_tokenDecimals[i]) + uint256(_priceDecimals[i]);
            uint256 numerator = bal * price;
            if (denom >= assetDec) {
                totalAssetValue += numerator / (10 ** (denom - assetDec));
            } else {
                totalAssetValue += numerator * (10 ** (assetDec - denom));
            }
        }

        // Add any asset balance held on the strategy (already in asset decimals).
        totalAssetValue += IERC20(asset).balanceOf(address(this));
        return (totalAssetValue, true);
    }

    /// @notice Routes a mid-proposal LP deposit across the basket at the
    ///         currently-stored target weights. Vault has already pushed
    ///         `assets` of underlying to this contract before calling here.
    /// @dev    Reuses `_quoteMinOut` so each leg gets adapter-quote-driven
    ///         slippage. Updates `tokenAmount` / `investedAmount` per
    ///         allocation so subsequent rebalances see the new principal.
    ///         Allocations whose post-split share rounds to zero are skipped —
    ///         the residual asset stays on the strategy and is reclaimed at
    ///         settle (or at the next rebalance).
    function _onLiveDeposit(uint256 assets) internal override {
        if (assets == 0) return;
        uint256 len = _allocations.length;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 allocation = (assets * alloc.targetWeightBps) / BPS_DENOMINATOR;
            if (allocation == 0) continue;
            IERC20(asset).forceApprove(address(swapAdapter), allocation);
            uint256 minOut = _quoteMinOut(asset, alloc.token, allocation, _swapExtraData[i]);
            uint256 amountOut = swapAdapter.swap(asset, alloc.token, allocation, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();
            alloc.tokenAmount += amountOut;
            alloc.investedAmount += allocation;
        }
    }
}
