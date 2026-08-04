// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SynthraSwapAdapter} from "../../src/adapters/SynthraSwapAdapter.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @title SynthraSwapAdapter multi-hop path reversal regression test (audit-181 finding #15)
/// @notice PortfolioStrategy stores ONE packed multi-hop path per allocation
///         (oriented buy: asset -> ... -> token) and reuses the SAME bytes
///         for the reverse sell leg (token -> ... -> asset). Unlike
///         UniswapSwapAdapter (which auto-orients the path to tokenIn via
///         `_extractFirstAddress`/`_reversePath` in both `swap()` and
///         `quote()`), SynthraSwapAdapter previously passed the caller's
///         path through untouched. On the sell leg the adapter had approved
///         the router only for the basket token (the true `tokenIn`) but
///         handed the router a path whose head was the vault asset — the
///         router's first pull is of a token the adapter has no allowance
///         for, so settlement reverts (STF-equivalent) and the vault can
///         never settle a multi-hop Synthra position.
///
///         This suite proves the adapter now re-orients the packed path to
///         `tokenIn` in both `swap()` and `quote()`, mirroring
///         UniswapSwapAdapter's mode-1 behavior exactly.
contract SynthraSwapAdapter_pathReversalTest is Test {
    SynthraSwapAdapter adapter;
    CapturingSynthraRouter router;
    CapturingSynthraQuoter quoter;

    ERC20Mock asset; // vault asset — head of the strategy's STORED (buy-oriented) path
    ERC20Mock mid; // intermediate hop token
    ERC20Mock token; // basket token — tail of the stored path, tokenIn on the sell leg

    address user = makeAddr("user");

    // Packed path as the strategy stores it: buy direction, asset -> mid -> token.
    bytes storedPath;
    // The correctly-oriented sell-direction path: token -> mid -> asset.
    bytes expectedReversedPath;

    function setUp() public {
        router = new CapturingSynthraRouter();
        quoter = new CapturingSynthraQuoter();
        adapter = new SynthraSwapAdapter(address(router), address(quoter));

        asset = new ERC20Mock("Asset", "ASSET", 18);
        mid = new ERC20Mock("Mid", "MID", 18);
        token = new ERC20Mock("Token", "TOKEN", 18);

        storedPath = abi.encodePacked(address(asset), uint24(500), address(mid), uint24(3000), address(token));
        expectedReversedPath =
            abi.encodePacked(address(token), uint24(3000), address(mid), uint24(500), address(asset));

        // Router needs asset-side liquidity to pay out the sell leg.
        asset.mint(address(router), 1_000_000e18);

        // User holds the basket token and approves the adapter for the sell leg
        // (tokenIn = token, tokenOut = asset — the reverse of how the path was stored).
        token.mint(user, 100_000e18);
        vm.prank(user);
        token.approve(address(adapter), type(uint256).max);
    }

    /// @notice The stored path is buy-oriented (asset -> mid -> token). Selling
    ///         (tokenIn = token, tokenOut = asset) reuses that SAME path bytes.
    ///         Before the fix, the adapter forwarded the path untouched: the
    ///         router's exactInput would try to pull `asset` (the path head)
    ///         from the adapter, which never held or approved `asset` for this
    ///         call (only `token`, the real tokenIn, was approved) — the call
    ///         reverts and the swap can never settle. After the fix, the
    ///         adapter reverses the path so `token` (tokenIn) is the head, the
    ///         router pulls the token it was actually approved for, and the
    ///         swap succeeds routing to `asset` (tokenOut).
    function test_swap_multiHop_reversesStoredPathForSellDirection() public {
        bytes memory extraData = abi.encode(uint24(500), storedPath);
        router.setReturn(1_500e18);

        vm.prank(user);
        uint256 amountOut = adapter.swap(address(token), address(asset), 1_000e18, 1_400e18, extraData);

        assertEq(amountOut, 1_500e18, "amountOut bubbled from router");
        assertEq(asset.balanceOf(user), 1_500e18, "output (asset) routed to caller");
        assertEq(token.balanceOf(user), 99_000e18, "input (token) pulled from caller");

        // The router must have received the REVERSED path (head = tokenIn = token),
        // not the raw stored (buy-oriented) path.
        assertEq(router.lastPath(), expectedReversedPath, "router did not receive path reoriented to tokenIn");
    }

    /// @notice quote() must apply the identical reorientation as swap(), since
    ///         PortfolioStrategy._quoteMinOut derives its floor from quote()
    ///         and then executes through swap() — a mismatch here would mean
    ///         the pre-trade floor is quoted against the wrong route.
    function test_quote_multiHop_reversesStoredPathForSellDirection() public {
        bytes memory extraData = abi.encode(uint24(500), storedPath);
        quoter.setReturn(1_500e18);

        uint256 out = adapter.quote(address(token), address(asset), 1_000e18, extraData);

        assertEq(out, 1_500e18);
        assertEq(quoter.lastPath(), expectedReversedPath, "quoter did not receive path reoriented to tokenIn");
    }

    /// @notice Sanity check: when tokenIn already matches the path head (the
    ///         buy leg, as originally stored), the path must pass through
    ///         UNCHANGED — reorientation must not double-reverse or corrupt
    ///         the already-correct forward direction.
    function test_swap_multiHop_leavesForwardPathUnchanged() public {
        // Buy leg: tokenIn = asset (path head already matches).
        asset.mint(user, 100_000e18);
        vm.prank(user);
        asset.approve(address(adapter), type(uint256).max);
        token.mint(address(router), 1_000_000e18);

        bytes memory extraData = abi.encode(uint24(500), storedPath);
        router.setReturn(1_500e18);

        vm.prank(user);
        adapter.swap(address(asset), address(token), 1_000e18, 1_400e18, extraData);

        assertEq(router.lastPath(), storedPath, "forward-direction path must not be mutated");
    }
}

