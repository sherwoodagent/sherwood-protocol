// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {BatchExecutorLib} from "../BatchExecutorLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Getters walked to name the protocol contracts a call may not target. Selectors only.
interface IProtocolPath {
    function governor() external view returns (address);
    function factory() external view returns (address);
    function tierRegistry() external view returns (address);
    function strategyFactory() external view returns (address);
}

/**
 * @title GenericCallStrategy
 * @notice Runs a proposer-supplied execute leg and settle leg of calls, fixed at initialize.
 *         Tier 2 forever, never certified, unaudited: see docs/generic-call-strategy.md.
 *
 *   Init:    abi.encode(uint256 pullAmount, Call[] executeCalls, Call[] settleCalls, address[] sweepTokens)
 *   Execute: [asset.approve(strategy, pullAmount), strategy.execute()]
 *   Settle:  [strategy.settle()]
 */
contract GenericCallStrategy is BaseStrategy {
    uint8 internal constant LEG_EXECUTE = 0;
    uint8 internal constant LEG_SETTLE = 1;
    uint256 public constant MAX_CALLS_PER_LEG = 16;
    uint256 public constant MAX_LEG_CALLDATA = 16_384;
    uint256 public constant MAX_SWEEP_TOKENS = 16;

    /// @notice An allowance (`forAll == false`) or operator approval a leg grants, revoked after each leg.
    struct Grant {
        address token;
        address spender;
        bool forAll;
    }

    error TooManyCalls(uint8 leg);
    error CalldataTooLarge(uint8 leg);
    error TooManySweepTokens();
    error NativeValueUnsupported(uint8 leg, uint256 index);
    error ForbiddenTarget(uint8 leg, uint256 index, address target);
    error TargetHasNoCode(uint8 leg, uint256 index, address target);
    error AssetCallNotAllowed(uint8 leg, uint256 index, bytes4 selector);
    error ProtocolAddressUnresolved();
    error TargetCodeChanged(address target);
    error CallFailed(uint8 leg, uint256 index, bytes reason);
    error NoTunableParams();

    /// @notice A best-effort revoke that the token refused; nothing else depends on it.
    event RevokeFailed(address indexed token, address indexed spender);

    /// @notice The vault asset, read at initialize.
    address public asset;
    /// @notice Asset pulled from the vault at execute; zero pulls nothing.
    uint256 public pullAmount;
    /// @notice `keccak256(abi.encode(pullAmount, executeCalls, settleCalls, sweepTokens))`.
    bytes32 public configHash;
    /// @notice Codehash of each target at initialize, re-checked at execute only.
    mapping(address target => bytes32 codehash) public pinnedCodehash;

    BatchExecutorLib.Call[] internal _executeCalls;
    BatchExecutorLib.Call[] internal _settleCalls;
    address[] internal _sweepTokens;
    Grant[] internal _grants;

    function name() external pure returns (string memory) {
        return "Generic Call";
    }

    function executeCalls() external view returns (BatchExecutorLib.Call[] memory) {
        return _executeCalls;
    }

    function settleCalls() external view returns (BatchExecutorLib.Call[] memory) {
        return _settleCalls;
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
    /// @dev Plain `transferFrom`: the vault has no ERC-721 receiver hook.
    function rescueERC721To(address token, uint256 tokenId) external onlyVault {
        IERC721(token).transferFrom(address(this), vault(), tokenId);
    }

    // ── Initialization ──

    function _initialize(bytes calldata data) internal override {
        (
            uint256 pull,
            BatchExecutorLib.Call[] memory execCalls,
            BatchExecutorLib.Call[] memory settleCalls_,
            address[] memory sweep
        ) = abi.decode(data, (uint256, BatchExecutorLib.Call[], BatchExecutorLib.Call[], address[]));

        if (sweep.length > MAX_SWEEP_TOKENS) revert TooManySweepTokens();
        address asset_ = IERC4626(vault()).asset();
        address[5] memory denied = _protocolAddresses();
        _storeLeg(LEG_EXECUTE, execCalls, _executeCalls, asset_, denied);
        _storeLeg(LEG_SETTLE, settleCalls_, _settleCalls, asset_, denied);
        for (uint256 i; i < sweep.length; ++i) {
            if (sweep[i] == address(0)) revert ZeroAddress();
            _sweepTokens.push(sweep[i]);
        }
        asset = asset_;
        pullAmount = pull;
        configHash = keccak256(abi.encode(pull, execCalls, settleCalls_, sweep));
    }

    function _storeLeg(
        uint8 leg,
        BatchExecutorLib.Call[] memory calls,
        BatchExecutorLib.Call[] storage dst,
        address asset_,
        address[5] memory denied
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
    function _checkCall(uint8 leg, uint256 i, BatchExecutorLib.Call memory c, address asset_, address[5] memory denied)
        private
        view
    {
        if (c.value != 0) revert NativeValueUnsupported(leg, i);
        address t = c.target;
        if (t == address(0) || t == address(this)) revert ForbiddenTarget(leg, i, t);
        for (uint256 k; k < 5; ++k) {
            if (t == denied[k]) revert ForbiddenTarget(leg, i, t);
        }
        if (t.code.length == 0) revert TargetHasNoCode(leg, i, t);
        if (t == asset_) {
            bytes4 sel = bytes4(c.data);
            if (c.data.length < 68 || (sel != IERC20.approve.selector && sel != IERC20.transfer.selector)) {
                revert AssetCallNotAllowed(leg, i, sel);
            }
        }
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

    /// @dev vault, governor, SyndicateFactory, TierRegistry, StrategyFactory; fail-closed on any hop.
    function _protocolAddresses() private view returns (address[5] memory a) {
        a[0] = vault();
        a[1] = _readAddress(a[0], abi.encodeCall(IProtocolPath.governor, ()));
        a[2] = _readAddress(a[0], abi.encodeCall(IProtocolPath.factory, ()));
        a[3] = _readAddress(a[1], abi.encodeCall(IProtocolPath.tierRegistry, ()));
        a[4] = _readAddress(a[3], abi.encodeCall(IProtocolPath.strategyFactory, ()));
        for (uint256 k = 1; k < 5; ++k) {
            if (a[k] == address(0)) revert ProtocolAddressUnresolved();
        }
    }

    // ── Execute / settle ──

    function _execute() internal override {
        _requirePinnedCode(_executeCalls);
        _requirePinnedCode(_settleCalls);
        if (pullAmount != 0) _pullFromVault(asset, pullAmount);
        _runLeg(LEG_EXECUTE, _executeCalls);
        _revokeGrants();
    }

    /// @dev No codehash check here: a refused settle would wedge the proposal in Executed.
    function _settle() internal override {
        _runLeg(LEG_SETTLE, _settleCalls);
        _revokeGrants();
        _pushAllToVault(asset);
        for (uint256 i; i < _sweepTokens.length; ++i) {
            _pushAllToVault(_sweepTokens[i]);
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
            (bool ok, bytes memory ret) = c.target.call(c.data);
            if (!ok) revert CallFailed(leg, i, ret);
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
            (bool ok,) = g.token.call(revoke);
            if (!ok) emit RevokeFailed(g.token, g.spender);
        }
    }

    /// @dev One-word read; a codeless target, revert or wrong-length return reads as zero.
    function _readWord(address target, bytes memory data) private view returns (uint256 word) {
        if (target.code.length == 0) return 0;
        (bool ok, bytes memory ret) = target.staticcall(data);
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
