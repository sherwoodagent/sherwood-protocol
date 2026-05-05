// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SynthraSwapAdapter} from "../src/adapters/SynthraSwapAdapter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title SynthraSwapAdapter unit tests
/// @notice The Synthra mainnet contracts live on Robinhood Chain; this suite
///         drives the adapter against mocked router/quoter implementations to
///         verify call construction, ERC-20 plumbing (pull / approve /
///         recipient routing), single-hop vs multi-hop dispatch by extraData
///         length, and zero-address rejection.
contract SynthraSwapAdapterTest is Test {
    SynthraSwapAdapter adapter;
    MockSynthraRouter router;
    MockSynthraQuoter quoter;
    ERC20Mock tokenIn;
    ERC20Mock tokenOut;

    address user = makeAddr("user");

    function setUp() public {
        router = new MockSynthraRouter();
        quoter = new MockSynthraQuoter();
        tokenIn = new ERC20Mock("In", "IN", 18);
        tokenOut = new ERC20Mock("Out", "OUT", 18);
        adapter = new SynthraSwapAdapter(address(router), address(quoter));

        // Seed the router with output-side liquidity so it can pay out swaps.
        tokenOut.mint(address(router), 1_000_000e18);
        // Fund the user with input-side and pre-approve the adapter.
        tokenIn.mint(user, 100_000e18);
        vm.prank(user);
        tokenIn.approve(address(adapter), type(uint256).max);
    }

    // ──────────────────────── constructor ────────────────────────

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(SynthraSwapAdapter.ZeroAddress.selector);
        new SynthraSwapAdapter(address(0), address(quoter));
        vm.expectRevert(SynthraSwapAdapter.ZeroAddress.selector);
        new SynthraSwapAdapter(address(router), address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(adapter.router()), address(router));
        assertEq(address(adapter.quoter()), address(quoter));
    }

    // ──────────────────────── swap — single-hop (extraData == 32 bytes) ────────────────────────

    function test_swap_singleHop_pullsApprovesAndRoutesToCaller() public {
        uint24 fee = 3000;
        bytes memory extraData = abi.encode(fee);
        router.setReturn(2_000e18);

        vm.prank(user);
        uint256 amountOut = adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 1_900e18, extraData);

        assertEq(amountOut, 2_000e18, "amountOut bubbled from router");
        assertEq(tokenIn.balanceOf(user), 99_000e18, "input pulled from caller");
        assertEq(tokenOut.balanceOf(user), 2_000e18, "output routed to caller (msg.sender)");
        // Adapter holds nothing post-swap.
        assertEq(tokenIn.balanceOf(address(adapter)), 0, "no input dust on adapter");
        assertEq(tokenOut.balanceOf(address(adapter)), 0, "no output dust on adapter");

        // Router observed the right params.
        MockSynthraRouter.LastSingleParams memory p = router.lastSingleParams();
        assertEq(p.tokenIn, address(tokenIn));
        assertEq(p.tokenOut, address(tokenOut));
        assertEq(p.fee, fee);
        assertEq(p.recipient, user, "recipient is the strategy that called swap");
        assertEq(p.amountIn, 1_000e18);
        assertEq(p.amountOutMinimum, 1_900e18);
        assertEq(p.sqrtPriceLimitX96, 0);
    }

    function test_swap_singleHop_forceApprovesEvenWithLeftoverAllowance() public {
        // Pre-set a stale allowance from adapter to router. forceApprove must
        // reset and apply the new amount cleanly.
        vm.prank(address(adapter));
        tokenIn.approve(address(router), 12345);

        uint24 fee = 500;
        router.setReturn(1e18);
        vm.prank(user);
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 0, abi.encode(fee));

        // The router consumed the input.
        assertEq(tokenIn.balanceOf(address(router)), 1_000e18);
    }

    function test_swap_singleHop_routerRevertBubbles() public {
        router.setShouldRevert(true);
        vm.prank(user);
        vm.expectRevert(bytes("router boom"));
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 0, abi.encode(uint24(3000)));
    }

    // ──────────────────────── swap — multi-hop (extraData != 32 bytes) ────────────────────────

    function test_swap_multiHop_dispatchesToExactInput() public {
        // Path: tokenIn → tokenMid → tokenOut, two pools at fee=500 and fee=3000.
        // Encoded as packed bytes: tokenIn(20) | fee(3) | tokenMid(20) | fee(3) | tokenOut(20).
        ERC20Mock tokenMid = new ERC20Mock("Mid", "MID", 18);
        bytes memory path =
            abi.encodePacked(address(tokenIn), uint24(500), address(tokenMid), uint24(3000), address(tokenOut));
        // extraData is (fee, path) — total length > 32 so adapter takes multi-hop branch.
        bytes memory extraData = abi.encode(uint24(500), path);
        router.setReturn(1_500e18);

        vm.prank(user);
        uint256 amountOut = adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 1_400e18, extraData);

        assertEq(amountOut, 1_500e18);
        assertEq(tokenOut.balanceOf(user), 1_500e18, "output routed to caller");
        // Router observed multi-hop params, not single-hop.
        assertEq(router.singleHopCount(), 0, "single-hop path not taken");
        assertEq(router.multiHopCount(), 1, "multi-hop path taken");

        MockSynthraRouter.LastMultiParams memory p = router.lastMultiParams();
        assertEq(p.recipient, user);
        assertEq(p.amountIn, 1_000e18);
        assertEq(p.amountOutMinimum, 1_400e18);
        assertEq(p.path, path);
    }

    // ──────────────────────── quote ────────────────────────

    function test_quote_passesArgsToQuoter() public {
        quoter.setReturn(987e18);
        bytes memory extraData = abi.encode(uint24(3000));

        uint256 out = adapter.quote(address(tokenIn), address(tokenOut), 1_000e18, extraData);

        assertEq(out, 987e18);
        MockSynthraQuoter.LastQuote memory q = quoter.lastQuote();
        assertEq(q.tokenIn, address(tokenIn));
        assertEq(q.tokenOut, address(tokenOut));
        assertEq(q.fee, 3000);
        assertEq(q.amountIn, 1_000e18);
        assertEq(q.sqrtPriceLimitX96, 0);
    }
}

