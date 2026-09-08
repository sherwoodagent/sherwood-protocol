// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICallSandbox} from "./interfaces/ICallSandbox.sol";
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

    /// @dev Probe budget for resolving the denied-address chain: a hop that
    ///      cannot answer inside it is treated as unreadable, never allowed to
    ///      consume the whole transaction.
    uint256 private constant _PROBE_GAS = 150_000;

    address private _vault;
    address private _asset;
    bool private _initialized;
    bool private _hasRun;

    Call[] private _calls;
    address[] private _declaredTokens;

    modifier onlyVault() {
        if (msg.sender != _vault) revert NotVault();
        _;
    }

    /// @inheritdoc ICallSandbox
    /// @dev The payload is written HERE and nowhere else: the guardian coverage
    ///      quorum replaces the owner's allowlist decision only if what runs
    ///      cannot change after it was reviewed. `asset` is snapshotted at bind.
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
        // The list is a review artifact; a duplicate is noise the reviewer
        // should not have to read past.
        for (uint256 i = 0; i < declaredTokens_.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (declaredTokens_[i] == declaredTokens_[j]) revert DuplicateDeclaredToken(declaredTokens_[i]);
            }
            _declaredTokens.push(declaredTokens_[i]);
        }
    }

    /// @inheritdoc ICallSandbox
    /// @dev ONE-SHOT AND VAULT-ONLY; a denied target or a reverting call takes
    ///      the whole run down. After the calls, the asset and every declared
    ///      token are pushed home and any balance left reverts the run.
    function run() external onlyVault {
        if (_hasRun) revert AlreadyRun();
        _hasRun = true;

        _assertNoDeniedTargets();

        uint256 n = _calls.length;
        for (uint256 i = 0; i < n; i++) {
            Call storage c = _calls[i];
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok,) = c.target.call(c.data);
            if (!ok) revert CallFailed(i);
        }

        address asset_ = _asset;
        uint256 returned = _pushHome(asset_);
        uint256 m = _declaredTokens.length;
        for (uint256 i = 0; i < m; i++) {
            address t = _declaredTokens[i];
            if (t != asset_) _pushHome(t);
        }

        emit SandboxRun(_vault, n, returned);
    }

    /// @dev Typed on purpose: a token that cannot be moved, or that moves less
    ///      than it reports, reverts here rather than leaving value behind.
    function _pushHome(address token) private returns (uint256 pushed) {
        pushed = IERC20(token).balanceOf(address(this));
        if (pushed != 0) IERC20(token).safeTransfer(_vault, pushed);
        uint256 left = IERC20(token).balanceOf(address(this));
        if (left != 0) revert SandboxHoldsTokens(token, left);
    }

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
