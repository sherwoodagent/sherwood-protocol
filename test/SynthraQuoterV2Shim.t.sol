// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SynthraQuoterV2Shim, ISynthraQuoterV2} from "../src/adapters/SynthraQuoterV2Shim.sol";

/// @title SynthraQuoterV2Shim unit tests
/// @notice Drives the shim against a mock struct-based QuoterV2 (which is what
///         Synthra actually exposes), asserting it (a) rejects a zero quoter,
///         (b) forwards the single-hop struct and bubbles the full QuoterV2
///         tuple, (c) defaults a zero `sqrtPriceLimitX96` per direction while a
///         nonzero limit passes through untouched, and (d) passes the multi-hop
///         path/tuple straight through.
contract SynthraQuoterV2ShimTest is Test {
    // TickMath bounds mirrored from the shim.
    uint160 constant MIN_SQRT_PRICE = 4295128739;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    SynthraQuoterV2Shim shim;
    MockSynthraQuoterV2 v2;

    address tokenIn = address(1);
    address tokenOut = address(2);

    function setUp() public {
        v2 = new MockSynthraQuoterV2();
        shim = new SynthraQuoterV2Shim(address(v2));
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(SynthraQuoterV2Shim.ZeroAddress.selector);
        new SynthraQuoterV2Shim(address(0));
    }

    function test_constructor_pinsQuoter() public view {
        assertEq(address(shim.synthraQuoter()), address(v2));
    }

    function test_quoteExactInputSingle_forwardsStructAndBubblesTuple() public {
        v2.setSingleReturn(1_234e18, 111, 5, 222);

        (uint256 amountOut, uint160 sqrtAfter, uint32 ticks, uint256 gasEst) = shim.quoteExactInputSingle(
            SynthraQuoterV2Shim.QuoteExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amountIn: 1_000e18, fee: 3000, sqrtPriceLimitX96: 42
            })
        );

        // Full QuoterV2 tuple bubbles through (no zero-fill).
        assertEq(amountOut, 1_234e18, "amountOut bubbled");
        assertEq(sqrtAfter, 111, "sqrtPriceX96After bubbled");
        assertEq(ticks, 5, "initializedTicksCrossed bubbled");
        assertEq(gasEst, 222, "gasEstimate bubbled");

        // The V2 quoter observed the forwarded struct fields.
        MockSynthraQuoterV2.LastSingle memory q = v2.lastSingle();
        assertEq(q.tokenIn, tokenIn);
        assertEq(q.tokenOut, tokenOut);
        assertEq(q.fee, 3000, "fee mapped");
        assertEq(q.amountIn, 1_000e18, "amountIn mapped");
        assertEq(q.sqrtPriceLimitX96, 42, "nonzero limit forwarded");
    }

    function test_quoteExactInputSingle_zeroLimitDefaultsToMinWhenTokenInLower() public {
        v2.setSingleReturn(500e18, 0, 0, 0);

        (uint256 amountOut,,,) = shim.quoteExactInputSingle(
            SynthraQuoterV2Shim.QuoteExactInputSingleParams({
                tokenIn: address(1), tokenOut: address(2), amountIn: 1e18, fee: 3000, sqrtPriceLimitX96: 0
            })
        );

        assertEq(amountOut, 500e18, "quote returns despite zero input limit");
        // tokenIn < tokenOut (zeroForOne) → MIN_SQRT_PRICE + 1.
        assertEq(v2.lastSingle().sqrtPriceLimitX96, MIN_SQRT_PRICE + 1, "defaulted to MIN + 1");
    }

    function test_quoteExactInputSingle_zeroLimitDefaultsToMaxWhenTokenInHigher() public {
        v2.setSingleReturn(500e18, 0, 0, 0);

        shim.quoteExactInputSingle(
            SynthraQuoterV2Shim.QuoteExactInputSingleParams({
                tokenIn: address(2), tokenOut: address(1), amountIn: 1e18, fee: 3000, sqrtPriceLimitX96: 0
            })
        );

        // tokenIn > tokenOut (!zeroForOne) → MAX_SQRT_PRICE - 1.
        assertEq(v2.lastSingle().sqrtPriceLimitX96, MAX_SQRT_PRICE - 1, "defaulted to MAX - 1");
    }

    function test_quoteExactInputSingle_nonzeroLimitPassesThrough() public {
        v2.setSingleReturn(7e18, 0, 0, 0);

        shim.quoteExactInputSingle(
            SynthraQuoterV2Shim.QuoteExactInputSingleParams({
                tokenIn: address(1), tokenOut: address(2), amountIn: 1e18, fee: 500, sqrtPriceLimitX96: 123456
            })
        );

        assertEq(v2.lastSingle().sqrtPriceLimitX96, 123456, "caller limit forwarded untouched");
    }

    function test_quoteExactInput_passesThrough() public {
        uint160[] memory sqrts = new uint160[](2);
        sqrts[0] = 7;
        sqrts[1] = 9;
        uint32[] memory ticks = new uint32[](2);
        ticks[0] = 1;
        ticks[1] = 2;
        v2.setMultiReturn(5_555e18, sqrts, ticks, 99);

        bytes memory path = abi.encodePacked(tokenIn, uint24(500), tokenOut);
        (uint256 amountOut, uint160[] memory outSqrts, uint32[] memory outTicks, uint256 gasEst) =
            shim.quoteExactInput(path, 2_000e18);

        assertEq(amountOut, 5_555e18);
        assertEq(outSqrts.length, 2);
        assertEq(outSqrts[1], 9);
        assertEq(outTicks[0], 1);
        assertEq(gasEst, 99);
        assertEq(v2.lastMultiPath(), path, "path forwarded verbatim");
        assertEq(v2.lastMultiAmountIn(), 2_000e18);
    }
}

