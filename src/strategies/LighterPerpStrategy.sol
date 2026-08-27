// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy, IAgentSet} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IStrategyDelivery} from "../interfaces/IStrategyDelivery.sol";
import {IZkLighter} from "../lighter/IZkLighter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISyndicateGovernor} from "../interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "../interfaces/ISyndicateVault.sol";

/// @notice The hops walked to resolve the governance-owned counterparty
///         allowlist from this strategy: `vault() -> governor() -> tierRegistry()
///         -> isCounterpartyAllowed(ZK_LIGHTER)`. The SAME registry, reached the
///         same way, that `ConcentratedLiquidityStrategy` binds the Uniswap
///         factory through.
/// @dev    Declared locally rather than imported, matching
///         `MorphoSupplyStrategy.ITierBindingPath` and
///         `PortfolioStrategy.ITierBindingPath`: every hop is a length-checked
///         raw staticcall, so the strategy takes on no type dependency and no
///         hop can revert `_initialize` undecodably. This exists to generate
///         selectors, not to type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isCounterpartyAllowed(address counterparty) external view returns (bool);
}

/**
 * @title LighterPerpStrategy
 * @notice Contract-owned Lighter (zkLighter) perp account. USDG is pulled from
 *         the vault and deposited into a strategy-owned margin account; an agent
 *         L2 trading key registered by the proposer drives trades off-chain via
 *         Lighter's API. The contract keeps the on-chain kill switch: cancel /
 *         market-close / withdraw all go through the venue authed by msg.sender.
 *
 *   Custody boundary (D1): the account is owned by THIS contract — only it can
 *   move funds. The agent key can trade but can never withdraw (changePubKey
 *   registers a trade-only L2 key; withdrawals are venue-authed to the account
 *   owner = this contract).
 *
 *   Settlement is THREE-STEP (G-H1 + C1/C2): withdrawals on Lighter are async
 *   priority requests that mature MUCH later (minutes to days), and the closing
 *   trades' PnL is not known until they fill.
 *     1. `initiateReturn()`        — cancel + both-side market-close every market.
 *     2. `queueWithdraw(ticks)`    — queue the drain, read off-chain AFTER the
 *                                    closes settle. Repeatable, and callable
 *                                    post-settle so an under-withdraw is never
 *                                    permanently stranded.
 *     3. `_settle()`               — claim the matured pending balance and push
 *                                    USDG to the vault, once everything queued
 *                                    has actually arrived.
 *
 *   Lane-B only: the venue exposes no on-chain mark anything here could trust —
 *   positions and margin are off-chain sequencer state and `IZkLighter` has no
 *   accessor for either — so the vault never prices an in-flight Lighter
 *   position and deposits/redeems settle at the frozen per-proposal queue price.
 *   `BaseStrategy` no longer carries a `positions()` / `selfManagesFees()` /
 *   `availableLiquidity()` / `withdrawTo()` surface to opt out of; what a
 *   template says about value it still holds is now `IStrategyDelivery`, and
 *   this template's three answers are `hasUndeliveredValue()`,
 *   `undeliveredValue()` and `hasUnvaluedResidue()` below — the last of which is
 *   how it declares the L2 margin it structurally cannot value.
 */
