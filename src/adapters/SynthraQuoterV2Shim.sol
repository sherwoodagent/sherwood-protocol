// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Synthra's on-chain quoter is a bit-compatible Uniswap QuoterV2:
///         struct-based single-hop + tuple-returning path quote. Verified on the
///         live Robinhood testnet (chain 46630) quoter
///         0x231606c321A99DE81e28fE48B07a93F1ba49e713 — the struct selector
///         0xc6a5026a returns normally; the positional V1 selector 0xf7729d43 is
///         not implemented (reverts with empty data).
interface ISynthraQuoterV2 {
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

    function quoteExactInput(bytes calldata path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

/// @title  SynthraQuoterV2Shim
/// @notice Thin adapter exposing the exact Uniswap QuoterV2 surface that
///         `UniswapSwapAdapter` consumes on top of Synthra's quoter, so the SAME
///         `UniswapSwapAdapter` deploys against Synthra on Robinhood testnet.
///
///         Synthra's quoter is already a struct-based QuoterV2 (see interface
///         note), so the single-hop call forwards the struct through unchanged
///         and the path call passes through verbatim. The shim additionally
///         defaults a zero `sqrtPriceLimitX96` to the direction's TickMath bound
///         (QuoterV2 semantics) as defence-in-depth — a spec-compliant QuoterV2
///         already does this internally, so it is behaviour-preserving.
contract SynthraQuoterV2Shim {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    ISynthraQuoterV2 public immutable synthraQuoter;

    // TickMath sqrt-price bounds. QuoterV2 treats a zero `sqrtPriceLimitX96` as
    // "no limit" (`zeroForOne ? MIN + 1 : MAX - 1`); we make that explicit.
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    error ZeroAddress();

    constructor(address _synthraQuoter) {
        if (_synthraQuoter == address(0)) revert ZeroAddress();
        synthraQuoter = ISynthraQuoterV2(_synthraQuoter);
    }

    /// @dev Forward the QuoterV2 struct to Synthra's struct-based quoter. A zero
    ///      `sqrtPriceLimitX96` is defaulted to the direction's TickMath bound; a
    ///      caller-supplied nonzero limit passes through untouched.
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        uint160 limit = params.sqrtPriceLimitX96;
        if (limit == 0) {
            limit = params.tokenIn < params.tokenOut ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;
        }
        return synthraQuoter.quoteExactInputSingle(
            ISynthraQuoterV2.QuoteExactInputSingleParams({
                tokenIn: params.tokenIn,
                tokenOut: params.tokenOut,
                amountIn: params.amountIn,
                fee: params.fee,
                sqrtPriceLimitX96: limit
            })
        );
    }

    /// @dev Synthra's `quoteExactInput` is tuple-shaped identically to QuoterV2 —
    ///      pass through.
    function quoteExactInput(bytes calldata path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        return synthraQuoter.quoteExactInput(path, amountIn);
    }
}
