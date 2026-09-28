// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniswapSwapAdapter, PathHop} from "../src/adapters/UniswapSwapAdapter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract UniswapAdapterPathTest is Test {
    UniswapSwapAdapterHarness adapter;

    function setUp() public {
        adapter = new UniswapSwapAdapterHarness(address(1), address(2), address(0), address(0));
    }

    // ── Mode 2 (V4) guards — the harness has address(0) poolManager/v4Quoter ──

    function test_mode2_swap_reverts_whenPoolManagerUnset() public {
        ERC20Mock tokenIn = new ERC20Mock("In", "IN", 18);
        address user = makeAddr("user");
        tokenIn.mint(user, 1e18);

        bytes memory extraData = abi.encodePacked(uint8(2), abi.encode(uint24(50_000), int24(1000)));

        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1e18);
        vm.expectRevert(UniswapSwapAdapter.V4Unavailable.selector);
        adapter.swap(address(tokenIn), makeAddr("out"), 1e18, 0, extraData);
        vm.stopPrank();
    }

    function test_mode2_quote_reverts_whenV4QuoterUnset() public {
        bytes memory extraData = abi.encodePacked(uint8(2), abi.encode(uint24(50_000), int24(1000)));
        vm.expectRevert(UniswapSwapAdapter.V4Unavailable.selector);
        adapter.quote(makeAddr("in"), makeAddr("out"), 1e18, extraData);
    }

    function test_unlockCallback_reverts_whenCallerNotPoolManager() public {
        // poolManager is address(0) on the harness → any external caller is
        // unauthorized (and a real PM would be the only accepted caller).
        vm.expectRevert(UniswapSwapAdapter.UnauthorizedCallback.selector);
        adapter.unlockCallback("");
    }

    function test_unsupportedMode_swap_reverts() public {
        ERC20Mock tokenIn = new ERC20Mock("In", "IN", 18);
        address user = makeAddr("user");
        tokenIn.mint(user, 1e18);

        bytes memory extraData = abi.encodePacked(uint8(9), abi.encode(uint24(500)));

        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1e18);
        vm.expectRevert(UniswapSwapAdapter.UnsupportedMode.selector);
        adapter.swap(address(tokenIn), makeAddr("out"), 1e18, 0, extraData);
        vm.stopPrank();
    }

    /// @notice The retired V3 multi-hop mode 1 is no longer routable.
    function test_mode1_swap_reverts_unsupported() public {
        ERC20Mock tokenIn = new ERC20Mock("In", "IN", 18);
        address user = makeAddr("user");
        tokenIn.mint(user, 1e18);
        bytes memory path = abi.encodePacked(address(tokenIn), uint24(500), makeAddr("out"));
        bytes memory extraData = abi.encodePacked(uint8(1), abi.encode(path, uint16(200)));

        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1e18);
        vm.expectRevert(UniswapSwapAdapter.UnsupportedMode.selector);
        adapter.swap(address(tokenIn), makeAddr("out"), 1e18, 0, extraData);
        vm.stopPrank();
    }

    /// @notice The retired V3 multi-hop mode 1 is no longer quotable.
    function test_mode1_quote_reverts_unsupported() public {
        bytes memory path = abi.encodePacked(makeAddr("in"), uint24(500), makeAddr("out"));
        bytes memory extraData = abi.encodePacked(uint8(1), abi.encode(path));
        vm.expectRevert(UniswapSwapAdapter.UnsupportedMode.selector);
        adapter.quote(makeAddr("in"), makeAddr("out"), 1e18, extraData);
    }

    function test_unsupportedMode_quote_reverts() public {
        bytes memory extraData = abi.encodePacked(uint8(9), abi.encode(uint24(500)));
        vm.expectRevert(UniswapSwapAdapter.UnsupportedMode.selector);
        adapter.quote(makeAddr("in"), makeAddr("out"), 1e18, extraData);
    }

    // ── Mode 3 (V4 multi-hop) guards — harness has address(0) pool manager/quoter ──

    function _mode3(PathHop[] memory hops) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(3), abi.encode(hops));
    }

    function test_mode3_swap_reverts_whenPoolManagerUnset() public {
        ERC20Mock tokenIn = new ERC20Mock("In", "IN", 18);
        address out = makeAddr("out");
        address user = makeAddr("user");
        tokenIn.mint(user, 1e18);

        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: address(0), fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: out, fee: 50_000, tickSpacing: 1000});

        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1e18);
        vm.expectRevert(UniswapSwapAdapter.V4Unavailable.selector);
        adapter.swap(address(tokenIn), out, 1e18, 0, _mode3(hops));
        vm.stopPrank();
    }

    function test_mode3_quote_reverts_whenV4QuoterUnset() public {
        address out = makeAddr("out");
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: address(0), fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: out, fee: 50_000, tickSpacing: 1000});

        vm.expectRevert(UniswapSwapAdapter.V4Unavailable.selector);
        adapter.quote(makeAddr("in"), out, 1e18, _mode3(hops));
    }

    /// @dev swap() validates the mode-3 path length BEFORE _swapV4's
    ///      V4Unavailable check, so the length gate reverts InvalidPath even with
    ///      an address(0) pool manager on the harness.
    function test_mode3_swap_reverts_emptyPath() public {
        ERC20Mock tokenIn = new ERC20Mock("In", "IN", 18);
        address out = makeAddr("out");
        address user = makeAddr("user");
        tokenIn.mint(user, 1e18);

        PathHop[] memory hops = new PathHop[](0);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1e18);
        vm.expectRevert(UniswapSwapAdapter.InvalidPath.selector);
        adapter.swap(address(tokenIn), out, 1e18, 0, _mode3(hops));
        vm.stopPrank();
    }

    /// @dev quote() gates on the v4Quoter presence first, so use a harness with a
    ///      non-zero quoter to reach the InvalidPath length/endpoint gate.
    function test_mode3_quote_reverts_emptyPath() public {
        UniswapSwapAdapterHarness q = new UniswapSwapAdapterHarness(address(1), address(2), address(0), address(3));
        PathHop[] memory hops = new PathHop[](0);
        vm.expectRevert(UniswapSwapAdapter.InvalidPath.selector);
        q.quote(makeAddr("in"), makeAddr("out"), 1e18, _mode3(hops));
    }

    function test_mode3_quote_reverts_singleHopPath() public {
        UniswapSwapAdapterHarness q = new UniswapSwapAdapterHarness(address(1), address(2), address(0), address(3));
        address out = makeAddr("out");
        PathHop[] memory hops = new PathHop[](1);
        hops[0] = PathHop({currency: out, fee: 500, tickSpacing: 10});
        vm.expectRevert(UniswapSwapAdapter.InvalidPath.selector);
        q.quote(makeAddr("in"), out, 1e18, _mode3(hops));
    }

    function test_mode3_quote_reverts_lastCurrencyNotTokenOut() public {
        UniswapSwapAdapterHarness q = new UniswapSwapAdapterHarness(address(1), address(2), address(0), address(3));
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: address(0), fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: makeAddr("notOut"), fee: 50_000, tickSpacing: 1000});
        vm.expectRevert(UniswapSwapAdapter.InvalidPath.selector);
        q.quote(makeAddr("in"), makeAddr("out"), 1e18, _mode3(hops));
    }

    /// @dev Callback auth unchanged after the mode-3 payload refactor: a non-PM
    ///      caller still reverts UnauthorizedCallback (payload is decoded only
    ///      after the auth gate).
    // ── _orientHops: forward passes through, reverse flips currencies + pools ──

    address constant A_IN = address(0xA11CE);
    address constant A_MID = address(0xB0B);
    address constant A_OUT = address(0xC0FFEE);

    function test_orientHops_forward_passthrough() public view {
        address tin = A_IN;
        address mid = A_MID;
        address tout = A_OUT;
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: mid, fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: tout, fee: 50_000, tickSpacing: 1000});

        PathHop[] memory oriented = adapter.orientHops(hops, tin, tout);
        assertEq(oriented.length, 2);
        assertEq(oriented[0].currency, mid);
        assertEq(uint256(oriented[0].fee), 500);
        assertEq(oriented[1].currency, tout);
        assertEq(uint256(oriented[1].fee), 50_000);
    }

    /// @dev Reverse: forward path in→mid→out with pools (in↔mid: 500/10),
    ///      (mid↔out: 50000/1000). Reverse (tokenIn=out, tokenOut=in) must be
    ///      out→mid→in reusing the same pools in reverse order.
    function test_orientHops_reverse_flipsCurrenciesAndPools() public view {
        address tin = A_IN;
        address mid = A_MID;
        address tout = A_OUT;
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: mid, fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: tout, fee: 50_000, tickSpacing: 1000});

        // Sell direction: tokenIn = tout (old end), tokenOut = tin (old head).
        PathHop[] memory rev = adapter.orientHops(hops, tout, tin);
        assertEq(rev.length, 2);
        // First reversed hop: out → mid via the mid↔out pool (50000/1000).
        assertEq(rev[0].currency, mid, "rev hop0 currency");
        assertEq(uint256(rev[0].fee), 50_000, "rev hop0 fee");
        assertEq(int256(rev[0].tickSpacing), 1000, "rev hop0 tickSpacing");
        // Second reversed hop: mid → in via the in↔mid pool (500/10).
        assertEq(rev[1].currency, tin, "rev hop1 currency == tokenOut");
        assertEq(uint256(rev[1].fee), 500, "rev hop1 fee");
        assertEq(int256(rev[1].tickSpacing), 10, "rev hop1 tickSpacing");
    }

    /// @dev Reversing a native-intermediate path keeps address(0) in the middle.
    function test_orientHops_reverse_nativeIntermediate() public view {
        address usdg = address(0x5D6);
        address tsla = address(0x715A);
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: address(0), fee: 500, tickSpacing: 10}); // native
        hops[1] = PathHop({currency: tsla, fee: 50_000, tickSpacing: 1000});

        // Buy was usdg→native→tsla; sell is tsla→native→usdg.
        PathHop[] memory rev = adapter.orientHops(hops, tsla, usdg);
        assertEq(rev[0].currency, address(0), "native stays intermediate");
        assertEq(uint256(rev[0].fee), 50_000);
        assertEq(rev[1].currency, usdg, "ends at usdg");
        assertEq(uint256(rev[1].fee), 500);
    }

    function test_orientHops_reverse_isInvolution_3hop() public view {
        address a = address(0xAA);
        address b = address(0xBB);
        address c = address(0xCC);
        address d = address(0xDD);
        PathHop[] memory hops = new PathHop[](3);
        hops[0] = PathHop({currency: b, fee: 100, tickSpacing: 1});
        hops[1] = PathHop({currency: c, fee: 500, tickSpacing: 10});
        hops[2] = PathHop({currency: d, fee: 3000, tickSpacing: 60});

        // a→b→c→d reversed to start at d, end at a; reversing again restores.
        PathHop[] memory rev = adapter.orientHops(hops, d, a);
        PathHop[] memory back = adapter.orientHops(rev, a, d);
        assertEq(back.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(back[i].currency, hops[i].currency, "involution currency");
            assertEq(uint256(back[i].fee), uint256(hops[i].fee), "involution fee");
            assertEq(int256(back[i].tickSpacing), int256(hops[i].tickSpacing), "involution ts");
        }
    }

    function test_orientHops_reverts_neitherEndpoint() public {
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: makeAddr("mid"), fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: makeAddr("out"), fee: 50_000, tickSpacing: 1000});
        vm.expectRevert(UniswapSwapAdapter.InvalidPath.selector);
        adapter.orientHops(hops, makeAddr("in"), makeAddr("wrong"));
    }

    function test_mode3_unlockCallback_reverts_whenCallerNotPoolManager() public {
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: address(0), fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: makeAddr("out"), fee: 50_000, tickSpacing: 1000});
        UniswapSwapAdapter.V4Callback memory cb = UniswapSwapAdapter.V4Callback({
            tokenIn: makeAddr("in"), recipient: makeAddr("r"), amountIn: 1e18, hops: hops
        });
        vm.expectRevert(UniswapSwapAdapter.UnauthorizedCallback.selector);
        adapter.unlockCallback(abi.encode(cb));
    }
}

contract UniswapSwapAdapterHarness is UniswapSwapAdapter {
    constructor(address r, address q, address pm, address v4q) UniswapSwapAdapter(r, q, pm, v4q) {}

    function orientHops(PathHop[] memory hops, address tokenIn, address tokenOut)
        external
        pure
        returns (PathHop[] memory)
    {
        return _orientHops(hops, tokenIn, tokenOut);
    }
}
