// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IProposalStatus} from "../interfaces/IProposalStatus.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The one hop `execute()` walks to resolve the vault's governor:
///         `vault()` → `governor()`. Declared locally rather than imported,
///         following `PortfolioStrategy`'s `ITierBindingPath` precedent
///         (src/strategies/PortfolioStrategy.sol:37) — this interface
///         exists to generate the selector, not to type the vault.
interface IGovernorBinding {
    function governor() external view returns (address);
}

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

    /// @notice `execute()` was reached by a batch other than the one belonging
    ///         to the proposal that declared this clone as its strategy.
    /// @dev The clone-ratchet bypass (issue #150): `executeGovernorBatch`
    ///      delegatecalls through `BatchExecutorLib`, so every sub-call of
    ///      every proposal's batch reaches its target with
    ///      `msg.sender == vault` (src/SyndicateVault.sol:504-505). `onlyVault`
    ///      alone can't distinguish "this clone's own proposal" from "any
    ///      other proposal on the same vault" — a registered agent could get
    ///      any proposal executed and target an unrelated, pre-deployed
    ///      clone's `execute()` from its batch, flipping the one-shot
    ///      `Pending → Executed` ratchet and permanently bricking that
    ///      clone's own later legitimate proposal (`AlreadyExecuted` forever).
    ///      Fail-closed by design (no capability probe, no try/catch): this
    ///      check IS the security boundary here, unlike #118's propose-time
    ///      check, which degrades open behind a second, authoritative layer.
    ///      See design.md of `fix-strategy-clone-ratchet`, Decision 2.
    error NotActiveProposalStrategy();

    // ── State ──
    enum State {
        Pending,
        Executed,
        Settled
    }

    address private _vault;
    address private _proposer;
    State internal _state;
    bool private _initialized;

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
    function initialize(address vault_, address proposer_, bytes calldata data) external {
        if (_initialized) revert AlreadyInitialized();
        if (vault_ == address(0)) revert ZeroAddress();
        if (proposer_ == address(0)) revert ZeroAddress();
        _initialized = true;
        _vault = vault_;
        _proposer = proposer_;
        _state = State.Pending;

        _initialize(data);
    }

    /// @inheritdoc IStrategy
    /// @dev Binds execution to the vault's currently-active proposal (issue
    ///      #150 fix): resolves `vault() → governor()` and requires the
    ///      governor's active proposal to declare THIS clone as its strategy,
    ///      else reverts `NotActiveProposalStrategy`. Typed calls, no
    ///      try/catch, no capability probe — any hop failing (vault lacking
    ///      `governor()`, governor lacking the `IProposalStatus` views, no
    ///      active proposal) reverts `execute()`, which is the deliberate
    ///      fail-closed posture (design.md Decision 2): a clone that can't
    ///      verify its wiring must not pull capital from the vault, and the
    ///      failure is recoverable (redeploy) while the failure it prevents
    ///      (a flipped ratchet) is permanent. `pid == 0` (no active proposal)
    ///      needs no special case: `strategyOf(0) == address(0) != address(this)`.
    ///      `settle()` below is deliberately left WITHOUT this check — see its
    ///      own natspec.
    function execute() external onlyVault {
        address gov = IGovernorBinding(_vault).governor();
        if (IProposalStatus(gov).strategyOf(IProposalStatus(gov).getActiveProposal()) != address(this)) {
            revert NotActiveProposalStrategy();
        }
        if (_state != State.Pending) revert AlreadyExecuted();
        _state = State.Executed;
        _execute();
    }

    /// @inheritdoc IStrategy
    /// @dev Deliberately NOT bound to the active-proposal check `execute()`
    ///      carries. Two independent reasons (design.md Decision 2):
    ///      (1) transitive protection — `settle()` requires `_state ==
    ///      Executed`, which post-fix only the owning proposal's batch can
    ///      set, and the single-open-proposal invariant means every batch
    ///      that can run while that proposal is open belongs to it (its own
    ///      settlement, its `unstick` replay, or its owner-proposed emergency
    ///      calls); (2) recovery is load-bearing — if the owning proposal
    ///      settles via emergency calls that bypass a broken clone, the clone
    ///      is orphaned in `Executed` with position tokens in custody, and a
    ///      LATER proposal's batch must still be able to call `settle()` to
    ///      push funds back to the vault. Guarding `settle()` the same way
    ///      `execute()` is guarded would strand those funds permanently. A
    ///      future "symmetry" refactor must confront this argument before
    ///      adding a check here.
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

    // ── Internal helpers ──

    /// @notice Pull tokens from the vault into this strategy
    function _pullFromVault(address token, uint256 amount) internal {
        IERC20(token).safeTransferFrom(_vault, address(this), amount);
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
}
