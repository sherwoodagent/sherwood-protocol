// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Chainlink Data Streams verifier proxy interface.
/// @dev    TWO ARGUMENTS, MATCHING `VerifierProxy 2.0.0`. This was declared with
///         the single-argument `verify(bytes)` of the 1.x proxy, a shape the
///         deployed contract does not have — probed read-only against the
///         verifier in `chains/46630.json`
///         (`0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64`), which answers
///         `typeAndVersion() == "VerifierProxy 2.0.0"`. A call to the one-argument
///         selector reverts with EMPTY returndata there, byte-identical to
///         calling a function that does not exist, while the two-argument
///         selector reverts with a typed `VerifierNotFound(bytes32)` — the
///         function running and rejecting a dummy feed. So the old declaration
///         did not merely mis-describe the proxy, it could never reach it, and
///         the failure carried nothing to decode.
///
///         `parameterPayload` selects the fee token when the proxy routes
///         through a `FeeManager`. This one does not: `s_feeManager()` reads
///         `address(0)`, so verification is free and the argument is passed
///         empty, which is why `submitPriceReports` needs neither `payable` nor a
///         refund path. WIRING A `FeeManager` IS A BREAKING CHANGE for this
///         contract: the empty payload would start reverting, and the call would
///         need a fee-token payload plus forwarded value. Fail loudly there
///         rather than quietly overpay from a permissionless entrypoint.
interface IVerifierProxy {
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
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
    /// @notice `submitPriceReports` called in push-feed mode, where the contract
    ///         reads its own aggregator and no report is consumed. Refused
    ///         explicitly rather than left to `_verifyPrice`'s `InvalidFeedId`,
    ///         so the caller learns the mode is wrong rather than the report.
    error PushModeNeedsNoReports();
    /// @notice A per-allocation view was asked for a slot the basket does not
    ///         have. Distinct from `LengthMismatch`, which is about an ARRAY
    ///         whose size disagrees with the basket's: nothing about a single
    ///         out-of-range index is a length, and the discovery views
    ///         (`feedIdOf`, `priceAnchorOf`) are the ones a third-party keeper
    ///         probes blind, so the revert they get should name what they did.
    error IndexOutOfRange(uint256 index);
    /// @notice Data Streams mode reached `_execute` with allocation `index`
    ///         carrying no price anchor, or one older than
    ///         `PRICE_ANCHOR_MAX_AGE_AT_EXECUTE`. Call `submitPriceReports`
    ///         (permissionless) and execute again — nothing is stranded, the
    ///         proposal stays Approved and no capital has left the vault.
    error PriceAnchorMissingOrStale(uint256 index);
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
    ///         predate a genuine move — equity feeds stop heartbeating outside
    ///         US market hours (see `MAX_PUSH_PRICE_AGE`) — but still an
    ///         attacker-independent number, which is the whole point: the old
    ///         fallback derived its floor from a quote taken against the very
    ///         pool the swap was about to hit, so the bound moved with the
    ///         attacker. This is the band at the instant the anchor is taken;
    ///         it widens with the anchor's age, see `STALE_WIDEN_PERIOD`.
    uint256 public constant STALE_PRICE_SLIPPAGE_BPS = MAX_SLIPPAGE_CEILING_BPS;
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
    ///         to the exit — `rebalance()` caps at `maxSlippageBps` — so this
    ///         is the price of keeping the one mandatory path alive, and
    ///         nothing else pays it.
    uint256 public constant MAX_STALE_SLIPPAGE_BPS = 3_000;
    /// @notice Span of anchor staleness over which the band ramps from
    ///         `STALE_PRICE_SLIPPAGE_BPS` to `MAX_STALE_SLIPPAGE_BPS`. Sized
    ///         past the longest documented equity-feed gap so an ordinary
    ///         holiday weekend lands mid-ramp rather than at the ceiling.
    uint256 public constant STALE_WIDEN_PERIOD = 7 days;
    /// @notice How fresh every allocation's price anchor must be for `_execute`
    ///         to deploy capital in Data Streams mode. See the check there.
    ///
    /// @dev    SIZED FOR TWO TRANSACTIONS, NOT ONE BLOCK. A Data Streams report
    ///         expires, so it cannot be carried in propose-time calldata and
    ///         still be valid at execute — the anchor has to be refreshed close
    ///         to execution, by a `submitPriceReports` call separate from
    ///         `executeProposal`. Both are permissionless, so the normal flow is
    ///         one caller sending two transactions; demanding they land in the
    ///         same block would fail honest executions for no security gain,
    ///         since the report itself already carries Chainlink's own expiry.
    ///
    ///         An hour is short enough that the entry floor is anchored to a
    ///         genuinely current price and long enough to survive a congested
    ///         block or a retried transaction. Deliberately NOT reusing
    ///         `STALE_WIDEN_PERIOD`: that governs how the band widens AFTER
    ///         capital is deployed and an exit must stay possible, a different
    ///         question from whether capital should be deployed at all.
    ///
    ///         MEASURED AGAINST THE PRICE, NOT THE RELAY. `_lastGoodAt` is dated
    ///         by the report's `observationsTimestamp`, so this bounds how old the
    ///         PRICE may be — which is the whole point, and also the thing that
    ///         makes the number depend on the FEED's cadence rather than on block
    ///         times. Two consequences worth stating before a basket ships:
    ///
    ///           - a feed that stops observing for longer than an hour cannot be
    ///             executed against until it resumes, and an approved proposal
    ///             whose `executeBy` falls entirely inside such a gap will expire
    ///             unexecuted. For a tokenized-equity feed that pauses outside
    ///             market hours, that means execution windows track market hours.
    ///             Refusing is the correct answer — an hours-old equity print is
    ///             not a floor — but it is an operational constraint, not a
    ///             detail: size `executeBy` against the feed's real cadence.
    ///           - it is also the ceiling on report SELECTION at the moment
    ///             capital moves; see `_verifyPrice` for why that pairing, rather
    ///             than the anchor's monotonicity alone, is what closes it.
    ///
    ///         One global constant, where push mode packs a per-slot max age into
    ///         `_feedIds[i]`. Fine while a basket's feeds share a cadence; a
    ///         basket mixing a 24/7 crypto feed with a market-hours equity feed
    ///         wants the per-slot treatment here too.
    uint256 public constant PRICE_ANCHOR_MAX_AGE_AT_EXECUTE = 1 hours;
    /// @notice Ceiling on `cumulativeDecayBps` across a clone's whole life
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
    ///      only case still degrading to the quote-anchored floor.
    mapping(uint256 allocationIndex => uint256 priceInFeedScale) private _lastGoodPrice;

