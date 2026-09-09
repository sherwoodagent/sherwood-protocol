// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Chainlink push-feed (AggregatorV3) surface read by `_feedPrice`.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Selectors for the `vault() -> governor() -> tierRegistry()` walk. Declared
///         locally: every hop is a length-checked raw staticcall, never a typed call.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isAdapterAllowed(address adapter) external view returns (bool);
    function isPriceSourceForToken(address token, bytes32 priceSource) external view returns (bool);
}

/**
 * @title PortfolioStrategy
 * @notice Weighted basket of tokens bought on execute, sold on settle. Target weights and
 *         routes are fixed at init, so `rebalanceDelta` trades only price drift. Every swap
 *         floor is the slot's Chainlink push-feed price discounted by `maxSlippageBps`; a feed
 *         older than `MAX_PUSH_PRICE_AGE` reverts.
 *
 *   Batch calls from governor:
 *     Execute: [asset.approve(strategy, totalAmount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 */
contract PortfolioStrategy is BaseStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error InvalidAmount();
    error InvalidWeights();
    error LengthMismatch();
    error TooManyTokens();
    error SwapFailed();
    error StalePrice();
    error InvalidPrice();
    error InvalidSlippage();
    error RoutesFrozen();
    error WeightsFrozen();
    error InvalidPriceDecimals();
    error DuplicateToken(address token);
    error AdapterNotAllowed(address swapAdapter, address registry);
    error PriceSourceNotAllowed(address priceSource, address registry);
    error TierRegistryUnresolved();
    error PriceSourceNotPairedWithToken(address token, bytes32 priceSource, address registry);

    // ── Constants ──
    uint256 public constant MAX_BASKET_SIZE = 20;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Slippage tolerance bounds, at init and on every update.
    uint256 public constant MAX_SLIPPAGE_CEILING_BPS = 1_000;
    uint256 public constant MIN_SLIPPAGE_BPS = 50;
    /// @notice Flat max age of a feed reading on every path: 24h heartbeat + 2h grace.
    uint256 public constant MAX_PUSH_PRICE_AGE = 26 hours;

    // ── Storage (per-clone) ──

    struct TokenAllocation {
        address token;
        uint256 targetWeightBps;
        uint256 tokenAmount;
        uint256 investedAmount;
    }

    address public asset;
    ISwapAdapter public swapAdapter;

    TokenAllocation[] internal _allocations;
    bytes[] internal _swapExtraData;

    uint256 public totalAmount;
    uint256 public maxSlippageBps;

    uint8 internal _assetDecimals;
    uint8[] internal _tokenDecimals;
    /// @dev Declared feed decimals per slot; re-checked live on every read.
    uint8[] internal _priceDecimals;
    /// @dev AggregatorV3 proxy per slot, bound to the slot's token at init.
    address[] internal _feeds;

    // ── Events ──
    event RebalancedDelta(
        address[] tokens,
        uint256[] oldWeights,
        uint256[] newWeights,
        uint256[] oldBalances,
        uint256[] newBalances,
        uint256 totalAssetValue,
        uint256 swapsExecuted
    );

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Portfolio";
    }

    // ── Initialization ──

    /// @dev Init tuple: (asset, swapAdapter, tokens, weightsBps, totalAmount, maxSlippageBps,
    ///      swapExtraData, priceDecimals, feeds).
    function _initialize(bytes calldata data) internal override {
        (
            address asset_,
            address swapAdapter_,
            address[] memory tokens,
            uint256[] memory weightsBps,
            uint256 totalAmount_,
            uint256 maxSlippageBps_,
            bytes[] memory swapExtraData_,
            uint8[] memory priceDecimals_,
            address[] memory feeds_
        ) = abi.decode(data, (address, address, address[], uint256[], uint256, uint256, bytes[], uint8[], address[]));

        if (asset_ == address(0) || swapAdapter_ == address(0)) revert ZeroAddress();
        _requireAllowedAdapter(swapAdapter_);
        if (tokens.length == 0 || tokens.length > MAX_BASKET_SIZE) revert TooManyTokens();
        if (tokens.length != weightsBps.length || tokens.length != swapExtraData_.length) revert LengthMismatch();
        if (tokens.length != priceDecimals_.length || tokens.length != feeds_.length) revert LengthMismatch();
        if (totalAmount_ == 0) revert InvalidAmount();
        if (maxSlippageBps_ < MIN_SLIPPAGE_BPS || maxSlippageBps_ > MAX_SLIPPAGE_CEILING_BPS) revert InvalidSlippage();
        if (_resolveTierRegistry() == address(0)) revert TierRegistryUnresolved();

        uint256 weightSum;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0) || feeds_[i] == address(0)) revert ZeroAddress();
            // 36 is past any Chainlink feed; guards the `10 ** decimals` math.
            if (priceDecimals_[i] > 36) revert InvalidPriceDecimals();
            _requireAllowedPriceSource(feeds_[i]);
            _requirePairedPriceSource(tokens[i], feeds_[i]);
            if (AggregatorV3Interface(feeds_[i]).decimals() != priceDecimals_[i]) revert InvalidPriceDecimals();
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == tokens[i]) revert DuplicateToken(tokens[i]);
            }
            weightSum += weightsBps[i];
            _allocations.push(
                TokenAllocation({token: tokens[i], targetWeightBps: weightsBps[i], tokenAmount: 0, investedAmount: 0})
            );
            _swapExtraData.push(swapExtraData_[i]);
            _tokenDecimals.push(IERC20Metadata(tokens[i]).decimals());
            _priceDecimals.push(priceDecimals_[i]);
            _feeds.push(feeds_[i]);
        }
        if (weightSum != BPS_DENOMINATOR) revert InvalidWeights();

        asset = asset_;
        swapAdapter = ISwapAdapter(swapAdapter_);
        totalAmount = totalAmount_;
        maxSlippageBps = maxSlippageBps_;
        _assetDecimals = IERC20Metadata(asset_).decimals();
    }

    // ── Execute: buy basket tokens ──

    function _execute() internal override {
        _requireAllowedAdapter(address(swapAdapter));
        _requireAllowedPriceSources();

        _pullFromVault(asset, totalAmount);

        uint256 len = _allocations.length;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 allocation = (totalAmount * alloc.targetWeightBps) / BPS_DENOMINATOR;
            if (allocation == 0) continue;

            IERC20(asset).forceApprove(address(swapAdapter), allocation);
            uint256 minOut = _buyFloor(i, allocation);
            uint256 amountOut = swapAdapter.swap(asset, alloc.token, allocation, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

            alloc.tokenAmount = amountOut;
            alloc.investedAmount = allocation;
        }

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
            uint256 minOut = _sellFloor(i, bal);
            uint256 amountOut = swapAdapter.swap(alloc.token, asset, bal, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

            alloc.tokenAmount = 0;
        }

        _pushAllToVault(asset);
    }

    // ── Update params ──

    /// @notice Update: (uint256[] newWeightsBps, uint256 newMaxSlippageBps, bytes[] newSwapExtraData)
    /// @dev Only the tolerance is tunable, and only tighter: a re-targeted basket would let the
    ///      proposer round-trip it at the floor through `rebalanceDelta`. Empty / 0 keeps current.
    function _updateParams(bytes calldata data) internal override {
        (uint256[] memory newWeightsBps, uint256 newMaxSlippageBps, bytes[] memory newSwapExtraData) =
            abi.decode(data, (uint256[], uint256, bytes[]));

        if (newWeightsBps.length > 0) revert WeightsFrozen();
        if (newSwapExtraData.length > 0) revert RoutesFrozen();

        if (newMaxSlippageBps > 0) {
            if (newMaxSlippageBps > maxSlippageBps || newMaxSlippageBps < MIN_SLIPPAGE_BPS) revert InvalidSlippage();
            maxSlippageBps = newMaxSlippageBps;
        }
    }

    // ── Rebalancing ──

    /// @dev Pre-rebalance snapshot, bundled so the legacy pipeline stays under the stack limit.
    struct DeltaSnapshot {
        address[] tokens;
        uint256[] oldWeights;
        uint256[] newWeights;
        uint256[] oldBalances;
        uint256[] prices;
        uint256[] currentValues;
    }

    /// @notice Delta rebalance: price every slot off its feed, swap only the drift away from the
    ///         init weights. Proposer-only, Executed only.
    function rebalanceDelta() external onlyProposer nonReentrant {
        if (_state != State.Executed) revert NotExecuted();
        _requireAllowedAdapter(address(swapAdapter));
        _requireAllowedPriceSources();

        uint256 len = _allocations.length;
        DeltaSnapshot memory snap = _snapshotAllocations(len);

        uint256 totalValue;
        uint256 assetDec = uint256(_assetDecimals);
        for (uint256 i; i < len; ++i) {
            snap.prices[i] = _feedPrice(i);
            snap.currentValues[i] = _tokensToValue(snap.oldBalances[i], snap.prices[i], i, assetDec);
            totalValue += snap.currentValues[i];
        }
        totalValue += IERC20(asset).balanceOf(address(this));

        uint256 swapsExecuted;
        for (uint256 i; i < len; ++i) {
            if (_sellOverweight(i, totalValue, snap.currentValues[i], snap.prices[i])) ++swapsExecuted;
        }
        for (uint256 i; i < len; ++i) {
            if (_buyUnderweight(i, totalValue, snap.currentValues[i])) ++swapsExecuted;
        }

        uint256[] memory newBalances = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 bal = IERC20(_allocations[i].token).balanceOf(address(this));
            _allocations[i].tokenAmount = bal;
            newBalances[i] = bal;
        }

        emit RebalancedDelta(
            snap.tokens, snap.oldWeights, snap.newWeights, snap.oldBalances, newBalances, totalValue, swapsExecuted
        );
    }

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

    /// @dev Sell slot `i`'s excess over its target value at the feed-priced floor.
    function _sellOverweight(uint256 i, uint256 totalValue, uint256 currentValue, uint256 price)
        private
        returns (bool)
    {
        uint256 targetValue = (totalValue * _allocations[i].targetWeightBps) / BPS_DENOMINATOR;
        if (currentValue <= targetValue) return false;
        uint256 assetDec = uint256(_assetDecimals);
        uint256 tokensToSell = _valueToTokens(currentValue - targetValue, price, i, assetDec);
        address token = _allocations[i].token;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (tokensToSell > bal) tokensToSell = bal;
        if (tokensToSell == 0) return false;
        IERC20(token).forceApprove(address(swapAdapter), tokensToSell);
        uint256 minOut = _sellFloor(i, tokensToSell);
        uint256 amountOut = swapAdapter.swap(token, asset, tokensToSell, minOut, _swapExtraData[i]);
        if (amountOut == 0) revert SwapFailed();
        return true;
    }

    /// @dev Buy slot `i`'s deficit under its target value (capped at held asset) at the feed-priced floor.
    function _buyUnderweight(uint256 i, uint256 totalValue, uint256 currentValue) private returns (bool) {
        uint256 targetValue = (totalValue * _allocations[i].targetWeightBps) / BPS_DENOMINATOR;
        if (currentValue >= targetValue) return false;
        uint256 deficitValue = targetValue - currentValue;
        uint256 available = IERC20(asset).balanceOf(address(this));
        uint256 amountToSpend = deficitValue > available ? available : deficitValue;
        if (amountToSpend == 0) return false;
        IERC20(asset).forceApprove(address(swapAdapter), amountToSpend);
        uint256 minOut = _buyFloor(i, amountToSpend);
        uint256 amountOut = swapAdapter.swap(asset, _allocations[i].token, amountToSpend, minOut, _swapExtraData[i]);
        if (amountOut == 0) revert SwapFailed();
        return true;
    }

    // ── Per-allocation dimensional helpers ──

    function _tokensToValue(uint256 balance, uint256 price, uint256 i, uint256 assetDec)
        private
        view
        returns (uint256)
    {
        uint256 denom = uint256(_tokenDecimals[i]) + uint256(_priceDecimals[i]);
        uint256 numerator = balance * price;
        if (denom >= assetDec) {
            return numerator / (10 ** (denom - assetDec));
        }
        return numerator * (10 ** (assetDec - denom));
    }

    function _valueToTokens(uint256 value, uint256 price, uint256 i, uint256 assetDec) private view returns (uint256) {
        uint256 numScale = uint256(_tokenDecimals[i]) + uint256(_priceDecimals[i]);
        if (numScale >= assetDec) {
            return (value * (10 ** (numScale - assetDec))) / price;
        }
        return value / (price * (10 ** (assetDec - numScale)));
    }

    // ── Floors ──

    /// @dev Minimum asset out for selling `bal` of slot `i`: feed value less `maxSlippageBps`.
    function _sellFloor(uint256 i, uint256 bal) private view returns (uint256) {
        uint256 value = _tokensToValue(bal, _feedPrice(i), i, uint256(_assetDecimals));
        return (value * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
    }

    /// @dev Minimum tokens out for spending `amountIn` on slot `i`: feed value less `maxSlippageBps`.
    function _buyFloor(uint256 i, uint256 amountIn) private view returns (uint256) {
        uint256 tokensExpected = _valueToTokens(amountIn, _feedPrice(i), i, uint256(_assetDecimals));
        return (tokensExpected * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
    }

    /// @dev Live feed reading for slot `i`. Reverts on a decimals drift, a non-positive answer,
    ///      or a reading older than `MAX_PUSH_PRICE_AGE`; a future `updatedAt` reads as age 0.
    function _feedPrice(uint256 i) private view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(_feeds[i]);
        if (feed.decimals() != _priceDecimals[i]) revert InvalidPriceDecimals();
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (updatedAt == 0 || age > MAX_PUSH_PRICE_AGE) revert StalePrice();
        return uint256(answer);
    }

    // ── Governance-allowlist binding ──

    /// @dev Skips when the registry is unresolvable so a broken walk never strands `rebalanceDelta`;
    ///      init is fail-closed on resolution separately.
    function _requireAllowedAdapter(address swapAdapter_) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, swapAdapter_)) revert AdapterNotAllowed(swapAdapter_, registry);
    }

    function _requireAllowedPriceSource(address priceSource) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, priceSource)) revert PriceSourceNotAllowed(priceSource, registry);
    }

    /// @dev Attestation key is the bare aggregator address widened to bytes32.
    function _requirePairedPriceSource(address token, address feed) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        bytes32 priceSource = bytes32(uint256(uint160(feed)));
        if (!_isPriceSourceForToken(registry, token, priceSource)) {
            revert PriceSourceNotPairedWithToken(token, priceSource, registry);
        }
    }

    /// @dev Length-checked raw staticcall; a registry without the selector reads as "not attested".
    function _isPriceSourceForToken(address registry, address token, bytes32 priceSource) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeCall(ITierBindingPath.isPriceSourceForToken, (token, priceSource)));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }

    function _requireAllowedPriceSources() private view {
        uint256 len = _feeds.length;
        for (uint256 i; i < len; ++i) {
            _requireAllowedPriceSource(_feeds[i]);
        }
    }

    /// @dev `vault() -> governor() -> tierRegistry()`; `address(0)` when any hop is unreadable.
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
    }

    /// @dev Length-checked raw staticcall; unreadable reads as `false`.
    function _isAdapterAllowed(address registry, address adapter) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeCall(ITierBindingPath.isAdapterAllowed, (adapter)));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }

    /// @dev Codeless target, revert, short return, or dirty upper bits all read as `address(0)`.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
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

    /// @notice Push feed bound to each allocation, in basket order.
    function getFeeds() external view returns (address[] memory) {
        return _feeds;
    }
}
