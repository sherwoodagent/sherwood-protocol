// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {Position} from "../interfaces/IPriceRouter.sol";
import {PositionKinds} from "../libraries/PositionKinds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Chainlink Data Streams verifier proxy interface
interface IVerifierProxy {
    function verify(bytes calldata signedReport) external payable returns (bytes memory verifierResponse);
}

/// @notice Minimal Chainlink push-feed (AggregatorV3) interface. Used in
///         push-feed mode (`chainlinkVerifier == address(0)`) where each
///         `_feedIds[i]` encodes an AggregatorV3 proxy address rather than a
///         Data Streams feed id.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice The hops walked to resolve the governance-owned ERC-20 spot feed
///         registry from this strategy: `vault()` → `factory()` →
///         `priceRouter()` → `adapterOf(ERC20_SPOT)` → `feedOf(token)`.
/// @dev    Declared locally rather than importing the pricing stack: every hop
///         is a length-checked raw staticcall (`_readAddress`), so the strategy
///         takes on no type dependency and no hop can revert into `_initialize`
///         or into a fail-soft view. `feedOf` is declared with only its FIRST
///         return field because the read decodes word 0 alone — the registry's
///         config struct leads with `aggregator`. This interface exists to
///         generate selectors, not to type the responses.
interface IFeedBindingPath {
    function factory() external view returns (address);
    function priceRouter() external view returns (address);
    function adapterOf(bytes32 kind) external view returns (address);
    function feedOf(address token) external view returns (address aggregator);
    function instantCapAssets(address token) external view returns (uint256);
}