    /// @dev When `_lastGoodPrice[i]` was OBSERVED, written in lockstep with it at
    ///      age — see `MAX_STALE_SLIPPAGE_BPS` — so an anchor and its age must
    ///      never diverge. Zero exactly when `_lastGoodPrice[i]` is zero, i.e.
    ///      the slot has never been priced.
    ///
    ///      THE CLOCK DIFFERS BY MODE, deliberately, because "observed" does:
    ///      in push mode the floors read the aggregator live, so the observation
    ///      IS the call and `block.timestamp` is exact; in Data Streams mode the
    ///      price is observed off-chain and relayed later, so it is dated by the
    ///      report's `observationsTimestamp` (clamped to now) rather than by the
    ///      transaction that carried it. Both therefore mean the same thing to
    ///      every reader — the age of the PRICE — which is what
    ///      `_staleSlippageBps` and `PRICE_ANCHOR_MAX_AGE_AT_EXECUTE` need.
    ///
    ///      MONOTONIC IN DATA STREAMS MODE: `_verifyPrice` skips the write for an
    ///      observation older than what is already recorded, so the anchor never
    ///      rewinds and the band never re-tightens onto an older price.
    mapping(uint256 allocationIndex => uint256 recordedAt) private _lastGoodAt;

    /// @notice Running sum, in bps, of oracle-valued NAV given up across every
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
    /// @notice `caller` submitted a full set of signed Data Streams reports.
    ///         Emitted so a keeper can see whether an anchor is already fresh
    ///         before paying to refresh it, and so the widening band in
    ///         `_staleSlippageBps` has an on-chain trail of who last closed it.
    ///
    ///         PER SLOT THE EFFECT IS FORWARD-ONLY: a report older than the
    ///         anchor already recorded is accepted and ignored rather than
    ///         reverted (see `_verifyPrice`), so this event marks a valid
    ///         submission, not proof that every anchor moved. Read
    ///         `priceAnchorOf` for the resulting state.
    /// @param  caller      Who submitted.
    /// @param  submittedAt When the submission landed. NOT the anchor's date:
    ///                     anchors are stamped with the report's OBSERVATION
    ///                     time, which precedes this by the relay lag. Named for
    ///                     the difference so a keeper does not read one for the
    ///                     other.
    event PriceAnchorsRefreshed(address indexed caller, uint256 submittedAt);
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

