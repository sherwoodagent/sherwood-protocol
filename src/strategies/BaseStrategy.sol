// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BaseStrategy
 * @notice Abstract base for strategy contracts. The vault calls execute() and
 *         settle() via batch calls — the strategy pulls tokens, deploys them
 *         into DeFi, and returns them on settlement.
 *
 *   Designed for Clones (ERC-1167) — deploy template once, clone per proposal.
 *
 *   Typical batch calls from the governor:
 *     Execute: [approve(strategy, amount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 *
 *   The strategy holds custody of position tokens (e.g., mUSDC) during the
 *   strategy period. On settlement, underlying returns to the vault.
 *
 *   Proposer can update tunable params (slippage, amounts) between execute
 *   and settle — no new proposal needed.
 */
abstract contract BaseStrategy is IStrategy {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error AlreadyInitialized();
    error NotProposer();
    error NotVault();
    error NotExecuted();
    error AlreadyExecuted();
    error AlreadySettled();
    error ZeroAddress();

    // ── State ──
    enum State {
        Pending,
        Executed,
        Settled
    }

    // slot 0: reserved for HyperCore FirstStorageSlot registration.
    // HyperliquidGridStrategy._initialize() writes address(this) here so HC
    // reads slot 0 post-block and confirms it equals the contract address.
    // Other strategies leave this as address(0) — no functional impact.
    address internal _hcSelf;
    address private _vault;
    address private _proposer;
    State internal _state;
    bool private _initialized;

    /// @notice Cumulative asset principal received by the strategy: sum of
    ///         what `_execute()` pulled from the vault plus any mid-flight
    ///         live deposits routed through `onLiveDeposit`. Used by
    ///         `positionValue` as the denominator for the NAV-floor guard
    ///         that defeats share-inflation dilution attacks (a strategy
    ///         under-reporting `_positionValue()` can let a new depositor
    ///         mint cheap shares against fake-low NAV; the floor returns
    ///         `valid=false` to force LPs onto the queue path until settle).
    uint256 internal _principal;

    /**
     * @notice Disables `initialize` on the template itself so an attacker
     *         can't front-run a clone deploy with their own init.
     * @dev Constructors are NOT executed for ERC-1167 minimal proxies, so
     *      `Clones.clone(template)` produces a clone with `_initialized = false`,
     *      keeping atomic `cloneAndInit` flows working. Only the template
     *      contract — deployed via `new` — is permanently locked.
     */
    constructor() {
        _initialized = true;
    }

    modifier onlyProposer() {
        if (msg.sender != _proposer) revert NotProposer();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != _vault) revert NotVault();
        _;
    }

    /// @inheritdoc IStrategy
    /// @dev Stamps `_hcSelf = address(this)` at slot 0 BEFORE delegating to
    ///      `_initialize` so HyperCore's FirstStorageSlot finalize variant
    ///      always sees the correct value. Foolproof for every strategy that
    ///      inherits BaseStrategy — strategy-specific `_initialize` overrides
    ///      cannot forget the stamp. Slot 0 is reserved for this purpose at
    ///      the storage layout level (see `_hcSelf` declaration above);
    ///      non-Hyperliquid strategies pay the cost (one SSTORE) but get
    ///      consistent layout in exchange.
    function initialize(address vault_, address proposer_, bytes calldata data) external {
        if (_initialized) revert AlreadyInitialized();
        if (vault_ == address(0)) revert ZeroAddress();
        if (proposer_ == address(0)) revert ZeroAddress();
        _initialized = true;
        _hcSelf = address(this);
        _vault = vault_;
        _proposer = proposer_;
        _state = State.Pending;

        _initialize(data);
    }

    /// @notice Slot 0 contents — used by HyperCore FirstStorageSlot variant.
    ///         Should equal `address(this)` after `initialize`. Diagnostic only.
    function hcSelf() external view returns (address) {
        return _hcSelf;
    }

    /// @inheritdoc IStrategy
    function execute() external onlyVault {
        if (_state != State.Pending) revert AlreadyExecuted();
        _state = State.Executed;
        _execute();
    }

    /// @inheritdoc IStrategy
    function settle() external onlyVault {
        if (_state != State.Executed) revert NotExecuted();
        _state = State.Settled;
        _settle();
    }

    /// @inheritdoc IStrategy
    function updateParams(bytes calldata data) external virtual onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        _updateParams(data);
    }

    /// @inheritdoc IStrategy
    function vault() public view returns (address) {
        return _vault;
    }

    /// @inheritdoc IStrategy
    function proposer() public view returns (address) {
        return _proposer;
    }

    /// @inheritdoc IStrategy
    function executed() external view returns (bool) {
        return _state == State.Executed;
    }

    /// @notice Current lifecycle state
    function state() external view returns (State) {
        return _state;
    }

    /// @inheritdoc IStrategy
    /// @dev State gating is centralized here so concrete strategies only
    ///      need to override `_positionValue` for the Executed case.
    ///
    ///      NAV-floor guard: when the underlying value falls below
    ///      `_principal / 2` (50% floor) we return `valid=false` so the
    ///      vault's `_lpFlowGate` falls through to queue-only. Defeats the
    ///      share-inflation attack where an under-reporting strategy
    ///      (`positionValue`=0 due to oracle bug or stranded funds) lets a
    ///      new depositor mint cheap shares and dilute existing LPs. The
    ///      bound is intentionally permissive (50% loss tolerated) — real
    ///      losses smaller than that report through; anything beyond signals
    ///      the strategy needs to settle, not keep accepting LP transactions.
    function positionValue() external view virtual returns (uint256, bool) {
        if (_state != State.Executed) return (0, false);
        (uint256 v, bool valid) = _positionValue();
        if (!valid) return (0, false);
        if (v < _principal >> 1) return (0, false);
        return (v, true);
    }

    /// @notice Cumulative asset principal received by the strategy across
    ///         `_execute()` and `onLiveDeposit` paths. Read by the vault's
    ///         off-chain monitoring; the on-chain NAV-floor check uses the
    ///         same value internally via `positionValue`.
    function principal() external view returns (uint256) {
        return _principal;
    }

    /// @inheritdoc IStrategy
    /// @dev Default no-op — strategies that can absorb mid-position
    ///      capital override `_onLiveDeposit`. Only callable by the vault and
    ///      only while the strategy is `Executed`. The base wrapper records
    ///      `assets` into the principal accumulator BEFORE delegating so the
    ///      floor calculation reflects the new inflow even if `_onLiveDeposit`
    ///      reverts (the vault's try/catch catches that, leaving assets on
    ///      the strategy as principal — `_principal` correctly reflects the
    ///      stranded amount).
    function onLiveDeposit(uint256 assets) external virtual onlyVault {
        if (_state != State.Executed) return;
        _principal += assets;
        _onLiveDeposit(assets);
    }

    /// @inheritdoc IStrategy
    /// @dev Default returns 0 — strategies that can free liquidity on demand
    ///      override `_onLiveWithdraw`. The vault treats any returned amount
    ///      less than `assetsNeeded` as "cannot fulfil" and reverts the LP's
    ///      withdraw (all-or-nothing), falling back to the async-redeem queue.
    function onLiveWithdraw(uint256 assetsNeeded) external virtual onlyVault returns (uint256) {
        if (_state != State.Executed) return 0;
        return _onLiveWithdraw(assetsNeeded);
    }

    // ── Internal helpers ──

    /// @notice Pull tokens from the vault into this strategy
    function _pullFromVault(address token, uint256 amount) internal {
        IERC20(token).safeTransferFrom(_vault, address(this), amount);
    }

    /// @notice Record `amount` as asset principal received from the vault.
    /// @dev Strategies call this from their `_execute()` after pulling the
    ///      asset from the vault so the NAV-floor denominator is accurate.
    ///      Live-deposit accumulation is automatic via `onLiveDeposit`.
    ///      Concrete strategies that pull a single asset typically call
    ///      `_recordPrincipal(amountIn)` once per `_execute()`. Multi-asset
    ///      strategies (Aerodrome) record only the asset matching the vault.
    function _recordPrincipal(uint256 amount) internal {
        _principal += amount;
    }

    /// @notice Push tokens from this strategy back to the vault
    function _pushToVault(address token, uint256 amount) internal {
        IERC20(token).safeTransfer(_vault, amount);
    }

    /// @notice Push entire balance of a token back to the vault
    function _pushAllToVault(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(_vault, bal);
    }

    // ── Abstract hooks for concrete strategies ──

    /// @notice Strategy-specific initialization (decode params from data)
    function _initialize(bytes calldata data) internal virtual;

    /// @notice Execute the strategy — pull tokens, deploy into DeFi
    function _execute() internal virtual;

    /// @notice Settle the strategy — unwind positions, push tokens back to vault
    function _settle() internal virtual;

    /// @notice Update tunable parameters (decode from data)
    function _updateParams(bytes calldata data) internal virtual;

    /// @notice Executed-state position valuation. Default stub returns
    ///         (0, false) so strategies without a queryable current
    ///         value (Mamo, Venice, HyperLiquid on non-HyperEVM) can
    ///         inherit without overriding. Strategies that can compute
    ///         an onchain value override this with their implementation.
    function _positionValue() internal view virtual returns (uint256, bool) {
        return (0, false);
    }

    /// @notice Override to route new vault deposits into the live position.
    ///         Default: no-op. Only invoked while the strategy is `Executed`.
    function _onLiveDeposit(
        uint256 /*assets*/
    )
        internal
        virtual {
        // default: do nothing
    }

    /// @notice Override to free `assetsNeeded` of underlying from the live
    ///         position and push it to the vault. Default: returns 0,
    ///         signalling no partial-unwind capability — LPs use the async
    ///         queue while the strategy is active. Only invoked while the
    ///         strategy is `Executed`.
    function _onLiveWithdraw(
        uint256 /*assetsNeeded*/
    )
        internal
        virtual
        returns (uint256 assetsReturned)
    {
        return 0;
    }
}
