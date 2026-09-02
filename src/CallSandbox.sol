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

    /// @dev Per-token CEILINGS for the two declared-token loops. They are only
    ///      the upper half of the bound — see `_fairShare`, which is what
    ///      actually stops one entry starving the rest.
    ///
    ///      A FIXED CEILING ALONE IS NOT A BOUND ON A LOOP. The first version of
    ///      this contract capped each token probe at `_PROBE_GAS` (150,000) —
    ///      the same figure the VAULT allows for the whole
    ///      `hasUnvaluedResidue()` call — so one declared token that burns its
    ///      allowance consumed the caller's entire budget and every token behind
    ///      it reverted the function out of gas. Two confirmed consequences:
    ///      `SyndicateVault._refreshUnvalued` reads unreadable, KEEPS the last
    ///      known flag, and a flag that latched true could never clear again
    ///      (permanent deposit brick); and `collectResidue`'s 1,500,000-gas
    ///      `sweep()` ran out before the asset leg, recovering nothing.
    ///      Regression-pinned by `test_probe_*` / `test_sweep_*` in
    ///      `test/governor/SandboxProposal.t.sol`.
    uint256 private constant _TOKEN_PROBE_GAS = 30_000;
    uint256 private constant _TOKEN_SWEEP_GAS = 80_000;

    /// @dev How long a declared token's transfer must have been failing before
    ///      it may be abandoned. Measured from the FIRST OBSERVED FAILURE, not
    ///      from the run: settlement is already `strategyDuration` past the run,
    ///      so anchoring there would leave the guard elapsed before anyone could
    ///      realistically sweep, which is the same as not having it.
    ///
    ///      What it buys: abandonment reopens deposits on a token the vault then
    ///      stops counting, and `sweep()` stays reachable by anyone through the
    ///      permissionless `SyndicateVault.collectResidue` — so without a delay
    ///      anyone could write off live value by calling during a TRANSIENT
    ///      failure (a paused token, a temporary blacklist) and the write-off
    ///      would outlive the condition. Requiring the failure to PERSIST is what
    ///      distinguishes "unmovable" from "not moving right now".
    ///
    ///      The cost is stated: a genuinely unmovable token holds the deposit
    ///      lock for this long instead of clearing on the first sweep. Bounded
    ///      and self-clearing, against a permanent brick on the other side —
    ///      the same trade `SyndicateVault.depositsLocked` already makes.
    uint256 public constant ABANDON_DELAY = 2 days;

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
    ///
    ///      TWO GUARDS AGAINST WRITING OFF LIVE VALUE, because this flag moves
    ///      in the direction that REOPENS deposits: a token wrongly abandoned is
    ///      one the vault stops counting while the sandbox still holds it, and
    ///      the next depositor mints too cheaply against it.
    ///
    ///      1. NOT UNTIL THE FAILURE HAS PERSISTED for `ABANDON_DELAY`, tracked
    ///         per token in `_failedSince`. `sweep()` is still reachable by
    ///         anyone via `SyndicateVault.collectResidue`, so without this
    ///         anyone could write a token off by calling during a
    ///         TRANSIENT failure — a paused token, a temporary blacklist, a
    ///         transfer momentarily over the per-token ceiling — and the
    ///         write-off would outlive the condition that caused it. Two failed
    ///         sweeps a week apart is evidence; one is a snapshot.
    ///      2. CLEARED THE MOMENT A LATER TRANSFER SUCCEEDS. The flag records a
    ///         belief about movability, not a verdict; if the token proves
    ///         movable after all, the belief was wrong and nothing should still
    ///         rest on it.
    mapping(address token => bool) private _abandoned;

    /// @dev When a declared token's transfer was first seen to fail, or zero if
    ///      it has never failed (or last succeeded). The clock `ABANDON_DELAY`
    ///      runs on. Cleared on any success, so a token that recovers starts
    ///      from scratch rather than carrying credit toward being written off.
    mapping(address token => uint64) private _failedSince;

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
        // DUPLICATES REFUSED. Both declared-token loops divide a borrowed gas
        // budget between entries (see `_fairShare`), so a list padded with the
        // same address 16 times shrinks every real entry's slice for nothing.
        // `MAX_DECLARED_TOKENS` bounds the count; this makes the count mean
        // distinct tokens. O(n^2) over at most 16 entries, once, at mint.
        for (uint256 i = 0; i < declaredTokens_.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (declaredTokens_[i] == declaredTokens_[j]) revert DuplicateDeclaredToken(declaredTokens_[i]);
            }
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
    ///      DEFENCE IN DEPTH, NOT THE LOAD-BEARING GUARD — do not build on it as
    ///      though it were. It screens STORED TARGETS ONLY, and a payload reaches
    ///      any of these addresses anyway by naming a proposer-deployed forwarder
    ///      that calls on to them; screening one hop cannot be made complete.
    ///      What actually holds is upstream and unaffected by indirection:
    ///      `SyndicateVault.runSandbox` is `nonReentrant`, so no route back into
    ///      the vault survives while a run is in flight, and every function on
    ///      the contracts below is gated to its own privileged caller. This list
    ///      catches the direct, obvious shape cheaply; it is not a boundary.
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
    /// @dev VAULT-ONLY, and that gate is load-bearing rather than tidiness.
    ///      `SyndicateVault._payCohortShare` splits a MEASURED BALANCE DELTA
    ///      taken across the call inside `collectResidue`, and a delta is a
    ///      complete measurement only while that is the one door vault asset can
    ///      arrive through. A sandbox is genuinely enrolled in that machinery —
    ///      `onProposalSettled` records it against the settling pid, the key the
    ///      split runs on — so a bare EOA driving this function directly landed
    ///      the whole balance in the vault OUTSIDE the measurement: the exited
    ///      cohort was credited nothing (unrepairably, the delta is spent) and
    ///      `depositNav()` double-counted until someone called
    ///      `collectResidue`. No attacker required; any keeper calling a
    ///      function advertised as permissionless did it.
    ///
    ///      Both `StrategyFactory` templates already carry this modifier for
    ///      exactly this reason (`MorphoSupplyStrategy.sweep`,
    ///      `ConcentratedLiquidityStrategy.sweep` / `releaseUnconvertible`); the
    ///      sandbox was a third residue holder merged with the door open.
    ///
    ///      THE PERMISSIONLESS PROPERTY IS NOT LOST, only routed:
    ///      `SyndicateVault.collectResidue` is itself permissionless and reaches
    ///      this through the vault, so capital still comes home with no registry
    ///      standing and no owner action — including in the state that wedges an
    ///      ordinary strategy, where a demotion has cleared the allowlist and
    ///      every batch-routed settlement path reverts `DisallowedBatchCallee`
    ///      (pashov finding #15). A sandbox holds no registry entry, so there is
    ///      nothing to demote and nothing to wedge.
    function sweep() external onlyVault returns (uint256 assets) {
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
        // BEST-EFFORT, PER TOKEN, ON A FAIRLY DIVIDED BUDGET. The list is
        // proposer-authored: a token that reverts, returns nothing, or burns gas
        // must not take down the sweep and re-brick the exit it is the only
        // escape from. `_fairShare` is what makes "its own leg" true — a FIXED
        // ceiling alone does not, because 16 entries at the old 150,000-gas
        // probe ceiling is 2.4M against the 1,500,000 `SyndicateVault.collectResidue`
        // lends this call. Measured before the fix: 16 gas-burning declared
        // tokens consumed the entire 1.5M and the ASSET TRANSFER ABOVE was
        // reverted with it, recovering nothing.
        //
        // Tokens land in the VAULT, where `totalAssets()` does not count them —
        // so this recovers custody without ever pricing an unvalued asset into a
        // mint, which is the distinction the whole residue design rests on.
        uint256 n = _declaredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            address t = _declaredTokens[i];
            if (t == address(0) || t == _asset || t.code.length == 0) continue;
            uint256 share = _fairShare(n - i);
            (bool okBal, bytes memory balRet) = t.staticcall{gas: _min(share / 4, _TOKEN_PROBE_GAS)}(
                abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
            );
            if (!okBal || balRet.length != 32) continue;
            uint256 bal = abi.decode(balRet, (uint256));
            if (bal == 0) continue;
            // solhint-disable-next-line avoid-low-level-calls
            (bool okXfer,) = t.call{gas: _min(share - share / 4, _TOKEN_SWEEP_GAS)}(
                abi.encodeWithSelector(IERC20.transfer.selector, vault_, bal)
            );
            if (okXfer) {
                emit SandboxTokenSwept(t, bal);
                // THE BELIEF WAS WRONG, SO DROP IT. A token that moves is
                // movable; leaving either mark set would keep the vault blind to
                // a balance it could arrive at again, and would let unrelated
                // past failures accumulate toward a write-off.
                _failedSince[t] = 0;
                if (_abandoned[t]) {
                    _abandoned[t] = false;
                    emit SandboxTokenAbandonmentCleared(t);
                }
            } else if (_failedSince[t] == 0) {
                // FIRST FAILURE STARTS THE CLOCK AND NOTHING ELSE. One failed
                // transfer is a snapshot, not a verdict, and this call is
                // reachable by anyone through `collectResidue` — writing the
                // token off here would let them pick the moment. See
                // `_abandoned`.
                _failedSince[t] = uint64(block.timestamp);
            } else if (block.timestamp >= _failedSince[t] + ABANDON_DELAY) {
                // Still failing a whole `ABANDON_DELAY` later: a transient cause
                // has been ruled out, so stop counting it or the lock is
                // permanent. Until then the token keeps counting and deposits
                // stay shut — the recoverable direction.
                _abandoned[t] = true;
                emit SandboxTokenAbandoned(t, bal);
            }
        }
    }

    /// @dev This iteration's slice of the gas still in hand, with `remaining`
    ///      tokens left to visit (this one included).
    ///
    ///      THE POINT IS THE DIVISION, NOT THE CEILING. A per-entry ceiling
    ///      bounds one call; it does not bound a LOOP, because n entries at the
    ///      ceiling exceed whatever the caller lent. Dividing what is actually
    ///      left means a hostile entry can consume its own slice and no more —
    ///      every token behind it still gets a turn, and the function always
    ///      returns rather than reverting the caller out of gas.
    ///
    ///      The `+ 1` reserves a slice for the work after the loop (the return,
    ///      and in `sweep` nothing else), so the LAST entry cannot take
    ///      everything either. Scales both ways: given a generous budget the
    ///      slices exceed the ceilings and the ceilings bind, which is the
    ///      ordinary case.
    function _fairShare(uint256 remaining) private view returns (uint256) {
        return gasleft() / (remaining + 1);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
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
    ///
    ///      AND IT MUST NOT BE ABLE TO BRICK IT BY BURNING, EITHER — the subtler
    ///      half, and the one this originally got wrong. The vault reads this
    ///      through a 150,000-gas staticcall and `_refreshUnvalued` KEEPS THE
    ///      LAST KNOWN FLAG when the read fails, so a payload that makes this
    ///      function unreadable forever freezes whatever the flag last said. One
    ///      declared token burning the old per-token ceiling (also 150,000, i.e.
    ///      the caller's whole budget) did exactly that: probe once while a real
    ///      residue token sits first in the list to latch the flag TRUE, drain
    ///      that token so the loop walks past it into the burner, and every
    ///      later read reverts out of gas — `depositsLocked()` true for the life
    ///      of the vault, with no permissionless exit and no owner override.
    ///      `_fairShare` removes the premise: no entry can take the budget the
    ///      entries behind it need, so this always returns an answer.
    function hasUnvaluedResidue() external view returns (bool) {
        address asset_ = _asset;
        uint256 n = _declaredTokens.length;
        for (uint256 i = 0; i < n; i++) {
            address t = _declaredTokens[i];
            if (t == address(0) || t == asset_ || _abandoned[t]) continue;
            (bool ok, bytes memory ret) = t.staticcall{gas: _min(_fairShare(n - i), _TOKEN_PROBE_GAS)}(
                abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
            );
            if (ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0) return true;
        }
        return false;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev ALWAYS ZERO, and not an oversight. The credit this view feeds tells
    ///      settlement that capital was deliberately CONVERTED at a known cost
    ///      rather than lost, and the sandbox executes proposer-supplied calls
    ///      against arbitrary declared tokens: it has no recorded deployment
    ///      cost to report and no way to distinguish an intended conversion from
    ///      a drain. Reporting zero keeps sandbox residue reading as a loss,
    ///      which is both the conservative answer and the behaviour that existed
    ///      before this view — a template earns the credit by knowing what it
    ///      spent, and this one cannot.
    function unpricedCostBasis() external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev False, consistent with the zero basis above: the sandbox never
    ///      claims a conversion, so it can never be credited for one.
    function expectsUnpricedResidue() external pure returns (bool) {
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
