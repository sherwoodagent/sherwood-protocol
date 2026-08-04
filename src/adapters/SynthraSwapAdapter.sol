// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Synthra Router interface (SwapRouter02 — Uniswap V3 compatible, no deadline)
interface ISynthraRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut);
}

/// @notice Synthra Quoter interface (Uniswap V3 QuoterV2 compatible)
interface ISynthraQuoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);

    /// @dev Multi-hop quote on a packed V3 path.
    function quoteExactInput(bytes calldata path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

/**
 * @title SynthraSwapAdapter
 * @notice ISwapAdapter implementation for Synthra DEX on Robinhood Chain.
 *         Synthra uses a Uniswap V3-compatible interface with an additional
 *         0.1% treasury fee deducted automatically from swaps.
 *
 *   extraData encoding:
 *     Single-hop: abi.encode(uint24 fee)
 *     Multi-hop:  abi.encode(uint24 fee, bytes path)  — path is packed (token+fee+token...)
 *
 *   Multi-hop paths are auto-oriented to tokenIn: a single stored path
 *   (buy: asset->...->token) is reused by strategies for the reverse
 *   (sell: token->...->asset), so both swap() and quote() reverse the path
 *   when its head isn't tokenIn, mirroring UniswapSwapAdapter's mode-1
 *   behavior. Without this, the reverse leg would hand the router a path
 *   whose head is a token the adapter never approved, reverting settlement.
 *
 *   The caller (strategy) must approve this adapter to spend tokenIn before calling swap().
 */
contract SynthraSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    ISynthraRouter public immutable router;
    ISynthraQuoter public immutable quoter;

    error ZeroAddress();

    constructor(address _router, address _quoter) {
        if (_router == address(0) || _quoter == address(0)) revert ZeroAddress();
        router = ISynthraRouter(_router);
        quoter = ISynthraQuoter(_quoter);
    }

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata extraData)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        if (extraData.length == 32) {
            // Single-hop: extraData = abi.encode(uint24 fee)
            uint24 fee = abi.decode(extraData, (uint24));
            amountOut = router.exactInputSingle(
                ISynthraRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: msg.sender,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin,
                    sqrtPriceLimitX96: 0
                })
            );
        } else {
            // Multi-hop: extraData = abi.encode(uint24 fee, bytes path)
            (, bytes memory path) = abi.decode(extraData, (uint24, bytes));
            // A single stored path (buy: asset->...->token) is reused by
            // strategies for the reverse (sell: token->...->asset) — orient
            // the path so tokenIn is always the head before routing,
            // mirroring UniswapSwapAdapter's mode-1 auto-reverse.
            address pathStart = _extractFirstAddress(path);
            if (pathStart != tokenIn) {
                path = _reversePath(path);
            }
            amountOut = router.exactInput(
                ISynthraRouter.ExactInputParams({
                    path: path, recipient: msg.sender, amountIn: amountIn, amountOutMinimum: amountOutMin
                })
            );
        }
    }

    /// @inheritdoc ISwapAdapter
    /// @dev Branches on `extraData.length` to support both single-hop
    ///      (32 bytes = abi.encode(uint24 fee)) and multi-hop (longer =
    ///      abi.encode(uint24 fee, bytes path)) encodings, mirroring the
    ///      dispatch in `swap()` above.
    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata extraData)
        external
        override
        returns (uint256 amountOut)
    {
        if (extraData.length == 32) {
            uint24 fee = abi.decode(extraData, (uint24));
            amountOut = quoter.quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);
        } else {
            (, bytes memory path) = abi.decode(extraData, (uint24, bytes));
            // Match `swap()`'s path orientation: ensure tokenIn is the head
            // of the path before passing to the quoter.
            if (_extractFirstAddress(path) != tokenIn) path = _reversePath(path);
            (amountOut,,,) = quoter.quoteExactInput(path, amountIn);
        }
    }

    /// @dev Extract the first 20-byte address from a packed V3 path.
    function _extractFirstAddress(bytes memory path) internal pure returns (address addr) {
        require(path.length >= 20, "path too short");
        assembly {
            addr := shr(96, mload(add(path, 32)))
        }
    }

    /// @dev Reverse a packed Uniswap V3 path (addr + fee + addr + fee + ...).
    ///      Each segment is 20 bytes (address) + 3 bytes (fee). Last element is 20 bytes.
    function _reversePath(bytes memory path) internal pure returns (bytes memory reversed) {
        uint256 len = path.length;
        // path layout: addr(20) [+ fee(3) + addr(20)]* — total = 20 + 23*n
        require(len >= 20 && (len - 20) % 23 == 0, "invalid path length");
        uint256 numHops = (len - 20) / 23;

        reversed = new bytes(len);
        uint256 writePos;

        // Write last address first
        uint256 lastAddrPos = 20 + numHops * 23;
        for (uint256 j; j < 20; ++j) {
            reversed[writePos++] = path[lastAddrPos - 20 + j];
        }

        // Walk backwards through hops
        for (uint256 i = numHops; i > 0; --i) {
            uint256 hopStart = (i - 1) * 23 + 20; // fee starts here
            // Copy fee (3 bytes)
            reversed[writePos++] = path[hopStart];
            reversed[writePos++] = path[hopStart + 1];
            reversed[writePos++] = path[hopStart + 2];
            // Copy address before this fee (20 bytes at hopStart - 20)
            uint256 addrStart = hopStart - 20;
            for (uint256 j; j < 20; ++j) {
                reversed[writePos++] = path[addrStart + j];
            }
        }
    }
}