    function _execute() internal override {
        _requireAllowedAdapter(address(swapAdapter));
        _requireAllowedPriceSources();
        if (chainlinkVerifier != address(0)) {
            uint256 n = _allocations.length;
            for (uint256 i; i < n; ++i) {
                if (_allocations[i].targetWeightBps == 0) continue;
                uint256 at = _lastGoodAt[i];
                if (at == 0 || block.timestamp - at > PRICE_ANCHOR_MAX_AGE_AT_EXECUTE) {
                    revert PriceAnchorMissingOrStale(i);
                }
            }
        }

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
        _requireAllowedAdapter(address(swapAdapter));
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

    /// @notice Refresh every allocation's price anchor from signed Data Streams
    ///         reports. Permissionless.
    /// @param signedReports Signed reports, one per allocation, in the same order.
    ///
    /// @dev    WHY THIS EXISTS, AND WHY IT IS OPEN TO ANYONE. In push mode the
    ///         contract fetches its own price: `_sellFloor`/`_buyFloor` read the
    ///         aggregator on every swap and re-stamp the anchor, so the anchor
    ///         ages only during a genuine oracle outage. In Data Streams mode it
    ///         CANNOT fetch — a price only exists on-chain once somebody hands
    ///         over a DON-signed report — and the whole live-read block sits
    ///         behind `chainlinkVerifier == address(0)`, so in DS mode both
    ///         re-stamps are skipped.
    ///
    ///         That left `_verifyPrice` as the only writer of `_lastGoodPrice`
    ///         and `_lastGoodAt`, reachable solely from `rebalanceDelta`, which
    ///         is `onlyProposer` — and `execute()`/`settle()`/`rebalance()` carry
    ///         no report at all. Two consequences, both proposer-controlled with
    ///         no oracle failure anywhere:
    ///
    ///           - the anchor is ZERO at `_execute`, so `_buyFloor` falls through
    ///             to `_quoteMinOut`, a floor quoted from the very pool the swap
    ///           - after execute the anchor ages purely because the proposer
    ///             declines to call `rebalanceDelta`, and `_staleSlippageBps`
    ///             ramps the accepted loss from `maxSlippageBps` toward
    ///             `MAX_STALE_SLIPPAGE_BPS` (30%) over `STALE_WIDEN_PERIOD`
    ///             choice rather than a symptom.
    ///
    ///         PERMISSIONLESS IS THE FIX, and it is safe by CONSTRUCTION rather
    ///         than by trust. `_verifyPrice` requires a DON signature through the
    ///         governance-bound verifier, requires `report.feedId` to equal THIS
    ///         slot's `_feedIds[i]` (so a valid report cannot be replayed into
    ///         another slot), rejects an expired report, and rejects a
    ///         non-positive price. On top of that `_verifyPrice` dates the anchor
    ///         by the report's OBSERVATION time and only ever moves it forward, so
    ///         a caller cannot inject a false price, another asset's price, or an
    ///         older one than is already recorded — the only thing an adversarial
    ///         caller can do here is advance the anchor to a fresher truth, which
    ///         is precisely what the anchor is for. Whoever dislikes a widening
    ///         band — an LP, a guardian, the keeper about to settle — can close it
    ///         themselves.
    ///
    ///         Re-certifies the verifier on the same fail-closed terms as
    ///         `rebalanceDelta`: the reports are DON-signed, but the contract
    ///         CHECKING those signatures is proposer-supplied, governance-bound
    ///         state.
    ///
    ///         No state gate: refreshing an anchor moves no funds, and it is
    ///         useful before `execute` (to satisfy the freshness requirement
    ///         there) and before `settle` (to tighten the band on the way out).
    ///         In push mode this is a no-op by construction — `_verifyPrice`
    ///         reverts `InvalidFeedId` on a non-empty report — so the function
    ///         is DS-mode only without needing to say so.
    ///
    ///         ALL-OR-NOTHING ACROSS EVERY SLOT, INCLUDING ZERO-WEIGHT ONES, AND
    ///         THAT IS THE POINT rather than an oversight. It reads as one: a
    ///         per-index variant (or accepting empty bytes as "skip this slot")
    ///         would make the refresh robust to a single momentarily
    ///         unobtainable feed, where today one bad feed blocks the whole
    ///         basket's refresh and therefore its `execute`. That liveness cost
    ///         is real and is accepted, because the coupling buys an invariant
    ///         the exit path depends on:
    ///
    ///           EVERY SLOT IS ANCHORED BY THE TIME `settle()` RUNS.
    ///
    ///         `_settle` sells any slot carrying a balance, `targetWeightBps == 0`
    ///         included — a slot the `_execute` gate deliberately skips and no
    ///         trade ever fills, but which a donation or a weight rebalanced to
    ///         zero can leave holding tokens. `_sellFloor` degrades to the
    ///         pool-quoted floor exactly when `_lastGoodPrice[i] == 0`. So an
    ///         unanchored zero-weight slot would be sold at settle against a quote
    ///         reintroduced on the way OUT, where refusing is not an option and
    ///         the sandwich window is widest.
    ///
    ///         Anchoring every slot unconditionally is what makes that
    ///         unreachable, since `_execute` cannot run until this has been called
    ///         and this cannot succeed on a subset. Anyone loosening the coupling
    ///         has to close that hole another way first — anchoring zero-weight
    ///         slots on the settle path, or refusing to sell an unanchored slot.
    function submitPriceReports(bytes[] calldata signedReports) external {
        if (chainlinkVerifier == address(0)) revert PushModeNeedsNoReports();
        uint256 len = _allocations.length;
        if (signedReports.length != len) revert LengthMismatch();
        _requireAllowedPriceSources();
        for (uint256 i; i < len; ++i) {
            _verifyPrice(i, signedReports[i]);
        }
        emit PriceAnchorsRefreshed(msg.sender, block.timestamp);
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

    // ── Slippage helper ──

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
        uint256 lastGood = _lastGoodPrice[i];
        if (lastGood != 0) {
            uint256 staleValue = _tokensToValue(bal, lastGood, i, uint256(_assetDecimals));
            uint256 band = _staleSlippageBps(i);
            if (band > bandCap) band = bandCap;
            uint256 staleFloor = (staleValue * (BPS_DENOMINATOR - band)) / BPS_DENOMINATOR;
            if (chainlinkVerifier != address(0)) {
                (uint256 quoteFloor, bool quoted) = _tryQuoteMinOut(token, asset, bal, _swapExtraData[i]);
                if (quoted && quoteFloor > staleFloor) staleFloor = quoteFloor;
            }
            return staleFloor;
        }
        return _quoteMinOut(token, asset, bal, _swapExtraData[i]);
    }

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

    function _staleSlippageBps(uint256 i) private view returns (uint256) {
        uint256 recordedAt = _lastGoodAt[i];
        uint256 age = block.timestamp > recordedAt ? block.timestamp - recordedAt : 0;
        if (age >= STALE_WIDEN_PERIOD) return MAX_STALE_SLIPPAGE_BPS;
        return
            STALE_PRICE_SLIPPAGE_BPS + ((MAX_STALE_SLIPPAGE_BPS - STALE_PRICE_SLIPPAGE_BPS) * age) / STALE_WIDEN_PERIOD;
    }

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

    function _verifyPrice(uint256 i, bytes calldata signedReport) internal returns (uint256 price) {
        // Push-feed mode: `_feedIds[i]` packs an AggregatorV3 proxy (low 160
        // bits) + an optional per-slot max age (upper 96 bits). No signed
        // report is consumed, so callers must pass empty bytes (a nonempty
        // report would imply a Data Streams path that isn't taken).
        if (chainlinkVerifier == address(0)) {
            if (signedReport.length != 0) revert InvalidFeedId();
            return _pushFeedPrice(i);
        }

        // Empty `parameterPayload`: this proxy has no `FeeManager`, so there is no
        // fee token to nominate and nothing to pay. See `IVerifierProxy`.
        bytes memory verifierResponse = IVerifierProxy(chainlinkVerifier).verify(signedReport, "");
        ChainlinkReport memory report = abi.decode(verifierResponse, (ChainlinkReport));

        bytes32 expected = _feedIds[i];
        if (report.feedId != expected) revert WrongFeedId(i, expected, report.feedId);
        if (block.timestamp > report.expiresAt) revert StalePrice();
        if (report.price <= 0) revert InvalidAmount();

        uint256 observedAt = report.observationsTimestamp;
        if (observedAt > block.timestamp) observedAt = block.timestamp;
        if (observedAt == 0) revert StalePrice();

        // Chainlink prices are int192 with the report's declared decimals (8 for
        // tokenized stocks, 18 for crypto pairs). The raw oracle units are
        // preserved here; decimal-correct scaling happens in `rebalanceDelta`
        // via `_tokensToValue` using the per-allocation `_priceDecimals`.
        price = uint256(uint192(report.price));
        if (observedAt >= _lastGoodAt[i]) {
            _lastGoodPrice[i] = price;
            _lastGoodAt[i] = observedAt;
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

    /// @notice The price-source identifier bound to allocation `index`.
    /// @dev    In Data Streams mode this is the expected `feedId`, the exact
    ///         value `_verifyPrice` matches a report against. In push mode it is
    ///         the packed `(maxAge, aggregator)` word.
    ///
    ///         EXPOSED BECAUSE `submitPriceReports` IS PERMISSIONLESS. Anyone may
    ///         refresh the anchor, so anyone must be able to discover WHICH feed
    ///         to fetch a report for — otherwise the open function is only
    ///         usable by whoever kept the init calldata, which would hand the
    ///         proposer back the control the permissionless refresh exists to
    ///         remove.
    /// @param  index Allocation index; reverts `IndexOutOfRange` past the basket.
    function feedIdOf(uint256 index) external view returns (bytes32) {
        if (index >= _allocations.length) revert IndexOutOfRange(index);
        return _feedIds[index];
    }

    /// @notice When allocation `index`'s price anchor was last stamped, and the
    ///         price it was stamped at. Zero `recordedAt` means never.
    /// @dev    The pair `_staleSlippageBps` derives the widening band from, and
    ///         what `_execute` checks against `PRICE_ANCHOR_MAX_AGE_AT_EXECUTE`.
    ///         Exposed for the same reason as `feedIdOf`: a keeper deciding
    ///         whether a refresh is needed before executing or settling should
    ///         not have to infer it from events.
    /// @param  index Allocation index; reverts `IndexOutOfRange` past the basket.
    function priceAnchorOf(uint256 index) external view returns (uint256 price, uint256 recordedAt) {
        if (index >= _allocations.length) revert IndexOutOfRange(index);
        return (_lastGoodPrice[index], _lastGoodAt[index]);
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
