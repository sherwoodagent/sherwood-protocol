// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {RobinhoodIntegrationTest} from "../RobinhoodIntegrationTest.sol";
import {PortfolioStrategy} from "../../../src/strategies/PortfolioStrategy.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PortfolioIntegrationTest
 * @notice Full-lifecycle fork tests for PortfolioStrategy driven against the
 *         LIVE V2 stack deployed on Robinhood L2 testnet (chain 46630): the
 *         deployed UniswapSwapAdapter (wired to Synthra via SynthraQuoterV2Shim),
 *         the deployed PortfolioStrategy template, and the deployed keyless
 *         StrategyFactory.
 *
 *         Pricing note: push-feed mode is unavailable on testnet (no Chainlink
 *         push aggregators), so the basket is initialized in Data Streams mode
 *         (chainlinkVerifier from chains/46630.json). `rebalanceDelta` needs
 *         signed Data Streams reports and is therefore NOT exercised here; the
 *         lifecycle covers propose → vote → execute (buy basket) → settle (sell
 *         back) → redeem, plus the quoter-based `rebalance()` path. Both
 *         `_execute`/`_settle`/`rebalance` price via the swap adapter's quoter
 *         (mode-agnostic `_quoteMinOut`), not the oracle.
 *
 * @dev Run:
 *   set -a; source .env; set +a
 *   forge test --match-path \
 *     "test/integration/strategies/PortfolioIntegration.t.sol" -vv
 */
