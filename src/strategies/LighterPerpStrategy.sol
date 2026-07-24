// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IZkLighter} from "../lighter/IZkLighter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISyndicateGovernor} from "../interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "../interfaces/ISyndicateVault.sol";

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
 *   Lane-B only: `positions()` stays empty (inherited) — the venue exposes no
 *   on-chain mark the PriceRouter can trust, so deposits/redeems settle at the
 *   frozen per-proposal queue price.
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
    uint256 public depositAmount; // 0 = dynamic-all (vault's full USDG at execute)
    uint256 public returnsInitiatedAt; // block.number of the FIRST initiateReturn(); 0 = not initiated
    bool public settled;
    /// @notice Cumulative ticks requested via `queueWithdraw`. The settle guard's
    ///         denominator: nothing settles until this much has come back.
    uint256 public queuedTicks;
    /// @notice Cumulative USDG this contract has pushed to the vault (settle push
    ///         + every sweep). Monotone, so a permissionless `sweepToVault()` can
    ///         never shrink what the settle guard counts as delivered.
    uint256 public returnedAssets;
    /// @notice Proposer/vault-owner assertion that settling below `queuedTicks`
    ///         is intended (venue under-fill / write-off). Settle's escape hatch.
    bool public shortfallAcknowledged;

    // ── Events ──
    event Deposited(uint256 amount, uint48 accountIndex);
    event AgentKeyRegistered(uint48 accountIndex, uint8 apiKeyIndex);
    event OrdersCancelled(uint48 accountIndex);
    event MarketClosed(uint16 market, uint8 isAsk);
    event WithdrawQueued(uint64 ticks, uint256 cumulativeTicks);
    event ReturnsInitiated(address indexed caller);
    event ShortfallAcknowledged(address indexed caller);
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
    error UnsupportedChain();

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
    /// @dev depositAmount == 0 ⇒ dynamic-all (use the vault's full USDG balance at execute).
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
        if (depositAmount_ > MAX_DEPOSIT) revert DepositTooLarge();

        apiKeyPubKey = pubKey;
        apiKeyIndex = keyIndex;
        markets = mkts;
        depositAmount = depositAmount_;
    }

    /// @notice Pull USDG from the vault and deposit into a strategy-owned Lighter
    ///         margin account (registers the account synchronously in this tx).
    function _execute() internal override {
        uint256 amountIn = depositAmount;
        if (amountIn == 0) amountIn = USDG.balanceOf(vault());
        if (amountIn < MIN_DEPOSIT) revert DepositTooSmall();
        if (amountIn > MAX_DEPOSIT) revert DepositTooLarge();

        _pullFromVault(address(USDG), amountIn);
        USDG.forceApprove(address(ZK_LIGHTER), amountIn);
        ZK_LIGHTER.deposit(address(this), USDG_ASSET_INDEX, ROUTE_PERPS, amountIn);

        // `_acct()` reverts if the venue did not register the account in this tx.
        // Every kill-switch path needs a nonzero index, so failing the whole
        // execute (funds stay in the vault) beats custodying capital in an
        // account this contract cannot address.
        emit Deposited(amountIn, _acct());
    }

    /// @notice Register / re-assert the agent L2 trading key. Proposer-driven,
    ///         idempotent, and reusable for rotation via the stored key.
    function registerAgentKey() external onlyProposer {
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

    /// @notice Unwind step 1: cancel every resting order and both-side
    ///         market-close every configured market. Queues NOTHING — the drain
    ///         amount is only knowable after these closes fill (C1).
    /// @dev    Auth: proposer anytime post-execute; anyone once `strategyDuration`
    ///         has elapsed on the live proposal. Re-callable by the proposer
    ///         (closes are idempotent in effect); a permissionless caller may
    ///         only KICK OFF the unwind, so a griefer cannot spam venue priority
    ///         requests block after block.
    function initiateReturn() external {
        if (_state != State.Executed) revert NotExecuted();

        if (msg.sender != proposer()) {
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
        if (msg.sender != proposer() && msg.sender != ISyndicateVault(vault()).owner()) revert NotAuthorized();
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
    function acknowledgeShortfall() external {
        if (msg.sender != proposer() && msg.sender != ISyndicateVault(vault()).owner()) revert NotAuthorized();
        shortfallAcknowledged = true;
        emit ShortfallAcknowledged(msg.sender);
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
    function _settle() internal override {
        if (returnsInitiatedAt == 0) revert ReturnsNotInitiated();
        if (block.number <= returnsInitiatedAt) revert SettleTooSoon();

        uint128 pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        uint256 bal = USDG.balanceOf(address(this));

        if (!shortfallAcknowledged) {
            if (queuedTicks == 0) revert NothingQueued();
            // 1 tick == 1 USDG base unit (both 6dp), so ticks and assets compare
            // directly. `returnedAssets` keeps the total MONOTONE: a
            // permissionless `sweepToVault()` immediately before settle moves
            // value to the vault without shrinking what counts as delivered.
            uint256 accounted = returnedAssets + pending + bal;
            if (accounted < queuedTicks) revert WithdrawalInFlight(queuedTicks, accounted);
        }

        if (pending > 0) ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
        _sweep();

        settled = true;
        emit Settled();
    }

    /// @notice Claim any matured pending balance and push it to the vault.
    ///         Permissionless, repeatable, and NOT gated on `settled` — a proposal
    ///         resolved through `finalizeEmergencySettle` never calls
    ///         `strategy.settle()`, and gating here would strand the funds (H-4).
    ///         Racing the unwind is harmless: funds only ever flow to the vault.
    function recoverResiduals() external {
        uint128 pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        if (pending > 0) ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
        _sweep();
    }

    /// @notice Push any USDG held by this contract to the vault (e.g. a pending
    ///         balance a third party already claimed here). Permissionless,
    ///         no-op on zero balance. Ungated for the same reason as
    ///         `recoverResiduals`.
    function sweepToVault() external {
        _sweep();
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

    function _sweep() internal {
        uint256 bal = USDG.balanceOf(address(this));
        if (bal == 0) return;
        returnedAssets += bal;
        _pushToVault(address(USDG), bal);
        emit FundsSwept(bal);
    }
}
