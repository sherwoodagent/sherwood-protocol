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
 *   Settlement is TWO-PHASE (G-H1): withdrawals on Lighter are async priority
 *   requests that mature MUCH later (minutes to days). `initiateReturn(ticks)`
 *   closes positions and queues the withdrawal; `_settle()` — a later block —
 *   claims the matured pending balance and pushes USDG to the vault. Settling
 *   before maturity would book a phantom loss, so `_settle` reverts unless a
 *   pending or already-claimed balance is present.
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
    uint32 internal constant MARKET_SELL_PRICE = 1; // protective bound for a market SELL close
    uint32 internal constant MARKET_BUY_PRICE = type(uint32).max; // 2^32-1: market BUY close

    // ── Init bounds ──
    uint256 internal constant PUBKEY_LEN = 40;
    uint8 internal constant MIN_API_KEY_INDEX = 2;
    uint8 internal constant MAX_API_KEY_INDEX = 254;
    uint16 internal constant MAX_MARKET_INDEX = 254;
    uint256 internal constant MIN_DEPOSIT = 1e6; // 1 USDG (6dp)

    // ── Guardrail actions ──
    uint8 internal constant ACTION_CANCEL_ALL = 1; // ()
    uint8 internal constant ACTION_CLOSE_MARKET = 2; // (uint16 market, uint32 price, uint8 isAsk)
    uint8 internal constant ACTION_ROTATE_KEY = 3; // (bytes newPubKey40)
    uint8 internal constant ACTION_WITHDRAW = 4; // (uint64 ticks)
    uint8 internal constant ACTION_REGISTER_KEY = 5; // ()

    // ── Storage (per-clone) ──
    bytes public apiKeyPubKey; // 40-byte Goldilocks L2 trading key
    uint8 public apiKeyIndex; // 2..254
    uint16[] public markets; // perp markets this clone may trade
    uint256 public depositAmount; // 0 = dynamic-all (vault's full USDG at execute)
    uint256 public returnsInitiatedAt; // block.number of initiateReturn(); 0 = not initiated
    bool public settled;
    uint256 public cumulativeSwept; // off-chain accounting only

    // ── Events ──
    event Deposited(uint256 amount, uint48 accountIndex);
    event AgentKeyRegistered(uint48 accountIndex, uint8 apiKeyIndex);
    event OrdersCancelled(uint48 accountIndex);
    event MarketClosed(uint16 market, uint8 isAsk);
    event WithdrawQueued(uint64 ticks);
    event ReturnsInitiated(uint64 ticks);
    event Settled();
    event FundsSwept(uint256 amount);

    // ── Errors ──
    error InvalidPubKey();
    error InvalidApiKeyIndex();
    error NoMarkets();
    error InvalidMarket();
    error DepositTooSmall();
    error AccountNotRegistered();
    error InvalidAction();
    error NotAuthorized();
    error ReturnsNotInitiated();
    error SettleTooSoon();
    error NothingToSettle();
    error NotSweepable();

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
        if (mkts.length == 0) revert NoMarkets();
        for (uint256 i; i < mkts.length; i++) {
            if (mkts[i] > MAX_MARKET_INDEX) revert InvalidMarket();
        }

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

        _pullFromVault(address(USDG), amountIn);
        USDG.forceApprove(address(ZK_LIGHTER), amountIn);
        ZK_LIGHTER.deposit(address(this), USDG_ASSET_INDEX, ROUTE_PERPS, amountIn);

        emit Deposited(amountIn, ZK_LIGHTER.addressToAccountIndex(address(this)));
    }

    /// @notice Register / re-assert the agent L2 trading key. Proposer-driven,
    ///         idempotent, and reusable for rotation via the stored key.
    function registerAgentKey() external onlyProposer {
        uint48 acct = ZK_LIGHTER.addressToAccountIndex(address(this));
        if (acct == 0) revert AccountNotRegistered();
        ZK_LIGHTER.changePubKey(acct, apiKeyIndex, apiKeyPubKey);
        emit AgentKeyRegistered(acct, apiKeyIndex);
    }

    /// @notice Proposer-only guardrails via `(uint8 action, bytes args)`:
    ///           1 CANCEL_ALL()
    ///           2 CLOSE_MARKET(uint16 market, uint32 price, uint8 isAsk)  — single-side, side chosen off-chain
    ///           3 ROTATE_KEY(bytes newPubKey40)                          — updates stored key + changePubKey
    ///           4 WITHDRAW(uint64 ticks)                                 — queue an async withdrawal
    ///           5 REGISTER_KEY()                                          — (re)register the stored key
    function _updateParams(bytes calldata data) internal override {
        (uint8 action, bytes memory args) = abi.decode(data, (uint8, bytes));
        uint48 acct = ZK_LIGHTER.addressToAccountIndex(address(this));

        if (action == ACTION_CANCEL_ALL) {
            ZK_LIGHTER.cancelAllOrders(acct);
            emit OrdersCancelled(acct);
        } else if (action == ACTION_CLOSE_MARKET) {
            (uint16 market, uint32 price, uint8 isAsk) = abi.decode(args, (uint16, uint32, uint8));
            ZK_LIGHTER.createOrder(acct, market, 0, price, isAsk, ORDER_MARKET);
            emit MarketClosed(market, isAsk);
        } else if (action == ACTION_ROTATE_KEY) {
            bytes memory newPubKey = abi.decode(args, (bytes));
            if (newPubKey.length != PUBKEY_LEN) revert InvalidPubKey();
            apiKeyPubKey = newPubKey;
            ZK_LIGHTER.changePubKey(acct, apiKeyIndex, newPubKey);
            emit AgentKeyRegistered(acct, apiKeyIndex);
        } else if (action == ACTION_WITHDRAW) {
            uint64 ticks = abi.decode(args, (uint64));
            ZK_LIGHTER.withdraw(acct, USDG_ASSET_INDEX, ROUTE_PERPS, ticks);
            emit WithdrawQueued(ticks);
        } else if (action == ACTION_REGISTER_KEY) {
            if (acct == 0) revert AccountNotRegistered();
            ZK_LIGHTER.changePubKey(acct, apiKeyIndex, apiKeyPubKey);
            emit AgentKeyRegistered(acct, apiKeyIndex);
        } else {
            revert InvalidAction();
        }
    }

    /// @notice Phase 1 of settlement: cancel orders, close every configured
    ///         market both directions, and queue the USDG withdrawal.
    /// @dev    Auth: proposer anytime post-execute; anyone after strategyDuration
    ///         (mirrors HyperliquidPerpStrategy). Idempotent.
    /// @param  ticks observed L2 balance (1 USDG = 1e6 ticks) — supplied off-chain
    ///         from the API. Too-large reverts venue-side; too-small leaves residue
    ///         recoverable via the WITHDRAW guardrail + `recoverResiduals()`.
    function initiateReturn(uint64 ticks) external {
        if (_state != State.Executed) revert NotExecuted();
        if (returnsInitiatedAt != 0) return; // idempotent

        if (msg.sender != proposer()) {
            ISyndicateGovernor gov = ISyndicateGovernor(ISyndicateVault(vault()).governor());
            uint256 pid = gov.getActiveProposal();
            ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
            if (block.timestamp < p.executedAt + p.strategyDuration) revert NotAuthorized();
        }

        uint48 acct = ZK_LIGHTER.addressToAccountIndex(address(this));
        ZK_LIGHTER.cancelAllOrders(acct);
        // Trustless close: the contract can't read a position's sign, so it emits
        // both a SELL-close and a BUY-close per market — the one opposing the open
        // position fills, the other no-ops against a flat/absent position.
        for (uint256 i; i < markets.length; i++) {
            uint16 m = markets[i];
            ZK_LIGHTER.createOrder(acct, m, 0, MARKET_SELL_PRICE, SIDE_ASK, ORDER_MARKET);
            ZK_LIGHTER.createOrder(acct, m, 0, MARKET_BUY_PRICE, SIDE_BID, ORDER_MARKET);
        }
        if (ticks > 0) ZK_LIGHTER.withdraw(acct, USDG_ASSET_INDEX, ROUTE_PERPS, ticks);

        returnsInitiatedAt = block.number;
        emit ReturnsInitiated(ticks);
    }

    /// @notice Phase 2 of settlement (governor-called). Claims the matured pending
    ///         USDG (if any) and pushes the entire USDG balance to the vault.
    /// @dev    Requires `initiateReturn` a strictly earlier block (async maturity)
    ///         and that funds are present — either matured pending, or already
    ///         claimed to this contract by a prior permissionless call. Reverts
    ///         `NothingToSettle` if both are zero (funds still in flight).
    function _settle() internal override {
        if (returnsInitiatedAt == 0) revert ReturnsNotInitiated();
        if (block.number <= returnsInitiatedAt) revert SettleTooSoon();

        uint128 pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        uint256 bal = USDG.balanceOf(address(this));
        if (pending == 0 && bal == 0) revert NothingToSettle();

        if (pending > 0) ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
        _pushAllToVault(address(USDG));

        settled = true;
        emit Settled();
    }

    /// @notice Post-settle recovery for late-maturing withdrawals: claim any newly
    ///         matured pending balance and push it to the vault. Permissionless,
    ///         repeatable — funds only ever flow to the vault.
    function recoverResiduals() external {
        if (!settled) revert NotSweepable();
        uint128 pending = ZK_LIGHTER.getPendingBalance(address(this), USDG_ASSET_INDEX);
        if (pending > 0) ZK_LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, pending);
        _sweep();
    }

    /// @notice Push any USDG held by this contract to the vault (e.g. a pending
    ///         balance a third party already claimed here). Permissionless,
    ///         no-op on zero balance.
    function sweepToVault() external {
        if (!settled) revert NotSweepable();
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

    function _sweep() internal {
        uint256 bal = USDG.balanceOf(address(this));
        if (bal == 0) return;
        cumulativeSwept += bal;
        _pushToVault(address(USDG), bal);
        emit FundsSwept(bal);
    }
}