/// @notice Mock Synthra Router. Records the last call parameters and pays out
///         `mockReturn` of `tokenOut` to `recipient`. Pulls `amountIn` of
///         `tokenIn` from msg.sender (the adapter) on each call.
contract MockSynthraRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct LastSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct LastMultiParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    LastSingleParams private _lastSingle;
    LastMultiParams private _lastMulti;
    uint256 public singleHopCount;
    uint256 public multiHopCount;
    uint256 public mockReturn;
    bool public shouldRevert;

    function setReturn(uint256 r) external {
        mockReturn = r;
    }

    function setShouldRevert(bool x) external {
        shouldRevert = x;
    }

    function lastSingleParams() external view returns (LastSingleParams memory) {
        return _lastSingle;
    }

    function lastMultiParams() external view returns (LastMultiParams memory) {
        return _lastMulti;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256 amountOut) {
        if (shouldRevert) revert("router boom");
        singleHopCount++;
        _lastSingle = LastSingleParams({
            tokenIn: p.tokenIn,
            tokenOut: p.tokenOut,
            fee: p.fee,
            recipient: p.recipient,
            amountIn: p.amountIn,
            amountOutMinimum: p.amountOutMinimum,
            sqrtPriceLimitX96: p.sqrtPriceLimitX96
        });
        // Pull input from caller (the adapter).
        (bool pulled,) = p.tokenIn
            .call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), p.amountIn)
            );
        require(pulled, "router pull failed");
        // Pay output to recipient.
        (bool paid,) = p.tokenOut.call(abi.encodeWithSignature("transfer(address,uint256)", p.recipient, mockReturn));
        require(paid, "router pay failed");
        return mockReturn;
    }

    function exactInput(ExactInputParams calldata p) external returns (uint256 amountOut) {
        if (shouldRevert) revert("router boom");
        multiHopCount++;
        _lastMulti = LastMultiParams({
            path: p.path, recipient: p.recipient, amountIn: p.amountIn, amountOutMinimum: p.amountOutMinimum
        });
        // Decode tokenIn from first 20 bytes of path; pull from caller.
        address tokenIn_;
        bytes memory path = p.path;
        assembly {
            tokenIn_ := shr(96, mload(add(path, 32)))
        }
        // tokenOut is the last 20 bytes of path.
        address tokenOut_;
        uint256 len = path.length;
        assembly {
            tokenOut_ := shr(96, mload(add(add(path, 32), sub(len, 20))))
        }
        (bool pulled,) = tokenIn_.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), p.amountIn)
        );
        require(pulled, "router pull failed");
        (bool paid,) = tokenOut_.call(abi.encodeWithSignature("transfer(address,uint256)", p.recipient, mockReturn));
        require(paid, "router pay failed");
        return mockReturn;
    }
}

contract MockSynthraQuoter {
    struct LastQuote {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    LastQuote private _lastQuote;
    uint256 public mockReturn;

    function setReturn(uint256 r) external {
        mockReturn = r;
    }

    function lastQuote() external view returns (LastQuote memory) {
        return _lastQuote;
    }

    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut) {
        _lastQuote = LastQuote({
            tokenIn: tokenIn, tokenOut: tokenOut, fee: fee, amountIn: amountIn, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        return mockReturn;
    }
}
