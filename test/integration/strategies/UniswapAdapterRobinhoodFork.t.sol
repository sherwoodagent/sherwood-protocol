// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapSwapAdapter, PathHop} from "../../../src/adapters/UniswapSwapAdapter.sol";
import {ROBINHOOD_FORK_BLOCK} from "../RobinhoodMainnetIntegrationTest.sol";

/**
 * @title UniswapAdapterRobinhoodForkTest
 * @notice Fork tests for UniswapSwapAdapter against Robinhood Chain mainnet's
 *         official Uniswap v3 deployment. Exercises mode-0 single-hop and mode-1
 *         chained multi-hop swaps on the live USDG/WETH pools.
 *
 * @dev Small swap sizes (~100-1000 USDG) — mainnet pool liquidity is modest.
 *      Skips if ROBINHOOD_RPC_URL is not set and PINS the shared harness fork
 *      block so pool/feed state stays deterministic. Run explicitly:
 *        forge test --fork-url $ROBINHOOD_RPC_URL \
 *          --match-path "test/integration/strategies/UniswapAdapterRobinhoodFork.t.sol" -vv
 */
contract UniswapAdapterRobinhoodForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant UNISWAP_SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant UNISWAP_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    // Uniswap v4 (hookless stock-token pools).
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    // Tokenized stocks with live native-ETH-paired v4 pools (50000/1000). These
    // four are exactly the CLI agent's default deep-route set — verified
    // on-chain (StateView.getLiquidity, 2026-07-06) to have real liquidity in
    // the native 50000/1000 pool. MSFT/AMZN/META/SPY/QQQ/SLV/GOOGL do NOT.
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AMD = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;

    uint24 constant FEE_500 = 500;
    uint24 constant FEE_3000 = 3000;
    // Live TSLA/USDG v4 pool: 5% fee, tickSpacing 1000, hookless.
    uint24 constant V4_FEE_50000 = 50_000;
    int24 constant V4_TICK_SPACING_1000 = 1000;

    // Native-ETH-paired v4 pools (mode 3): the deepest stock/USDG liquidity.
    address constant NATIVE = address(0);
    // native(0)/USDG pool: 5bps fee, tickSpacing 10 — deepest USDG v4 pool.
    uint24 constant V4_NATIVE_USDG_FEE = 500;
    int24 constant V4_NATIVE_USDG_TS = 10;

    UniswapSwapAdapter adapter;
    address caller = makeAddr("caller");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, ROBINHOOD_FORK_BLOCK);
        require(block.chainid == 4663, "not on Robinhood mainnet fork");
        adapter = new UniswapSwapAdapter(UNISWAP_SWAP_ROUTER, UNISWAP_QUOTER_V2, V4_POOL_MANAGER, V4_QUOTER);
    }

    // ── Mode 0: single-hop USDG → WETH ──

    function test_singleHop_USDG_to_WETH() public {
        uint256 amountIn = 1000e6; // 1000 USDG
        deal(USDG, caller, amountIn);

        bytes memory extraData = abi.encodePacked(uint8(0), abi.encode(FEE_500));

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        uint256 amountOut = adapter.swap(USDG, WETH, amountIn, 0, extraData);
        vm.stopPrank();

        console2.log("Single-hop USDG->WETH (1000 USDG):", amountOut);
        assertGt(amountOut, 0, "should receive WETH");
        assertEq(IERC20(WETH).balanceOf(caller), amountOut, "WETH should be in caller");
    }

    // ── Mode 0: single-hop WETH → USDG (reverse) ──

    function test_singleHop_WETH_to_USDG() public {
        // Acquire WETH first via a forward swap.
        uint256 usdcIn = 1000e6;
        deal(USDG, caller, usdcIn);
        bytes memory extra = abi.encodePacked(uint8(0), abi.encode(FEE_500));

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), usdcIn);
        uint256 wethAmount = adapter.swap(USDG, WETH, usdcIn, 0, extra);

        // Sell the WETH back.
        IERC20(WETH).approve(address(adapter), wethAmount);
        uint256 usdgOut = adapter.swap(WETH, USDG, wethAmount, 0, extra);
        vm.stopPrank();

        console2.log("Reverse WETH->USDG:", usdgOut);
        assertGt(usdgOut, 0, "should receive USDG back");
        console2.log("Roundtrip loss (USDG raw):", usdcIn - usdgOut);
    }

    // ── Mode 1: chained multi-hop USDG -(500)- WETH -(3000)- USDG ──

    function test_multiHop_USDG_WETH_USDG() public {
        uint256 amountIn = 500e6; // 500 USDG
        deal(USDG, caller, amountIn);

        // Path exercises both liquid pools: USDG/WETH fee-500 then WETH/USDG
        // fee-3000. tokenIn == tokenOut == USDG, so this is a pure plumbing
        // test of the chained-hop machinery on live liquidity.
        bytes memory path = abi.encodePacked(USDG, FEE_500, WETH, FEE_3000, USDG);
        bytes memory extraData = abi.encodePacked(uint8(1), abi.encode(path, uint16(200)));

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        uint256 amountOut = adapter.swap(USDG, USDG, amountIn, 0, extraData);
        vm.stopPrank();

        console2.log("Multi-hop USDG->WETH->USDG (500 USDG in):", amountOut);
        assertGt(amountOut, 0, "should receive USDG out");
        // Two hops of fees → out < in, but should recover most of it.
        assertLt(amountOut, amountIn, "two-hop roundtrip pays fees");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "no WETH stranded in adapter");
    }

    // ── Quoter ABI sanity against live QuoterV2 ──

    function test_quote_singleHop_USDG_to_WETH() public {
        bytes memory extraData = abi.encodePacked(uint8(0), abi.encode(FEE_500));
        uint256 expected = adapter.quote(USDG, WETH, 1000e6, extraData);
        console2.log("Quote USDG->WETH (1000 USDG):", expected);
        assertGt(expected, 0, "quote must return a non-zero amount");
    }

    // ── Mode 2: V4 single-hop USDG → TSLA on the live 5% hookless pool ──

    function _v4Extra() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(2), abi.encode(V4_FEE_50000, V4_TICK_SPACING_1000));
    }

    function test_v4_quote_USDG_to_TSLA() public {
        uint256 amountIn = 1000e6; // 1000 USDG
        uint256 quoted = adapter.quote(USDG, TSLA, amountIn, _v4Extra());
        console2.log("V4 quote USDG->TSLA (1000 USDG):", quoted);
        // Reference: ~2.3298e18 TSLA per 1000 USDG at the pinned block.
        assertGt(quoted, 0, "v4 quote must be non-zero");
    }

    function test_v4_swap_USDG_to_TSLA() public {
        uint256 amountIn = 1000e6;
        deal(USDG, caller, amountIn);

        uint256 quoted = adapter.quote(USDG, TSLA, amountIn, _v4Extra());
        console2.log("V4 quote USDG->TSLA:", quoted);
        // 1% slippage floor off the quote.
        uint256 minOut = (quoted * 9900) / 10_000;

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        uint256 amountOut = adapter.swap(USDG, TSLA, amountIn, minOut, _v4Extra());
        vm.stopPrank();

        console2.log("V4 swap USDG->TSLA out (TSLA):", amountOut);
        assertGe(amountOut, minOut, "output below quoted floor");
        assertEq(IERC20(TSLA).balanceOf(caller), amountOut, "TSLA delivered to caller");
        assertEq(IERC20(TSLA).balanceOf(address(adapter)), 0, "no TSLA stranded in adapter");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "no USDG stranded in adapter");
    }

    // ── Mode 2: reverse TSLA → USDG (buy TSLA first, then sell it back) ──

    function test_v4_swap_TSLA_to_USDG() public {
        uint256 amountIn = 1000e6;
        deal(USDG, caller, amountIn);

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        uint256 tslaAmount = adapter.swap(USDG, TSLA, amountIn, 0, _v4Extra());

        IERC20(TSLA).approve(address(adapter), tslaAmount);
        uint256 usdgQuote = adapter.quote(TSLA, USDG, tslaAmount, _v4Extra());
        uint256 minOut = (usdgQuote * 9900) / 10_000;
        uint256 usdgOut = adapter.swap(TSLA, USDG, tslaAmount, minOut, _v4Extra());
        vm.stopPrank();

        console2.log("V4 reverse TSLA->USDG out (USDG):", usdgOut);
        assertGe(usdgOut, minOut, "reverse output below quoted floor");
        assertGt(usdgOut, 0, "should receive USDG back");
        // Two 5% legs → meaningful roundtrip loss expected.
        assertLt(usdgOut, amountIn, "roundtrip pays fees");
        assertEq(IERC20(TSLA).balanceOf(address(adapter)), 0, "no TSLA stranded");
    }

    // ── minOut enforcement: an impossible floor reverts in the adapter ──

    function test_v4_swap_reverts_onImpossibleMinOut() public {
        uint256 amountIn = 1000e6;
        deal(USDG, caller, amountIn);

        uint256 quoted = adapter.quote(USDG, TSLA, amountIn, _v4Extra());
        uint256 impossible = quoted * 2; // demand 2x the quote — unreachable

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        vm.expectRevert(UniswapSwapAdapter.SlippageExceeded.selector);
        adapter.swap(USDG, TSLA, amountIn, impossible, _v4Extra());
        vm.stopPrank();
    }

    // ── Mode 3: V4 multi-hop through a native-ETH intermediate ──
    //
    //   USDG →(native/USDG 500/10)→ native ETH →(TSLA/native 50000/1000)→ TSLA
    //   Native ETH nets to zero inside one unlock (flash accounting) — no ETH is
    //   ever held, no WETH wrap. Endpoints (USDG, TSLA) are ERC20s.

    /// @dev hops: [native via 500/10, then TSLA via 50000/1000]. tokenIn = USDG.
    function _mode3_USDG_to_TSLA() internal pure returns (bytes memory) {
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: NATIVE, fee: V4_NATIVE_USDG_FEE, tickSpacing: V4_NATIVE_USDG_TS});
        hops[1] = PathHop({currency: TSLA, fee: V4_FEE_50000, tickSpacing: V4_TICK_SPACING_1000});
        return abi.encodePacked(uint8(3), abi.encode(hops));
    }

    /// @dev reverse: TSLA →(native)→ USDG. tokenIn = TSLA.
    function _mode3_TSLA_to_USDG() internal pure returns (bytes memory) {
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: NATIVE, fee: V4_FEE_50000, tickSpacing: V4_TICK_SPACING_1000});
        hops[1] = PathHop({currency: USDG, fee: V4_NATIVE_USDG_FEE, tickSpacing: V4_NATIVE_USDG_TS});
        return abi.encodePacked(uint8(3), abi.encode(hops));
    }

    function test_v4_mode3_quote_USDG_via_native_to_TSLA() public {
        uint256 amountIn = 1000e6;
        uint256 quoted = adapter.quote(USDG, TSLA, amountIn, _mode3_USDG_to_TSLA());
        console2.log("Mode-3 quote USDG->native->TSLA (1000 USDG):", quoted);
        assertGt(quoted, 0, "mode-3 quote must be non-zero");
    }

    function test_v4_mode3_swap_USDG_via_native_to_TSLA() public {
        uint256 amountIn = 1000e6;
        deal(USDG, caller, amountIn);

        uint256 quoted = adapter.quote(USDG, TSLA, amountIn, _mode3_USDG_to_TSLA());
        console2.log("Mode-3 quote USDG->native->TSLA:", quoted);
        uint256 minOut = (quoted * 9900) / 10_000; // 1% floor off the quote

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        uint256 amountOut = adapter.swap(USDG, TSLA, amountIn, minOut, _mode3_USDG_to_TSLA());
        vm.stopPrank();

        console2.log("Mode-3 swap USDG->native->TSLA out (TSLA):", amountOut);
        assertGe(amountOut, minOut, "output below quoted floor");
        assertEq(IERC20(TSLA).balanceOf(caller), amountOut, "TSLA delivered to caller");
        assertEq(IERC20(TSLA).balanceOf(address(adapter)), 0, "no TSLA stranded");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "no USDG stranded");
        assertEq(address(adapter).balance, 0, "no native ETH stranded in adapter");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "no WETH stranded");
    }

    function test_v4_mode3_swap_TSLA_via_native_to_USDG() public {
        // Buy TSLA first (direct mode-2), then sell it back via mode 3 native path.
        uint256 amountIn = 1000e6;
        deal(USDG, caller, amountIn);

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        uint256 tslaAmount = adapter.swap(USDG, TSLA, amountIn, 0, _v4Extra());

        IERC20(TSLA).approve(address(adapter), tslaAmount);
        uint256 usdgQuote = adapter.quote(TSLA, USDG, tslaAmount, _mode3_TSLA_to_USDG());
        uint256 minOut = (usdgQuote * 9900) / 10_000;
        uint256 usdgOut = adapter.swap(TSLA, USDG, tslaAmount, minOut, _mode3_TSLA_to_USDG());
        vm.stopPrank();

        console2.log("Mode-3 reverse TSLA->native->USDG out (USDG):", usdgOut);
        assertGe(usdgOut, minOut, "reverse output below quoted floor");
        assertGt(usdgOut, 0, "should receive USDG back");
        assertEq(IERC20(TSLA).balanceOf(address(adapter)), 0, "no TSLA stranded");
        assertEq(IERC20(USDG).balanceOf(address(adapter)), 0, "no USDG stranded");
        assertEq(address(adapter).balance, 0, "no native ETH stranded");
    }

    function test_v4_mode3_swap_reverts_onImpossibleMinOut() public {
        uint256 amountIn = 1000e6;
        deal(USDG, caller, amountIn);

        uint256 quoted = adapter.quote(USDG, TSLA, amountIn, _mode3_USDG_to_TSLA());
        uint256 impossible = quoted * 2;

        vm.startPrank(caller);
        IERC20(USDG).approve(address(adapter), amountIn);
        vm.expectRevert(UniswapSwapAdapter.SlippageExceeded.selector);
        adapter.swap(USDG, TSLA, amountIn, impossible, _mode3_USDG_to_TSLA());
        vm.stopPrank();
    }

    // ── Comparison: mode-3 via-native output vs mode-2 direct output ──
    //
    //   Same 1000 USDG → TSLA. Deeper native-paired pools *should* net a better
    //   (or similar) output than the direct USDG/TSLA 5% pool — but we only log,
    //   never assert superiority (liquidity/price drifts block-to-block).

    function test_v4_mode3_vs_mode2_outputComparison() public {
        uint256 amountIn = 1000e6;

        uint256 directQuote = adapter.quote(USDG, TSLA, amountIn, _v4Extra());
        uint256 viaNativeQuote = adapter.quote(USDG, TSLA, amountIn, _mode3_USDG_to_TSLA());

        console2.log("mode-2 direct  USDG->TSLA (TSLA out):", directQuote);
        console2.log("mode-3 native  USDG->TSLA (TSLA out):", viaNativeQuote);
        if (viaNativeQuote >= directQuote) {
            console2.log("mode-3 better by (TSLA):", viaNativeQuote - directQuote);
        } else {
            console2.log("mode-2 better by (TSLA):", directQuote - viaNativeQuote);
        }
        assertGt(directQuote, 0, "direct quote non-zero");
        assertGt(viaNativeQuote, 0, "via-native quote non-zero");
    }

    // ── Default deep-route set: every stock the CLI agent routes by default
    //    must have a live native-paired v4 pool (Fix D / review #5) ──
    //
    //   Mode 3: USDG →(native/USDG 500/10)→ native ETH →(stock/native 50000/1000)
    //   → stock. If a pool disappears or the agent's default set drifts from the
    //   verified {AAPL, TSLA, NVDA, AMD}, this quote returns 0 and CI-with-RPC
    //   fails loudly.

    function _mode3_USDG_to_stock(address stock) internal pure returns (bytes memory) {
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: NATIVE, fee: V4_NATIVE_USDG_FEE, tickSpacing: V4_NATIVE_USDG_TS});
        hops[1] = PathHop({currency: stock, fee: V4_FEE_50000, tickSpacing: V4_TICK_SPACING_1000});
        return abi.encodePacked(uint8(3), abi.encode(hops));
    }

    function test_v4_mode3_defaultStockRoutes_allQuoteNonzero() public {
        address[4] memory stocks = [AAPL, TSLA, NVDA, AMD];
        string[4] memory labels = ["AAPL", "TSLA", "NVDA", "AMD"];
        uint256 amountIn = 100e6; // 100 USDG

        for (uint256 i; i < stocks.length; ++i) {
            uint256 quoted = adapter.quote(USDG, stocks[i], amountIn, _mode3_USDG_to_stock(stocks[i]));
            console2.log(labels[i], "mode-3 quote (100 USDG -> stock):", quoted);
            assertGt(quoted, 0, string.concat(labels[i], ": default native route quoted zero"));
        }
    }
}
