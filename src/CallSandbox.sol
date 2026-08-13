// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICallSandbox} from "./interfaces/ICallSandbox.sol";
import {IStrategyDelivery} from "./interfaces/IStrategyDelivery.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CallSandbox
 * @notice Runs proposer-authored calldata against arbitrary targets, from an
 *         address that holds nothing but the capital it was funded with.
 *
 *         WHY THIS EXISTS. `SyndicateVault._guardBatchCalls` refuses any batch
 *         callee the TierRegistry owner has not allowlisted, and that gate is
 *         tier-blind — so tier 2 ("arbitrary calldata at full notional") could
 *         price a call it could not reach, and every new venue cost an owner
 *         transaction. The gate cannot simply be dropped: a batch runs under
 *         `delegatecall`, so a sub-call arrives as the VAULT, and
 *         authorization-shaped calldata (`approve(attacker, max)`, ERC-777
 *         `authorizeOperator`, ERC-721 `setApprovalForAll`, any unenumerated
 *         router's approval shape) moves zero assets, meters zero, prices zero
 *         coverage, and drains in a later transaction. No per-call cap can bound
 *         that, because the loss does not land in the metered transaction.
 *
 *         Executing one hop further out removes the premise. A target called
 *         from here sees `msg.sender == address(this)`: no vault allowance to
 *         spend, no vault-held position token to move, no `msg.sender == vault`
 *         gate satisfied anywhere. The most a hostile call set can cost is the
 *         balance this contract was handed — which is exactly the figure
 *         full-notional tier-2 coverage already charged for. That is why no
 *         owner attests a sandbox target: blast radius is set by the funding,
 *         not by the callee's reputation, and the review that remains
 *         (guardians, against slashable stake, on a payload frozen at propose)
 *         is the one that was actually pricing the risk all along.
 *
 * @dev    PROTOCOL CODE, NOT A LISTED THIRD PARTY. Minted by the vault from an
 *         implementation address fixed at vault deployment. It is not a
 *         `StrategyFactory` template and carries no TierRegistry entry, because
 *         every "list something" path in this codebase is `onlyOwner` and a
 *         template would only move the ceremony rather than remove it.
 *
 *         Designed for ERC-1167 clones: no constructor state, `init` once.
 *
 *         See `openspec/changes/permissionless-tier2-sandbox/` — capability
 *         `sandbox-execution`.
 */
contract CallSandbox is ICallSandbox {
    using SafeERC20 for IERC20;

    /// @dev Bounds the two proposer-supplied arrays. An unbounded payload is a
    ///      gas-griefing surface on `run` (and on every guardian who reads it),
    ///      and the ceiling is far above any legitimate call set.
    uint256 public constant MAX_CALLS = 32;
    uint256 public constant MAX_DECLARED_TOKENS = 16;

    /// @dev Probe budget for resolving the denied-address chain. Matches the
    ///      vault's own `_PROBE_GAS` doctrine: a hop that cannot answer inside a
    ///      bounded budget is treated as unreadable rather than allowed to
    ///      consume the whole transaction.
    uint256 private constant _PROBE_GAS = 150_000;

    /// @dev Per-token ceiling for the declared-token leg of `sweep`. Sized so
    ///      all 16 declared tokens fit inside the vault's own 1,500,000-gas
    ///      `_SWEEP_GAS` budget for the whole call, with room left for the asset
    ///      transfer that runs first: a single hostile entry can waste its own
    ///      leg and nothing else.
    uint256 private constant _TOKEN_SWEEP_GAS = 80_000;

    address private _vault;
    address private _asset;
    bool private _initialized;
    bool private _hasRun;

    Call[] private _calls;
    address[] private _declaredTokens;

    /// @dev Declared tokens that have PROVEN unsweepable — `sweep` tried to
    ///      transfer them to the vault and the call failed. Without this, a
    ///      token whose `transfer` always reverts (a proposer can deploy one)
    ///      keeps `hasUnvaluedResidue()` true forever while nothing on earth can
    ///      move it, and `SyndicateVault.depositsLocked()` never reopens: a
    ///      permanent, unrecoverable deposit brick, which the vault's own
    ///      residue doctrine treats as worse than the suppression it guards.
    ///
    ///      Abandoning degrades that case to the UNDECLARED one, which the
    ///      design already accepts: the token stays stranded here, is never
    ///      counted as vault value, and no LP mints against it. Nothing that
    ///      could be recovered is given up — the flag is only ever set after a
    ///      real transfer attempt failed.
    mapping(address token => bool) private _abandoned;

    modifier onlyVault() {
        if (msg.sender != _vault) revert NotVault();
        _;
    }

    /// @inheritdoc ICallSandbox
    /// @dev The payload is written HERE and nowhere else. The guardian coverage
    ///      quorum is what replaces the owner's allowlist decision, and that
    ///      substitution only holds if reviewers can see exactly what will run
    ///      and it cannot change afterwards — a mutable payload would let a
    ///      proposal be covered against one call set and executed against
    ///      another, which is the proposer-as-adversary case.
    ///
    ///      `asset` is snapshotted from the vault at bind time rather than read
    ///      live, so the residue reads below cannot be moved by anything that
    ///      happens to the vault afterwards.
    function init(address vault_, Call[] calldata calls_, address[] calldata declaredTokens_) external {
        if (_initialized) revert AlreadyInitialized();
        if (vault_ == address(0)) revert NotVault();
        if (calls_.length == 0 || calls_.length > MAX_CALLS) revert InvalidCallSet();
        if (declaredTokens_.length > MAX_DECLARED_TOKENS) revert InvalidCallSet();

        _initialized = true;
        _vault = vault_;
        _asset = IERC4626Minimal(vault_).asset();

        for (uint256 i = 0; i < calls_.length; i++) {
            if (calls_[i].target == address(0)) revert InvalidCallSet();
            _calls.push(Call({target: calls_[i].target, data: calls_[i].data}));
        }
        for (uint256 i = 0; i < declaredTokens_.length; i++) {
            _declaredTokens.push(declaredTokens_[i]);
        }
    }

    /// @inheritdoc ICallSandbox
    /// @dev ONE-SHOT AND VAULT-ONLY. Funding happens once, immediately before
    ///      this call, so a second run would dispatch the same reviewed calldata
    ///      against whatever balance happened to be here later.
    ///
    ///      REFUSAL REVERTS THE WHOLE RUN. Skipping a denied call would execute
    ///      a SUBSET of what guardians approved, which is a different proposal
    ///      than the one that was covered — so a denied target, or any call that
    ///      reverts, takes the entire execution down and the funding with it.
    function run() external onlyVault {
        if (_hasRun) revert AlreadyRun();
        _hasRun = true;

        _assertNoDeniedTargets();

        uint256 n = _calls.length;
        for (uint256 i = 0; i < n; i++) {
            Call storage c = _calls[i];
            // No `value`: the struct carries none by construction (see
            // `ICallSandbox.Call`), so native transfer is not reachable here.
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok,) = c.target.call(c.data);
            if (!ok) revert CallFailed(i);
        }

        emit SandboxRun(_vault, n, IERC20(_asset).balanceOf(address(this)));
    }

    /// @dev THE ACCOUNTING DENYLIST, resolved live because every one of these
    ///      addresses can be re-pointed after this clone was minted.
    ///
    ///      The adversary here is NOT fund theft — the funded balance already
    ///      bounds that, and it is the whole point of the sandbox. It is
    ///      protocol accounting: a sandbox holding vault capital could deposit it
    ///      back to mint shares while an open proposal has deposits locked, or
    ///      touch the queue's stamp and reserve counters, corrupting figures
    ///      other guards assume only the vault itself can move.
    ///
    ///      TWO CLASSES, AND THE DIFFERENCE IS DELIBERATE.
    ///
    ///      REQUIRED (vault, queue, governor): resolvable directly from the
    ///      vault, and the exact surface the funded cap does NOT bound. An
    ///      unreadable hop here reverts — failing closed is safe because the
    ///      failure is recoverable (the proposal expires with the capital never
    ///      having left) while the thing it prevents is not.
    ///
    ///      BEST-EFFORT (tier registry, exposure ledger, sWOOD, WOOD): reached
    ///      through a chain of getters that a legitimately unwired deployment
    ///      may not answer. An unresolvable hop leaves that address undenied,
    ///      and that is acceptable on a specific argument rather than a shrug:
    ///      every function on those contracts is gated to its own privileged
    ///      caller (owner, governor, or the staker acting for themselves), so a
    ///      sandbox reaching them acts only as itself, holding no stake and no
    ///      standing. Denying them is belt-and-braces; failing closed on a
    ///      four-hop chain would trade a real liveness risk for it.
    function _assertNoDeniedTargets() private view {
        address vault_ = _vault;
        address queue = IVaultMinimal(vault_).withdrawalQueue();
        address governor = IVaultMinimal(vault_).governor();

        _denyIfNamed(vault_);
        _denyIfNamed(queue);
        _denyIfNamed(governor);

        address registry = _probeAddress(governor, ISandboxProbe.tierRegistry.selector);
        address ledger = _probeAddress(governor, ISandboxProbe.exposureLedger.selector);
        _denyIfNamed(registry);
        _denyIfNamed(ledger);

        address swood = _probeAddress(ledger, ISandboxProbe.swood.selector);
        _denyIfNamed(swood);
        _denyIfNamed(_probeAddress(swood, ISandboxProbe.wood.selector));
    }

    /// @dev Reverts if any stored call names `denied`. `address(0)` is the
    ///      "unresolved" sentinel and never matches, because `init` rejects a
    ///      zero target — so an unreadable probe cannot accidentally deny every
    ///      call, nor silently deny none of them by matching everything.
    function _denyIfNamed(address denied) private view {
        if (denied == address(0)) return;
        uint256 n = _calls.length;
        for (uint256 i = 0; i < n; i++) {
            if (_calls[i].target == denied) revert DeniedTarget(denied);
        }
    }

    /// @dev Raw, length-checked, gas-bounded staticcall returning `address(0)`
    ///      on any failure. Deliberately not a typed call: a missing selector on
    ///      a legitimately older or unwired collaborator reverts in THIS frame
    ///      with no data, which would be indistinguishable from a bug here and
    ///      would brick execution for a contract that is only belt-and-braces on
    ///      the list. Same doctrine as `SyndicateVault._pricingSupply`.
    function _probeAddress(address target, bytes4 selector) private view returns (address) {
        if (target == address(0) || target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall{gas: _PROBE_GAS}(abi.encodeWithSelector(selector));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @inheritdoc ICallSandbox
    /// @dev PERMISSIONLESS, and reached by a DIRECT call from the vault rather
    ///      than through a governor batch. That is what lets capital come home
    ///      with no registry standing and no owner action — including in the
    ///      state that wedges an ordinary strategy, where a demotion has cleared
    ///      the allowlist and every batch-routed settlement path reverts
    ///      `DisallowedBatchCallee` (pashov finding #15). A sandbox holds no
    ///      registry entry, so there is nothing to demote and nothing to wedge.
    function sweep() external returns (uint256 assets) {
        address vault_ = _vault;
        // THE ASSET FIRST, ALWAYS. It is the only leg that carries priced value,
        // and the declared-token loop below runs on the same borrowed gas
        // budget — recovering real capital must not depend on how the
        // proposer's token list behaves.
        assets = IERC20(_asset).balanceOf(address(this));
        if (assets != 0) {
            IERC20(_asset).safeTransfer(vault_, assets);
            emit SandboxSwept(assets);
        }

        // THEN THE DECLARED TOKENS, OR THE DEPOSIT LOCK IS PERMANENT. This is
        // not tidiness: `hasUnvaluedResidue()` reports true while any declared
        // non-asset token sits here, `SyndicateVault.depositsLocked()` shuts the
        // mint side on exactly that flag, and `collectResidue` clears it only by
        // re-reading the same probe. Without this leg the flag can never go
        // false — nothing else can move a token out of a sandbox whose `run` is
        // one-shot and already spent — so any registered agent could brick
        // deposits forever by declaring a token its payload leaves behind. The
        // vault's own `depositsLocked` natspec calls exactly that trade (a
        // permanent, unrecoverable brick) worse than the suppression it guards.
        //
        // BEST-EFFORT, PER TOKEN, ON A BOUNDED BUDGET. The list is
        // proposer-authored: a token that reverts, returns nothing, or burns gas
        // must not take down the sweep and re-brick the exit it is the only
        // escape from. A raw call with its own ceiling means the worst a hostile
        // entry costs is its own leg. `MAX_DECLARED_TOKENS` bounds the loop.
        //
        // Tokens land in the VAULT, where `totalAssets()` does not count them —
        // so this recovers custody without ever pricing an unvalued asset into a
        // mint, which is the distinction the whole residue design rests on.
        uint256 n = _declaredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            address t = _declaredTokens[i];
            if (t == address(0) || t == _asset || t.code.length == 0) continue;
            (bool okBal, bytes memory balRet) =
                t.staticcall{gas: _PROBE_GAS}(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
            if (!okBal || balRet.length != 32) continue;
            uint256 bal = abi.decode(balRet, (uint256));
            if (bal == 0) continue;
            // solhint-disable-next-line avoid-low-level-calls
            (bool okXfer,) =
                t.call{gas: _TOKEN_SWEEP_GAS}(abi.encodeWithSelector(IERC20.transfer.selector, vault_, bal));
            if (okXfer) {
                emit SandboxTokenSwept(t, bal);
            } else {
                // Proven unmovable — stop counting it, or the lock is permanent.
                // See `_abandoned`.
                _abandoned[t] = true;
                emit SandboxTokenAbandoned(t, bal);
            }
        }
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev The vault-asset balance still sitting here. MUST NOT REVERT — the
    ///      vault reads this through a length-checked staticcall on the mint
    ///      pricing path.
    function undeliveredValue() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    /// @inheritdoc IStrategyDelivery
    function hasUndeliveredValue() external view returns (bool) {
        return IERC20(_asset).balanceOf(address(this)) != 0;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev HONEST ABOUT ITS OWN BLIND SPOT, which is the entire contract of
    ///      this function. `undeliveredValue()` above can only speak for the
    ///      vault asset, and a sandbox runs proposer-authored calls that may
    ///      leave any token behind. Reporting true here makes the vault refuse
    ///      to MINT rather than charge a price it knows is incomplete — the one
    ///      place a lock still beats a price, because there is no honest number.
    ///
    ///      BOUNDED BY THE DECLARED SET. A contract cannot enumerate every ERC-20
    ///      it holds, so without a declaration this could only be a constant.
    ///      An UNDER-declared leftover is stranded here and never counted as
    ///      vault value: the safe direction of error, and the proposer's own
    ///      loss rather than the LPs'.
    ///
    ///      A token that fails to answer `balanceOf` is treated as holding
    ///      nothing, so a hostile token cannot brick the mint path by reverting.
    function hasUnvaluedResidue() external view returns (bool) {
        address asset_ = _asset;
        uint256 n = _declaredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            address t = _declaredTokens[i];
            if (t == address(0) || t == asset_ || _abandoned[t]) continue;
            (bool ok, bytes memory ret) =
                t.staticcall{gas: _PROBE_GAS}(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
            if (ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0) return true;
        }
        return false;
    }

    // ── Views ──

    /// @inheritdoc ICallSandbox
    function vault() external view returns (address) {
        return _vault;
    }

    /// @inheritdoc ICallSandbox
    function calls() external view returns (Call[] memory) {
        return _calls;
    }

    /// @inheritdoc ICallSandbox
    function declaredTokens() external view returns (address[] memory) {
        return _declaredTokens;
    }

    /// @inheritdoc ICallSandbox
    function hasRun() external view returns (bool) {
        return _hasRun;
    }
}

/// @dev The two reads the sandbox REQUIRES from its vault. Typed deliberately:
///      these are the accounting-critical hops and an unreadable one must fail
///      closed, which a typed call does by reverting.
interface IVaultMinimal {
    function withdrawalQueue() external view returns (address);
    function governor() external view returns (address);
}

interface IERC4626Minimal {
    function asset() external view returns (address);
}

/// @dev Selector carrier for the best-effort half of the denylist chain. Never
///      called typed — only `.selector` is taken, and the call goes out through
///      `_probeAddress`'s raw staticcall.
interface ISandboxProbe {
    function tierRegistry() external view returns (address);
    function exposureLedger() external view returns (address);
    function swood() external view returns (address);
    function wood() external view returns (address);
}