contract LighterPerpStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Venue (shared by 4663 mainnet + 9994663 fork — mainnet replay) ──
    IZkLighter internal constant ZK_LIGHTER = IZkLighter(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);
    IERC20 internal constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    uint16 internal constant USDG_ASSET_INDEX = 3;
    uint8 internal constant ROUTE_PERPS = 0;
    uint8 internal constant ORDER_MARKET = 1;
    uint8 internal constant SIDE_BID = 0; // long / buy
    uint8 internal constant SIDE_ASK = 1; // short / sell
    /// @dev Unwind closes use the widest legal price bound (SELL at 1, BUY at
    ///      2^32-1) so the close is GUARANTEED to fill — an unwind that silently
    ///      no-fills is strictly worse than a bad fill, because the margin then
    ///      never leaves the venue. The cost is that the unwind carries NO
    ///      slippage protection and is an MEV / adverse-fill surface: a
    ///      searcher who can see the pending priority request may fill it at a
    ///      punitive price. Accepted deliberately; see docs/LighterPerpStrategy.md.
    uint32 internal constant MARKET_SELL_PRICE = 1;
    uint32 internal constant MARKET_BUY_PRICE = type(uint32).max;

    // ── Init bounds ──
    uint256 internal constant PUBKEY_LEN = 40;
    uint8 internal constant MIN_API_KEY_INDEX = 2;
    uint8 internal constant MAX_API_KEY_INDEX = 254;
    uint16 internal constant MAX_MARKET_INDEX = 254;
    /// @dev M2: `initiateReturn` makes 2 venue calls per market in ONE tx. An
    ///      unbounded list could push it past the block gas limit, which would
    ///      make `returnsInitiatedAt` unreachable and therefore `_settle`
    ///      permanently unreachable — locking vault redemptions.
    uint256 internal constant MAX_MARKETS = 16;
    uint256 internal constant MIN_DEPOSIT = 1e6; // 1 USDG (6dp)
    /// @dev `IZkLighter.withdraw` takes `uint64` ticks and 1 tick == 1 USDG base
    ///      unit, so a deposit above this could never be drained in one request.
    uint256 internal constant MAX_DEPOSIT = type(uint64).max;

    // ── Chain guard (venue addresses above are hardcoded constants) ──
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ROBINHOOD_FORK = 9994663;

    // ── Guardrail actions ──
    // NOTE: 4 (WITHDRAW) is RETIRED — superseded by the top-level `queueWithdraw`,
    // which must also work in the `Settled` state and therefore cannot route
    // through `BaseStrategy.updateParams` (Executed-only). The number is left as
    // a hole so existing encodings for 1/2/3/5 keep their meaning; 4 now reverts
    // `InvalidAction`.
    uint8 internal constant ACTION_CANCEL_ALL = 1; // ()
    uint8 internal constant ACTION_CLOSE_MARKET = 2; // (uint16 market, uint32 price, uint8 isAsk)
    uint8 internal constant ACTION_ROTATE_KEY = 3; // (bytes newPubKey40)
    uint8 internal constant ACTION_REGISTER_KEY = 5; // ()

    // ── Storage (per-clone) ──
    bytes public apiKeyPubKey; // 40-byte Goldilocks L2 trading key
    uint8 public apiKeyIndex; // 2..254
    uint16[] public markets; // perp markets this clone may trade
    uint256 public depositAmount; // exact USDG pulled at execute; [MIN_DEPOSIT, MAX_DEPOSIT]
    uint256 public returnsInitiatedAt; // block.number of the FIRST initiateReturn(); 0 = not initiated
    bool public settled;
    /// @notice Cumulative ticks requested via `queueWithdraw`. The settle guard's
    ///         denominator: nothing settles until this much has come back.
    uint256 public queuedTicks;
    /// @notice Cumulative USDG this contract has pushed to the vault (settle push
    ///         + every sweep). Monotone, so a `collectResidue` sweep can never
    ///         shrink what the settle guard counts as delivered.
    uint256 public returnedAssets;
    /// @notice Proposer/vault-owner assertion that settling below `queuedTicks`
    ///         is intended (venue under-fill / write-off). Settle's escape hatch.
    bool public shortfallAcknowledged;
    /// @notice USDG actually pulled and deposited at `execute()`. Equal to
    ///         `depositAmount` on a fully covered proposal, and the
    ///         coverage-scaled figure otherwise — see `_execute`. Zero before
    ///         execution. THIS, not `depositAmount`, is what the unwind is
    ///         accounted against: `queueWithdraw` should drain this, and every
    ///         off-chain sizing (the CLI's `queue-withdraw --all`, the bench's
    ///         vault-delta assertion) must read it rather than the declaration.
    uint256 public deployedAmount;

    // ── Events ──
    event Deposited(uint256 amount, uint48 accountIndex);
    event AgentKeyRegistered(uint48 accountIndex, uint8 apiKeyIndex);
    event OrdersCancelled(uint48 accountIndex);
    event MarketClosed(uint16 market, uint8 isAsk);
    event WithdrawQueued(uint64 ticks, uint256 cumulativeTicks);
    event ReturnsInitiated(address indexed caller);
    event ShortfallAcknowledged(address indexed caller, uint256 queuedTicks, uint256 accounted);
    event Settled();
    event FundsSwept(uint256 amount);

    // ── Errors ──
    error InvalidPubKey();
    error InvalidApiKeyIndex();
    error NoMarkets();
    error InvalidMarket();
    error DuplicateMarket();
    error TooManyMarkets();
    error DepositTooSmall();
    error DepositTooLarge();
    error AccountNotRegistered();
    error InvalidAction();
    error NotAuthorized();
    error ReturnsNotInitiated();
    error AlreadyInitiated();
    error SettleTooSoon();
    error ZeroTicks();
    error NothingQueued();
    error WithdrawalInFlight(uint256 queued, uint256 accounted);
    error NoShortfall(uint256 queued, uint256 accounted);
    error UnsupportedChain();
    /// @notice The vault's ERC-4626 asset is not the `USDG` this template pins.
    error AssetMismatch();
    /// @notice `ZK_LIGHTER` does not carry counterparty standing in the registry
    ///         reached from this vault's governor.
    error CounterpartyNotAllowed(address counterparty, address registry);
    /// @notice `vault() -> governor() -> tierRegistry()` yielded nothing at init.
    error TierRegistryUnresolved();

    /// @dev Template-only guard (ERC-1167 clones skip constructors). The venue and
    ///      asset addresses above are `constant`, so a template deployed on any
    ///      other chain would point at whatever code happens to live there.
    constructor() {
        if (block.chainid != CHAIN_ROBINHOOD && block.chainid != CHAIN_ROBINHOOD_FORK) revert UnsupportedChain();
    }

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "LighterPerp";
    }

    /// @notice Decode: (bytes apiKeyPubKey, uint8 apiKeyIndex, uint16[] markets, uint256 depositAmount)
    /// @dev `depositAmount` IS MANDATORY AND EXPLICIT. It used to accept 0 as
    ///      "dynamic-all" — pull whatever USDG the vault happens to hold at
    ///      execute. That mode cannot survive the post-audit governor: the batch
    ///      that executes this proposal is checked against a per-call cap, and
    ///      `SyndicateVault` refuses a pull that would breach `QueueReserveBreached`
    ///      or `BufferBreached`. All three are decided against a SIZE, and a size
    ///      only knowable at execute time is a size nobody could vote on — a
    ///      deposit arriving between the vote and the execute silently enlarged
    ///      the pull. So the amount is pinned here, bounded on both ends, and
    ///      `_execute` never re-reads the vault's balance.
    ///
    ///      ALSO BINDS THE VAULT ASSET. The venue asset is a `constant` in this
    ///      template, so a vault whose ERC-4626 asset is anything else would have
    ///      every pull and every push denominated in a token that vault does not
    ///      account for — `_pushToVault` would credit it nothing measurable and
    ///      the residue probes below would report a figure in the wrong unit.
    ///      Same bind, same reason, as `MorphoSupplyStrategy`'s
    ///      `LoanAssetMismatch`.
    function _initialize(bytes calldata data) internal override {
        (bytes memory pubKey, uint8 keyIndex, uint16[] memory mkts, uint256 depositAmount_) =
            abi.decode(data, (bytes, uint8, uint16[], uint256));

        if (pubKey.length != PUBKEY_LEN) revert InvalidPubKey();
        if (keyIndex < MIN_API_KEY_INDEX || keyIndex > MAX_API_KEY_INDEX) revert InvalidApiKeyIndex();
        uint256 n = mkts.length;
        if (n == 0) revert NoMarkets();
        if (n > MAX_MARKETS) revert TooManyMarkets();
        // M2: dedupe with a 255-bit set (indices are bounded to 254, so `1 << m`
        // always fits a uint256). A padded/duplicated list would otherwise make
        // `initiateReturn` emit redundant venue calls for no benefit.
        uint256 seen;
        for (uint256 i; i < n; i++) {
            uint16 m = mkts[i];
            if (m > MAX_MARKET_INDEX) revert InvalidMarket();
            uint256 bit = 1 << m;
            if (seen & bit != 0) revert DuplicateMarket();
            seen |= bit;
        }
        if (depositAmount_ < MIN_DEPOSIT) revert DepositTooSmall();
        if (depositAmount_ > MAX_DEPOSIT) revert DepositTooLarge();

        if (address(USDG) != IERC4626(vault()).asset()) revert AssetMismatch();

        // INIT IS FAIL-CLOSED ON THE REGISTRY, AND ONLY INIT — matching
        // `MorphoSupplyStrategy._initialize`, whose note explains why a walk that
        // yields NO registry must be fatal here and a skip at `_execute`. A
        // governor created before `setTierRegistry`/`pushWiring` resolves to
        // nothing, and for that whole population an early-return bind would be a
        // silent no-op: the venue switch would read as armed while doing nothing.
        // Refusing at bind time costs a re-proposal; refusing at execute would
        // cost the deployed capital.
        address registry = _resolveTierRegistry();
        if (registry == address(0)) revert TierRegistryUnresolved();
        _requireAllowedCounterparty(registry, address(ZK_LIGHTER));

        apiKeyPubKey = pubKey;
        apiKeyIndex = keyIndex;
        markets = mkts;
        depositAmount = depositAmount_;
    }

    /// @notice Pull USDG from the vault and deposit into a strategy-owned Lighter
    ///         margin account (registers the account synchronously in this tx).
    function _execute() internal override {
        // NEVER RE-READ FROM THE VAULT, BUT SCALED BY THE PROPOSAL'S OWN
        // COVERAGE. `_initialize` pinned `depositAmount` and bounded it to
        // [MIN_DEPOSIT, MAX_DEPOSIT]; that declaration is still the CEILING and
        // the vault's live balance still never enters the sizing. What has
        // changed is that the ceiling is not always reachable: when the approve
        // quorum comes in short, `SyndicateGovernor._deriveAndStoreEffectiveCapital`
        // scales the whole proposal down by `raised / required` — the batch cap
        // AND every per-call cap. Pulling the pinned declaration into a scaled
        // batch reverts `CallCapExceeded` at the execute leg, a governance cycle
        // after the sizing decision was made and with the vault untouched.
        // Deploying less is the strictly better outcome, and the proposal was
        // already voted on as a ceiling.
        uint256 amountIn = _coverageScaledDeposit();

        // FAIL CLOSED RATHER THAN DEPLOY DUST. The bounds `_initialize`
        // enforced were on the DECLARATION; this is the first point at which
        // the amount that will actually move is known, so `MIN_DEPOSIT` is
        // re-asserted against it. A deeply under-covered proposal is not a
        // smaller strategy — it is a Lighter account whose unwind costs more in
        // venue round-trips than it holds, and the recoverable failure (the
        // proposal expires, the vault is untouched) beats the unrecoverable one.
        if (amountIn < MIN_DEPOSIT) revert DepositTooSmall();

        // RE-CERTIFY THE VENUE, and here only. Blocking `execute()` strands
        // nothing — the proposal expires at `executeBy` with the vault untouched
        // — while blocking `settle()`/`sweep()` would strand capital already at
        // Lighter. Degrades OPEN on an unresolved registry, which `_initialize`
        // has already refused to allow at bind time; the case that remains is a
        // registry unwired AFTER the clone was initialized, where the honest
        // answer is the same one `SyndicateVault._guardBatchCalls` gives when it
        // has no registry to ask.
        address registry = _resolveTierRegistry();
        if (registry != address(0)) _requireAllowedCounterparty(registry, address(ZK_LIGHTER));

        _pullFromVault(address(USDG), amountIn);
        USDG.forceApprove(address(ZK_LIGHTER), amountIn);
        ZK_LIGHTER.deposit(address(this), USDG_ASSET_INDEX, ROUTE_PERPS, amountIn);

        // RECORDED, because from here on `depositAmount` is only a declaration.
        // The unwind, the CLI's drain sizing and the residue probes all reason
        // about what actually left the vault.
        deployedAmount = amountIn;

        // `_acct()` reverts if the venue did not register the account in this tx.
        // Every kill-switch path needs a nonzero index, so failing the whole
        // execute (funds stay in the vault) beats custodying capital in an
        // account this contract cannot address.
        emit Deposited(amountIn, _acct());
    }

    /// @notice Register / re-assert the agent L2 trading key. Idempotent, and
    ///         reusable for rotation via the stored key.
    /// @dev    PROPOSER OR VAULT OWNER, not proposer alone. See
    ///         `guardrailAction` for why the owner needs a door here: after
    ///         `removeAgent` the proposer is no longer live, and a key that
    ///         cannot be re-registered is an account nobody can trade out of.
    function registerAgentKey() external {
        _requireProposerOrOwner();
        uint48 acct = _acct();
        ZK_LIGHTER.changePubKey(acct, apiKeyIndex, apiKeyPubKey);
        emit AgentKeyRegistered(acct, apiKeyIndex);
    }

    /// @notice Proposer-only guardrails via `(uint8 action, bytes args)`:
    ///           1 CANCEL_ALL()
    ///           2 CLOSE_MARKET(uint16 market, uint32 price, uint8 isAsk)  — single-side, side chosen off-chain
    ///           3 ROTATE_KEY(bytes newPubKey40)                          — updates stored key + changePubKey
    ///           5 REGISTER_KEY()                                          — (re)register the stored key
    ///         (4 WITHDRAW is retired — see `queueWithdraw`.)
    function _updateParams(bytes calldata data) internal override {
        (uint8 action, bytes memory args) = abi.decode(data, (uint8, bytes));
        uint48 acct = _acct();

        if (action == ACTION_CANCEL_ALL) {
            ZK_LIGHTER.cancelAllOrders(acct);
            emit OrdersCancelled(acct);
        } else if (action == ACTION_CLOSE_MARKET) {
            // H1/M3: `market` is DELIBERATELY not checked against `markets`. The
            // registered L2 key can trade ANY Lighter market — the venue enforces
            // no whitelist — so `markets` is only the automatic unwind list, not
            // the agent's reach. If the agent opens a position outside that list,
            // this is the operator's only way to close it. Impact is bounded:
            // `baseAmount = 0` can only CLOSE a position, never open one.
            (uint16 market, uint32 price, uint8 isAsk) = abi.decode(args, (uint16, uint32, uint8));
            ZK_LIGHTER.createOrder(acct, market, 0, price, isAsk, ORDER_MARKET);
            emit MarketClosed(market, isAsk);
        } else if (action == ACTION_ROTATE_KEY) {
            bytes memory newPubKey = abi.decode(args, (bytes));
            if (newPubKey.length != PUBKEY_LEN) revert InvalidPubKey();
            apiKeyPubKey = newPubKey;
            ZK_LIGHTER.changePubKey(acct, apiKeyIndex, newPubKey);
            emit AgentKeyRegistered(acct, apiKeyIndex);
        } else if (action == ACTION_REGISTER_KEY) {
            ZK_LIGHTER.changePubKey(acct, apiKeyIndex, apiKeyPubKey);
            emit AgentKeyRegistered(acct, apiKeyIndex);
        } else {
            revert InvalidAction();
        }
    }

    /// @notice The same guardrail actions `updateParams` dispatches, reachable by
    ///         the VAULT OWNER as well as the proposer.
    /// @dev    CLOSES A LIVENESS HOLE, not a permission gap. Every guardrail —
    ///         `CANCEL_ALL`, `CLOSE_MARKET`, `ROTATE_KEY`, `REGISTER_KEY` — was
    ///         reachable only through `BaseStrategy.updateParams`, which is
    ///         `onlyProposer`, which since the pashov finding-#9 fix re-reads the
    ///         vault's LIVE agent set. So the owner's own revocation lever,
    ///         `SyndicateVault.removeAgent`, KILLED THE KILL SWITCH: the moment
    ///         a misbehaving agent was de-registered, nobody could cancel its
    ///         resting orders or close its positions, the L2 key stayed
    ///         registered and tradeable, and the account sat exposed until
    ///         `strategyDuration` elapsed and the permissionless `initiateReturn`
    ///         opened. Revoking the agent made the position LESS controllable,
    ///         which is precisely backwards.
    ///
    ///         The owner is the right second holder: `SyndicateVault.owner()` is
    ///         the party that could remove the agent in the first place, and the
    ///         actions here cannot move funds anywhere — `CLOSE_MARKET` passes
    ///         `baseAmount = 0`, which the venue can only use to CLOSE a
    ///         position, and every withdrawal is venue-authed to this contract,
    ///         which only ever pushes to `vault()`.
    ///
    ///         `updateParams` is left exactly as it was: it is the `IStrategy`
    ///         surface the governor and the CLI already speak, and widening a
    ///         base-contract modifier for one template would change the auth of
    ///         every other one.
    function guardrailAction(bytes calldata data) external {
        _requireProposerOrOwner();
        if (_state != State.Executed) revert NotExecuted();
        _updateParams(data);
    }

    /// @notice Unwind step 1: cancel every resting order and both-side
    ///         market-close every configured market. Queues NOTHING — the drain
    ///         amount is only knowable after these closes fill (C1).
    /// @dev    Auth: LIVE proposer or vault owner anytime post-execute; anyone
    ///         once `strategyDuration` has elapsed on the live proposal.
    ///         Re-callable by the privileged callers (closes are idempotent in
    ///         effect); a permissionless caller may only KICK OFF the unwind, so
    ///         a griefer cannot spam venue priority requests block after block.
    ///
    ///         THE OWNER BRANCH IS THE LIVENESS FIX (see `guardrailAction`).
    ///         Without it, `removeAgent` pinned settlement shut until
    ///         `strategyDuration` expired: the de-registered proposer failed the
    ///         live-agent check, and nobody else could start the unwind.
    ///
    ///         `_isLiveProposer` RATHER THAN A BARE `msg.sender != proposer()`.
    ///         The hand-rolled comparison bypassed the live-agent re-check that
    ///         `onlyProposer` performs, so a de-registered agent kept the
    ///         PRIVILEGED branch — unbounded re-calls with no timing gate —
    ///         which is the standing the revocation was supposed to remove. It
    ///         now falls through to the permissionless branch, where it has
    ///         exactly as much authority as anyone else and no more.
    function initiateReturn() external {
        if (_state != State.Executed) revert NotExecuted();

        if (!_isLiveProposer(msg.sender) && !_isVaultOwner(msg.sender)) {
            // M1: `getProposal(0)` returns a ZEROED struct rather than reverting,
            // so `block.timestamp < 0 + 0` is false and the timing gate alone is
            // fail-OPEN for everyone once `_activeProposal` has been cleared —
            // which is exactly what the emergency-settle paths do while this
            // strategy is still `Executed`.
            ISyndicateGovernor gov = ISyndicateGovernor(ISyndicateVault(vault()).governor());
            uint256 pid = gov.getActiveProposal();
            if (pid == 0) revert NotAuthorized();
            ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
            if (p.strategy != address(this)) revert NotAuthorized();
            if (block.timestamp < p.executedAt + p.strategyDuration) revert NotAuthorized();
            if (returnsInitiatedAt != 0) revert AlreadyInitiated();
        }

        uint48 acct = _acct();
        ZK_LIGHTER.cancelAllOrders(acct);
        // Trustless close: the contract can't read a position's sign, so it emits
        // both a SELL-close and a BUY-close per market — the one opposing the open
        // position fills, the other no-ops against a flat/absent position.
        // PROVEN on 4663 (2026-08-23, H2 canary, account 623): a baseAmount=0
        // market order fired against a FLAT book did nothing — 37 API samples
        // over 2 minutes, size 0.0 throughout. See test/harness/LighterH2Canary.md.
        uint256 n = markets.length;
        for (uint256 i; i < n; i++) {
            uint16 m = markets[i];
            ZK_LIGHTER.createOrder(acct, m, 0, MARKET_SELL_PRICE, SIDE_ASK, ORDER_MARKET);
            ZK_LIGHTER.createOrder(acct, m, 0, MARKET_BUY_PRICE, SIDE_BID, ORDER_MARKET);
        }

        // Latch on the FIRST call only. Re-latching would reset the async-maturity
        // clock and let a repeat caller hold `_settle` in `SettleTooSoon` forever.
        if (returnsInitiatedAt == 0) returnsInitiatedAt = block.number;
        emit ReturnsInitiated(msg.sender);
    }

    /// @notice Unwind step 2: queue an async USDG withdrawal of `ticks`
    ///         (1 USDG = 1e6 ticks) from the margin account to THIS contract.
    /// @dev    C1: deliberately separate from `initiateReturn` and callable in
    ///         BOTH `Executed` and `Settled`. The closing trades' PnL is not known
    ///         until they fill, so any amount read off-chain before them is
    ///         structurally stale; under-stating must therefore stay correctable
    ///         AFTER settle, which rules out routing this through
    ///         `BaseStrategy.updateParams` (Executed-only).
    ///
    ///         C2: proposer/vault-owner-gated. The permissionless unwind path
    ///         must never be able to choose the drain amount — a wrong amount
    ///         cannot be un-queued and, pre-fix, poisoned the whole settlement.
    ///
    ///         Destination is structurally this contract (the venue pays the
    ///         account owner) and this contract only ever pushes to `vault()`,
    ///         so widening auth adds no exfiltration surface.
    function queueWithdraw(uint64 ticks) external {
        if (_state == State.Pending) revert NotExecuted();
        _requireProposerOrOwner();
        if (ticks == 0) revert ZeroTicks();

        queuedTicks += ticks;
        ZK_LIGHTER.withdraw(_acct(), USDG_ASSET_INDEX, ROUTE_PERPS, ticks);
        emit WithdrawQueued(ticks, queuedTicks);
    }

    /// @notice Waive the settle guard's "everything queued has come back" check.
    /// @dev    The contract cannot read its own L2 balance, so it can only verify
    ///         that what it ASKED for has arrived. When the venue under-fills
    ///         (partial fill, forced liquidation, a write-off), that check would
    ///         otherwise hold `_settle` shut. Proposer or vault owner asserts the
    ///         shortfall is real and settlement should book it. It only relaxes a
    ///         timing gate — it cannot redirect funds, and anything that matures
    ///         later is still recoverable post-settle via `queueWithdraw` +
    ///         `recoverResiduals`.
    ///
    ///         R3: the waiver is gated on an ACTUAL, currently-observable
    ///         shortfall. Ungated it was a one-call bypass of BOTH settle guards
    ///         from the moment the strategy went `Executed` — arm it before the
    ///         closes and before any drain, and `settle()` booked the entire
    ///         principal as a 100% loss with the funds still at the venue. The
    ///         stranding is recoverable (C1), but the damage is the Lane-B price
    ///         stamp: `onProposalSettled` freezes the per-proposal redeem price
    ///         at the deflated NAV, so a later `recoverResiduals` top-up lands
    ///         AFTER the stamp and the haircut falls on the exiting LPs.
    ///         Preconditions, all three necessary:
    ///           - `ReturnsNotInitiated` — you cannot acknowledge a shortfall on
    ///             positions that were never closed.
    ///           - `NothingQueued`       — nor on a drain that was never asked
    ///             for; there is no denominator to fall short of.
    ///           - `NoShortfall`         — nor when everything asked for is
    ///             already accounted. `returnedAssets` is monotone so `accounted`
    ///             only grows: if it ever reaches `queuedTicks`, `_settle` passes
    ///             unaided and the waiver is not needed. Arming while
    ///             `accounted == 0` (nothing matured yet) stays legal — that is
    ///             the normal venue-under-fill case.
    function acknowledgeShortfall() external {
        _requireProposerOrOwner();
        if (returnsInitiatedAt == 0) revert ReturnsNotInitiated();
        if (queuedTicks == 0) revert NothingQueued();

        uint256 accounted = returnedAssets + ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX)
            + USDG.balanceOf(address(this));
        if (accounted >= queuedTicks) revert NoShortfall(queuedTicks, accounted);

        shortfallAcknowledged = true;
        emit ShortfallAcknowledged(msg.sender, queuedTicks, accounted);
    }

    /// @notice Unwind step 3 (governor-called). Claims the matured pending USDG
    ///         and pushes this contract's entire USDG balance to the vault.
    /// @dev    Guards, in order:
    ///           - `ReturnsNotInitiated` — positions were never closed.
    ///           - `SettleTooSoon`       — same block as the close (async maturity).
    ///           - `NothingQueued`       — no drain was ever requested, so a
    ///             permissionless settle would book the whole principal as a loss.
    ///           - `WithdrawalInFlight`  — a drain was requested but has not fully
    ///             arrived; settling now books a phantom loss a depositor could
    ///             sandwich. Replaces the old `pending == 0 && bal == 0` check,
    ///             which anyone could satisfy by donating 1 wei of USDG.
    ///         `acknowledgeShortfall()` waives the last two.
    ///
    ///         SCOPE (be precise about what this does NOT do): the denominator is
    ///         `queuedTicks`, which the proposer chooses. This is a LIVENESS /
    ///         anti-phantom-loss check — "everything I ASKED for came back" — and
    ///         NOT a completeness check. `queueWithdraw(1)` plus one tick maturing
    ///         satisfies it with the rest of the account still at the venue. It
    ///         cannot be made complete on-chain: the contract has no way to read
    ///         its own L2 balance (positions and margin are off-chain sequencer
    ///         state, and IZkLighter exposes no accessor). Completeness is an
    ///         OFF-CHAIN guarantee — the CLI's `queue-withdraw --all` reads the
    ///         true L2 balance from the Lighter API and hard-aborts on any nonzero
    ///         position — and it sits in the same trust bucket as the agent key.
    ///         See the trust model in docs/LighterPerpStrategy.md.
    function _settle() internal override {
        if (returnsInitiatedAt == 0) revert ReturnsNotInitiated();
        if (block.number <= returnsInitiatedAt) revert SettleTooSoon();

        uint128 pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        uint256 bal = USDG.balanceOf(address(this));

        if (!shortfallAcknowledged) {
            if (queuedTicks == 0) revert NothingQueued();
            // 1 tick == 1 USDG base unit (both 6dp), so ticks and assets compare
            // directly. `returnedAssets` keeps the total MONOTONE: a
            // `collectResidue` sweep immediately before settle moves value to
            // the vault without shrinking what counts as delivered.
            uint256 accounted = returnedAssets + pending + bal;
            if (accounted < queuedTicks) revert WithdrawalInFlight(queuedTicks, accounted);
        }

        if (pending > 0) ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
        _sweep();

        settled = true;
        emit Settled();
    }

    /// @dev Claim everything the venue has matured for this contract. Shared by
    ///      `sweep()` and the permissionless `recoverResiduals()`; `_settle`
    ///      keeps its own inline claim because it has already read `pending` for
    ///      the settle guard and must not pay for the read twice.
    function _claimMatured() internal returns (uint128 pending) {
        pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        if (pending > 0) ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
    }

    /// @notice Claim any matured pending balance from the venue INTO THIS
    ///         CONTRACT. Permissionless, repeatable, and NOT gated on `settled`.
    /// @dev    CLAIM-ONLY, AND DELIBERATELY NOT A PUSH. It used to push to the
    ///         vault as well, which made it a SECOND door onto the balance delta
    ///         `SyndicateVault._recoverResidueVia` measures across `sweep()`.
    ///         That delta is a complete measurement only while there is exactly
    ///         one door: assets arriving outside the window credit the exited
    ///         redeem cohort nothing (`_payCohortShare` sees zero) and silently
    ///         lift the price for whoever stayed — unrepairably, because the
    ///         delta is spent. `MorphoSupplyStrategy.sweep` and
    ///         `ConcentratedLiquidityStrategy.sweep` were made `onlyVault` for
    ///         exactly this reason and this template now matches them.
    ///
    ///         What is preserved is the property that made this permissionless
    ///         in the first place (H-4): a proposal resolved through
    ///         `finalizeEmergencySettle` never calls `strategy.settle()`, so
    ///         nobody privileged may be around to move matured funds off the
    ///         venue. Anyone may still do that half, at any time, with no
    ///         privilege — the USDG simply lands HERE, where the vault's own
    ///         permissionless `collectResidue(this)` then measures and collects
    ///         it through the single door.
    function recoverResiduals() external {
        _claimMatured();
    }

    /// @notice The vault's residue door: claim whatever has matured at the venue
    ///         and push this contract's whole USDG balance home.
    /// @dev    `onlyVault`, and the selector is load-bearing —
    ///         `SyndicateVault.collectResidue` dispatches `bytes4(keccak256("sweep()"))`
    ///         (`_SEL_SWEEP == 0x35faa416`) with the result ignored, so the name
    ///         is part of the ABI contract with the vault. Renamed from
    ///         `sweepToVault()`, which that dispatch could never reach.
    ///
    ///         NOT GATED ON `State.Settled`, unlike both sibling templates. The
    ///         H-4 reasoning holds here and does not hold there: a Lighter clone
    ///         resolved by `finalizeEmergencySettle` stays `Executed` forever
    ///         while still holding — or still owed — real USDG, and a
    ///         `Settled`-gated door would strand it permanently with no
    ///         permissionless way out. The siblings accept that gate because
    ///         their residue is a lending position the vault can still see; this
    ///         template's residue is a venue balance it cannot.
    ///
    ///         Idempotent and safe to call with nothing to move.
    /// @return assets The USDG pushed to the vault this call.
    function sweep() external onlyVault returns (uint256 assets) {
        _claimMatured();
        return _sweep();
    }

    // ── IStrategyDelivery (the vault's residue probes) ──

    /// @inheritdoc IStrategyDelivery
    /// @dev True while a settled clone still holds USDG, or is still owed USDG
    ///      the venue has matured — exactly what `sweep()` above would move. The
    ///      vault reads it under `_PROBE_GAS` (150k) to keep deposits shut over
    ///      that window, because `totalAssets()` prices anything held here at
    ///      zero and a depositor would otherwise mint against a NAV missing it.
    ///
    ///      SAME BASIS AS `undeliveredValue()` — both read the pending balance
    ///      plus the idle balance, ticks 1:1 with USDG base units (both 6dp), no
    ///      conversion and no price source in either — but NOT the same
    ///      arithmetic: this bool applies the `RESIDUE_DUST` floor to EACH term,
    ///      while the amount is the unfiltered sum. Two sub-dust terms
    ///      (e.g. 900 + 900) therefore report `false` here with a nonzero
    ///      `undeliveredValue()` of 1,800 — deliberate (each term alone is
    ///      donation-sized dust; `test_delivery_dustDonation_doesNotTripTheLock`
    ///      pins the shape) and bounded at `2 * RESIDUE_DUST`, matching
    ///      `MorphoSupplyStrategy`'s identical per-term floor. Two staticcalls,
    ///      no loops — comfortably inside the probe cap.
    ///
    ///      `Settled` ONLY, matching both sibling templates and for their reason
    ///      rather than a new one: answering for `Executed` too would report
    ///      residue on every live proposal, since a clone mid-strategy always has
    ///      value at the venue. That is what `openProposalCount() != 0` already
    ///      gates, so it would be redundant — and it would shut deposits for the
    ///      whole strategy period on top of it.
    function hasUndeliveredValue() public view override returns (bool) {
        if (_state != State.Settled) return false;
        if (uint256(ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX)) > RESIDUE_DUST) return true;
        return USDG.balanceOf(address(this)) > RESIDUE_DUST;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev USDG IS the vault asset (`_initialize` binds it against
    ///      `IERC4626(vault()).asset()`), and a withdrawal tick IS a USDG base
    ///      unit, so both terms are already denominated in vault-asset units.
    ///      No oracle, no pool read, and nothing an attacker can move inside the
    ///      settlement transaction.
    function undeliveredValue() public view override returns (uint256) {
        if (_state != State.Settled) return 0;
        return uint256(ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX)) + USDG.balanceOf(address(this));
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev THE EXACT COMPLEMENT OF WHAT `undeliveredValue()` CAN SEE. That
    ///      figure counts matured ticks and idle USDG — everything that has
    ///      already crossed back onto L1. It cannot count the margin still SITTING
    ///      at Lighter: positions and margin are off-chain sequencer state and
    ///      `IZkLighter` exposes no accessor for either, which is the same reason
    ///      this template is Lane-B and reports no positions at all.
    ///
    ///      So this declares the two states in which unpriced value is still out
    ///      there, and the vault refuses to mint at all while either holds:
    ///        - `returnedAssets < queuedTicks` — a drain was asked for and has not
    ///          fully arrived. Reachable after settlement too, because
    ///          `queueWithdraw` stays callable in `Settled` (C1) precisely so an
    ///          under-withdraw can be corrected.
    ///        - `shortfallAcknowledged` — settlement was let through on the
    ///          assertion that the venue under-filled. That assertion says the
    ///          contract could not verify its own L2 balance, which is exactly
    ///          "there may be value here I cannot value".
    ///
    ///      THE DEPOSIT-LOCK CONSEQUENCE, STATED PLAINLY. A true here marks the
    ///      clone in `SyndicateVault._recordResidue` and shuts vault deposits —
    ///      but only for `UNVALUED_MAX_LOCK` from the mark, after which
    ///      `depositsLocked()` reads false again and anyone may
    ///      `pruneUnvaluedMark(this)` to burn the mark and re-arm the gate for
    ///      the next one. So an acknowledged shortfall, which never clears on its
    ///      own, costs the vault one bounded deposit window and not a permanent
    ///      freeze. A clean settle — everything queued came back, no shortfall —
    ///      answers false immediately and locks nothing.
    ///
    ///      Storage reads only: no external call, so no venue outage and no gas
    ///      griefing can suppress this probe the way an IRM could suppress
    ///      Morpho's.
    function hasUnvaluedResidue() public view override returns (bool) {
        if (_state != State.Settled) return false;
        if (shortfallAcknowledged) return true;
        return returnedAssets < queuedTicks;
    }

    // ── Views ──

    /// @notice This contract's Lighter account index (0 until the first deposit).
    function accountIndex() external view returns (uint48) {
        return ZK_LIGHTER.addressToAccountIndex(address(this));
    }

    /// @notice USDG ticks matured on Lighter and awaiting claim.
    function pendingBalance() external view returns (uint128) {
        return ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
    }

    // ── Internal ──

    /// @dev Shared account-index read. Every venue-calling path goes through this
    ///      so none of them can address account 0 (which is a DIFFERENT account,
    ///      not "no account") if registration ever stops being synchronous.
    function _acct() internal view returns (uint48 acct) {
        acct = ZK_LIGHTER.addressToAccountIndex(address(this));
        if (acct == 0) revert AccountNotRegistered();
    }

    // ── Auth ──

    /// @dev `BaseStrategy.onlyProposer`'s predicate, as an expression rather than
    ///      a modifier, so the paths that also admit the vault owner can consult
    ///      it instead of hand-rolling `msg.sender == proposer()`.
    ///
    ///      THAT HAND-ROLLED COMPARISON WAS THE BUG. `queueWithdraw`,
    ///      `acknowledgeShortfall` and `initiateReturn` each wrote it out, which
    ///      skipped the LIVE agent-set re-check `onlyProposer` performs — so
    ///      `SyndicateVault.removeAgent` did not actually revoke anything on an
    ///      already-deployed clone, and the whole point of the pashov finding-#9
    ///      fix (`BaseStrategy.sol:103-136`) was that revocation must bite.
    ///
    ///      Byte-for-byte the same read as the modifier, including the raw
    ///      staticcall and the explicit length check: a typed call into a vault
    ///      that cannot answer `isAgent` would revert in THIS frame with no data,
    ///      turning a missing selector into an undecodable failure of every
    ///      proposer-gated path rather than a stated one. Unanswerable resolves
    ///      to FALSE here, which for a caller who is also not the owner means
    ///      `NotAuthorized` — closed, matching the modifier.
    function _isLiveProposer(address who) internal view returns (bool) {
        if (who != proposer()) return false;
        (bool ok, bytes memory ret) = vault().staticcall(abi.encodeCall(IAgentSet.isAgent, (who)));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    /// @dev The vault owner — the party that can seat and remove agents, and
    ///      therefore the right holder of the second key on every guardrail.
    function _isVaultOwner(address who) internal view returns (bool) {
        return who == ISyndicateVault(vault()).owner();
    }

    function _requireProposerOrOwner() internal view {
        if (!_isLiveProposer(msg.sender) && !_isVaultOwner(msg.sender)) revert NotAuthorized();
    }

    // ── Governance-allowlist binding ──

    /// @dev BINDS THE VENUE ON THE COUNTERPARTY AXIS, the way
    ///      `ConcentratedLiquidityStrategy` binds the Uniswap factory. `ZK_LIGHTER`
    ///      is a `constant` here rather than proposer input, so this is not
    ///      protection against a hostile address — it is the governance switch
    ///      that lets an owner make this template INERT without touching the
    ///      `StrategyFactory` allowlist or waiting on a redeploy. Lighter is a
    ///      third-party rollup whose sequencer this protocol does not control;
    ///      "stop opening new positions there, now" needs to be one owner call.
    ///
    ///      The counterparty axis and not the adapter axis, for CL's reason:
    ///      `setAdapterAllowed` is the flag `SyndicateVault._guardBatchCalls`
    ///      reads to decide whether proposer-authored calldata may name an
    ///      address as an approve spender or transfer recipient. Listing the
    ///      venue there would widen the batch guard as a side effect of a
    ///      strategy decision. `isCounterpartyAllowed` is the weak grant — a
    ///      CERTIFIED TEMPLATE may approve this from inside its own reviewed code
    ///      path — which is exactly what `_execute` does.
    ///
    ///      Called from `_initialize` (fail-CLOSED, including on an unresolved
    ///      registry) and from `_execute` (re-certified, degrading OPEN on an
    ///      unresolved registry). Deliberately NOT from `_settle`, `sweep` or
    ///      `recoverResiduals`: those are the exit path, and gating them would
    ///      hand a demotion — or an unreachable registry — the power to freeze
    ///      capital already at the venue. `MorphoSupplyStrategy._requireAllowedMorpho`
    ///      spells the same asymmetry out.
    function _requireAllowedCounterparty(address registry, address counterparty) private view {
        if (!_readAllowed(registry, abi.encodeCall(ITierBindingPath.isCounterpartyAllowed, (counterparty)))) {
            revert CounterpartyNotAllowed(counterparty, registry);
        }
    }

    /// @dev The `vault() -> governor() -> tierRegistry()` walk. `address(0)` when
    ///      unresolved (no `governor()` surface, a governor predating the getter,
    ///      or `tierRegistry() == 0`).
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
    }

    /// @dev Staticcall-safe allowlist read. Unreadable → `false`.
    ///
    ///      READS THE WORD, DOES NOT `abi.decode` IT. `abi.decode(ret, (bool))`
    ///      reverts on any returned word outside `{0, 1}`, and that revert would
    ///      land in THIS frame with nothing to catch it — bricking `_initialize`
    ///      instead of resolving to "not vouched for". Mirrors
    ///      `ConcentratedLiquidityStrategy._readAllowed`.
    function _readAllowed(address registry, bytes memory data) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) = registry.staticcall(data);
        if (!ok || ret.length != 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return word != 0;
    }

    // ── Coverage scaling ──

    /// @dev The USDG `_execute` will actually pull: `depositAmount` scaled by
    ///      the SAME `raised / required` ratio the governor applied to the
    ///      proposal at execute time, expressed as `effectiveMaxCapital /
    ///      maxCapital` because those are the two figures a strategy can read.
    ///
    ///      WHY THE RATIO AND NOT `min(depositAmount, effectiveMaxCapital)`.
    ///      There are TWO caps in play and the smaller one is not the one that
    ///      names the batch. `effectiveMaxCapital` is the batch-level net-outflow
    ///      meter; `BatchExecutorLib` additionally meters THIS call's gross
    ///      outflow against `_scaleCaps`'s `floor(cap_i * raised / required)`.
    ///      A proposal normally declares `maxCapital` as the vault's whole TVL
    ///      and `cap_i` as just the deploy size (the fork bench does exactly
    ///      that), so `min(depositAmount, effectiveMaxCapital)` resolves to the
    ///      unscaled `depositAmount` and still breaks the per-call cap. The
    ///      ratio form cannot: `floor(dep * floor(max*r/q) / max) <=
    ///      floor(dep * r / q) = scaledCap_i` for any `dep <= cap_i`, because the
    ///      inner floor only ever moves the numerator DOWN. The residue is at
    ///      most a couple of base units, always on the safe side.
    ///
    ///      DEGRADES TO THE PINNED AMOUNT, and only there. An unresolvable
    ///      governor, a governor predating `getEffectiveMaxCapital` (issue #27),
    ///      a zero declared envelope, or an effective capital at or above the
    ///      declared one all mean "nothing scaled this proposal" — and a
    ///      governor that does not scale the envelope does not scale the caps
    ///      either, so the pinned pull is exactly what such a batch expects.
    ///      Every read is a length-checked raw staticcall for the reason the
    ///      rest of this file gives: a typed call into a governor that cannot
    ///      answer would revert in THIS frame with no data, turning a missing
    ///      selector into an undecodable `execute()` failure.
    function _coverageScaledDeposit() private view returns (uint256) {
        uint256 pinned = depositAmount;

        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return pinned;
        (bool okPid, uint256 pid) = _readUint(governor_, abi.encodeCall(ISyndicateGovernor.getActiveProposal, ()));
        if (!okPid || pid == 0) return pinned;

        (bool okMax, uint256 declared) = _readUint(governor_, abi.encodeCall(ISyndicateGovernor.getRiskEnvelope, (pid)));
        if (!okMax || declared == 0) return pinned;
        (bool okEff, uint256 effective) =
            _readUint(governor_, abi.encodeCall(ISyndicateGovernor.getEffectiveMaxCapital, (pid)));
        if (!okEff || effective >= declared) return pinned;

        // `mulDiv` rather than `*` then `/`: the product is bounded in practice
        // (`pinned <= type(uint64).max`) but `declared` is proposer input, and a
        // revert here would brick `execute()` on an arithmetic edge instead of
        // sizing it. Floors, matching `_scaleCaps` and `effectiveMaxCapital`.
        return Math.mulDiv(pinned, effective, declared);
    }

    /// @dev Staticcall-safe leading-word read. Codeless target, revert, or short
    ///      return all resolve to `(false, 0)` — distinguishable from a genuine
    ///      zero answer, which the callers above need.
    function _readUint(address target, bytes memory data) private view returns (bool, uint256) {
        if (target.code.length == 0) return (false, 0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return (false, 0);
        uint256 word;
        // Leading word of the payload; `getRiskEnvelope` returns two and only
        // the first (`maxCapital`) is wanted, which `abi.decode` cannot express.
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return (true, word);
    }

    /// @dev Staticcall-safe address read: codeless target, revert, short return,
    ///      or dirty upper bits all resolve to `address(0)`.
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

    function _sweep() internal returns (uint256 bal) {
        bal = USDG.balanceOf(address(this));
        if (bal == 0) return 0;
        returnedAssets += bal;
        _pushToVault(address(USDG), bal);
        emit FundsSwept(bal);
    }
}