contract PortfolioIntegrationTest is RobinhoodIntegrationTest {
    // Testnet pools are thin — keep swap sizes tiny.
    uint256 constant TOTAL_AMOUNT = 0.1e18; // 0.1 SYNTHRA_WETH total
    uint256 constant STRATEGY_DURATION = 1 hours;
    uint256 constant PERF_FEE_BPS = 1000; // 10%
    uint256 constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint24 constant FEE_TIER = 3000; // 0.3% — verified live at pinned block
    uint16 constant PER_HOP_SLIPPAGE_BPS = 200;

    /// @dev True only if the LIVE deployed adapter can quote the basket route, a
    ///      precondition for PortfolioStrategy execution. Computed once in setUp
    ///      so the guarded lifecycle tests can `vm.skip` as their first action
    ///      (Foundry counts skip-after-work as a failure, not a skip).
    bool internal stackCanExecute;

    function setUp() public override {
        super.setUp();
        // Only probe when the fork actually selected (super.setUp skips + leaves
        // the default chain id when ROBINHOOD_TESTNET_RPC_URL is unset).
        if (block.chainid != 46630) return;
        stackCanExecute = _deployedStackCanQuoteBasket();
        if (!stackCanExecute) {
            console2.log("NO-GO: deployed Synthra quoter/shim cannot quote the basket route (mode-0).");
            console2.log("PortfolioStrategy execute() is BLOCKED on chain 46630 at the pinned block.");
            console2.log("Fix: redeploy SynthraQuoterV2Shim speaking the struct-based QuoterV2 ABI + re-wire adapter.");
        }
    }

    // ── Swap-route extraData ──
    // Mode-0 (v3 single-hop) is the natural encoding for a Portfolio basket, so
    // the strategy is wired with mode-0. See the KNOWN DEPLOYED-STACK DEFECT
    // note on test_diagnose_quotePaths: the ORIGINAL shim called a positional
    // V1 selector that Synthra's quoter (a standard struct-based QuoterV2)
    // never implemented, so every mode-0 quote reverted with empty data.
    // Fixed by re-pointing the shim at the struct ABI (+ zero-limit
    // defaulting as defense-in-depth); the lifecycle tests below auto-activate
    // once the fixed shim + adapter are live in chains/46630.json.

    function _mode0(uint24 fee) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), abi.encode(fee));
    }

    function _mode1(address tokenIn, uint24 fee, address tokenOut) internal pure returns (bytes memory) {
        bytes memory path = abi.encodePacked(tokenIn, fee, tokenOut);
        return abi.encodePacked(uint8(1), abi.encode(path, PER_HOP_SLIPPAGE_BPS));
    }

    /// @dev The deployed adapter can execute a Portfolio strategy only if it can
    ///      quote the basket route. Probe the mode-0 quote the strategy uses; if
    ///      it reverts, the deployed Synthra quoter/shim is broken and the
    ///      lifecycle cannot run (see the diagnostic). Used to skip the
    ///      happy-path lifecycle tests cleanly until a shim/adapter redeploy.
    function _deployedStackCanQuoteBasket() internal returns (bool) {
        try ISwapAdapter(swapAdapter).quote(SYNTHRA_WETH, TSLA, 1e15, _mode0(FEE_TIER)) returns (uint256 out) {
            return out > 0;
        } catch {
            return false;
        }
    }

    // ── Basket init-data builder (Data Streams mode) ──

    function _buildBasketInitData(address[] memory tokens, uint256[] memory weightsBps, uint256 totalAmt)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory extraData = new bytes[](tokens.length);
        uint8[] memory priceDecimals = new uint8[](tokens.length);
        bytes32[] memory feedIds = new bytes32[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            // mode-0 v3 single-hop at the live fee tier.
            extraData[i] = _mode0(FEE_TIER);
            // Data Streams mode ignores priceDecimals for init validation; only
            // rebalanceDelta consumes it. Non-zero feedId placeholder passes the
            // init non-zero check (rebalanceDelta is not exercised on testnet).
            priceDecimals[i] = 18;
            feedIds[i] = bytes32(uint256(i + 1));
        }

        return abi.encode(
            SYNTHRA_WETH, // asset — Synthra pools denominate in this WETH
            swapAdapter, // deployed UniswapSwapAdapter (Synthra-wired)
            chainlinkVerifier, // Data Streams verifier (non-zero → DS mode)
            tokens,
            weightsBps,
            totalAmt,
            MAX_SLIPPAGE_BPS,
            extraData,
            priceDecimals,
            feedIds
        );
    }

    function _buildExecCalls(address strategy, uint256 amount)
        internal
        pure
        returns (BatchExecutorLib.Call[] memory calls)
    {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: SYNTHRA_WETH, data: abi.encodeCall(IERC20.approve, (strategy, amount)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});
    }

    function _buildSettleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    function _deploy3TokenBasket() internal returns (address strategy, uint256 proposalId) {
        address[] memory tokens = new address[](3);
        tokens[0] = TSLA;
        tokens[1] = AMZN;
        tokens[2] = AMD;

        uint256[] memory weights = new uint256[](3);
        weights[0] = 4000; // 40%
        weights[1] = 3500; // 35%
        weights[2] = 2500; // 25%

        bytes memory initData = _buildBasketInitData(tokens, weights, TOTAL_AMOUNT);
        strategy = _cloneAndInit(portfolioTemplate, initData);

        proposalId = _proposeVoteExecute(
            _buildExecCalls(strategy, TOTAL_AMOUNT), _buildSettleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION
        );
    }

    // ── Diagnostic: which deployed-adapter quote/swap paths actually work ──

    function test_diagnose_quotePaths() public {
        ISwapAdapter a = ISwapAdapter(swapAdapter);
        uint256 amtIn = (TOTAL_AMOUNT * 4000) / 10_000; // one basket leg

        console2.log("=== deployed-adapter quote diagnostics (SYNTHRA_WETH -> stock) ===");
        console2.log("adapter:", swapAdapter);
        console2.log("amountIn (SYNTHRA_WETH):", amtIn);

        address[3] memory toks = [TSLA, AMZN, AMD];
        string[3] memory names = ["TSLA", "AMZN", "AMD"];
        for (uint256 i; i < 3; ++i) {
            // mode-0 (single-hop) quote — expected to revert on Synthra.
            try a.quote(SYNTHRA_WETH, toks[i], amtIn, _mode0(FEE_TIER)) returns (uint256 out0) {
                console2.log(string.concat(names[i], " mode-0 quote OK:"), out0);
            } catch {
                console2.log(string.concat(names[i], " mode-0 quote REVERTED (Synthra quoteExactInputSingle)"));
            }
            // mode-1 (path) quote — expected to work via quoteExactInput.
            try a.quote(SYNTHRA_WETH, toks[i], amtIn, _mode1(SYNTHRA_WETH, FEE_TIER, toks[i])) returns (uint256 out1) {
                console2.log(string.concat(names[i], " mode-1 quote OK:"), out1);
                assertGt(out1, 0, "mode-1 quote must be non-zero");
            } catch {
                console2.log(string.concat(names[i], " mode-1 quote REVERTED"));
            }
        }

        // Isolate the defect: does the SWAP plumbing work when it does NOT touch
        // the quoter? mode-0 swap routes straight through the Synthra router
        // (v3Router.exactInputSingle) with no quoter pre-call. If this succeeds
        // while mode-0/mode-1 quotes revert, the defect is confined to the
        // quoter (Synthra's quoteExactInputSingle + the shim forwarding limit 0).
        deal(SYNTHRA_WETH, address(this), amtIn);
        IERC20(SYNTHRA_WETH).approve(swapAdapter, amtIn);
        try a.swap(SYNTHRA_WETH, TSLA, amtIn, 0, _mode0(FEE_TIER)) returns (uint256 out) {
            console2.log("mode-0 SWAP (router-direct, no quoter) OK, TSLA out:", out);
            assertGt(out, 0, "mode-0 router swap should deliver TSLA");
        } catch {
            console2.log("mode-0 SWAP (router-direct) REVERTED");
        }
    }

    // ── Full lifecycle: execute basket → settle → verify unwind + redeem ──

    function test_basketIndex_fullLifecycle() public {
        if (!stackCanExecute) {
            vm.skip(true);
            return;
        }
        uint256 vaultBefore = IERC20(SYNTHRA_WETH).balanceOf(address(vault));
        console2.log("Vault WETH before:", vaultBefore);

        (address strategy, uint256 proposalId) = _deploy3TokenBasket();

        uint256 vaultAfterExec = IERC20(SYNTHRA_WETH).balanceOf(address(vault));
        console2.log("Vault WETH after exec:", vaultAfterExec);
        assertLt(vaultAfterExec, vaultBefore, "vault should have less WETH after execution");

        PortfolioStrategy strat = PortfolioStrategy(strategy);
        PortfolioStrategy.TokenAllocation[] memory allocs = strat.getAllocations();
        for (uint256 i; i < allocs.length; ++i) {
            uint256 bal = IERC20(allocs[i].token).balanceOf(strategy);
            console2.log("Strategy token balance:", allocs[i].token, bal);
            assertGt(bal, 0, "strategy should hold tokens after execution");
            assertEq(allocs[i].tokenAmount, bal, "allocation tokenAmount should match balance");
        }

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION);
        governor.settleProposal(proposalId);

        uint256 vaultAfterSettle = IERC20(SYNTHRA_WETH).balanceOf(address(vault));
        console2.log("Vault WETH after settle:", vaultAfterSettle);
        if (vaultAfterSettle >= vaultBefore) {
            console2.log("NET PROFIT:", vaultAfterSettle - vaultBefore);
        } else {
            console2.log("NET LOSS (fees/slippage):", vaultBefore - vaultAfterSettle);
        }

        for (uint256 i; i < allocs.length; ++i) {
            assertEq(IERC20(allocs[i].token).balanceOf(strategy), 0, "strategy should be empty after settle");
        }

        // Redeem: lp1 pulls its pro-rata share back out post-settle.
        uint256 lp1Shares = vault.balanceOf(lp1);
        assertGt(lp1Shares, 0, "lp1 holds shares");
        vm.prank(lp1);
        uint256 assetsOut = vault.redeem(lp1Shares, lp1, lp1);
        console2.log("lp1 redeemed assets:", assetsOut);
        assertGt(assetsOut, 0, "redeem returns assets");
        assertEq(IERC20(SYNTHRA_WETH).balanceOf(lp1), assetsOut, "redeemed assets delivered to lp1");
    }

    // ── Rebalance: execute → update weights → quoter-based rebalance() → settle ──

    function test_basketIndex_rebalance() public {
        if (!stackCanExecute) {
            vm.skip(true);
            return;
        }
        uint256 vaultBefore = IERC20(SYNTHRA_WETH).balanceOf(address(vault));

        (address strategy, uint256 proposalId) = _deploy3TokenBasket();
        PortfolioStrategy strat = PortfolioStrategy(strategy);

        // New weights: TSLA 60%, AMZN 30%, AMD 10%.
        uint256[] memory newWeights = new uint256[](3);
        newWeights[0] = 6000;
        newWeights[1] = 3000;
        newWeights[2] = 1000;

        vm.prank(agent);
        strat.updateParams(abi.encode(newWeights, uint256(0), new bytes[](0)));

        vm.prank(agent);
        strat.rebalance();

        PortfolioStrategy.TokenAllocation[] memory after_ = strat.getAllocations();
        for (uint256 i; i < after_.length; ++i) {
            console2.log("post-rebalance token/amount:", after_[i].token, after_[i].tokenAmount);
            assertGt(after_[i].tokenAmount, 0, "should hold tokens after rebalance");
        }
        assertEq(after_[0].targetWeightBps, 6000);
        assertEq(after_[1].targetWeightBps, 3000);
        assertEq(after_[2].targetWeightBps, 1000);

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION);
        governor.settleProposal(proposalId);

        uint256 vaultAfter = IERC20(SYNTHRA_WETH).balanceOf(address(vault));
        console2.log("Vault WETH before:", vaultBefore);
        console2.log("Vault WETH after:", vaultAfter);
        for (uint256 i; i < after_.length; ++i) {
            assertEq(IERC20(after_[i].token).balanceOf(strategy), 0, "strategy empty after settle");
        }
    }
}