/// @notice The hops walked to resolve the governance-owned adapter allowlist
///         from this strategy: `vault()` → `governor()` → `tierRegistry()` →
///         `isAdapterAllowed(spender)`. The SAME registry, reached the same
///         way, that `SyndicateVault._guardBatchCalls` gates the spender of
///         every value-moving ERC-20 selector in a governor batch against.
/// @dev    Declared locally for the same reason as `IFeedBindingPath`: every
///         hop is a length-checked raw staticcall, so the strategy takes on no
///         type dependency and no hop can revert `_initialize`. This interface
///         exists to generate selectors, not to type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isAdapterAllowed(address adapter) external view returns (bool);
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
    /// @notice `_updateParams` was passed a non-empty `swapExtraData`. Routes are
    ///         reviewed with the proposal and frozen once it executes — see the
    ///         rationale in `_updateParams`.
    error RoutesFrozen();
    error QuoteUnavailable();
    error InvalidPriceDecimals();
    /// @notice Feed id missing at init, or report's `feedId` doesn't match
    ///         the slot's declared `_feedIds[i]`.
    error InvalidFeedId();
    error WrongFeedId(uint256 index, bytes32 expected, bytes32 actual);
    /// @notice Push-mode per-slot max-age (upper 96 bits of `_feedIds[i]`) is
    ///         outside `[MIN_PUSH_PRICE_AGE, MAX_PUSH_PRICE_AGE_CAP]`.
    error InvalidPriceAge();
    /// @notice A slot's declared push feed is not the aggregator governance
    ///         registered for that slot's token in the pricing adapter's feed
    ///         registry. Adversary: a proposer declaring an aggregator that
    ///         quotes something other than the token it sits next to — see the
    ///         binding note on `_initialize`.
    error FeedNotRegistered(address token, address declared, address registered);
    /// @notice Basket cannot contain the same token address twice —
    ///         duplicates would double-count balances and inflate live NAV.
    error DuplicateToken(address token);
    /// @notice `withdrawTo` needed a basket sale but no oracle-anchored mark is
    ///         available on-chain (Data Streams mode has no push feed to read).
    error MarkUnavailable();
    /// @notice The unwind could not raise the requested assets within the
    ///         slippage bound — all-or-revert, no partial delivery.
    error InsufficientUnwindProceeds();
    /// @notice The proposer-supplied `swapAdapter_` is not allowlisted in the
    ///         `TierRegistry` the vault's own governor gates batch approvals
    ///         against. Adversary: a proposer naming an address they control as
    ///         the swap adapter, which `_execute` then `forceApprove`s the
    ///         vault's whole capital to — one hop outside the batch guard that
    ///         would otherwise have caught it. See the binding note on
    ///         `_initialize`.
    error AdapterNotAllowed(address swapAdapter, address registry);

    // ── Constants ──
    uint256 public constant MAX_BASKET_SIZE = 20;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Hard ceiling on the swap slippage tolerance, at init and on every
    ///         update (10%). Live baskets run at 100–500 bps, so this bounds the
    ///         parameter well above real use while excluding degenerate settings.
    /// @dev    In PUSH mode this is a real bound on a fair price: every swap
    ///         path floors at the Chainlink mark as well as the adapter quote,
    ///         taking whichever is stronger (`_legMinOut`), and `rebalanceDelta`
    ///         prices off the oracle alone. In DATA STREAMS mode `execute` /
    ///         `settle` / `rebalance` have no on-chain mark to read, so there
    ///         this bounds drift from a same-transaction quote rather than from
    ///         a fair price — see the residual on `_legMinOut`.
    uint256 public constant MAX_SLIPPAGE_CEILING_BPS = 1_000;
    /// @notice Hard floor on the swap slippage tolerance, at init and on every
    ///         update (50 bps). `maxSlippageBps` doubles as the mark-anchored
    ///         `minOut` floor for vault-initiated instant-exit unwinds
    ///         (`_sellForUnwind`), so a value below the venue fee makes every
    ///         unwind unfillable. Adversary: a proposer calling `updateParams`
    ///         with a near-zero slippage to irreversibly brick the instant lane
    ///         while `availableLiquidity` keeps advertising capacity.
    uint256 public constant MIN_SLIPPAGE_BPS = 50;
    uint256 public constant PRICE_PRECISION = 1e18;
    /// @notice Default max staleness for a push-feed `latestRoundData` when a
    ///         slot declares no per-slot age. Robinhood Chainlink push feeds
    ///         heartbeat at 86400s (24h); 2h of grace absorbs sequencer/DON
    ///         jitter → 26h. Equity feeds stop heartbeating outside US market
    ///         hours (observed 77h gaps over holiday weekends) — such slots
    ///         override this via the per-slot packed age (see `_decodePushFeed`).
    uint256 public constant MAX_PUSH_PRICE_AGE = 26 hours;
    /// @notice Bounds for a per-slot push-feed max age packed into `_feedIds[i]`.
    uint256 public constant MIN_PUSH_PRICE_AGE = 1 hours;
    uint256 public constant MAX_PUSH_PRICE_AGE_CAP = 30 days;

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

    /// @dev Cached `decimals()` of the vault asset, read once at init so the
    ///      rebalance decimal-scaling math avoids a per-read external call.
    uint8 internal _assetDecimals;

    /// @dev Cached `decimals()` per allocation, parallel to `_allocations`.
    uint8[] internal _tokenDecimals;

    /// @dev Declared per-allocation Chainlink feed decimals (raw oracle scale).
    ///      Required because Chainlink Data Streams reports for tokenized stocks
    ///      may use 1e8 while crypto pairs use 1e18 — we must not hard-code 1e18.
    uint8[] internal _priceDecimals;

    /// @dev Per-allocation feed identifier. Two modes:
    ///        Data Streams (chainlinkVerifier != 0): the full 32 bytes are the
    ///          expected Data Streams `feedId`; the verifier-decoded report must
    ///          match exactly or `_verifyPrice` reverts, blocking a valid signed
    ///          report for one feed (e.g. WBTC) from being replayed into another
    ///          slot's price (e.g. AAPL).
    ///        Push (chainlinkVerifier == 0): packed as
    ///          `bytes32(uint256(maxAgeSeconds) << 160 | uint160(feedAddress))`.
    ///          The low 160 bits are the AggregatorV3 proxy; the upper 96 bits
    ///          are an OPTIONAL per-slot max staleness in seconds. `0` → default
    ///          `MAX_PUSH_PRICE_AGE`; nonzero must be within
    ///          `[MIN_PUSH_PRICE_AGE, MAX_PUSH_PRICE_AGE_CAP]`. Equity feeds
    ///          don't heartbeat outside market hours, so their slots pack a
    ///          longer age (e.g. 96h) while crypto slots use the default.
    ///
    ///      Proposer-supplied, and in push mode the mark it yields sizes and
    ///      floors every instant-exit unwind — so it is bound to the token by
    ///      `_registeredAggregator` at init AND re-bound on every read in
    ///      `_pushMark`, and published by `getFeedIds()` for review. Adversary:
    ///      see the binding note on `_initialize`.
    bytes32[] internal _feedIds;

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

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Portfolio";
    }

    // ── Initialization ──

    /// @notice Decode: (address asset, address swapAdapter, address chainlinkVerifier,
    ///         address[] tokens, uint256[] weightsBps, uint256 totalAmount,
    ///         uint256 maxSlippageBps, bytes[] swapExtraData, uint8[] priceDecimals,
    ///         bytes32[] feedIds)
    /// @dev    `priceDecimals[i]` declares the raw Chainlink feed scale for
    ///         allocation `i` (typically 8 for tokenized stocks, 18 for crypto
    ///         pairs). Must be ≤ 36 to keep `10**(...)` math safe. Token decimals
    ///         are read once via `IERC20Metadata.decimals()` and cached for the
    ///         rebalance decimal-scaling math.
    ///
    ///         `feedIds[i]` binds each allocation to its expected Chainlink Data
    ///         Streams feed id. Any inbound report whose decoded `feedId` doesn't
    ///         match the per-slot value reverts in `_verifyPrice`. Required to be
    ///         non-zero — the contract cannot enforce binding against a zero
    ///         sentinel.
    ///
    ///         Push mode (`chainlinkVerifier == 0`): `feedIds[i]` packs an
    ///         AggregatorV3 proxy in the low 160 bits and an OPTIONAL per-slot
    ///         max staleness (seconds) in the upper 96 bits —
    ///         `bytes32(uint256(maxAgeSeconds) << 160 | uint160(feed))`. Age 0
    ///         → default `MAX_PUSH_PRICE_AGE`; nonzero must be within
    ///         `[MIN_PUSH_PRICE_AGE, MAX_PUSH_PRICE_AGE_CAP]` (equity feeds go
    ///         stale outside market hours and need a longer bound than crypto).
    ///
    ///         FEED-TO-TOKEN BINDING (push mode). Matching `decimals()` proves
    ///         only that the address is *a* feed, not that it quotes
    ///         `tokens[i]`. The mark `_pushMark` reads from this feed is what
    ///         sizes and floors every leg of an instant-exit unwind
    ///         (`_unwindBasket` / `_sellForUnwind`), and the mark cancels out of
    ///         the `minOut` computation — so a wrong-LOW feed makes the basket
    ///         surrender an unbounded multiple of the stock a fair mark would
    ///         (a minimum-size exit can drain nearly the whole basket), while a
    ///         wrong-HIGH feed reverts every instant exit that
    ///         `availableLiquidity` advertises. Adversary: a proposer who
    ///         declares slot `i`'s feed as some cheap token's aggregator, waits
    ///         for the vault's instant lane to open, and exits into the
    ///         mispriced unwind at the remaining LPs' expense.
    ///
    ///         So each push-mode slot must declare the SAME aggregator
    ///         governance registered for `tokens[i]` in the pricing adapter's
    ///         feed registry — the registry the `PriceRouter` itself prices
    ///         that token with — resolved through
    ///         `vault() → factory() → priceRouter() → adapterOf(ERC20_SPOT)`.
    ///         CONDITIONAL, by exactly one condition: the check is skipped when
    ///         that walk yields no registered aggregator for the token (Lane A
    ///         not wired yet, no ERC-20 spot adapter, or the token not listed),
    ///         because a hard requirement would brick legitimate Lane-B-only
    ///         baskets on vaults whose kind has no adapter. Skipping is safe
    ///         because it is the same condition under which the router prices
    ///         the position `(0, false)`, the vault's lane never opens, and
    ///         `withdrawTo` is therefore never called — the unbound mark is
    ///         inert. Its one residual window, a token listed only AFTER init,
    ///         is closed by re-binding on every read in `_pushMark`.
    ///
    ///         SWAP-ADAPTER BINDING. `swapAdapter_` is proposer input and
    ///         `_execute` `forceApprove`s it the whole of `totalAmount` — the
    ///         vault's capital — from inside the strategy, one hop OUTSIDE the
    ///         governor batch. `SyndicateVault._guardBatchCalls` gates the
    ///         spender of every approve/transfer in the batch against
    ///         `TierRegistry.isAdapterAllowed` and calls that "a complete bound
    ///         on ERC20 exfiltration"; the strategy's own re-approval is the
    ///         hop that bound does not see. Adversary: a proposer naming an
    ///         address they control as the swap adapter and draining the
    ///         approval in a later transaction. So the adapter must be
    ///         allowlisted in the SAME registry, resolved through
    ///         `vault() → governor() → tierRegistry()`.
    ///         CONDITIONAL, by exactly one condition: skipped when that walk
    ///         yields no registry (no `governor()` surface, a governor
    ///         predating the getter, or `tierRegistry() == 0`). Skipping is
    ///         safe and is NOT attacker-forcible: the whole walk starts at
    ///         `vault()`, which the proposer does not supply, so nothing in the
    ///         init calldata can steer it. And that skip condition is exactly
    ///         the condition under which `_guardBatchCalls` disables ITSELF
    ///         ("UNSET REGISTRY: the guard cannot run and the batch is
    ///         unguarded by design") — with no registry the governor batch can
    ///         already approve vault funds to any address, so the strategy's
    ///         re-approval grants nothing that is not already granted. Where
    ///         the registry IS live the requirement is hard: governance must
    ///         allowlist the swap adapter, the same one-line action it already
    ///         performs for the strategy clone itself so the batch's
    ///         `asset.approve(strategy, …)` can pass.
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
            uint8[] memory priceDecimals_,
            bytes32[] memory feedIds_
        ) = abi.decode(
            data, (address, address, address, address[], uint256[], uint256, uint256, bytes[], uint8[], bytes32[])
        );

        if (asset_ == address(0) || swapAdapter_ == address(0)) revert ZeroAddress();
        // Bind the proposer's swap adapter to the governance allowlist before
        // anything else is written (see the swap-adapter binding note above).
        _requireAllowedAdapter(swapAdapter_);
        if (tokens.length == 0 || tokens.length > MAX_BASKET_SIZE) revert TooManyTokens();
        if (tokens.length != weightsBps.length || tokens.length != swapExtraData_.length) revert LengthMismatch();
        if (tokens.length != priceDecimals_.length || tokens.length != feedIds_.length) revert LengthMismatch();
        if (totalAmount_ == 0) revert InvalidAmount();
        // Ceiling, not just a sanity bound — bounds the initial tolerance below
        // 100% so the tighten-only guard in `_updateParams` has room to enforce
        // a monotonic decrease.
        if (maxSlippageBps_ < MIN_SLIPPAGE_BPS || maxSlippageBps_ > MAX_SLIPPAGE_CEILING_BPS) revert InvalidSlippage();

        // Push-feed mode when no Data Streams verifier is wired: each
        // `feedIds[i]` encodes an AggregatorV3 proxy as bytes32(uint160(feed)).
        bool pushMode = chainlinkVerifier_ == address(0);
        // Resolved once, outside the loop: the walk is four staticcalls and the
        // answer is identical for every slot.
        address feedRegistry = pushMode ? _spotFeedRegistry() : address(0);

        uint256 weightSum;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            // 36 ≈ max informally seen across Chainlink feeds; main guard is
            // against bogus calldata that would overflow `10 ** denom` math.
            if (priceDecimals_[i] > 36) revert InvalidPriceDecimals();
            if (feedIds_[i] == bytes32(0)) revert InvalidFeedId();
            if (pushMode) {
                // Decode the aggregator + optional per-slot age, validate the
                // age bounds, and assert the feed's live `decimals()` matches
                // the declared `priceDecimals[i]` — a mismatch would silently
                // mis-scale every value in `rebalanceDelta`.
                (address feed, uint256 age) = _decodePushFeed(feedIds_[i]);
                if (age != MAX_PUSH_PRICE_AGE && (age < MIN_PUSH_PRICE_AGE || age > MAX_PUSH_PRICE_AGE_CAP)) {
                    revert InvalidPriceAge();
                }
                if (AggregatorV3Interface(feed).decimals() != priceDecimals_[i]) revert InvalidPriceDecimals();
                // Bind the feed to the token (see the binding note above).
                // Loud here, fail-soft on read: a mismatch is a proposal that
                // should never have been written, so it dies at creation rather
                // than silently pinning the basket to Lane B months later.
                (address registered,) = _registeredFeed(feedRegistry, tokens[i]);
                if (registered != address(0) && registered != feed) {
                    revert FeedNotRegistered(tokens[i], feed, registered);
                }
            }
            // Rejects duplicate token addresses: a basket like [TSLA, TSLA]
            // aggregates into a single TSLA balance while rebalance math treats
            // each slot as a distinct target weight, corrupting
            // overweight/underweight swap sizing.
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
            _feedIds.push(feedIds_[i]);
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

    /// @dev NOT terminal: an unquotable leg still reverts `QuoteUnavailable`
    ///      here rather than falling back to the mark alone (see `_legMinOut`)
    ///      — a route whose quoter cannot price it has no business receiving
    ///      the vault's capital, and nothing is stranded by refusing to enter.
    function _execute() internal override {
        _pullFromVault(asset, totalAmount);

        address registry = _markRegistry();
        uint256 len = _allocations.length;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 allocation = (totalAmount * alloc.targetWeightBps) / BPS_DENOMINATOR;
            if (allocation == 0) continue;

            IERC20(asset).forceApprove(address(swapAdapter), allocation);
            uint256 minOut = _legMinOut(i, true, allocation, registry, false);
            uint256 amountOut = swapAdapter.swap(asset, alloc.token, allocation, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

            alloc.tokenAmount = amountOut;
            alloc.investedAmount = allocation;
        }

        _pushAllToVault(asset);
    }

    // ── Settle: sell all basket tokens ──

    /// @dev THE terminal unwind — the `terminal` flag on `_legMinOut` is set
    ///      here and nowhere else. A leg whose quote is unavailable falls back
    ///      to the push-feed mark floor instead of reverting the whole
    ///      settlement. Adversary: a proposer who routed a slot through a pool
    ///      they solely LP, and withdraws that liquidity after execute. Routes
    ///      are frozen by `RoutesFrozen`, so they cannot be repointed; without
    ///      the fallback one dead quoter reverts `_settle` forever and the
    ///      vault's capital is hostage to an owner + guardian emergency path.
    function _settle() internal override {
        address registry = _markRegistry();
        uint256 len = _allocations.length;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 bal = IERC20(alloc.token).balanceOf(address(this));
            if (bal == 0) continue;

            IERC20(alloc.token).forceApprove(address(swapAdapter), bal);
            uint256 minOut = _legMinOut(i, false, bal, registry, true);
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

        // TIGHTEN-ONLY: blocks the proposer from raising the slippage tolerance
        // after a proposal was reviewed and executed, then self-settling into a
        // sandwich they control (`settleProposal` is proposer-callable an hour
        // after execute).
        if (newMaxSlippageBps > 0) {
            // Tighten-only, but never below the floor: `maxSlippageBps` is also
            // the mark-anchored unwind `minOut` floor, so a sub-fee value would
            // brick every instant exit irreversibly (raising is disallowed).
            if (newMaxSlippageBps > maxSlippageBps || newMaxSlippageBps < MIN_SLIPPAGE_BPS) revert InvalidSlippage();
            maxSlippageBps = newMaxSlippageBps;
        }

        // Routes are frozen once the proposal executes: the quote half of
        // `_legMinOut` prices the SAME `extraData` route it swaps through, so
        // rewriting the route would move that half of the floor with it, and
        // `maxSlippageBps` can't bound it because the percentage applies to the
        // attacker's own quote. In push mode the mark half of the floor is
        // route-independent and would survive a rewrite; the freeze stays
        // because Data Streams mode has no mark, because the routes are what
        // the guardian review actually reviewed, and because a repointed route
        // is a new venue nobody vouched for. `rebalanceDelta` stays available
        // since its floors come from oracle feeds rather than the route.
        if (newSwapExtraData.length > 0) revert RoutesFrozen();
    }

    // ── Rebalancing ──

    /// @notice Simple rebalance: sell all positions, re-buy at current target weights.
    ///         Proposer-only, Executed state only.
    /// @dev NOT terminal: like `_execute`, an unquotable leg reverts rather
    ///      than falling back to a mark-only floor. `rebalance()` is
    ///      `onlyProposer` with no cooldown — it is the most repeatable of the
    ///      three swap paths and gets the strictest availability requirement,
    ///      and refusing to rebalance strands nothing (`_settle` still exits).
    function rebalance() external onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        if (_rebalancing) revert RebalancingInProgress();
        _rebalancing = true;

        address registry = _markRegistry();
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

        // Sell all positions back to asset
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 bal = IERC20(alloc.token).balanceOf(address(this));
            if (bal == 0) continue;

            IERC20(alloc.token).forceApprove(address(swapAdapter), bal);
            uint256 minOut = _legMinOut(i, false, bal, registry, false);
            swapAdapter.swap(alloc.token, asset, bal, minOut, _swapExtraData[i]);
            alloc.tokenAmount = 0;
            alloc.investedAmount = 0;
        }

        // Re-buy at current target weights
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 allocation = (assetBalance * alloc.targetWeightBps) / BPS_DENOMINATOR;
            if (allocation == 0) continue;

            IERC20(asset).forceApprove(address(swapAdapter), allocation);
            uint256 minOut = _legMinOut(i, true, allocation, registry, false);
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

        // Verify prices and compute current portfolio value, scaling each
        // allocation by `_tokenDecimals[i] + _priceDecimals[i]` against the
        // cached `_assetDecimals` — Chainlink tokenized-stock feeds are 8
        // decimals, so a flat `PRICE_PRECISION` would mis-scale by orders of
        // magnitude and propagate into the target/overweight/underweight math.
        uint256 totalValue;
        uint256 assetDec = uint256(_assetDecimals);
        address registry = _markRegistry();
        for (uint256 i; i < len; ++i) {
            snap.prices[i] = _verifyPrice(i, priceReports[i], registry);
            snap.currentValues[i] = _tokensToValue(snap.oldBalances[i], snap.prices[i], i, assetDec);
            totalValue += snap.currentValues[i];
        }
        // Include any asset balance already held (e.g. from previous partial rebalances).
        totalValue += IERC20(asset).balanceOf(address(this));

        // Sell overweight positions.
        uint256 swapsExecuted;
        for (uint256 i; i < len; ++i) {
            if (_sellOverweight(i, totalValue, snap.currentValues[i], snap.prices[i])) ++swapsExecuted;
        }

        // Buy underweight positions with available asset.
        for (uint256 i; i < len; ++i) {
            if (_buyUnderweight(i, totalValue, snap.currentValues[i], snap.prices[i])) ++swapsExecuted;
        }

        // Update stored token amounts and snapshot post-balances.
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
        uint256 assetDec = uint256(_assetDecimals);
        uint256 tokensToSell = _valueToTokens(currentValue - targetValue, price, i, assetDec);
        address token = _allocations[i].token;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (tokensToSell > bal) tokensToSell = bal;
        if (tokensToSell == 0) return false;
        IERC20(token).forceApprove(address(swapAdapter), tokensToSell);
        // Apply slippage off the chainlink-priced expectation so an AMM
        // sandwich can't drift output below this floor.
        uint256 minOut =
            (_tokensToValue(tokensToSell, price, i, assetDec) * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        swapAdapter.swap(token, asset, tokensToSell, minOut, _swapExtraData[i]);
        return true;
    }

    /// @dev If allocation `i` is underweight at `currentValue`, buy the
    ///      deficit (capped at currently-available asset balance). Returns
    ///      true when a swap was executed. Uses the same per-allocation decimal
    ///      scaling as `_sellOverweight`.
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
        uint256 assetDec = uint256(_assetDecimals);
        uint256 minOut =
            (_valueToTokens(amountToSpend, price, i, assetDec) * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        uint256 amountOut = swapAdapter.swap(asset, _allocations[i].token, amountToSpend, minOut, _swapExtraData[i]);
        if (amountOut == 0) revert SwapFailed();
        return true;
    }

    // ── Per-allocation dimensional helpers ──

    /// @dev Convert `balance` of allocation `i`'s token (in token decimals) at
    ///      `price` (in price decimals) into asset-denominated value (in
    ///      `assetDec` decimals) — the same decimals as
    ///      `IERC20(asset).balanceOf(...)`.
    ///
    ///        value = balance * price / 10^(tokenDec + priceDec - assetDec)
    ///              = balance * price * 10^(assetDec - tokenDec - priceDec)
    ///
    ///      Depending on the sign of `(tokenDec + priceDec) - assetDec`,
    ///      either divide or multiply by the appropriate power of 10.
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

    /// @dev Inverse of `_tokensToValue`. Convert `value` (in asset decimals)
    ///      at `price` (in price decimals) into a count of allocation `i`'s
    ///      tokens (in token decimals).
    ///
    ///        tokens = value * 10^(tokenDec + priceDec - assetDec) / price
    ///               = value * 10^(tokenDec + priceDec) / (price * 10^assetDec)
    ///
    ///      Equivalent rearrangement avoids losing precision when assetDec >
    ///      tokenDec + priceDec by combining the scaling with the division.
    function _valueToTokens(uint256 value, uint256 price, uint256 i, uint256 assetDec) private view returns (uint256) {
        uint256 numScale = uint256(_tokenDecimals[i]) + uint256(_priceDecimals[i]);
        if (numScale >= assetDec) {
            return (value * (10 ** (numScale - assetDec))) / price;
        }
        return value / (price * (10 ** (assetDec - numScale)));
    }

    // ── Slippage helper ──

    /// @dev The `minOut` for one swap leg of allocation `i`, in `tokenOut`
    ///      units. Two INDEPENDENT lower bounds on fair output exist, and the
    ///      floor is the STRONGER (larger) of the two, each already discounted
    ///      by `maxSlippageBps`:
    ///        - the ADAPTER QUOTE through the slot's frozen route;
    ///        - the CHAINLINK PUSH MARK — the same anchor `_sellForUnwind`
    ///          already floors every instant-exit leg at.
    ///
    ///      WHY THE MARK AT ALL. The quote alone is not sandwich protection and
    ///      must not be described as such: it is taken in the same transaction,
    ///      through the same `extraData` route, as the swap it floors, so both
    ///      operands come from one pool state and the bound is self-referential
    ///      — `maxSlippageBps` bounds drift from the attacker's own number, not
    ///      from a fair price. Adversary: `rebalance()` is `onlyProposer` with
    ///      no cooldown and `settleProposal` is proposer-callable an hour after
    ///      execute, so a proposer who moves the route pool first gets a quote
    ///      at the moved price AND a floor derived from it, and the swap clears
    ///      — a repeatable PRIVILEGED extraction, not merely searcher MEV.
    ///
    ///      WHY MAX, NOT MIN. Taking the MINIMUM of the two would leave that
    ///      attack intact: the manipulated quote is the SMALLER number in
    ///      exactly the direction that pays the attacker (on a sell it is the
    ///      pool pushed below the mark; on a buy it is the pool pushed above
    ///      it), so a min-floor still clears. `max` means the pool cannot pull
    ///      the floor below the mark. It is symmetric on the other side too:
    ///      the mark comes from a PROPOSER-declared feed, and where the feed
    ///      registry does not resolve that feed is unbound, so a mark reading
    ///      the wrong way must not be able to pull the floor below the quote
    ///      either. `max` never returns a floor weaker than the one this
    ///      contract enforced before.
    ///
    ///      LIVENESS COST OF MAX OVER A MARK-ONLY FLOOR: none. `quoteFloor` is
    ///      `quote * (1 - maxSlippageBps)` while the pool delivers ~`quote`, so
    ///      the quote term never binds; a leg reverts iff the MARK exceeds the
    ///      executable price by more than `maxSlippageBps` — precisely the
    ///      stale / held-mark regime in which the basket should not be trading,
    ///      and the regime `Erc20SpotAdapter`'s divergence gate exists to close
    ///      on the valuation side. Deployments are expected to set
    ///      `maxSlippageBps` above the registered `maxDivergenceBps` plus the
    ///      venue fee (the same relation `availableLiquidity` documents).
    ///
    ///      DATA STREAMS MODE (`chainlinkVerifier != 0`) has no on-chain mark
    ///      to read — the price only exists inside a signed report the
    ///      `IStrategy` execute/settle signatures cannot carry — so it keeps
    ///      the quote-only floor and keeps the residual above. Push mode is the
    ///      mode that gets the guarantee; `rebalanceDelta` is oracle-anchored
    ///      in both modes.
    /// @param buy      true: asset → token (`amountIn` in asset units, output
    ///                 in token units). false: token → asset. The mark is a
    ///                 TOKEN price, so the two legs invert its application —
    ///                 `_valueToTokens` on the buy, `_tokensToValue` on the
    ///                 sell. Getting this backwards silently inverts the floor.
    /// @param terminal True only on `_settle`. See `_settle` for why the mark
    ///                 alone is accepted there when no quote is available, and
    ///                 `_execute` / `rebalance` for why it is not accepted
    ///                 there. With NEITHER a quote nor a mark the leg reverts
    ///                 on every path including settle: an unfloored `minOut` on
    ///                 a frozen route the proposer chose is a signed blank
    ///                 cheque, strictly worse than a stuck settlement that the
    ///                 owner + guardian emergency path can still resolve.
    function _legMinOut(uint256 i, bool buy, uint256 amountIn, address registry, bool terminal)
        internal
        returns (uint256)
    {
        (uint256 markFloor, bool okMark) = _markFloor(i, buy, amountIn, registry);
        address token = _allocations[i].token;
        (uint256 quoteFloor, bool okQuote) =
            buy ? _quoteFloor(asset, token, amountIn, i) : _quoteFloor(token, asset, amountIn, i);

        if (okQuote) return (okMark && markFloor > quoteFloor) ? markFloor : quoteFloor;
        if (okMark && terminal) return markFloor;
        revert QuoteUnavailable();
    }

    /// @dev Adapter-quote half of `_legMinOut`. An adapter whose `quote()`
    ///      reverts or returns zero cannot bound slippage, so it reports
    ///      unavailable rather than a zero floor — a zero floor is not a weaker
    ///      bound, it is no bound.
    function _quoteFloor(address tokenIn, address tokenOut, uint256 amountIn, uint256 i)
        private
        returns (uint256, bool)
    {
        try swapAdapter.quote(tokenIn, tokenOut, amountIn, _swapExtraData[i]) returns (uint256 expected) {
            if (expected == 0) return (0, false);
            return ((expected * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Chainlink-mark half of `_legMinOut`, in `tokenOut` units. Reuses
    ///      `_pushMark` verbatim — the same feed-to-token re-bind, live decimals
    ///      re-check, positive-answer and per-slot age gauntlet that sizes every
    ///      instant-exit unwind — so there is exactly one definition of "the
    ///      mark" in this contract. Unavailable (Data Streams mode, stale or
    ///      broken feed, rebound failure, or a value that rounds to zero) is
    ///      reported, never substituted with a zero floor.
    function _markFloor(uint256 i, bool buy, uint256 amountIn, address registry) private view returns (uint256, bool) {
        if (chainlinkVerifier != address(0)) return (0, false);
        (uint256 price, bool ok) = _pushMark(i, registry);
        if (!ok) return (0, false);
        uint256 assetDec = uint256(_assetDecimals);
        uint256 expected =
            buy ? _valueToTokens(amountIn, price, i, assetDec) : _tokensToValue(amountIn, price, i, assetDec);
        if (expected == 0) return (0, false);
        return ((expected * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR, true);
    }

    /// @dev The spot feed registry, resolved once per swap path and passed down
    ///      to every `_pushMark` / `_verifyPrice` in that path — the walk is
    ///      four staticcalls and the answer is identical for every slot. Only
    ///      push mode has an on-chain mark to bind, so Data Streams mode skips
    ///      the walk entirely.
    function _markRegistry() private view returns (address) {
        return chainlinkVerifier == address(0) ? _spotFeedRegistry() : address(0);
    }

    /// @dev Decode a push-mode packed feed id into its AggregatorV3 proxy and
    ///      resolved max staleness. Packing:
    ///        `bytes32(uint256(maxAgeSeconds) << 160 | uint160(feedAddress))`.
    ///      A packed age of 0 resolves to the default `MAX_PUSH_PRICE_AGE`.
    function _decodePushFeed(bytes32 packed) private pure returns (address feed, uint256 maxAge) {
        feed = address(uint160(uint256(packed)));
        uint256 age = uint256(packed) >> 160;
        maxAge = age == 0 ? MAX_PUSH_PRICE_AGE : age;
    }

    // ── Feed-to-token binding (see the binding note on `_initialize`) ──

    /// @dev The governance-owned ERC-20 spot feed registry this strategy's
    ///      vault prices through — the adapter the `PriceRouter` itself hands
    ///      `PositionKinds.ERC20_SPOT` positions to — or `address(0)` when any
    ///      hop is unavailable. Unavailable is a legitimate state, not an
    ///      error: a vault with no `factory()`, a factory with Lane A unwired
    ///      (`priceRouter() == 0`), or a router with no spot adapter all mean
    ///      the router cannot price this basket either, so its marks are never
    ///      consumed. Every hop is a raw staticcall so none of them can revert
    ///      `_initialize` or a fail-soft view — a hostile or codeless target
    ///      reads as unavailable, which only ever loses this check, never
    ///      weakens another.
    function _spotFeedRegistry() private view returns (address) {
        address factory_ = _readAddress(vault(), abi.encodeCall(IFeedBindingPath.factory, ()));
        if (factory_ == address(0)) return address(0);
        address router = _readAddress(factory_, abi.encodeCall(IFeedBindingPath.priceRouter, ()));
        if (router == address(0)) return address(0);
        return _readAddress(router, abi.encodeCall(IFeedBindingPath.adapterOf, (PositionKinds.ERC20_SPOT)));
    }

    /// @dev What `registry` has registered against `token`: the aggregator and
    ///      the max staleness governance accepts for it. Both are
    ///      `0`/`address(0)` when the registry is unresolved or the token
    ///      unlisted. Decodes words 0 and 1 of `feedOf`'s return: the
    ///      registry's per-token config is `(aggregator, maxAge, …)`, and the
    ///      public-mapping getter ABI-encodes each field into its own word. A
    ///      future registry that reorders those fields reads as an aggregator
    ///      mismatch — init reverts, Lane A shuts — never as a silent pass; a
    ///      reordered age reads as either a tighter bound (fails closed) or an
    ///      enormous one (no tightening, i.e. the pre-bound behaviour), never
    ///      as a loosening past the slot's own `MAX_PUSH_PRICE_AGE_CAP`.
    function _registeredFeed(address registry, address token) private view returns (address, uint256) {
        if (registry == address(0) || registry.code.length == 0) return (address(0), 0);
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeCall(IFeedBindingPath.feedOf, (token)));
        if (!ok || ret.length < 64) return (address(0), 0);
        uint256 aggregatorWord;
        uint256 maxAgeWord;
        // Reads the leading two return words directly: `abi.decode` cannot
        // express "first two words of a longer payload".
        assembly ("memory-safe") {
            aggregatorWord := mload(add(ret, 0x20))
            maxAgeWord := mload(add(ret, 0x40))
        }
        if (aggregatorWord >> 160 != 0) return (address(0), 0);
        return (address(uint160(aggregatorWord)), maxAgeWord);
    }

    // ── Swap-adapter binding (see the binding note on `_initialize`) ──

    /// @dev Reverts unless `swapAdapter_` is allowlisted in the `TierRegistry`
    ///      the vault's own governor gates batch approvals against, resolved
    ///      `vault() → governor() → tierRegistry()`. Skips only when that walk
    ///      yields no registry — the same condition under which
    ///      `SyndicateVault._guardBatchCalls` disables itself, and one the
    ///      proposer cannot steer because no hop of the walk is proposer input.
    ///      A registry that IS resolved but whose `isAdapterAllowed` is
    ///      unreadable (wrong address wired, non-registry contract) fails
    ///      CLOSED: a registry that cannot vouch for the adapter has not
    ///      vouched for it. Every hop is a length-checked raw staticcall so a
    ///      codeless or hostile target reads as unresolved rather than
    ///      reverting some unrelated deployment.
    function _requireAllowedAdapter(address swapAdapter_) private view {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return;
        address registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, swapAdapter_)) revert AdapterNotAllowed(swapAdapter_, registry);
    }

    /// @dev Staticcall-safe `isAdapterAllowed`. Unreadable → `false` (see the
    ///      fail-closed rationale on `_requireAllowedAdapter`).
    function _isAdapterAllowed(address registry, address adapter) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeCall(ITierBindingPath.isAdapterAllowed, (adapter)));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }

    /// @dev Staticcall-safe address read: codeless target, revert, short
    ///      return, or dirty upper bits all resolve to `address(0)`. The
    ///      length bound is `>=` rather than `==` because `feedOf` returns a
    ///      multi-field config of which only the leading word is read.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        // Reads the first return word directly: `abi.decode` cannot express
        // "leading word of a longer payload".
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    // ── Chainlink price verification ──

    /// @dev The staleness bound actually enforced for a push-mode slot: the
    ///      TIGHTER of the per-slot age the proposer packed into `_feedIds[i]`
    ///      and the `maxAge` governance registered for that token in the spot
    ///      pricing registry. `registeredAge == 0` means the registry is
    ///      unresolved or the token unlisted — no governance opinion exists, so
    ///      the slot's own bound stands.
    ///
    ///      Adversary: the slot's own bound is validated only against
    ///      `[MIN_PUSH_PRICE_AGE, MAX_PUSH_PRICE_AGE_CAP]`, and that cap is 30
    ///      DAYS. There is no oracle-vs-pool divergence check anywhere in this
    ///      contract — that gate lives in `Erc20SpotAdapter` and gates
    ///      valuation, not swaps — so during a stale-mark regime a proposer
    ///      could call `rebalanceDelta` and sell the basket into their own
    ///      frozen route at a month-old mark, pocketing the gap. Deferring to
    ///      the registry (whose own `MAX_FEED_MAX_AGE` is 30 days but which the
    ///      Lane A deploy script pins at 24h) means the mark this contract
    ///      trades on can never be older than the mark the protocol is willing
    ///      to PRICE on, for exactly the tokens it prices.
    ///
    ///      RESIDUAL: a token the registry does not list gets no tightening.
    ///      That token also gets no Lane A — `Erc20SpotAdapter.value` returns
    ///      `(0, false)` for an unlisted venue, so no instant exit and no
    ///      instant deposit can be priced against it — which leaves the stale
    ///      mark able to mis-size an internal rebalance between basket slots
    ///      but not to move value in or out of the vault, and still bounded by
    ///      `MAX_PUSH_PRICE_AGE_CAP`.
    function _boundedMaxAge(uint256 slotAge, uint256 registeredAge) private pure returns (uint256) {
        if (registeredAge == 0 || registeredAge >= slotAge) return slotAge;
        return registeredAge;
    }

    /// @param i             Allocation index — used to check `report.feedId`
    ///                      against the slot's expected feed id.
    /// @param signedReport  LayerZero-style signed Chainlink Data Streams report.
    /// @param registry      Spot feed registry from `_markRegistry()`, resolved
    ///                      once by `rebalanceDelta` and passed down; bounds
    ///                      the push branch's accepted staleness (see
    ///                      `_boundedMaxAge`). Ignored on the Data Streams
    ///                      branch, whose freshness comes from the signed
    ///                      report's own `expiresAt`.
    /// @dev Verifies the report's `feedId` matches the slot's expected id
    ///      before returning the price, so a valid-but-mismatched report
    ///      (e.g. WBTC's report accepted into the AAPL slot) cannot inflate
    ///      cached NAV.
    function _verifyPrice(uint256 i, bytes calldata signedReport, address registry) internal returns (uint256 price) {
        // Push-feed mode: `_feedIds[i]` packs an AggregatorV3 proxy (low 160
        // bits) + an optional per-slot max age (upper 96 bits). No signed
        // report is consumed, so callers must pass empty bytes (a nonempty
        // report would imply a Data Streams path that isn't taken).
        if (chainlinkVerifier == address(0)) {
            if (signedReport.length != 0) revert InvalidFeedId();
            (address feed, uint256 maxAge) = _decodePushFeed(_feedIds[i]);
            // Defer to governance's own staleness bound for this token when one
            // exists — a 30-day slot age must not outlive the age the protocol
            // prices with (see `_boundedMaxAge`).
            (, uint256 registeredAge) = _registeredFeed(registry, _allocations[i].token);
            maxAge = _boundedMaxAge(maxAge, registeredAge);
            // Re-check decimals live every call: a proxy upgrade to a different
            // scale would otherwise silently mis-scale NAV against the init
            // snapshot (mirrors the Data Streams path's per-call feedId bind).
            if (AggregatorV3Interface(feed).decimals() != _priceDecimals[i]) revert InvalidPriceDecimals();
            (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
            if (answer <= 0) revert InvalidAmount();
            if (updatedAt == 0 || block.timestamp - updatedAt > maxAge) revert StalePrice();
            return uint256(answer);
        }

        bytes memory verifierResponse = IVerifierProxy(chainlinkVerifier).verify(signedReport);
        ChainlinkReport memory report = abi.decode(verifierResponse, (ChainlinkReport));

        bytes32 expected = _feedIds[i];
        if (report.feedId != expected) revert WrongFeedId(i, expected, report.feedId);
        if (block.timestamp > report.expiresAt) revert StalePrice();
        if (report.price <= 0) revert InvalidAmount();

        // Chainlink prices are int192 with the report's declared decimals (8 for
        // tokenized stocks, 18 for crypto pairs). The raw oracle units are
        // preserved here; decimal-correct scaling happens in `rebalanceDelta`
        // via `_tokensToValue` using the per-allocation `_priceDecimals`.
        price = uint256(uint192(report.price));
    }

    // ── Lane A surface: positions / availableLiquidity / withdrawTo ──
    //
    // Opt-in overrides of the BaseStrategy Lane B defaults. They add a
    // read/unwind surface only — execute, settle, updateParams, and the two
    // rebalance paths are untouched, and settle remains the sole terminal
    // unwind (spec: portfolio-strategy-lane-a).

    /// @inheritdoc IStrategy
    /// @dev One ERC-20 spot position per basket slot while the basket is held
    ///      (Executed state, no rebalance/unwind in flight); empty before
    ///      execute, after settle, and mid-rebalance. `ref` is empty by
    ///      design: the pricing adapter's governance registry selects the feed
    ///      keyed by the venue token, so there is nothing a locator could add
    ///      except an attack surface (design D2). No value or quantity figures
    ///      are reported — the router reads `balanceOf` at the venue.
    ///      Adversary: a mid-rebalance basket (sell leg done, buy leg pending)
    ///      would price transiently distorted, so `_rebalancing` — also set
    ///      during a `withdrawTo` basket sale — suspends enumeration and Lane A
    ///      fails closed for the duration (design D5).
    function positions() external view override returns (Position[] memory) {
        if (_state != State.Executed || _rebalancing) return new Position[](0);
        uint256 len = _allocations.length;
        // Report the strategy's idle vault-asset balance as a numeraire position
        // (the adapter prices `venue == numeraire` at par) so that value the
        // strategy holds but has not yet returned to the vault — the
        // `_unwindBasket` slippage gross-up residue and `rebalanceDelta`
        // leftovers — is counted in live NAV instead of understating it and
        // letting a mid-proposal Lane A depositor mint against the gap.
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 extra = idle == 0 ? 0 : 1;
        Position[] memory ps = new Position[](len + extra);
        for (uint256 i; i < len; ++i) {
            ps[i] = Position({venue: _allocations[i].token, kind: PositionKinds.ERC20_SPOT, ref: ""});
        }
        if (extra == 1) {
            ps[len] = Position({venue: asset, kind: PositionKinds.ERC20_SPOT, ref: ""});
        }
        return ps;
    }

    /// @inheritdoc IStrategy
    /// @dev Idle vault-asset balance plus a conservative basket estimate: per
    ///      slot, the Chainlink mark value discounted by `maxSlippageBps` —
    ///      the SAME basis `_sellForUnwind` floors each sale at, so what this
    ///      advertises is exactly what `withdrawTo` enforces (the divergence
    ///      gate keeps the executable pool price within `maxDivergenceBps` of
    ///      the mark, and `maxSlippageBps` is set above that plus venue fee).
    ///      Degrades to the idle balance alone whenever the mark cannot be
    ///      trusted: not executed, rebalance/unwind in flight, Data Streams
    ///      mode (no on-chain mark to anchor to), or a stale/broken feed.
    ///
    ///      Deliberately does NOT consult the swap adapter's `quote()`: every
    ///      production `ISwapAdapter.quote` routes into a Uniswap-style
    ///      simulate-and-revert quoter that mutates state, so a staticcall from
    ///      this view always fails and would collapse the whole basket term to
    ///      idle-only in production (invisible under view-quote test mocks).
    ///      Adversary: an overstated figure makes the vault attempt an unwind
    ///      that under-delivers and reverts exits Lane A advertised.
    ///
    ///      DEPTH BOUND. Capacity is additionally capped so no single unwind
    ///      leg exceeds its token's measured DEX depth, published per token by
    ///      the spot pricing registry (`Erc20SpotAdapter.instantCapAssets`).
    ///      `_unwindBasket` sells pro-rata by mark value, so a total sale of
    ///      `g` sells `g * v_i / V` from slot `i` (v_i = that slot's mark
    ///      value, V = the basket's). Keeping every leg inside its cap means
    ///      `g <= V * min_i(cap_i / v_i)`, which is what the loop below
    ///      computes before applying the slippage discount. Adversary: an
    ///      instant exit sized beyond a token's real depth unwinds at a
    ///      slippage the instant-exit fee cannot cover, socializing the gap to
    ///      the LPs who stay. Against a LIVE registry, a slot with no cap has
    ///      no measured depth to justify ANY instant capacity, so it degrades
    ///      the whole basket to idle-only rather than being skipped — skipping
    ///      it would let the pro-rata sale reach an unbounded token anyway.
    ///      When no registry resolves at all, the router cannot price this
    ///      strategy either, so Lane A is shut and the bound is moot. The
    ///      numeraire is exempt: it is the unit of account, realized at par.
    function availableLiquidity() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (_state != State.Executed || _rebalancing) return idle;
        if (chainlinkVerifier != address(0)) return idle;

        uint256 assetDec = uint256(_assetDecimals);
        uint256 len = _allocations.length;
        uint256 totalValue;
        // Largest total basket sale that keeps EVERY leg inside its token's
        // depth cap (see the pro-rata derivation in the natspec above).
        uint256 grossLimit = type(uint256).max;
        address registry = _spotFeedRegistry();
        for (uint256 i; i < len; ++i) {
            address token = _allocations[i].token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            (uint256 price, bool ok) = _pushMark(i, registry);
            if (!ok) return idle;
            uint256 markValue = _tokensToValue(bal, price, i, assetDec);
            if (markValue == 0) continue;
            totalValue += markValue;

            // The numeraire needs no depth bound (it is the unit of account,
            // realized at par).
            if (token == asset) continue;
            // No registry resolved at all (Lane A unwired: no factory, no
            // router, or no ERC20_SPOT adapter) means the router cannot price
            // this strategy either, so Lane A is structurally shut and this
            // figure is never consumed by an instant exit — leave the estimate
            // mark-anchored rather than pretending the basket is illiquid.
            if (registry == address(0)) continue;
            // A registry that IS live but vouches no cap for this token is the
            // dangerous case: `setFeed` requires a nonzero cap, so a zero here
            // means the token is unlisted, or the registered adapter does not
            // publish caps at all. Either way nothing has justified a depth
            // number, and the lane may still be open — fail closed to
            // idle-only rather than advertise an unbounded basket.
            uint256 cap = _instantCapAssets(registry, token);
            if (cap == 0) return idle;
            // Leg i of a sale totalling `g` is `g * markValue / totalValue`,
            // so `g <= totalValue * (cap / markValue)` keeps it inside the cap.
            // Clamped at 1e18 (the whole basket) so the later multiply cannot
            // overflow on a slot whose cap dwarfs its current value.
            uint256 ratio = (cap * 1e18) / markValue;
            if (ratio > 1e18) ratio = 1e18;
            if (ratio < grossLimit) grossLimit = ratio;
        }
        if (totalValue == 0) return idle;

        // grossLimit is min_i(cap_i / v_i) in 1e18 fixed point, clamped to 1e18.
        uint256 gross = grossLimit >= 1e18 ? totalValue : (totalValue * grossLimit) / 1e18;
        return idle + (gross * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
    }

    /// @dev Per-token instant-exit depth cap from the spot pricing registry, in
    ///      vault-asset units; `0` when the registry is unresolved or the token
    ///      is unlisted. Staticcall-safe: `availableLiquidity` is consumed
    ///      inside `SyndicateVault.maxWithdraw`, so an unreadable registry must
    ///      degrade capacity, never revert the vault's view.
    function _instantCapAssets(address registry, address token) private view returns (uint256) {
        if (registry == address(0) || registry.code.length == 0) return 0;
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeCall(IFeedBindingPath.instantCapAssets, (token)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @inheritdoc IStrategy
    /// @dev All-or-revert shortfall unwind for the vault's instant-exit path:
    ///      idle balance first, then pro-rata (by current mark value) basket
    ///      sales, then transfer exactly `assets` to the vault in the same
    ///      transaction. Pro-rata keeps basket weights unchanged by exits so
    ///      an instant exit does not silently re-tilt the remaining LPs'
    ///      portfolio (design D4). Each sale enforces `maxSlippageBps` against
    ///      the slot's Chainlink push-feed mark — NOT against the adapter's
    ///      own quote — so a searcher who moves the pool cannot move the floor
    ///      with it. Routes are the frozen per-slot `_swapExtraData`.
    ///      Adversary: an unwind that silently under-delivers strands the exit
    ///      at the vault's balance-diff check; the proceeds check below reverts
    ///      first, and any raise beyond `assets` stays idle in the strategy
    ///      (returned to the vault at settle).
    function withdrawTo(uint256 assets) external override onlyVault {
        if (assets == 0) revert InvalidAmount();
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (idle < assets) {
            _unwindBasket(assets - idle);
            if (IERC20(asset).balanceOf(address(this)) < assets) revert InsufficientUnwindProceeds();
        }
        _pushToVault(asset, assets);
    }

    /// @dev Sell basket tokens pro-rata by current mark value to raise at least
    ///      `shortfall` of the asset. Sets `_rebalancing` for the duration so a
    ///      reentrant `positions()` / `availableLiquidity()` read (e.g. via the
    ///      swap adapter) sees Lane A closed rather than a half-sold basket,
    ///      and so a reentrant rebalance is locked out. The gross-up by
    ///      `maxSlippageBps` sizes the sale so the per-leg floors sum to at
    ///      least `shortfall` even if every leg fills exactly at its floor.
    function _unwindBasket(uint256 shortfall) private {
        if (_state != State.Executed) revert NotExecuted();
        if (_rebalancing) revert RebalancingInProgress();
        if (chainlinkVerifier != address(0)) revert MarkUnavailable();
        _rebalancing = true;

        uint256 len = _allocations.length;
        uint256 assetDec = uint256(_assetDecimals);
        uint256[] memory prices = new uint256[](len);
        uint256[] memory values = new uint256[](len);
        uint256 totalValue;
        address registry = _spotFeedRegistry();
        for (uint256 i; i < len; ++i) {
            uint256 bal = IERC20(_allocations[i].token).balanceOf(address(this));
            if (bal == 0) continue;
            (uint256 price, bool ok) = _pushMark(i, registry);
            // Loud here (vs the fail-closed views): the vault only calls in
            // with an exit in flight, and a silent skip would under-deliver.
            if (!ok) revert StalePrice();
            prices[i] = price;
            values[i] = _tokensToValue(bal, price, i, assetDec);
            totalValue += values[i];
        }
        if (totalValue == 0) revert InsufficientUnwindProceeds();

        uint256 grossTarget = (shortfall * BPS_DENOMINATOR) / (BPS_DENOMINATOR - maxSlippageBps) + 1;
        for (uint256 i; i < len; ++i) {
            if (values[i] == 0) continue;
            uint256 sellValue = (grossTarget * values[i]) / totalValue + 1;
            if (sellValue > values[i]) sellValue = values[i];
            _sellForUnwind(i, sellValue, prices[i], assetDec);
        }

        _rebalancing = false;
    }

    /// @dev One unwind leg: sell `sellValue` (asset units) of allocation `i`
    ///      with the minOut floored at the Chainlink mark less `maxSlippageBps`.
    ///      Extracted so the legacy (no via_ir) coverage pipeline doesn't trip
    ///      stack-too-deep, mirroring `_sellOverweight`.
    function _sellForUnwind(uint256 i, uint256 sellValue, uint256 price, uint256 assetDec) private {
        address token = _allocations[i].token;
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 tokensToSell = _valueToTokens(sellValue, price, i, assetDec);
        if (tokensToSell > bal) tokensToSell = bal;
        if (tokensToSell == 0) return;
        IERC20(token).forceApprove(address(swapAdapter), tokensToSell);
        uint256 minOut =
            (_tokensToValue(tokensToSell, price, i, assetDec) * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        swapAdapter.swap(token, asset, tokensToSell, minOut, _swapExtraData[i]);
        _allocations[i].tokenAmount = IERC20(token).balanceOf(address(this));
    }

    /// @dev Non-reverting push-feed mark for allocation `i`: `(price, ok)` in
    ///      the slot's declared `_priceDecimals[i]`. Mirrors `_verifyPrice`'s
    ///      push branch (live decimals re-check, positive answer, per-slot max
    ///      age) but fails soft so view callers can degrade instead of revert.
    ///      Only meaningful in push mode; callers gate on
    ///      `chainlinkVerifier == address(0)`.
    /// @param registry The spot feed registry from `_spotFeedRegistry()`,
    ///        resolved once by the caller and passed down (identical for every
    ///        slot, four staticcalls to resolve).
    /// @dev Re-binds the feed to the token on every read, closing the two
    ///      windows the init-time bind cannot see: a token listed in the
    ///      registry only AFTER this strategy was initialized, and an
    ///      aggregator rotated under a live basket. Both would leave the mark
    ///      that sizes an unwind diverging from the one the router prices the
    ///      very same position with. Fails soft in the same direction as every
    ///      other doubt here — Lane A shuts, the async queue stays open.
    /// @dev Also bounds the slot's per-slot staleness by the one governance
    ///      registered for the token (see `_boundedMaxAge`).
    function _pushMark(uint256 i, address registry) private view returns (uint256, bool) {
        (address feed, uint256 maxAge) = _decodePushFeed(_feedIds[i]);
        (address registered, uint256 registeredAge) = _registeredFeed(registry, _allocations[i].token);
        if (registered != address(0) && registered != feed) return (0, false);
        maxAge = _boundedMaxAge(maxAge, registeredAge);
        try AggregatorV3Interface(feed).decimals() returns (uint8 dec) {
            if (dec != _priceDecimals[i]) return (0, false);
        } catch {
            return (0, false);
        }
        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return (0, false);
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > maxAge) return (0, false);
            return (uint256(answer), true);
        } catch {
            return (0, false);
        }
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

    /// @notice Per-allocation feed id exactly as the proposer declared it,
    ///         parallel to `getAllocations()`. Data Streams mode: the expected
    ///         report `feedId`. Push mode: the packed
    ///         `maxAgeSeconds << 160 | aggregator` (decode with
    ///         `address(uint160(uint256(id)))` and `uint256(id) >> 160`).
    /// @dev    The oracle side of the basket is the one input a proposer
    ///         supplies that the rest of the contract cannot re-derive, and in
    ///         push mode it sets the mark that sizes every instant-exit unwind.
    ///         Adversary: a proposer sneaking a feed that quotes something
    ///         other than the token beside it. The binding check on
    ///         `_initialize` rejects that on-chain; this getter is what lets a
    ///         guardian, a monitor, or an off-chain coverage check
    ///         SEE the declared feed rather than take the check on faith —
    ///         including for the slots the bind deliberately skips (token not
    ///         yet in the registry) and for the whole Data Streams mode, where
    ///         there is no on-chain registry to bind against at all.
    function getFeedIds() external view returns (bytes32[] memory) {
        return _feedIds;
    }

    /// @notice Vault asset decimals snapshotted at init.
    function assetDecimals() external view returns (uint8) {
        return _assetDecimals;
    }
}
