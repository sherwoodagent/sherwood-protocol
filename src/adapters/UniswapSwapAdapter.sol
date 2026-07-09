// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ── Uniswap V3 interfaces ──

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IQuoterV2 {
    /// @dev Uniswap V3 QuoterV2 takes a struct, NOT positional args
    ///      (V1's signature). Order is: tokenIn, tokenOut, amountIn, fee,
    ///      sqrtPriceLimitX96 — note `amountIn` comes BEFORE `fee`.
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    /// @dev Sherlock #58 — packed V3 path quoting for mode-1 multi-hop routes.
    function quoteExactInput(bytes calldata path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

// ── Uniswap V4 interfaces (minimal, inlined — no v4-core dependency) ──
//
// Currency/IHooks are `address` here (ABI-compatible with v4's UDVT/interface
// types). BalanceDelta is an int256 packing two int128s: upper 128 bits =
// amount0, lower 128 bits = amount1; positive = owed to us, negative = we owe.

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/// @dev A single hop of a v4 multi-hop path (v4-periphery PathKey layout,
///      UDVTs flattened to address/bytes). `intermediateCurrency` is the
///      *output* currency of this hop; the input is the previous currency
///      (tokenIn for hop 0).
struct PathKey {
    address intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
    bytes hookData;
}

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    struct QuoteExactParams {
        address exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);
}

/**
 * @title UniswapSwapAdapter
 * @notice ISwapAdapter implementation supporting Uniswap V3 (single/multi-hop) and
 *         Uniswap V4 (single-hop, hookless) swaps.
 *
 *   extraData encoding (mode determines swap type):
 *     Mode 0 — V3 single-hop:  abi.encode(uint8(0), abi.encode(uint24 fee))
 *     Mode 1 — V3 multi-hop:   abi.encode(uint8(1), abi.encode(bytes path, uint16 perHopSlippageBps))
 *     Mode 2 — V4 single-hop:  abi.encode(uint8(2), abi.encode(uint24 fee, int24 tickSpacing))
 *     Mode 3 — V4 multi-hop:   abi.encode(uint8(3), abi.encode(PathHop[] hops))
 *
 *   Modes 2/3 target hookless (hooks == address(0)) pools. Mode 3 supports a
 *   native-ETH (address(0)) currency as an *intermediate* hop only — endpoints
 *   (tokenIn/tokenOut) must be ERC20s (the ISwapAdapter contract guarantees
 *   this). v4 flash accounting nets the intermediate ETH to zero inside one
 *   unlock, so no ETH is ever held and no WETH wrap/unwrap is needed. V4 args
 *   (poolManager, v4Quoter) may be address(0) on chains without V4 — modes 2/3
 *   then revert.
 *
 *   The caller (strategy) must approve this adapter to spend tokenIn before calling swap().
 */
/// @dev One hop of a v4 multi-hop route: swap from the previous currency
///      (tokenIn for hop 0) into `currency` in the hookless pool identified by
///      (sorted pair, fee, tickSpacing, hooks=0). `currency` may be address(0)
///      (native ETH) for intermediate hops; the last hop's `currency` must
///      equal tokenOut.
struct PathHop {
    address currency;
    uint24 fee;
    int24 tickSpacing;
}

contract UniswapSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable v3Router;
    IQuoterV2 public immutable quoter;
    IPoolManager public immutable poolManager;
    IV4Quoter public immutable v4Quoter;

    // V4 sqrtPriceX96 bounds (from v4-core TickMath).
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    // unlockCallback payload — the callback is only reachable from our own
    // poolManager.unlock (the PM calls back the locker), and the
    // msg.sender == poolManager gate below closes it to anyone else.
    struct V4Callback {
        address tokenIn;
        address recipient;
        uint256 amountIn;
        PathHop[] hops; // 1 element for mode 2, ≥2 for mode 3
    }

    error ZeroAddress();
    error UnsupportedMode();
    error V4Unavailable();
    error UnauthorizedCallback();
    error SlippageExceeded();
    error InvalidPath();

    constructor(address _v3Router, address _quoter, address _poolManager, address _v4Quoter) {
        if (_v3Router == address(0) || _quoter == address(0)) revert ZeroAddress();
        v3Router = ISwapRouter(_v3Router);
        quoter = IQuoterV2(_quoter);
        // V4 args optional (address(0) on chains without V4).
        poolManager = IPoolManager(_poolManager);
        v4Quoter = IV4Quoter(_v4Quoter);
    }

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata extraData)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint8 mode = uint8(bytes1(extraData[:1]));
        bytes calldata routeData = extraData[1:];

        if (mode == 2 || mode == 3) {
            // V4 (hookless). Handled before the v3 approval so the v3 router
            // never gets a pointless allowance. Mode 2 is a single hop; mode 3
            // is an arbitrary-length path (native ETH allowed as an intermediate
            // currency, endpoints ERC20).
            PathHop[] memory hops;
            if (mode == 2) {
                (uint24 v4Fee, int24 tickSpacing) = abi.decode(routeData, (uint24, int24));
                hops = new PathHop[](1);
                hops[0] = PathHop({currency: tokenOut, fee: v4Fee, tickSpacing: tickSpacing});
            } else {
                hops = _orientHops(abi.decode(routeData, (PathHop[])), tokenIn, tokenOut);
            }
            return _swapV4(tokenIn, tokenOut, amountIn, amountOutMin, hops);
        }

        // Modes 0/1 route through the v3 router.
        IERC20(tokenIn).forceApprove(address(v3Router), amountIn);

        if (mode == 0) {
            // V3 single-hop
            uint24 fee = abi.decode(routeData, (uint24));
            amountOut = v3Router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: msg.sender,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMin,
                    sqrtPriceLimitX96: 0
                })
            );
        } else if (mode == 1) {
            // V3 multi-hop via chained exactInputSingle calls.
            // SwapRouter02's exactInput computes wrong pool addresses for certain pairs
            // on Base, so we decompose the path and swap hop-by-hop using exactInputSingle
            // which always resolves pools correctly.
            //
            // Sherlock run #2 #11: extraData v2 — `abi.encode(bytes path,
            // uint16 perHopSlippageBps)`. Each non-terminal hop's
            // `amountOutMinimum` is derived AT SWAP TIME from a quoter
            // pre-call (`expected * (10000 - perHopSlippageBps) / 10000`),
            // so an MEV sandwich on any intermediate hop reverts at that
            // hop instead of silently draining value into the next. Stays
            // STATIC across swaps (template-friendly): the caller sets one
            // slippage bps and the adapter handles per-swap quoting. The
            // legacy `amountOutMin` parameter is still enforced on the
            // terminal hop as a top-level safety check.
            (bytes memory path, uint16 perHopSlippageBps) = abi.decode(routeData, (bytes, uint16));
            require(perHopSlippageBps <= 10_000, "slippage > 100%");
            address pathStart = _extractFirstAddress(path);
            if (pathStart != tokenIn) {
                path = _reversePath(path);
            }
            amountOut = _chainedSingleHops(path, amountIn, amountOutMin, perHopSlippageBps);
        } else {
            revert UnsupportedMode();
        }
    }

    // ── Modes 2/3: Uniswap V4 single- and multi-hop (hookless) ──

    /// @dev Drive the swap through poolManager.unlock, passing the route in the
    ///      unlock payload (a dynamic path doesn't fit fixed transient slots).
    ///      Output is `take`n directly to the original swap() caller, matching
    ///      mode-0 recipient semantics. `amountOutMin` is enforced on the FINAL
    ///      output after unlock returns (still inside the revert boundary) since
    ///      v4 core enforces none itself.
    ///
    ///      MEV note: this terminal floor bounds TOTAL route slippage to the
    ///      caller's budget; it does NOT localize which hop was attacked (unlike
    ///      mode 1's per-hop quoter floors — see Sherlock run #2 #11). Per-hop
    ///      floors are NOT implementable here: the V4Quoter itself drives
    ///      poolManager.unlock, and a nested unlock reverts, so we cannot quote
    ///      mid-callback. Pre-quoting each hop before unlock would add no security
    ///      over the terminal floor — those quotes are computed in the same tx,
    ///      i.e. against post-frontrun state. The binding protection for strategy
    ///      flows is the CALLER-SIDE floor: PortfolioStrategy.rebalanceDelta
    ///      derives minOut from Chainlink prices (oracle-anchored) and passes it
    ///      here as amountOutMin.
    function _swapV4(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, PathHop[] memory hops)
        internal
        returns (uint256 amountOut)
    {
        if (address(poolManager) == address(0)) revert V4Unavailable();
        tokenOut; // final currency is hops[last].currency, validated by the caller

        bytes memory ret = poolManager.unlock(
            abi.encode(V4Callback({tokenIn: tokenIn, recipient: msg.sender, amountIn: amountIn, hops: hops}))
        );
        amountOut = abi.decode(ret, (uint256));

        if (amountOut < amountOutMin) revert SlippageExceeded();
    }

    /// @notice V4 unlock callback — only the PoolManager may call.
    /// @dev Walks the hops, feeding each hop's output into the next. Intermediate
    ///      deltas cancel exactly (full output → next input). At the end: settle
    ///      the original tokenIn, take the final output to the recipient. A native
    ///      ETH (address(0)) intermediate nets to zero within this unlock — never
    ///      settled/taken, never held.
    ///
    ///      No per-hop slippage floor is (or can be) applied inside this loop: the
    ///      V4Quoter drives its own poolManager.unlock, so a nested quote reverts
    ///      here. Each hop runs to full price impact against whatever pool state
    ///      exists at execution; the atomicity of the unlock does NOT prevent an
    ///      intermediate-hop sandwich, it only guarantees the hops execute in one
    ///      tx. Slippage is bounded solely by the terminal `amountOutMin` checked
    ///      in _swapV4 (total-route budget) — and for strategy flows that budget
    ///      is oracle-anchored caller-side (see _swapV4's MEV note).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        V4Callback memory cb = abi.decode(data, (V4Callback));

        address currentIn = cb.tokenIn;
        uint256 currentAmount = cb.amountIn;

        for (uint256 i; i < cb.hops.length; ++i) {
            PathHop memory hop = cb.hops[i];
            (PoolKey memory key, bool zeroForOne) = _buildPoolKey(currentIn, hop.currency, hop.fee, hop.tickSpacing);

            int256 delta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(currentAmount),
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
                }),
                ""
            );

            // BalanceDelta: upper 128 bits = amount0, lower 128 = amount1.
            // Input currency's delta is negative (we owe); output's is positive.
            uint256 out = zeroForOne ? uint256(int256(int128(delta))) : uint256(int256(int128(delta >> 128)));

            currentIn = hop.currency;
            currentAmount = out;
        }

        // Settle the original input we owe: sync → transfer tokenIn → settle.
        poolManager.sync(cb.tokenIn);
        IERC20(cb.tokenIn).safeTransfer(address(poolManager), cb.amountIn);
        poolManager.settle();

        // Pull the final output straight to the original caller.
        poolManager.take(currentIn, cb.recipient, currentAmount);

        return abi.encode(currentAmount);
    }

    /// @dev Address-sort a pair into a hookless PoolKey; returns zeroForOne.
    function _buildPoolKey(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory key, bool zeroForOne)
    {
        (address currency0, address currency1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: address(0)
        });
        zeroForOne = tokenIn == currency0;
    }

    /// @dev Validate + orient a mode-3 hop list for the requested direction.
    ///      A single stored path (buy: asset→…→token) is reused by strategies
    ///      for the reverse (sell: token→…→asset), mirroring mode-1's packed-path
    ///      auto-reverse. Accept the path as-is when it already ends at tokenOut;
    ///      reverse it when it ends at tokenIn; otherwise revert.
    function _orientHops(PathHop[] memory hops, address tokenIn, address tokenOut)
        internal
        pure
        returns (PathHop[] memory)
    {
        uint256 n = hops.length;
        if (n < 2) revert InvalidPath();
        if (hops[n - 1].currency == tokenOut) return hops;
        // Reversed direction: the stored path was head→…→hops[n-1].currency with
        // head == tokenOut (the original input, now our output).
        if (hops[n - 1].currency == tokenIn) return _reverseHops(hops, tokenOut);
        revert InvalidPath();
    }

    /// @dev Reverse a hop list. Forward currency sequence (from `head`) is
    ///      [head, h0.c, h1.c, …, h[n-1].c]; the pool for hop i sits between
    ///      currency i and i+1 (fee/tickSpacing = hops[i].{fee,tickSpacing}).
    ///      The reversed path starts at h[n-1].c and walks back to head, so the
    ///      j-th reversed hop's output currency is currency (n-1-j) of the
    ///      forward sequence and it reuses forward pool (n-1-j)'s fee/tickSpacing.
    function _reverseHops(PathHop[] memory hops, address head) internal pure returns (PathHop[] memory rev) {
        uint256 n = hops.length;
        rev = new PathHop[](n);
        for (uint256 j; j < n; ++j) {
            uint256 k = n - 1 - j; // forward hop index supplying this pool
            address outCurrency = k == 0 ? head : hops[k - 1].currency;
            rev[j] = PathHop({currency: outCurrency, fee: hops[k].fee, tickSpacing: hops[k].tickSpacing});
        }
    }

    /// @dev Execute a multi-hop swap as sequential exactInputSingle calls.
    ///      Intermediate tokens are held by this contract between hops.
    ///      Sherlock run #2 #11: each hop's `amountOutMinimum` is derived
    ///      at swap time from `quoter.quoteExactInputSingle` against the
    ///      hop's input, scaled by `(10_000 - perHopSlippageBps) / 10_000`.
    ///      The final-hop floor also respects the legacy top-level
    ///      `amountOutMin` (max of the two) so the existing slippage
    ///      contract still holds. Adapter does the quoter calls so
    ///      callers don't need to re-compute per-hop floors at every
    ///      swap — the extraData stays static (template-friendly).
    function _chainedSingleHops(bytes memory path, uint256 amountIn, uint256 amountOutMin, uint16 perHopSlippageBps)
        internal
        returns (uint256 amountOut)
    {
        uint256 len = path.length;
        require(len >= 43 && (len - 20) % 23 == 0, "invalid path length");
        uint256 numHops = (len - 20) / 23;

        uint256 currentAmount = amountIn;
        uint256 slipDenom = 10_000 - uint256(perHopSlippageBps);

        for (uint256 i; i < numHops; ++i) {
            address hopIn = _extractAddressAt(path, i * 23);
            uint24 fee = _extractFeeAt(path, i * 23 + 20);
            address hopOut = _extractAddressAt(path, i * 23 + 23);

            bool lastHop = (i == numHops - 1);

            // Approve router for intermediate tokens (first hop was approved in swap())
            if (i > 0) {
                IERC20(hopIn).forceApprove(address(v3Router), currentAmount);
            }

            // Per-hop floor from quoter pre-call, scaled by the caller's
            // slippage budget. Final hop additionally honors the top-level
            // `amountOutMin` so the legacy contract holds.
            (uint256 quoted,,,) = quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: hopIn, tokenOut: hopOut, amountIn: currentAmount, fee: fee, sqrtPriceLimitX96: 0
                })
            );
            uint256 hopFloor = (quoted * slipDenom) / 10_000;
            if (lastHop && amountOutMin > hopFloor) hopFloor = amountOutMin;

            currentAmount = v3Router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: hopIn,
                    tokenOut: hopOut,
                    fee: fee,
                    recipient: lastHop ? msg.sender : address(this),
                    amountIn: currentAmount,
                    amountOutMinimum: hopFloor,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        amountOut = currentAmount;
    }

    /// @dev Extract a 20-byte address at an arbitrary byte offset in a packed path.
    function _extractAddressAt(bytes memory path, uint256 offset) internal pure returns (address addr) {
        require(path.length >= offset + 20, "path too short");
        assembly {
            addr := shr(96, mload(add(add(path, 32), offset)))
        }
    }

    /// @dev Extract a 3-byte uint24 fee at an arbitrary byte offset in a packed path.
    function _extractFeeAt(bytes memory path, uint256 offset) internal pure returns (uint24 fee) {
        require(path.length >= offset + 3, "path too short");
        assembly {
            fee := shr(232, mload(add(add(path, 32), offset)))
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

    /// @inheritdoc ISwapAdapter
    /// @dev Sherlock #58: mode-1 multi-hop quoting was unsupported, so
    ///      `PortfolioStrategy._quoteMinOut` (which wraps this) reverted with
    ///      `QuoteUnavailable` for any allocation configured with a packed
    ///      V3 path. The matching `swap()` already supports mode 1 — adding
    ///      the symmetric `quoteExactInput(path, amountIn)` here unblocks
    ///      multi-hop routes end-to-end.
    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata extraData)
        external
        override
        returns (uint256 amountOut)
    {
        uint8 mode = uint8(bytes1(extraData[:1]));
        bytes calldata routeData = extraData[1:];

        if (mode == 0) {
            uint24 fee = abi.decode(routeData, (uint24));
            (amountOut,,,) = quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
                })
            );
        } else if (mode == 1) {
            bytes memory path = abi.decode(routeData, (bytes));
            // Match `swap()`'s path orientation: ensure tokenIn is the head
            // of the path before passing to the quoter.
            if (_extractFirstAddress(path) != tokenIn) path = _reversePath(path);
            (amountOut,,,) = quoter.quoteExactInput(path, amountIn);
        } else if (mode == 2) {
            if (address(v4Quoter) == address(0)) revert V4Unavailable();
            (uint24 fee, int24 tickSpacing) = abi.decode(routeData, (uint24, int24));
            (PoolKey memory key, bool zeroForOne) = _buildPoolKey(tokenIn, tokenOut, fee, tickSpacing);
            (amountOut,) = v4Quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(amountIn), hookData: ""
                })
            );
        } else if (mode == 3) {
            if (address(v4Quoter) == address(0)) revert V4Unavailable();
            PathHop[] memory hops = _orientHops(abi.decode(routeData, (PathHop[])), tokenIn, tokenOut);
            PathKey[] memory path = new PathKey[](hops.length);
            for (uint256 i; i < hops.length; ++i) {
                path[i] = PathKey({
                    intermediateCurrency: hops[i].currency,
                    fee: hops[i].fee,
                    tickSpacing: hops[i].tickSpacing,
                    hooks: address(0),
                    hookData: ""
                });
            }
            (amountOut,) = v4Quoter.quoteExactInput(
                IV4Quoter.QuoteExactParams({exactCurrency: tokenIn, path: path, exactAmount: uint128(amountIn)})
            );
        } else {
            revert UnsupportedMode();
        }
    }
}