/// @notice Mock Synthra Router that pulls `amountIn` of the path's HEAD token
///         (not a caller-supplied `tokenIn` param — `exactInput` has none) from
///         msg.sender (the adapter) and pays `mockReturn` of the path's TAIL
///         token to `recipient`. This mirrors the real SwapRouter02 semantics:
///         the router trusts the packed path's own encoding for what it pulls
///         first, so an unreoriented path pulls the wrong token and reverts.
contract CapturingSynthraRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    bytes private _lastPath;
    uint256 public mockReturn;

    function setReturn(uint256 r) external {
        mockReturn = r;
    }

    function lastPath() external view returns (bytes memory) {
        return _lastPath;
    }

    function exactInput(ExactInputParams calldata p) external returns (uint256 amountOut) {
        _lastPath = p.path;

        bytes memory path = p.path;
        uint256 len = path.length;
        address head;
        address tail;
        assembly {
            head := shr(96, mload(add(path, 32)))
            tail := shr(96, mload(add(add(path, 32), sub(len, 20))))
        }

        // Pull the path's head token from the adapter — reverts if the
        // adapter never approved this token (the bug this test guards).
        (bool pulled,) = head.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), p.amountIn)
        );
        require(pulled, "router pull failed: path head not approved by adapter");

        (bool paid,) = tail.call(abi.encodeWithSignature("transfer(address,uint256)", p.recipient, mockReturn));
        require(paid, "router pay failed");

        return mockReturn;
    }
}

/// @notice Mock Synthra Quoter that simply records the path it was called
///         with, so the test can assert `quote()` reorients identically to
///         `swap()`.
contract CapturingSynthraQuoter {
    bytes private _lastPath;
    uint256 public mockReturn;

    function setReturn(uint256 r) external {
        mockReturn = r;
    }

    function lastPath() external view returns (bytes memory) {
        return _lastPath;
    }

    function quoteExactInput(bytes calldata path, uint256 /* amountIn */ )
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        _lastPath = path;
        amountOut = mockReturn;
        sqrtPriceX96AfterList = new uint160[](0);
        initializedTicksCrossedList = new uint32[](0);
        gasEstimate = 0;
    }
}
