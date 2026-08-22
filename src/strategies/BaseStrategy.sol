// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IProposalStatus} from "../interfaces/IProposalStatus.sol";
import {IStrategyDelivery} from "../interfaces/IStrategyDelivery.sol";
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

/// @notice The vault's live agent set, consulted by `onlyProposer` so that a
///         de-registered agent loses its standing on already-deployed clones
///         (pashov review finding #9). Declared locally for the same reason
///         `IGovernorBinding` is: to generate the selector, not to type the
///         vault.
interface IAgentSet {
    function isAgent(address agentAddress) external view returns (bool);
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
abstract contract BaseStrategy is IStrategy, IStrategyDelivery {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error AlreadyInitialized();
    error NotProposer();
    /// @notice The clone's pinned `_proposer` is no longer in the vault's live
    ///         agent set. See the `onlyProposer` natspec.
    error ProposerNoLongerAgent();
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

    /// @dev RE-CHECKED LIVE, NOT JUST AGAINST THE PIN (pashov review finding
    ///      #9). `_proposer` is written once at `initialize` and never
    ///      revisited, while `SyndicateVault.removeAgent` — the owner's
    ///      revocation lever — only deletes `_agents[a]` and reaches no
    ///      already-deployed clone. A de-registered agent therefore kept
    ///      unbounded `updateParams` / `rebalance` / `rebalanceDelta` authority
    ///      over deployed capital for the rest of `strategyDuration` (30 days
    ///      by factory default, up to `ABSOLUTE_MAX_STRATEGY_DURATION`), and
    ///      the owner's only alternatives were demoting the shared swap adapter
    ///      or price feed — whose blast radius is every strategy on the
    ///      protocol — or waiting for a permissionless settle.
    ///
    ///      `PortfolioStrategy.rebalance` already re-checks the swap ADAPTER
    ///      and the price SOURCES live on every call; this closes the same gap
    ///      for the CALLER, which was the one input still trusted from init.
    ///      Failing closed strands nothing: `settle()` is `onlyVault` and never
    ///      consults this modifier, so the exit path is unaffected.
    ///      RAW STATICCALL, NOT A HIGH-LEVEL CALL — same doctrine as
    ///      `SyndicateVault._openProposalPid` / `_pricingSupply` and
    ///      `ExposureLedger._feedPriceX8`. A typed call into a vault that does
    ///      not answer `isAgent` reverts in THIS frame with no data, which
    ///      turns a missing selector into an undecodable failure of every
    ///      proposer-gated path rather than a stated one. Decoding the answer
    ///      explicitly keeps the failure branch a DECISION: a vault that says
    ///      `false`, and a vault that cannot answer at all, both fail closed
    ///      here with a named error — closed rather than open because the
    ///      whole point is that revocation must bite, and blocking a
    ///      rebalance strands nothing (`settle()` is `onlyVault` and never
    ///      consults this modifier).
    modifier onlyProposer() {
        if (msg.sender != _proposer) revert NotProposer();
        (bool ok, bytes memory ret) = _vault.staticcall(abi.encodeCall(IAgentSet.isAgent, (_proposer)));
        if (!ok || ret.length != 32 || !abi.decode(ret, (bool))) revert ProposerNoLongerAgent();
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

    /// @inheritdoc IStrategyDelivery
    /// @dev FALSE BY DEFAULT, and that is the safe default rather than a lazy
    ///      one: this base has no idea what a given template can strand, and a
    ///      template that answers true when it holds nothing would shut the
    ///      vault's deposits until someone calls a sweep that moves nothing.
    ///      Templates whose settlement is deliverable-maximum override it —
    ///      `MorphoSupplyStrategy` (market utilization caps the withdrawal) and
    ///      `ConcentratedLiquidityStrategy` (debt, collateral wrapper, LP legs).
    ///      A template that always settles all-or-nothing correctly inherits
    ///      this.
    function hasUndeliveredValue() public view virtual returns (bool) {
        return false;
    }

    /// @notice The vault-asset value this strategy still holds undelivered.
    /// @dev    Default 0, matching `hasUndeliveredValue`'s default of false: a
    ///         template that settles all-or-nothing has no residue to report.
    ///         Overriding one without the other is a bug — the bool gates the
    ///         deposit lock, this figure corrects the settle price, and they
    ///         must describe the same value.
    function undeliveredValue() public view virtual returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev Default FALSE, matching the zero default above: a template that
    ///      holds nothing has nothing it cannot value. A template that DOES
    ///      hold value its `undeliveredValue()` override cannot express must
    ///      override this too, or the vault will price mints against a figure
    ///      that silently omits it.
    function hasUnvaluedResidue() public view virtual returns (bool) {
        return false;
    }

    /// @dev Dust floor for the residue probes. Anyone may transfer 1 wei to a
    ///      long-settled clone, and `hasUndeliveredValue()` keying on `!= 0`
    ///      turned that into an indefinite deposit DoS: `sweep()` clears it,
    ///      the griefer re-donates for 1 wei plus gas, forever. A residue below
    ///      this is not worth shutting deposits over — it cannot move a share
    ///      price meaningfully, which is the only thing the lock protects.
    ///
    ///      Denominated in the strategy's own units on purpose: the templates
    ///      that override this hold the VAULT ASSET, so the threshold reads in
    ///      the same units as the value being judged.
    uint256 internal constant RESIDUE_DUST = 1e3;

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