/// @notice Mock struct-based Uniswap QuoterV2 (Synthra's actual quoter shape).
/// @dev Reverts on a zero `sqrtPriceLimitX96` — STRICTER than the real Synthra
///      QuoterV2 (which defaults zero internally). This guards that the shim
///      never forwards a raw zero limit: if the underlying quoter ever rejected
///      it, the shim's own defaulting must have already replaced it.
contract MockSynthraQuoterV2 {
    struct LastSingle {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    LastSingle private _lastSingle;
    uint256 private _singleAmountOut;
    uint160 private _singleSqrtAfter;
    uint32 private _singleTicks;
    uint256 private _singleGas;

    bytes private _lastMultiPath;
    uint256 private _lastMultiAmountIn;
    uint256 private _multiReturn;
    uint160[] private _multiSqrts;
    uint32[] private _multiTicks;
    uint256 private _multiGas;

    function setSingleReturn(uint256 amountOut, uint160 sqrtAfter, uint32 ticks, uint256 gasEst) external {
        _singleAmountOut = amountOut;
        _singleSqrtAfter = sqrtAfter;
        _singleTicks = ticks;
        _singleGas = gasEst;
    }

    function setMultiReturn(uint256 r, uint160[] calldata sqrts, uint32[] calldata ticks, uint256 gasEst) external {
        _multiReturn = r;
        _multiSqrts = sqrts;
        _multiTicks = ticks;
        _multiGas = gasEst;
    }

    function lastSingle() external view returns (LastSingle memory) {
        return _lastSingle;
    }

    function lastMultiPath() external view returns (bytes memory) {
        return _lastMultiPath;
    }

    function lastMultiAmountIn() external view returns (uint256) {
        return _lastMultiAmountIn;
    }

    function quoteExactInputSingle(ISynthraQuoterV2.QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        require(params.sqrtPriceLimitX96 != 0, "SPL");
        _lastSingle = LastSingle({
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            fee: params.fee,
            amountIn: params.amountIn,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });
        return (_singleAmountOut, _singleSqrtAfter, _singleTicks, _singleGas);
    }

    function quoteExactInput(bytes calldata path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        _lastMultiPath = path;
        _lastMultiAmountIn = amountIn;
        return (_multiReturn, _multiSqrts, _multiTicks, _multiGas);
    }
}
