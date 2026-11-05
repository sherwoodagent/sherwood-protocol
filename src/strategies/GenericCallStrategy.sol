// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {BatchExecutorLib} from "../BatchExecutorLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Getters walked to name the protocol contracts a call may not target. Selectors only.
interface IProtocolPath {
    function governor() external view returns (address);
    function factory() external view returns (address);
    function tierRegistry() external view returns (address);
    function strategyFactory() external view returns (address);
    function guardianRegistry() external view returns (address);
    function swood() external view returns (address);
    function withdrawalQueue() external view returns (address);
    function exposureLedger() external view returns (address);
    function coverageFreezer() external view returns (address);
}

/**
 * @title GenericCallStrategy
 * @notice Runs a proposer-supplied execute leg and settle leg of calls, fixed at initialize except
 *         for settle-leg balance patches.
 *         Tier 2 forever, never certified, unaudited: see docs/generic-call-strategy.md.
 *
 *   Init:    abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls,
 *                       BalancePatch[] settlePatches, address[] sweepTokens)
 *   Execute: [asset.approve(strategy, pullAmount), strategy.execute()]
 *   Settle:  [strategy.settle()]
 */
contract GenericCallStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    uint8 internal constant LEG_EXECUTE = 0;
    uint8 internal constant LEG_SETTLE = 1;
    uint256 internal constant DENIED = 10;
    /// @dev Gas for each revoke read and write and each sweep balance read: hygiene cannot starve settle.
    uint256 internal constant HYGIENE_GAS = 100_000;
    bytes4 internal constant SAFE_TRANSFER_FROM = 0x42842e0e; // safeTransferFrom(address,address,uint256)
    bytes4 internal constant SAFE_TRANSFER_FROM_DATA = 0xb88d4fde; // safeTransferFrom(address,address,uint256,bytes)
    uint256 public constant MAX_CALLS_PER_LEG = 16;
    uint256 public constant MAX_LEG_CALLDATA = 16_384;
    uint256 public constant MAX_SWEEP_TOKENS = 16;

    /// @notice An allowance (`forAll == false`) or operator approval a leg grants, revoked after each leg.
    struct Grant {
        address token;
        address spender;
        bool forAll;
    }

    /// @notice At settle, argument word `wordIndex` of settle call `callIndex` becomes the clone's
    ///         live `token` balance. Byte offset `4 + 32 * wordIndex`; one patch per call.
    struct BalancePatch {
        uint256 callIndex;
        uint256 wordIndex;
        address token;
    }

    error TooManyCalls(uint8 leg);
    error CalldataTooLarge(uint8 leg);
    error TooManySweepTokens();
    error InvalidSweepToken(uint256 index);
    error NativeValueUnsupported(uint8 leg, uint256 index);
    error ForbiddenTarget(uint8 leg, uint256 index, address target);
    error TargetHasNoCode(uint8 leg, uint256 index, address target);
    error AssetCallNotAllowed(uint8 leg, uint256 index, bytes4 selector);
    error InvalidPatch(uint256 patchIndex);
    error ProtocolAddressUnresolved();
    error TargetCodeChanged(address target);
    error CallFailed(uint8 leg, uint256 index, bytes reason);
    error NoTunableParams();

    /// @notice A best-effort revoke that the token refused; nothing else depends on it.
    event RevokeFailed(address indexed token, address indexed spender);
    /// @notice A sweep token whose transfer failed; it stays on the clone for `rescueTo`.
    event SweepFailed(address indexed token);

    /// @notice The vault asset, read at initialize.
    address public asset;
    /// @notice Asset pulled from the vault at execute; zero pulls nothing.
    uint256 public pullAmount;
    /// @notice `keccak256` of the decoded init tuple, re-encoded.
    bytes32 public configHash;
    /// @notice Codehash of each target at initialize, re-checked at execute only.
    mapping(address target => bytes32 codehash) public pinnedCodehash;

    BatchExecutorLib.Call[] internal _executeCalls;
    BatchExecutorLib.Call[] internal _settleCalls;
    BalancePatch[] internal _settlePatches;
    address[] internal _sweepTokens;
    Grant[] internal _grants;
    /// @dev Settle call index -> patch index + 1; zero means unpatched.
    mapping(uint256 callIndex => uint256 slot) internal _patchSlot;

    function name() external pure returns (string memory) {
        return "Generic Call";
    }

    function executeCalls() external view returns (BatchExecutorLib.Call[] memory) {
        return _executeCalls;
    }

    function settleCalls() external view returns (BatchExecutorLib.Call[] memory) {
        return _settleCalls;
    }

    function settlePatches() external view returns (BalancePatch[] memory) {
        return _settlePatches;
    }

    function sweepTokens() external view returns (address[] memory) {
        return _sweepTokens;
    }

    function grants() external view returns (Grant[] memory) {
        return _grants;
    }

    /// @notice Accepts ERC-721s delivered with `safeTransferFrom`; `rescueERC721To` is the way out.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return GenericCallStrategy.onERC721Received.selector;
    }

    /// @notice Push an ERC-721 the clone holds to the vault, in any state.
    /// @dev Plain `transferFrom`: the recipient is always the vault, an `ERC721Holder`, so the
    ///      receiver callback would add nothing.
    function rescueERC721To(address token, uint256 tokenId) external onlyVault {
        IERC721(token).transferFrom(address(this), vault(), tokenId);
    }

    // ── Initialization ──

    function _initialize(bytes calldata data) internal override {
        (
            uint256 pull,
            BatchExecutorLib.Call[] memory execCalls,
            BatchExecutorLib.Call[] memory settleCalls_,
            BalancePatch[] memory patches,
            address[] memory sweep
        ) = abi.decode(data, (uint256, BatchExecutorLib.Call[], BatchExecutorLib.Call[], BalancePatch[], address[]));

        if (sweep.length > MAX_SWEEP_TOKENS) revert TooManySweepTokens();
        address asset_ = IERC4626(vault()).asset();
        address[DENIED] memory denied = _protocolAddresses();
        _storeLeg(LEG_EXECUTE, execCalls, _executeCalls, asset_, denied);
        _storeLeg(LEG_SETTLE, settleCalls_, _settleCalls, asset_, denied);
        for (uint256 i; i < sweep.length; ++i) {
            if (_isForbidden(sweep[i], denied) || sweep[i].code.length == 0) revert InvalidSweepToken(i);
            _sweepTokens.push(sweep[i]);
        }
        for (uint256 i; i < patches.length; ++i) {
            _storePatch(i, patches[i], settleCalls_, asset_);
        }
        asset = asset_;
        pullAmount = pull;
        configHash = keccak256(abi.encode(pull, execCalls, settleCalls_, patches, sweep));
    }

    function _storeLeg(
        uint8 leg,
        BatchExecutorLib.Call[] memory calls,
        BatchExecutorLib.Call[] storage dst,
        address asset_,
        address[DENIED] memory denied
    ) private {
        if (calls.length > MAX_CALLS_PER_LEG) revert TooManyCalls(leg);
        uint256 size;
        for (uint256 i; i < calls.length; ++i) {
            BatchExecutorLib.Call memory c = calls[i];
            size += c.data.length;
            _checkCall(leg, i, c, asset_, denied);
            pinnedCodehash[c.target] = c.target.codehash;
            _recordGrant(c.target, c.data);
            dst.push(c);
        }
        if (size > MAX_LEG_CALLDATA) revert CalldataTooLarge(leg);
    }

    /// @dev On the asset only `approve`/`transfer`: the vault's allowance to this clone is live for the
    ///      whole execute batch, so `transferFrom` or a token extension would spend past `pullAmount`.
    function _checkCall(
        uint8 leg,
        uint256 i,
        BatchExecutorLib.Call memory c,
        address asset_,
        address[DENIED] memory denied
    ) private view {
        if (c.value != 0) revert NativeValueUnsupported(leg, i);
        address t = c.target;
        if (_isForbidden(t, denied)) revert ForbiddenTarget(leg, i, t);
        if (t.code.length == 0) revert TargetHasNoCode(leg, i, t);
        if (t == asset_) {
            bytes4 sel = bytes4(c.data);
            if (c.data.length < 68 || (sel != IERC20.approve.selector && sel != IERC20.transfer.selector)) {
                revert AssetCallNotAllowed(leg, i, sel);
            }
        }
    }

    /// @dev The token must already be in the plan (asset, leg target or sweep token). A balance
    ///      never lands in the address words of an approve or transfer selector.
    function _storePatch(uint256 i, BalancePatch memory p, BatchExecutorLib.Call[] memory settleCalls_, address asset_)
        private
    {
        if (p.callIndex >= settleCalls_.length || _patchSlot[p.callIndex] != 0) revert InvalidPatch(i);
        bytes memory data = settleCalls_[p.callIndex].data;
        if (data.length < 36 || p.wordIndex >= (data.length - 4) / 32) revert InvalidPatch(i);
        if (p.token != asset_ && pinnedCodehash[p.token] == 0 && !_isSweepToken(p.token)) revert InvalidPatch(i);
        if (p.wordIndex < _addressWords(bytes4(data))) revert InvalidPatch(i);
        _patchSlot[p.callIndex] = i + 1;
        _settlePatches.push(p);
    }

    /// @dev Leading address words: the spender or operator, the recipient, or `from` and `to`.
    function _addressWords(bytes4 sel) private pure returns (uint256) {
        if (sel == IERC20.approve.selector || sel == IERC721.setApprovalForAll.selector) return 1;
        if (sel == IERC20.transfer.selector) return 1;
        if (sel == IERC20.transferFrom.selector || sel == SAFE_TRANSFER_FROM || sel == SAFE_TRANSFER_FROM_DATA) {
            return 2;
        }
        return 0;
    }

    function _isSweepToken(address t) private view returns (bool) {
        for (uint256 k; k < _sweepTokens.length; ++k) {
            if (_sweepTokens[k] == t) return true;
        }
        return false;
    }

    function _recordGrant(address token, bytes memory data) private {
        if (data.length < 68) return;
        bytes4 sel = bytes4(data);
        bool forAll = sel == IERC721.setApprovalForAll.selector;
        if (!forAll && sel != IERC20.approve.selector) return;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(data, 36))
        }
        _grants.push(Grant({token: token, spender: address(uint160(word)), forAll: forAll}));
    }

    function _isForbidden(address t, address[DENIED] memory denied) private view returns (bool) {
        if (t == address(0) || t == address(this)) return true;
        for (uint256 k; k < DENIED; ++k) {
            if (t == denied[k]) return true;
        }
        return false;
    }

    /// @dev vault, governor, SyndicateFactory, TierRegistry, StrategyFactory, GuardianRegistry, sWOOD
    ///      (fail-closed), then the withdrawal queue, ExposureLedger and ChallengeGame, which may be unset.
    function _protocolAddresses() private view returns (address[DENIED] memory a) {
        a[0] = vault();
        a[1] = _readAddress(a[0], abi.encodeCall(IProtocolPath.governor, ()));
        a[2] = _readAddress(a[0], abi.encodeCall(IProtocolPath.factory, ()));
        a[3] = _readAddress(a[1], abi.encodeCall(IProtocolPath.tierRegistry, ()));
        a[4] = _readAddress(a[3], abi.encodeCall(IProtocolPath.strategyFactory, ()));
        a[5] = _readAddress(a[1], abi.encodeCall(IProtocolPath.guardianRegistry, ()));
        a[6] = _readAddress(a[5], abi.encodeCall(IProtocolPath.swood, ()));
        for (uint256 k = 1; k < 7; ++k) {
            if (a[k] == address(0)) revert ProtocolAddressUnresolved();
        }
        a[7] = _readAddress(a[0], abi.encodeCall(IProtocolPath.withdrawalQueue, ()));
        a[8] = _readAddress(a[1], abi.encodeCall(IProtocolPath.exposureLedger, ()));
        a[9] = _readAddress(a[8], abi.encodeCall(IProtocolPath.coverageFreezer, ()));
    }

    // ── Execute / settle ──

    function _execute() internal override {
        _requirePinnedCode(_executeCalls);
        _requirePinnedCode(_settleCalls);
        if (pullAmount != 0) _pullFromVault(asset, pullAmount);
        _runLeg(LEG_EXECUTE, _executeCalls);
        _revokeGrants();
    }

    /// @dev No codehash check here: a refused settle would wedge the proposal in Executed. The asset
    ///      push is strict; sweeps are best-effort, so a broken sweep token cannot block it.
    function _settle() internal override {
        _runLeg(LEG_SETTLE, _settleCalls);
        _revokeGrants();
        _pushAllToVault(asset);
        for (uint256 i; i < _sweepTokens.length; ++i) {
            address t = _sweepTokens[i];
            uint256 bal = _readWord(t, abi.encodeCall(IERC20.balanceOf, (address(this))));
            if (bal != 0 && !IERC20(t).trySafeTransfer(vault(), bal)) emit SweepFailed(t);
        }
    }

    function _updateParams(bytes calldata) internal pure override {
        revert NoTunableParams();
    }

    function _requirePinnedCode(BatchExecutorLib.Call[] storage calls) private view {
        for (uint256 i; i < calls.length; ++i) {
            address t = calls[i].target;
            if (t.codehash != pinnedCodehash[t]) revert TargetCodeChanged(t);
        }
    }

    function _runLeg(uint8 leg, BatchExecutorLib.Call[] storage calls) private {
        for (uint256 i; i < calls.length; ++i) {
            BatchExecutorLib.Call storage c = calls[i];
            bytes memory data = c.data;
            if (leg == LEG_SETTLE) _applyPatch(i, data);
            (bool ok, bytes memory ret) = c.target.call(data);
            if (!ok) revert CallFailed(leg, i, ret);
        }
    }

    /// @dev The written amount is the clone's own balance: it can never exceed what the clone holds.
    function _applyPatch(uint256 callIndex, bytes memory data) private view {
        uint256 slot = _patchSlot[callIndex];
        if (slot == 0) return;
        BalancePatch storage p = _settlePatches[slot - 1];
        uint256 bal = IERC20(p.token).balanceOf(address(this));
        uint256 offset = 4 + 32 * p.wordIndex;
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), bal)
        }
    }

    /// @dev Best-effort: a grant whose read does not answer one word is skipped, a failed revoke is
    ///      ignored. Hygiene only; the bound is that the clone holds only what it pulled.
    function _revokeGrants() private {
        for (uint256 i; i < _grants.length; ++i) {
            Grant memory g = _grants[i];
            bytes memory read = g.forAll
                ? abi.encodeCall(IERC721.isApprovedForAll, (address(this), g.spender))
                : abi.encodeCall(IERC20.allowance, (address(this), g.spender));
            if (_readWord(g.token, read) == 0) continue;
            bytes memory revoke = g.forAll
                ? abi.encodeCall(IERC721.setApprovalForAll, (g.spender, false))
                : abi.encodeCall(IERC20.approve, (g.spender, 0));
            (bool ok,) = g.token.call{gas: HYGIENE_GAS}(revoke);
            if (!ok) emit RevokeFailed(g.token, g.spender);
        }
    }

    /// @dev One-word read under `HYGIENE_GAS`; a codeless target, revert or wrong-length return reads as zero.
    function _readWord(address target, bytes memory data) private view returns (uint256 word) {
        if (target.code.length == 0) return 0;
        (bool ok, bytes memory ret) = target.staticcall{gas: HYGIENE_GAS}(data);
        if (!ok || ret.length != 32) return 0;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
    }

    /// @dev Dirty upper bits read as zero, which `_protocolAddresses` refuses.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }
}
