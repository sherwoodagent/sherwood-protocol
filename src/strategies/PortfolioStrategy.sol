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

/// @notice The hops walked to resolve the governance-owned adapter allowlist from
///         this strategy: `vault()` -> `governor()` -> `tierRegistry()` ->
///         `isAdapterAllowed(spender)`. The SAME registry, reached the same way,
///         that `SyndicateVault._guardBatchCalls` gates batch approvals against.
/// @dev    Declared locally rather than imported: every hop is a length-checked
///         raw staticcall, so the strategy takes on no type dependency and no hop
///         can revert `_initialize`. This exists to generate selectors, not to
///         type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isAdapterAllowed(address adapter) external view returns (bool);
    function isPriceSourceForToken(address token, bytes32 priceSource) external view returns (bool);
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
    /// @notice `rebalance` / `rebalanceDelta` would push `cumulativeDecayBps`
    ///         past `MAX_CUMULATIVE_DECAY_BPS`. The clone has spent its
    ///         lifetime slippage allowance; `settle()` is unaffected.
    error DecayBudgetExhausted();
    error StalePrice();
    error InvalidSlippage();
    /// @notice `_updateParams` was passed a non-empty `swapExtraData`. Routes are
    ///         reviewed with the proposal and frozen once it executes — see the
    ///         rationale in `_updateParams`.
    error RoutesFrozen();
    error QuoteUnavailable();
    /// @notice Data Streams mode was paired with a swap adapter whose `quote()`
    ///         returns 0 or reverts. In that mode `_sellFloor`/`_buyFloor` never
    ///         reach an oracle at `execute()`/`settle()` (neither carries report
    ///         calldata), so the adapter quote is the ONLY floor source on every
    ///         call — and `_quoteMinOut` reverts when it is unavailable, from
    ///         inside the `try` block's SUCCESS branch where its own `catch`
    ///         cannot absorb it. `settle()` is the only non-emergency exit and
    ///         `unstick` replays the identical batch, so the pairing wedges the
    ///         proposal in `Executed` permanently. Rejected at bind time, where it
    ///         costs a re-proposal, rather than at settle time, where it costs the
    ///         vault its liquidity. Push mode is unaffected.
    error AdapterCannotQuoteInDataStreamsMode(address swapAdapter);
    error InvalidPriceDecimals();
    /// @notice Feed id missing at init, or report's `feedId` doesn't match
    ///         the slot's declared `_feedIds[i]`.
    error InvalidFeedId();
    error WrongFeedId(uint256 index, bytes32 expected, bytes32 actual);
    /// @notice Push-mode per-slot max-age (upper 96 bits of `_feedIds[i]`) is
    ///         outside `[MIN_PUSH_PRICE_AGE, MAX_PUSH_PRICE_AGE_CAP]`.
    error InvalidPriceAge();
    /// @notice Basket cannot contain the same token address twice —
    ///         duplicates would double-count balances and inflate live NAV.
    error DuplicateToken(address token);
    /// @notice The proposer-supplied `swapAdapter_` is not allowlisted in the
    ///         `TierRegistry` the vault's own governor gates batch approvals
    ///         against. Adversary: a proposer naming an address they control as
    ///         the swap adapter, which `_execute` then `forceApprove`s the vault's
    ///         whole capital to — one hop outside the batch guard.
    error AdapterNotAllowed(address swapAdapter, address registry);
    /// @notice The proposer-supplied Chainlink price source — the Data Streams
    ///         verifier, or a push-mode per-slot aggregator — is not allowlisted
    ///         in the same `TierRegistry` the swap adapter is bound against.
    ///         Adversary: a proposer wiring a price source they control, then
    ///         using `updateParams` to re-weight a holding to 0% and authorizing
    ///         `rebalanceDelta` to sell it against a floor scaled to a fabricated
    ///         price.
    error PriceSourceNotAllowed(address priceSource, address registry);
    /// @notice The tier registry could not be resolved through
    ///         `vault() → governor() → tierRegistry()` at initialization.
    /// @dev    Init-only. Rebalance and settle deliberately keep degrading
    ///         open on an unresolvable registry — see the block comment in
    ///         `_initialize` for why the balance inverts here.
    error TierRegistryUnresolved();
    /// @notice The price source for a basket slot is allowlisted, but is not
    ///         governance-attested to price THAT slot's token. Adversary: a
    ///         proposer pairing a valuable token with a cheap asset's feed so
    ///         the slot's minimum-output floor is derived from the wrong
    ///         reference and every slippage check still passes.
    error PriceSourceNotPairedWithToken(address token, bytes32 priceSource, address registry);

    // ── Constants ──
    uint256 public constant MAX_BASKET_SIZE = 20;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Hard ceiling on the swap slippage tolerance, at init and on every
    ///         update (10%). Live baskets run at 100-500 bps.
    /// @dev    NOT sandwich protection on its own: `_quoteMinOut` measures against
    ///         a quote taken in the same transaction as the swap, so this bounds
    ///         drift from that quote, not from a fair price. The oracle-anchored
    ///         floors are `rebalanceDelta` and, in push mode,
    ///         `_sellFloor`/`_buyFloor`.
    uint256 public constant MAX_SLIPPAGE_CEILING_BPS = 1_000;
    /// @notice Hard floor on the swap slippage tolerance (50 bps).
    /// @dev    `rebalanceDelta` floors its `minOut` against signed Chainlink
    ///         reports discounted by `maxSlippageBps`, so a tolerance below the
    ///         venue fee plus oracle-vs-pool basis makes every delta swap
    ///         structurally unfillable. Combined with the tighten-only rule in
    ///         `_updateParams`, a too-low value would be irreversible for the
    ///         strategy's lifetime — this floor turns a permanent self-brick into
    ///         a rejected input.
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
    /// @notice Slippage band applied when a floor is anchored to a STALE
    ///         last-good oracle price rather than a live one (pashov review
    ///         finding #4). Wider than `maxSlippageBps` because the anchor may
    ///         predate a genuine move — equity feeds stop heartbeating outside
    ///         US market hours (see `MAX_PUSH_PRICE_AGE`) — but still an
    ///         attacker-independent number, which is the whole point: the old
    ///         fallback derived its floor from a quote taken against the very
    ///         pool the swap was about to hit, so the bound moved with the
    ///         attacker. This is the band at the instant the anchor is taken;
    ///         it widens with the anchor's age, see `STALE_WIDEN_PERIOD`.
    uint256 public constant STALE_PRICE_SLIPPAGE_BPS = MAX_SLIPPAGE_CEILING_BPS;
    /// @notice Ceiling the stale band widens to (PR #195 re-review).
    ///
    ///         A FIXED 1,000 BPS BAND CANNOT TELL A MANIPULATION FROM A GAP.
    ///         The stale anchor is a price this contract observed, so it does
    ///         not move with an attacker — but it also does not move with the
    ///         MARKET, and `_sellFloor` sits on `_settle()`, the only exit. A
    ///         feed outage of the length this contract's own
    ///         `MAX_PUSH_PRICE_AGE` documents as routine ("77h gaps over
    ///         holiday weekends") coinciding with a genuine move past the band
    ///         — an earnings gap on an equity — made every swap revert on its
    ///         floor, stranding the vault's capital for the length of the
    ///         outage. That is the fail-closed outcome finding #4's fix
    ///         explicitly set out to avoid, reached by a different route.
    ///
    ///         Widening linearly in the ANCHOR'S AGE separates the two cases on
    ///         the axis that actually distinguishes them. A pool manipulated in
    ///         the settle transaction is judged against a fresh anchor and a
    ///         near-`STALE_PRICE_SLIPPAGE_BPS` band, which is what rejects it;
    ///         a week-long outage earns the full ceiling. The ceiling stays
    ///         well below `BPS_DENOMINATOR`, so the floor never degenerates to
    ///         zero and the anchor never stops binding — an attacker who waits
    ///         out the whole ramp still cannot take more than 30%, against the
    ///         unbounded take the pre-fix quote-anchored floor allowed.
    ///
    ///         THE RESIDUAL, stated so it reads as a decision (pashov 2026-08
    ///         finding #25). `settleProposal` is proposer-callable one hour
    ///         after execute, so a proposer who simply lets the anchor age can
    ///         self-settle the basket up to 30% below its last observed oracle
    ///         price with `minOut` still satisfied. That is real and it is
    ///         accepted, because every way of removing it is worse:
    ///
    ///           - Tightening this ceiling re-creates the exact wedge the ramp
    ///             was introduced to remove. A genuine move beyond the new
    ///             ceiling while the feed is stale makes the adapter revert on
    ///             `minOut`, which reverts `_settle`, which reverts BOTH
    ///             `settleProposal` and `unstick` — pinning the proposal in
    ///             `Executed` with redemptions locked, recoverable only through
    ///             the owner-multisig emergency path. The file's own
    ///             `MAX_PUSH_PRICE_AGE` note documents 77h equity-feed gaps as
    ///             routine, so that is not a tail case.
    ///           - Making the band depend on WHO is settling would put a
    ///             caller-dependent floor on the exit path, which nothing else
    ///             here does, and the proposer is exactly the party who must be
    ///             able to settle when a keeper will not.
    ///
    ///         What bounds it instead: the anchor still binds (30% is not
    ///         unbounded), the ramp is linear in age so a manipulated pool in
    ///         the settle transaction is judged against a NEAR-FRESH anchor,
    ///         and `strategyDuration` plus guardian review of the route sit
    ///         upstream. Since finding #14, the widened band also applies ONLY
    ///         to the exit — `rebalance()` caps at `maxSlippageBps` — so this
    ///         is the price of keeping the one mandatory path alive, and
    ///         nothing else pays it.
    uint256 public constant MAX_STALE_SLIPPAGE_BPS = 3_000;
    /// @notice Span of anchor staleness over which the band ramps from
    ///         `STALE_PRICE_SLIPPAGE_BPS` to `MAX_STALE_SLIPPAGE_BPS`. Sized
    ///         past the longest documented equity-feed gap so an ordinary
    ///         holiday weekend lands mid-ramp rather than at the ceiling.
    uint256 public constant STALE_WIDEN_PERIOD = 7 days;
    /// @notice Ceiling on `cumulativeDecayBps` across a clone's whole life
    ///         (pashov review finding #9).
    ///
    ///         WHAT IS METERED IS THE ALLOWANCE, NOT THE REALIZED LOSS. Each
    ///         `rebalance` is charged `2 * maxSlippageBps` (a sell leg and a
    ///         re-buy leg, each permitted to land that far below the
    ///         oracle-implied value) and each `rebalanceDelta` one leg's worth.
    ///         That is the worst case, so an honest rebalance that clears at
    ///         mid is over-charged — deliberate, because the alternative is
    ///         valuing the whole basket on every call, and the quantity that
    ///         actually needed bounding is the ALLOWANCE: it composed
    ///         multiplicatively (`1-(1-s)^2N`) over an unlimited call count.
    ///
    ///         WHAT THE BOUND ACTUALLY IS, and why this number moved. A leg
    ///         costs its own `maxSlippageBps` and compounds at that rate, so
    ///         with a budget `B` the reachable loss is
    ///         `1 - (1 - s)^(B/s) ~= 1 - e^(-B/10000)` for ANY setting of `s`.
    ///         That invariance is the point: lowering `maxSlippageBps` buys
    ///         more calls that each bite proportionally less, so a proposer
    ///         cannot pick a slippage figure that games the cap.
    ///
    ///         It follows that the budget IS the drain ceiling, in one number.
    ///         The first cut shipped 5,000 bps, which reads like a hard limit
    ///         but resolves to `1 - e^-0.5 ~= 39%` of the basket — enough that
    ///         describing it as cutting off the traced drains (~62% in ten
    ///         calls at 500 bps, ~50% in seventy at 50 bps) overstated what one
    ///         constant was carrying. 2,000 bps puts the ceiling at
    ///         `1 - e^-0.2 ~= 18%`.
    ///
    ///         THE COST IS HEADROOM, AND IT IS REAL. At the shipped 500 bps
    ///         allowance this is two full round trips over the clone's whole
    ///         life (four `rebalanceDelta` calls, which are charged one leg
    ///         rather than two); at the `MIN_SLIPPAGE_BPS` floor it is twenty
    ///         round trips. A strategy that expects to rebalance often should
    ///         be initialized nearer the slippage floor, where the budget buys
    ///         an order of magnitude more calls for the same 18% ceiling.
    ///
    ///         Exhaustion is not a brick: `settle()` never consults this meter,
    ///         so the exit path stays open, and 18% still wants the
    ///         `strategyDuration` and adapter allowlist doing their share.
    ///
    ///         CALL BUDGET AFTER PER-LEG BILLING (pashov 2026-08 finding #20).
    ///         `rebalanceDelta` used to bill one leg per call however many legs
    ///         traded; it now bills each leg that ran, which is what
    ///         `rebalance()` always did. The constant was NOT re-sized, so the
    ///         lifetime call count for a two-sided delta rebalance halves:
    ///
    ///           maxSlippageBps  50 -> 20 calls    (was 40)
    ///                          200 ->  5 calls    (was 10)
    ///                        1_000 ->  1 call     (was 2)
    ///
    ///         AT THE `MAX_SLIPPAGE_CEILING_BPS` CEILING THAT IS EXACTLY ONE
    ///         two-sided delta rebalance per clone, and every later call
    ///         reverts `DecayBudgetExhausted`. Deliberate, not an oversight: a
    ///         proposal that reserved the right to lose 10% per leg has spent
    ///         the entire 18% lifetime allowance the moment it uses it twice,
    ///         and the budget is a cap on REACHABLE LOSS rather than on
    ///         activity. Raising the constant to restore the old call count
    ///         would raise that reachable loss by the same factor, which is the
    ///         thing the cap exists to bound.
    ///
    ///         A proposal that wants many rebalances asks for a tighter
    ///         `maxSlippageBps`, which is also the direction that makes each
    ///         one cheaper. Unlike the withdrawn finding #14 change, nothing
    ///         here reverts on the FIRST call at any legal parameterisation.
    uint256 public constant MAX_CUMULATIVE_DECAY_BPS = 2_000;

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

    /// @dev Last price a push feed successfully returned for allocation `i`, in
    ///      that slot's declared `_priceDecimals` scale. Written by
    ///      `_sellFloor` / `_buyFloor` whenever `_tryPushFeedPrice` reports
    ///      `ok`, and read by those same two when it does not (pashov review
    ///      finding #4). Zero means "this slot has never been priced" — the
    ///      only case still degrading to the quote-anchored floor.
    mapping(uint256 allocationIndex => uint256 priceInFeedScale) private _lastGoodPrice;

    /// @dev `block.timestamp` at which `_lastGoodPrice[i]` was recorded, written
    ///      in lockstep with it at every site (PR #195 re-review). The stale
    ///      band is a function of this age — see `MAX_STALE_SLIPPAGE_BPS` — so
    ///      an anchor and its age must never diverge. Zero exactly when
    ///      `_lastGoodPrice[i]` is zero, i.e. the slot has never been priced.
    mapping(uint256 allocationIndex => uint256 recordedAt) private _lastGoodAt;

    /// @notice Running sum, in bps, of oracle-valued NAV given up across every
    ///         `rebalance` / `rebalanceDelta` on this clone (pashov review
    ///         finding #9). `maxSlippageBps` bounds ONE swap; nothing bounded
    ///         the NUMBER of full-notional round trips, so the per-call
    ///         allowance composed multiplicatively over an unlimited call count
    ///         for the whole `strategyDuration`. Checked against
    ///         `MAX_CUMULATIVE_DECAY_BPS`.
    uint256 public cumulativeDecayBps;

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
    ///        Data Streams (`chainlinkVerifier != 0`): the full 32 bytes are the
    ///          expected `feedId`; the verifier-decoded report must match exactly
    ///          or `_verifyPrice` reverts, so a valid signed report for one feed
    ///          cannot be replayed into another slot's price.
    ///        Push (`chainlinkVerifier == 0`): packed as
    ///          `bytes32(uint256(maxAgeSeconds) << 160 | uint160(feedAddress))`.
    ///          The low 160 bits are the AggregatorV3 proxy; the upper 96 bits are
    ///          an OPTIONAL per-slot max staleness. Zero means the default;
    ///          nonzero must be within `[MIN_PUSH_PRICE_AGE,
    ///          MAX_PUSH_PRICE_AGE_CAP]`. Equity feeds do not heartbeat outside
    ///          market hours, so their slots pack a longer age.
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

    /// @notice Decode: (address asset, address swapAdapter, address
    ///         chainlinkVerifier, address[] tokens, uint256[] weightsBps, uint256
    ///         totalAmount, uint256 maxSlippageBps, bytes[] swapExtraData, uint8[]
    ///         priceDecimals, bytes32[] feedIds)
    /// @dev    `priceDecimals[i]` declares the raw Chainlink feed scale for
    ///         allocation `i`. Must be <= 36 to keep the `10**(...)` math safe.
    ///         Token decimals are read once and cached. `feedIds[i]` binds each
    ///         allocation to its expected feed — see that field's own doc for the
    ///         two encodings.
    ///
    ///         SWAP-ADAPTER BINDING. `swapAdapter_` is proposer input and
    ///         `_execute` `forceApprove`s it the whole of `totalAmount` from
    ///         inside the strategy, one hop OUTSIDE the governor batch.
    ///         `_guardBatchCalls` gates the spender of every approve/transfer in
    ///         the batch against `TierRegistry.isAdapterAllowed`; the strategy's
    ///         own re-approval is the hop that bound does not see. So the adapter
    ///         must be allowlisted in the SAME registry, resolved through
    ///         `vault() -> governor() -> tierRegistry()`.
    ///
    ///         CONDITIONAL, by exactly one condition: skipped when that walk
    ///         yields no registry. Skipping is safe and NOT attacker-forcible —
    ///         the walk starts at `vault()`, which the proposer does not supply —
    ///         and it is exactly the condition under which `_guardBatchCalls`
    ///         disables ITSELF, so the strategy's re-approval grants nothing that
    ///         is not already granted.
    ///
    ///         ORACLE BINDING. `chainlinkVerifier_` and each push-mode aggregator
    ///         are also proposer input, and `rebalanceDelta` is THE
    ///         oracle-anchored remedy for `_quoteMinOut`'s quote-anchored floor —
    ///         worthless if the oracle itself is attacker-chosen. Bound exactly
    ///         like `swapAdapter_`, with the identical skip-when-unresolved
    ///         behavior. The push-mode sentinel `chainlinkVerifier_ == 0` is
    ///         exempt on itself, but every aggregator it implies is bound
    ///         individually, per slot. This binding is re-certified LIVE on every
    ///         `rebalance`/`rebalanceDelta`, not just here.
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
        // a monotonic decrease. Floor subsumes the previous `== 0` rejection.
        if (maxSlippageBps_ < MIN_SLIPPAGE_BPS || maxSlippageBps_ > MAX_SLIPPAGE_CEILING_BPS) revert InvalidSlippage();

        // INIT IS FAIL-CLOSED ON THE REGISTRY, AND ONLY INIT. The binding
        // helpers degrade open when it cannot be resolved, which is right at
        // rebalance/settle — blocking those strands vault capital. Init has the
        // opposite balance: nothing is at stake yet, and a clone initialized
        // against an unreachable registry carries adapter, price-source and
        // token↔feed pairings never checked against governance, which
        // codehash-class certification would then vouch for under its
        // "holds under EVERY initialization" claim. Do not make these symmetric.
        //
        // Deploy order is consequently load-bearing: the registry must resolve
        // through vault() → governor() → tierRegistry() before any clone inits.
        // Placed after the purely-local checks so a malformed proposal still
        // reports its own error rather than being masked by resolution failure.
        if (_resolveTierRegistry() == address(0)) revert TierRegistryUnresolved();

        // Push-feed mode when no Data Streams verifier is wired: each
        // `feedIds[i]` encodes an AggregatorV3 proxy as bytes32(uint160(feed)).
        bool pushMode = chainlinkVerifier_ == address(0);
        // Bind the Data Streams verifier to the governance allowlist before
        // any allocation is written — same registry, same
        // skip-when-unresolved behavior as the swap-adapter binding above
        // (see the ORACLE BINDING note). `address(0)` is the push-mode
        // sentinel, not a price source, so it's exempt here; each push-mode
        // aggregator is bound individually below, per slot.
        if (!pushMode) _requireAllowedPriceSource(chainlinkVerifier_);

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
                // Bind this slot's aggregator to the governance allowlist —
                // see the ORACLE BINDING note above.
                _requireAllowedPriceSource(feed);
                // …and bind it to THIS slot's token. The allowlist alone lets a
                // proposer point any allowlisted feed at any token; the pairing
                // is what stops a valuable token being priced by a cheap
                // asset's feed. Normalized to the bare aggregator address so
                // one attestation covers every max-age variant of the packed
                // feed id.
                _requirePairedPriceSource(tokens[i], bytes32(uint256(uint160(feed))));
            } else {
                // Data Streams mode: the feed id is opaque, so the pairing is
                // the ONLY thing tying this slot's report to this slot's token
                // — the verifier is allowlisted once, globally, and says
                // nothing about which asset a given feed id describes.
                _requirePairedPriceSource(tokens[i], feedIds_[i]);
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

        // DATA STREAMS MODE REQUIRES A QUOTING ADAPTER.
        //
        // `_sellFloor`/`_buyFloor` are NON-REVERTING BY DESIGN: whenever the
        // oracle leg is unavailable they degrade to `_quoteMinOut` instead of
        // stranding vault capital. In push mode that degrade is a genuine
        // fallback, and an adapter that cannot quote (the in-repo
        // `SynthraDirectAdapter` returns 0 by design) is a supported pairing.
        //
        // In Data Streams mode it is not a fallback but the only path: neither
        // `execute()` nor `settle()` carries report calldata, so EVERY call lands
        // on `_quoteMinOut`. Paired with a non-quoting adapter that is a
        // guaranteed revert on the only non-emergency exit — and `unstick`
        // replays the same batch, so the proposal wedges in `Executed`, freezing
        // LP exits, queue claims, rescues, new proposals and owner unstaking.
        //
        // Probed at each allocation's real size rather than 1 wei: a dust-sized
        // quote can legitimately floor to zero on a healthy pool. EVERY
        // allocation is probed, not just the first: routes are per-allocation, so
        // an adapter can quote slot 0 fine and still return 0 for slot 3, and a
        // zero-weight slot 0 would otherwise skip the probe entirely. A probe is
        // still point-in-time — a route that only gains liquidity later
        // false-rejects, and an adapter that degrades after init can still wedge
        // settle. It narrows the hazard, it cannot close it.
        if (!pushMode) {
            for (uint256 i; i < _allocations.length; ++i) {
                uint256 probeIn = (totalAmount_ * _allocations[i].targetWeightBps) / BPS_DENOMINATOR;
                if (probeIn == 0) continue;
                try ISwapAdapter(swapAdapter_)
                    .quote(asset_, _allocations[i].token, probeIn, _swapExtraData[i]) returns (
                    uint256 probeOut
                ) {
                    if (probeOut == 0) revert AdapterCannotQuoteInDataStreamsMode(swapAdapter_);
                } catch {
                    revert AdapterCannotQuoteInDataStreamsMode(swapAdapter_);
                }
            }
        }
    }

    // ── Execute: buy basket tokens ──

    /// @dev Buy-side floor uses `_buyFloor` (oracle-anchored in push mode,
    ///      quote-anchored fallback in Data Streams mode), not a bare
    ///      `_quoteMinOut`: this is the PERMISSIONLESS entry point, so a
    ///      quote-anchored-only floor let anyone move the pool immediately before
    ///      triggering execution and unwind against their own quote.
    ///
    ///      RE-CERTIFIES ADAPTER AND PRICE SOURCES, unlike `_settle`. The
    ///      capital-hostage rationale that exempts `_settle` does NOT hold here:
    ///      blocking `settle()` strands capital already deployed, while blocking
    ///      `execute()` strands nothing — the proposal simply expires at
    ///      `executeBy` with the vault untouched. Without the check, an adapter
    ///      demoted between clone-init and execute — reachable with NO governance
    ///      action via the permissionless `poke`/`demoteByChallenge`, or a
    ///      metamorphic redeploy — still received `forceApprove` of the whole
    ///      allocation, one hop outside the batch gate.
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
            uint256 minOut = _buyFloor(i, allocation, type(uint256).max);
            uint256 amountOut = swapAdapter.swap(asset, alloc.token, allocation, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

            alloc.tokenAmount = amountOut;
            alloc.investedAmount = allocation;
        }

        _pushAllToVault(asset);
    }

    // ── Settle: sell all basket tokens ──

    /// @dev Sell-side floor uses `_sellFloor` (oracle-anchored in push mode,
    ///      quote-anchored fallback in Data Streams mode); the settle window is
    ///      uniquely exposed to a proposer-timed sandwich. The swap return is
    ///      captured and checked like the buy side rather than discarded.
    ///      `_sellFloor`'s push-mode oracle read never reverts here: `settle()` is
    ///      the only non-emergency exit, so a stale or mid-upgrade feed degrades
    ///      to the quote-anchored floor instead of stranding vault capital.
    function _settle() internal override {
        uint256 len = _allocations.length;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 bal = IERC20(alloc.token).balanceOf(address(this));
            if (bal == 0) continue;

            IERC20(alloc.token).forceApprove(address(swapAdapter), bal);
            uint256 minOut = _sellFloor(i, alloc.token, bal, type(uint256).max);
            uint256 amountOut = swapAdapter.swap(alloc.token, asset, bal, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

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
            // Tighten-only, but never below the floor: a sub-floor value would
            // brick `rebalanceDelta` irreversibly (raising is disallowed).
            if (newMaxSlippageBps > maxSlippageBps || newMaxSlippageBps < MIN_SLIPPAGE_BPS) revert InvalidSlippage();
            maxSlippageBps = newMaxSlippageBps;
        }

        // Routes are frozen once the proposal executes: `_quoteMinOut` prices the
        // SAME `extraData` route it swaps through, so rewriting the route would
        // move the slippage floor with it — `maxSlippageBps` can't bound that
        // because the percentage applies to the attacker's own quote.
        // `rebalanceDelta` stays available since its floors come from signed
        // oracle feeds rather than the route.
        if (newSwapExtraData.length > 0) revert RoutesFrozen();
    }

    // ── Rebalancing ──

    /// @notice Simple rebalance: sell all positions, re-buy at current target weights.
    ///         Proposer-only, Executed state only.
    function rebalance() external onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        if (_rebalancing) revert RebalancingInProgress();
        // The decay budget is charged at the END of this function, per LEG
        // THAT ACTUALLY SWAPPED — see the charge site below. Charging up front
        // billed a rebalance that moved nothing the full `2 * maxSlippageBps`,
        // which at the `MAX_SLIPPAGE_CEILING_BPS` of 1_000 is two no-op calls
        // to exhaust a 30-day strategy (PR #195 review, minor 1). Charging
        // after is equally safe: a revert unwinds the swaps it refuses to pay.
        // Live re-check. Unlike `_execute`/`_settle`'s one-shot check,
        // `rebalance`/`rebalanceDelta` are proposer-callable an unbounded number
        // of times while `Executed`, with no time limit — a demotion that lands
        // after execute would otherwise be invisible, and every subsequent call
        // would keep `forceApprove`-ing the demoted adapter. Blocking a rebalance
        // strands nothing, since `settle()` remains the exit path either way, so
        // this fails CLOSED rather than degrading open.
        _requireAllowedAdapter(address(swapAdapter));
        // Live re-check of the oracle itself. The adapter check above
        // re-certifies the swap VENUE on every call, but the price SOURCE
        // anchoring `_sellFloor`/`_buyFloor` would otherwise be certified once at
        // `_initialize` and never again — a revoked or compromised feed kept
        // anchoring every rebalance for the strategy's lifetime. Same
        // skip-when-unresolved, fail-closed behavior as the adapter check;
        // blocking here strands nothing.
        _requireAllowedPriceSources();
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

        // Sell all positions back to asset via `_sellFloor` (oracle-anchored in
        // push mode). The buy leg below uses the mirror `_buyFloor` rather than a
        // bare `_quoteMinOut`, for the same reason: this flow is proposer-only but
        // the pool state it quotes against is not otherwise anchored.
        bool soldAny;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 bal = IERC20(alloc.token).balanceOf(address(this));
            if (bal == 0) continue;

            IERC20(alloc.token).forceApprove(address(swapAdapter), bal);
            uint256 minOut = _sellFloor(i, alloc.token, bal, maxSlippageBps);
            uint256 amountOut = swapAdapter.swap(alloc.token, asset, bal, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();
            alloc.tokenAmount = 0;
            alloc.investedAmount = 0;
            soldAny = true;
        }

        // Re-buy at current target weights
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        bool boughtAny;
        for (uint256 i; i < len; ++i) {
            TokenAllocation storage alloc = _allocations[i];
            uint256 allocation = (assetBalance * alloc.targetWeightBps) / BPS_DENOMINATOR;
            if (allocation == 0) continue;

            IERC20(asset).forceApprove(address(swapAdapter), allocation);
            uint256 minOut = _buyFloor(i, allocation, maxSlippageBps);
            uint256 amountOut = swapAdapter.swap(asset, alloc.token, allocation, minOut, _swapExtraData[i]);
            if (amountOut == 0) revert SwapFailed();

            alloc.tokenAmount = amountOut;
            alloc.investedAmount = allocation;
            boughtAny = true;
        }

        // PER LEG THAT ACTUALLY SWAPPED (PR #195 review, minor 1). The unit of
        // the allowance is a LEG, not a swap: `maxSlippageBps` bounds how far
        // below the oracle-implied value one side of the round trip may land,
        // and every swap inside a leg is bounded individually by its own
        // floor. Charging per SWAP would scale the bill with basket size and
        // exhaust a 3-token basket in a single call; charging a flat
        // `2 * maxSlippageBps` billed no-op rebalances. This bills what ran.
        uint256 legs = (soldAny ? maxSlippageBps : 0) + (boughtAny ? maxSlippageBps : 0);
        if (legs != 0) _chargeDecayBudget(legs);

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

    /// @notice Delta-based rebalance using Chainlink Data Streams prices. Only
    ///         swaps the difference between current and target allocations.
    /// @param priceReports Signed reports, one per allocation, in the same order.
    /// @dev Heavy loop bodies extracted into `_sellOverweight`, `_buyUnderweight`
    ///      and `_snapshotAllocations` so the legacy compiler pipeline (forge
    ///      coverage, no via_ir) does not trip stack-too-deep.
    function rebalanceDelta(bytes[] calldata priceReports) external onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        if (_rebalancing) revert RebalancingInProgress();
        // Charged at the END, and only if a swap actually ran — see the charge
        // site in `rebalance()` and `MAX_CUMULATIVE_DECAY_BPS` for what is
        // metered and why (pashov review finding #9, refined by PR #195 review
        // minor 1). A delta rebalance trades only the over/under-weight
        // remainder rather than the full basket, so it is charged one leg's
        // worth where the full round trip is charged two. A delta call whose
        // every allocation is already within threshold swaps nothing and is
        // therefore free.
        // Live re-check, fail-closed on demotion — see the identical guard on
        // `rebalance()` above for the full rationale (issue #147).
        _requireAllowedAdapter(address(swapAdapter));
        // Live re-check of the oracle itself (Finding C) — see the identical
        // guard and full rationale on `rebalance()` above. In Data Streams
        // mode this re-certifies `chainlinkVerifier` (the reports are signed
        // by the DON, but the VERIFIER contract that checks those signatures
        // is itself proposer-supplied governance-bound state, same as a
        // push-mode aggregator).
        _requireAllowedPriceSources();
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
        for (uint256 i; i < len; ++i) {
            snap.prices[i] = _verifyPrice(i, priceReports[i]);
            snap.currentValues[i] = _tokensToValue(snap.oldBalances[i], snap.prices[i], i, assetDec);
            totalValue += snap.currentValues[i];
        }
        // Include any asset balance already held (e.g. from previous partial rebalances).
        totalValue += IERC20(asset).balanceOf(address(this));

        // Sell overweight positions.
        uint256 swapsExecuted;
        bool soldAny;
        bool boughtAny;
        for (uint256 i; i < len; ++i) {
            if (_sellOverweight(i, totalValue, snap.currentValues[i], snap.prices[i])) {
                ++swapsExecuted;
                soldAny = true;
            }
        }

        // Buy underweight positions with available asset.
        for (uint256 i; i < len; ++i) {
            if (_buyUnderweight(i, totalValue, snap.currentValues[i], snap.prices[i])) {
                ++swapsExecuted;
                boughtAny = true;
            }
        }

        // Update stored token amounts and snapshot post-balances.
        uint256[] memory newBalances = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 bal = IERC20(_allocations[i].token).balanceOf(address(this));
            _allocations[i].tokenAmount = bal;
            newBalances[i] = bal;
        }

        // ONE CHARGE PER LEG THAT ACTUALLY RAN, not one per call (pashov
        // 2026-08 finding #20).
        //
        // This used to bill a flat `maxSlippageBps` however many legs traded,
        // on the premise stated at the top of this function that a delta
        // rebalance trades only the over/under-weight remainder rather than the
        // full basket. NOTHING ENFORCES THAT PARTIALITY: `_updateParams`
        // accepts any weight vector summing to `BPS_DENOMINATOR`, so `[0,
        // 10_000]` on a 50/50 basket makes `_sellOverweight` sell the entire
        // slot and `_buyUnderweight` spend the entire proceeds — the same two
        // legs `rebalance()` bills at `2 * maxSlippageBps`.
        //
        // Billed at half rate, the reachable lifetime loss becomes
        // `1 - (1-s)^(2B/s)` instead of `1 - (1-s)^(B/s)`: about 33% against
        // the ~18% `MAX_CUMULATIVE_DECAY_BPS` documents, and alternating
        // `[0,10_000]` / `[10_000,0]` rotates the whole basket every call.
        //
        // Deliberately counts LEGS, not swaps: a basket with eight overweight
        // slots still crosses the spread twice, once in each direction, which
        // is what `rebalance()` charges and what the budget's arithmetic
        // assumes.
        uint256 legs = (soldAny ? maxSlippageBps : 0) + (boughtAny ? maxSlippageBps : 0);
        if (legs != 0) _chargeDecayBudget(legs);

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
        // FLOORED BY THE QUOTE, never replaced by it. `_priceDecimals[i]` is
        // proposer-declared and, in Data Streams mode, cross-checked against
        // NOTHING: the push branch asserts it against the feed's live
        // `decimals()`, but a Data Streams report carries no decimals field, so
        // `_verifyPrice` returns `report.price` raw at whatever scale the slot
        // claims. An inflated declaration shrinks `_tokensToValue` and collapses
        // this floor — traced at a $200,000 position floored to 19 raw USDC. The
        // quote floor derives from a different, non-proposer-declared quantity,
        // so taking the MAX means a mis-scaled oracle can only raise the bar.
        // Safe to fail closed: blocking one `rebalanceDelta` strands nothing.
        //
        // DATA STREAMS MODE ONLY. Push mode needs no quote floor — the declared
        // scale is already asserted against the feed's live `decimals()` — and it
        // must not run there: `_quoteMinOut` reverts on a non-quoting adapter,
        // while push mode plus a non-quoting adapter is a supported pairing, so
        // an unconditional call would permanently brick `rebalanceDelta` for it.
        if (chainlinkVerifier != address(0)) {
            uint256 quoteFloor = _quoteMinOut(token, asset, tokensToSell, _swapExtraData[i]);
            if (quoteFloor > minOut) minOut = quoteFloor;
        }
        uint256 amountOut = swapAdapter.swap(token, asset, tokensToSell, minOut, _swapExtraData[i]);
        if (amountOut == 0) revert SwapFailed();
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
        // Floored by the quote for the same reason — and with the same
        // Data-Streams-only scoping — as `_sellOverweight`'s sell leg; see the
        // note there on the unvalidated Data Streams price scale and on why
        // push mode must not reach `_quoteMinOut`.
        if (chainlinkVerifier != address(0)) {
            uint256 quoteFloor = _quoteMinOut(asset, _allocations[i].token, amountToSpend, _swapExtraData[i]);
            if (quoteFloor > minOut) minOut = quoteFloor;
        }
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

    /// @dev Adapter-quote-driven minOut. Adapters with a reliable `quote()` return
    ///      the expected output, off which `maxSlippageBps` is applied; adapters
    ///      whose `quote()` returns 0 or reverts cannot guarantee slippage, so
    ///      this reverts `QuoteUnavailable`.
    ///
    ///      NOT SANDWICH PROTECTION, and it must not be described as such. The
    ///      quote is taken in the same transaction — and through the same
    ///      `extraData` route — as the swap that follows, so both operands come
    ///      from the same pool state. What this bounds is drift between the quote
    ///      and the execution, which within one transaction is zero; it does NOT
    ///      bound the price against a fair external reference. A searcher who
    ///      moves the pool before the call gets a quote at the moved price and a
    ///      floor derived from it, and the swap clears.
    ///
    ///      The oracle-anchored path is `rebalanceDelta`, and in PUSH MODE ONLY
    ///      the `_sellFloor`/`_buyFloor` legs. In Data Streams mode neither has a
    ///      report to verify against at those call sites, so both fall back to
    ///      THIS floor and inherit the caveat above. A full Data Streams-mode fix
    ///      needs `execute()`/`settle()` to carry report calldata, which is
    ///      `IStrategy` surface this contract does not own. Until then the
    ///      exposure there is bounded by `MAX_SLIPPAGE_CEILING_BPS`, by the routes
    ///      being frozen at execute, and by guardian review of those routes.
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

    /// @dev Non-reverting sibling of `_quoteMinOut`, for the stale-anchor branch
    ///      of `_sellFloor`/`_buyFloor`. Those sit on `settle()` — the only
    ///      non-emergency exit — so they cannot adopt `_quoteMinOut`'s
    ///      fail-closed contract; they need the quote as an ADDITIONAL floor
    ///      that is simply absent when unavailable, never as a revert.
    ///
    ///      `ok == false` covers both a reverting adapter (non-quoting adapters
    ///      are a supported pairing) and a zero quote, and leaves the caller's
    ///      oracle-derived floor standing unchanged.
    ///
    ///      WHAT THIS DOES NOT SOFTEN, stated because the distinction is the
    ///      whole liveness argument: an UNAVAILABLE quote is non-fatal, an
    ///      OVERSTATED one is not. An adapter whose `quote` promises more than
    ///      its own `swap` delivers by more than `maxSlippageBps` now reverts
    ///      the swap it floors — and in Data Streams mode that reaches
    ///      `settle()`, where the stale-anchor branch was previously
    ///      pool-state-independent and always cleared. `_sellOverweight` has
    ///      carried the identical exposure since the quote floor was introduced,
    ///      but only on `rebalanceDelta`, where blocking one call strands
    ///      nothing. Accepted here on the same terms the oracle floor is:
    ///      quote and swap are taken in ONE transaction against ONE pool state
    ///      through the SAME `extraData` route, so a conforming adapter's quote
    ///      already includes its fee and price impact and the gap is zero. A
    ///      non-conforming adapter degrades this to the emergency-settle path
    ///      rather than to a silent skim, which is the correct direction for
    ///      the only floor Data Streams mode has here.
    function _tryQuoteMinOut(address tokenIn, address tokenOut, uint256 amountIn, bytes memory extraData)
        private
        returns (uint256 floor, bool ok)
    {
        try swapAdapter.quote(tokenIn, tokenOut, amountIn, extraData) returns (uint256 expected) {
            if (expected == 0) return (0, false);
            return ((expected * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Sell-side floor for `_settle` and `rebalance`'s sell leg. Neither call
    ///      site carries signed price reports (both are parameterless), unlike
    ///      `rebalanceDelta`. In push mode that is not a blocker:
    ///      `_tryPushFeedPrice` reads `latestRoundData()` directly, so an
    ///      oracle-anchored floor is reachable here too when the read succeeds.
    ///
    ///      NON-REVERTING BY DESIGN. Unlike `_verifyPrice`/`_pushFeedPrice`, where
    ///      blocking a call strands nothing, `settle()` IS the non-emergency exit
    ///      — and equity feeds stop heartbeating outside market hours (observed
    ///      77h gaps over holiday weekends against a 26h default). A hard revert
    ///      on a routine feed gap would strand vault capital, recoverable only via
    ///      owner-multisig emergency settle. So a stale, mismatched-decimals or
    ///      codeless feed degrades to the quote-anchored `_quoteMinOut` floor and
    ///      inherits that path's NOT-SANDWICH-PROTECTION caveat.
    /// @param bandCap The WIDEST band this caller will accept, and therefore
    ///        the widest it is willing to be BILLED for (pashov 2026-08
    ///        finding #14). The stale-anchor branch widens with anchor age up
    ///        to `MAX_STALE_SLIPPAGE_BPS`, which does not scale with
    ///        `maxSlippageBps` — so a metered caller billing
    ///        `2 * maxSlippageBps` while enforcing up to 3_000 was billing a
    ///        band it did not enforce, by a ratio reaching 60x. That is the
    ///        finding.
    ///
    ///        Resolved at the SPLIT rather than at the meter, because the two
    ///        callers want opposite things. `settle()` is the only
    ///        non-emergency exit and passes `type(uint256).max`: it must take
    ///        the widened band, since failing closed there strands capital and
    ///        is exactly what the age ramp was introduced to prevent.
    ///        `rebalance()` is discretionary and passes `maxSlippageBps`:
    ///        blocking one rebalance strands nothing, so it refuses a trade it
    ///        cannot bill for rather than taking a 30% band on a 0.5% budget.
    ///
    ///        With the cap in place the metered path's enforced band IS
    ///        `maxSlippageBps`, so the existing charge is correct and
    ///        `MAX_CUMULATIVE_DECAY_BPS` needs no re-sizing. Billing the wide
    ///        band instead — the other candidate fix — made the FIRST
    ///        `rebalance()` revert `DecayBudgetExhausted` at any anchor age
    ///        above ~303 seconds, removing the function rather than metering
    ///        it.
    function _sellFloor(uint256 i, address token, uint256 bal, uint256 bandCap) private returns (uint256 minOut) {
        if (chainlinkVerifier == address(0)) {
            (uint256 price, bool ok) = _tryPushFeedPrice(i);
            if (ok) {
                _lastGoodPrice[i] = price;
                _lastGoodAt[i] = block.timestamp;
                uint256 value = _tokensToValue(bal, price, i, uint256(_assetDecimals));
                return (value * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
            }
        }
        // STALE ORACLE BEATS NO ORACLE (pashov review finding #4). The old
        // fallback went straight to `_quoteMinOut`, whose floor is derived from
        // a quote taken in the SAME transaction against the SAME pool the swap
        // is about to hit — so `maxSlippageBps` bounded drift from a price the
        // attacker had just set, not from a fair one. That path is reachable
        // without any oracle failure at all in Data Streams mode (neither
        // `execute()` nor `settle()` nor `rebalance()` carries a signed
        // report), and in push mode on any stale/mismatched/codeless feed —
        // which this contract's own `MAX_PUSH_PRICE_AGE` notes is routine for
        // equity feeds ("observed 77h gaps over holiday weekends").
        //
        // A price this contract ITSELF observed from an allowlisted feed is
        // attacker-independent, however old it is, so it is a strictly better
        // anchor than the counterparty's quote. Fail-closed was the other
        // option and was rejected deliberately: it would brick `settle()` for
        // the entire duration of a feed outage, stranding capital — which is
        // also why the band around the anchor widens with the anchor's age
        // rather than staying fixed. See `_staleSlippageBps`.
        uint256 lastGood = _lastGoodPrice[i];
        if (lastGood != 0) {
            uint256 staleValue = _tokensToValue(bal, lastGood, i, uint256(_assetDecimals));
            uint256 band = _staleSlippageBps(i);
            if (band > bandCap) band = bandCap;
            uint256 staleFloor = (staleValue * (BPS_DENOMINATOR - band)) / BPS_DENOMINATOR;
            // FLOORED BY THE QUOTE in Data Streams mode, for exactly the reason
            // `_sellOverweight` does it: `_priceDecimals[i]` is proposer-declared
            // and cross-checked against NOTHING there (a DS report carries no
            // decimals field), so an inflated declaration shrinks
            // `_tokensToValue` and collapses this floor — to literal 0 at the
            // declaration ceiling of 36 against an 8-decimal report.
            //
            // Reachable the moment an anchor exists: `_verifyPrice` seeds
            // `_lastGoodPrice[i]` in DS mode, and a `rebalanceDelta` that
            // executes ZERO swaps still seeds it (the same mis-scale floors
            // every `currentValues[i]` to 0, so every allocation reads
            // on-target and no decay is charged). One such call arms this
            // branch, after which `settleProposal` — proposer-callable an hour
            // after execute — sells the basket at `minOut = 0`.
            //
            // NON-REVERTING, unlike `_sellOverweight`'s version: blocking one
            // `rebalanceDelta` strands nothing, but this sits on `settle()`,
            // the only non-emergency exit. So an unavailable quote leaves the
            // stale floor standing rather than bricking the exit.
            if (chainlinkVerifier != address(0)) {
                (uint256 quoteFloor, bool quoted) = _tryQuoteMinOut(token, asset, bal, _swapExtraData[i]);
                if (quoted && quoteFloor > staleFloor) staleFloor = quoteFloor;
            }
            return staleFloor;
        }
        return _quoteMinOut(token, asset, bal, _swapExtraData[i]);
    }

    /// @dev Buy-side floor for `_execute` and `rebalance`'s re-buy leg. Mirrors
    ///      `_sellFloor` exactly — same non-reverting push-mode oracle read, same
    ///      quote-anchored fallback in Data Streams mode or on an unreadable feed.
    ///      Neither `execute()` nor `rebalance()` carries signed reports, so like
    ///      `_sellFloor` this can only reach the oracle in push mode.
    ///
    ///      Deriving `minOut` purely from `_quoteMinOut` here meant quoting
    ///      against the SAME pool state as the swap that follows, and
    ///      `executeProposal` is PERMISSIONLESS — so anyone could move the pool
    ///      immediately before triggering execution and unwind the vault's
    ///      allocation against their own quote (traced: a 1,000,000 USDC
    ///      allocation with the pool pushed 100x nets ~10,000 USDC of tokens).
    /// @param i        Allocation index.
    /// @param amountIn Asset amount about to be spent buying allocation `i`.
    /// @param bandCap As `_sellFloor` — see the note there.
    function _buyFloor(uint256 i, uint256 amountIn, uint256 bandCap) private returns (uint256 minOut) {
        if (chainlinkVerifier == address(0)) {
            (uint256 price, bool ok) = _tryPushFeedPrice(i);
            if (ok) {
                _lastGoodPrice[i] = price;
                _lastGoodAt[i] = block.timestamp;
                uint256 tokensExpected = _valueToTokens(amountIn, price, i, uint256(_assetDecimals));
                return (tokensExpected * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
            }
        }
        // Mirrors `_sellFloor`'s stale-anchor fallback exactly — see the block
        // there for why a price this contract already observed beats a quote
        // taken against the pool being traded (pashov review finding #4).
        uint256 lastGood = _lastGoodPrice[i];
        if (lastGood != 0) {
            uint256 staleTokens = _valueToTokens(amountIn, lastGood, i, uint256(_assetDecimals));
            uint256 band = _staleSlippageBps(i);
            if (band > bandCap) band = bandCap;
            uint256 staleFloor = (staleTokens * (BPS_DENOMINATOR - band)) / BPS_DENOMINATOR;
            // Floored by the quote in Data Streams mode for the same reason, and
            // with the same non-reverting degradation, as `_sellFloor`; see the
            // note there on the unvalidated Data Streams price scale.
            if (chainlinkVerifier != address(0)) {
                (uint256 quoteFloor, bool quoted) =
                    _tryQuoteMinOut(asset, _allocations[i].token, amountIn, _swapExtraData[i]);
                if (quoted && quoteFloor > staleFloor) staleFloor = quoteFloor;
            }
            return staleFloor;
        }
        return _quoteMinOut(asset, _allocations[i].token, amountIn, _swapExtraData[i]);
    }

    /// @dev The stale band for allocation `i`, ramping linearly from
    ///      `STALE_PRICE_SLIPPAGE_BPS` at a zero-age anchor to
    ///      `MAX_STALE_SLIPPAGE_BPS` once the anchor is `STALE_WIDEN_PERIOD`
    ///      old, and flat at the ceiling thereafter (PR #195 re-review). See
    ///      `MAX_STALE_SLIPPAGE_BPS` for why the age is the right axis.
    ///
    ///      `_lastGoodAt[i]` is written in lockstep with `_lastGoodPrice[i]` at
    ///      every site, and this is only reached when the latter is non-zero,
    ///      so the former is non-zero too and `age` is a real elapsed span. The
    ///      `>` guard is belt-and-braces against a same-block read, not a case
    ///      that can legitimately arise.
    function _staleSlippageBps(uint256 i) private view returns (uint256) {
        uint256 recordedAt = _lastGoodAt[i];
        uint256 age = block.timestamp > recordedAt ? block.timestamp - recordedAt : 0;
        if (age >= STALE_WIDEN_PERIOD) return MAX_STALE_SLIPPAGE_BPS;
        return
            STALE_PRICE_SLIPPAGE_BPS + ((MAX_STALE_SLIPPAGE_BPS - STALE_PRICE_SLIPPAGE_BPS) * age) / STALE_WIDEN_PERIOD;
    }

    /// @dev Non-reverting push-feed read for `_sellFloor`/`_buyFloor`. Mirrors
    ///      `_pushFeedPrice`'s checks exactly (live `decimals()` match,
    ///      `answer > 0`, guarded-subtraction staleness) but reports failure via
    ///      `ok == false`, so callers on the settle/execute liveness path can
    ///      degrade to the quote-anchored floor rather than brick.
    ///      `_pushFeedPrice` itself keeps reverting: it backs `_verifyPrice`,
    ///      whose only caller can safely fail closed.
    ///
    ///      RAW STATICCALL, NOT A TYPED `try` — same precedent as
    ///      `ExposureLedger._feedPriceX8`. A typed try guards only the CALL and
    ///      its error selector; a call that SUCCEEDS but returns malformed data
    ///      fails at ABI-DECODING, which is a full, UNCAUGHT revert.
    ///      `code.length == 0` is checked FIRST because the codesize guard on a
    ///      high-level call to a codeless address reverts in THIS frame. Every
    ///      decode target is `uint256`/`int256`, never the narrower types the
    ///      interface declares, since a sub-256-bit type is validity-constrained
    ///      at decode time. Comparing `dec` as a `uint256` is exactly correct: a
    ///      legitimate declared value is always `< 256`, so a dirty word can never
    ///      false-positive a match.
    /// @dev Accrues `spendBps` against the clone's lifetime slippage allowance
    ///      and refuses once `MAX_CUMULATIVE_DECAY_BPS` is exhausted (pashov
    ///      review finding #9). See that constant for what is metered, why the
    ///      worst case rather than the realized loss, and why exhaustion is not
    ///      a brick.
    function _chargeDecayBudget(uint256 spendBps) private {
        uint256 spent = cumulativeDecayBps + spendBps;
        if (spent > MAX_CUMULATIVE_DECAY_BPS) revert DecayBudgetExhausted();
        cumulativeDecayBps = spent;
    }

    function _tryPushFeedPrice(uint256 i) private view returns (uint256 price, bool ok) {
        (address feed, uint256 maxAge) = _decodePushFeed(_feedIds[i]);
        if (feed.code.length == 0) return (0, false);

        (bool decOk, bytes memory decRet) = feed.staticcall(abi.encodeCall(AggregatorV3Interface.decimals, ()));
        if (!decOk || decRet.length < 32) return (0, false);
        uint256 dec = abi.decode(decRet, (uint256));
        if (dec != uint256(_priceDecimals[i])) return (0, false);

        (bool rdOk, bytes memory rdRet) = feed.staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        // latestRoundData returns (uint80, int256, uint256, uint256, uint80):
        // 5 words, 160 bytes. Short/absent data is rejected before any decode
        // is attempted.
        if (!rdOk || rdRet.length < 160) return (0, false);
        (, int256 answer,, uint256 updatedAt,) = abi.decode(rdRet, (uint256, int256, uint256, uint256, uint256));
        if (answer <= 0) return (0, false);
        // Same guarded subtraction / future-timestamp convention as
        // `_pushFeedPrice` — see its natspec for the rationale.
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (updatedAt == 0 || age > maxAge) return (0, false);
        return (uint256(answer), true);
    }

    // ── Governance-allowlist binding (see the binding notes on `_initialize`) ──

    /// @dev Reverts unless `swapAdapter_` is allowlisted in the `TierRegistry` the
    ///      vault's own governor gates batch approvals against, resolved via
    ///      `vault() -> governor() -> tierRegistry()`. Skips only when that walk
    ///      yields no registry — the same condition under which
    ///      `_guardBatchCalls` disables itself, and one the proposer cannot steer
    ///      because no hop is proposer input. A registry that IS resolved but
    ///      whose `isAdapterAllowed` is unreadable fails CLOSED: a registry that
    ///      cannot vouch for the adapter has not vouched for it. Every hop is a
    ///      length-checked raw staticcall.
    ///
    ///      Called from `_initialize` (certifies provenance once, at binding time)
    ///      and from `rebalance`/`rebalanceDelta` (re-certifies on every call,
    ///      since those are proposer-callable an unbounded number of times
    ///      post-execute and blocking one strands no capital). `_execute`/
    ///      `_settle` deliberately do not: see the capital-hostage rationale on
    ///      the `_initialize` binding note.
    function _requireAllowedAdapter(address swapAdapter_) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, swapAdapter_)) revert AdapterNotAllowed(swapAdapter_, registry);
    }

    /// @dev Same registry resolution and skip-when-unresolved behavior as
    ///      `_requireAllowedAdapter`, for binding a Chainlink price source
    ///      instead of a swap adapter. Kept separate purely so a revert names the
    ///      actual offending role. Called from `_initialize` once and from
    ///      `_requireAllowedPriceSources` on every rebalance.
    function _requireAllowedPriceSource(address priceSource) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, priceSource)) revert PriceSourceNotAllowed(priceSource, registry);
    }

    /// @notice Require that `priceSource` is governance-attested to price `token`.
    /// @dev    The allowlist answers "may this oracle be used at all"; this
    ///         answers "…for THIS token". Adversary: a proposer pairing a
    ///         valuable basket token with a cheap asset's allowlisted feed — the
    ///         slot's minimum-output floor is then derived from the wrong
    ///         reference and value leaks while `maxSlippageBps` still reads as
    ///         satisfied.
    ///
    ///         ATTESTED, not derived: `AggregatorV3` exposes no on-chain link
    ///         from a feed to the asset it prices, and Chainlink's Feed Registry
    ///         is not deployed on Robinhood Chain.
    ///
    ///         `priceSource` is normalized by the CALLER — a push aggregator
    ///         widened from its address with any packed max-age stripped, or a
    ///         Data Streams feed id verbatim — so one attestation covers an
    ///         aggregator across every staleness variant.
    function _requirePairedPriceSource(address token, bytes32 priceSource) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isPriceSourceForToken(registry, token, priceSource)) {
            revert PriceSourceNotPairedWithToken(token, priceSource, registry);
        }
    }

    /// @dev Length-checked raw staticcall, mirroring `_isAdapterAllowed`. A
    ///      registry predating this function returns empty returndata and reads
    ///      as "not attested" — fail-closed is correct here, since the pairing
    ///      is the guard that makes this template class-certifiable.
    function _isPriceSourceForToken(address registry, address token, bytes32 priceSource) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeCall(ITierBindingPath.isPriceSourceForToken, (token, priceSource)));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }

    /// @dev Live re-validation of every price source `rebalance`/`rebalanceDelta`
    ///      depend on. Certified only at `_initialize`, a revoked or compromised
    ///      feed kept anchoring `_sellFloor`/`_buyFloor`/`_verifyPrice` for the
    ///      strategy's entire lifetime, invisible to every later rebalance.
    ///      `_pushFeedPrice`/`_tryPushFeedPrice` already re-read `decimals()` live
    ///      on every call, so the code already accepts that feed state can change
    ///      post-init; this extends the same acceptance to governance's allowlist
    ///      decision.
    ///
    ///      Data Streams mode re-certifies `chainlinkVerifier` once; push mode
    ///      re-certifies EVERY slot's aggregator, since both rebalance paths touch
    ///      every allocation. Deliberately NOT called from `_execute`/`_settle` —
    ///      same capital-hostage rationale as the adapter re-check.
    function _requireAllowedPriceSources() private view {
        if (chainlinkVerifier == address(0)) {
            uint256 len = _allocations.length;
            for (uint256 i; i < len; ++i) {
                (address feed,) = _decodePushFeed(_feedIds[i]);
                _requireAllowedPriceSource(feed);
            }
        } else {
            _requireAllowedPriceSource(chainlinkVerifier);
        }
    }

    /// @dev Shared `vault() → governor() → tierRegistry()` walk used by both
    ///      `_requireAllowedAdapter` and `_requireAllowedPriceSource`.
    ///      Returns `address(0)` when unresolved (no `governor()` surface, a
    ///      governor predating the getter, or `tierRegistry() == 0`) — the
    ///      condition under which callers skip their check entirely; see the
    ///      fail-open-only-here rationale on `_requireAllowedAdapter`.
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
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
    ///      return, or dirty upper bits all resolve to `address(0)`.
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

    /// @dev Decode a push-mode packed feed id into its AggregatorV3 proxy and
    ///      resolved max staleness. Packing:
    ///        `bytes32(uint256(maxAgeSeconds) << 160 | uint160(feedAddress))`.
    ///      A packed age of 0 resolves to the default `MAX_PUSH_PRICE_AGE`.
    function _decodePushFeed(bytes32 packed) private pure returns (address feed, uint256 maxAge) {
        feed = address(uint160(uint256(packed)));
        uint256 age = uint256(packed) >> 160;
        maxAge = age == 0 ? MAX_PUSH_PRICE_AGE : age;
    }

    /// @dev Read and validate allocation `i`'s push-feed price. HARD-REVERTING,
    ///      and called ONLY from `_verifyPrice` (via `rebalanceDelta`), where
    ///      blocking one call strands nothing. `_sellFloor`/`_buyFloor` call the
    ///      sibling `_tryPushFeedPrice` instead, which duplicates the same checks
    ///      in non-reverting form. Reverts `InvalidPriceDecimals` /
    ///      `InvalidAmount` / `StalePrice`.
    function _pushFeedPrice(uint256 i) private view returns (uint256 price) {
        (address feed, uint256 maxAge) = _decodePushFeed(_feedIds[i]);
        // Re-check decimals live every call: a proxy upgrade to a different
        // scale would otherwise silently mis-scale NAV against the init
        // snapshot (mirrors the Data Streams path's per-call feedId bind).
        if (AggregatorV3Interface(feed).decimals() != _priceDecimals[i]) revert InvalidPriceDecimals();
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        if (answer <= 0) revert InvalidAmount();
        // Guarded subtraction, matching the convention at every other staleness
        // site in this repo: a future `updatedAt` (feed clock ahead of a lagging
        // L2 `block.timestamp`) is the freshest possible answer, so age 0 rather
        // than an underflow panic. Clamping rather than rejecting is deliberate —
        // the bug being fixed is the panic, not the accept.
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (updatedAt == 0 || age > maxAge) revert StalePrice();
        return uint256(answer);
    }

    // ── Chainlink price verification ──

    /// @param i             Allocation index — used to check `report.feedId`
    ///                      against the slot's expected feed id.
    /// @param signedReport  Signed Chainlink Data Streams report. Ignored in push
    ///                      mode: pass empty bytes.
    /// @dev Verifies the report's `feedId` matches the slot's expected id before
    ///      returning the price, so a valid-but-mismatched report cannot inflate
    ///      cached NAV. Called from `rebalanceDelta`, one report per allocation.
    ///      The push-mode branch delegates to the HARD-REVERTING `_pushFeedPrice`;
    ///      `_sellFloor`/`_buyFloor` reach the same price via the NON-reverting
    ///      `_tryPushFeedPrice` instead, since neither may brick on a stale feed
    ///      the way this path safely can.
    function _verifyPrice(uint256 i, bytes calldata signedReport) internal returns (uint256 price) {
        // Push-feed mode: `_feedIds[i]` packs an AggregatorV3 proxy (low 160
        // bits) + an optional per-slot max age (upper 96 bits). No signed
        // report is consumed, so callers must pass empty bytes (a nonempty
        // report would imply a Data Streams path that isn't taken).
        if (chainlinkVerifier == address(0)) {
            if (signedReport.length != 0) revert InvalidFeedId();
            return _pushFeedPrice(i);
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
        // ANCHOR THE DATA STREAMS SIDE TOO (PR #195 review, item 6). The
        // last-good price was originally recorded only in `_sellFloor` /
        // `_buyFloor`, both of which read the feed exclusively inside
        // `if (chainlinkVerifier == address(0))` — so in Data Streams mode the
        // anchor stayed 0 forever and those floors still fell through to
        // `_quoteMinOut`, the pool-quoted floor the fix exists to remove. DS
        // mode is the case the floors' own natspec calls "reachable without any
        // oracle failure at all", since `execute()` / `settle()` / `rebalance()`
        // carry no signed report.
        //
        // This is a DON-signed, feed-id-matched, unexpired, positive price in
        // the slot's declared decimals — the same units and the same
        // trustworthiness as the push-mode read, so it is a valid anchor for
        // the calls that arrive without a report of their own.
        _lastGoodPrice[i] = price;
        // In lockstep, always — `_staleSlippageBps` derives the band from this
        // age, so an anchor recorded without its timestamp would be judged as
        // maximally stale and get the widest band on its very first use.
        _lastGoodAt[i] = block.timestamp;
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
}
