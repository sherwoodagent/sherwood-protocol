// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {RobinhoodMainnetIntegrationTest} from "../RobinhoodMainnetIntegrationTest.sol";
import {PortfolioStrategy, AggregatorV3Interface} from "../../../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter, PathHop} from "../../../src/adapters/UniswapSwapAdapter.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PortfolioMainnetForkTest
 * @notice Full-lifecycle fork tests for PortfolioStrategy on Robinhood Chain
 *         mainnet using the push-feed (AggregatorV3) price mode.
 *
 *         The basket is a single WETH position bought with USDG (mode-0, fee
 *         500). Because the vault asset (USDG ≈ $1) is the numeraire, the
 *         Chainlink X/USD push feeds are the correct pricing oracle:
 *           priceDecimals = 8, tokenDecimals = 18 (WETH), assetDecimals = 6.
 *
 * @dev Run explicitly (shares the fork in setUp):
 *        forge test --match-path "test/integration/strategies/PortfolioMainnetFork.t.sol" -vv
 */
contract PortfolioMainnetForkTest is RobinhoodMainnetIntegrationTest {
    uint256 constant TOTAL_AMOUNT = 5_000e6; // 5000 USDG deployed
    uint256 constant STRATEGY_DURATION = 1 hours;
    uint256 constant PERF_FEE_BPS = 1000; // 10%
    uint256 constant MAX_SLIPPAGE_BPS = 500; // 5%

    address swapAdapter;
    address template;

    function setUp() public override {
        super.setUp();
        swapAdapter =
            address(new UniswapSwapAdapter(UNISWAP_SWAP_ROUTER, UNISWAP_QUOTER_V2, V4_POOL_MANAGER, V4_QUOTER));
        template = address(new PortfolioStrategy());
    }

    // ── Init-data builder: 100% WETH basket, push-feed mode ──

    function _buildWethBasketInitData(uint256 totalAmt) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000; // 100%
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = abi.encodePacked(uint8(0), abi.encode(FEE_500));
        uint8[] memory priceDecimals = new uint8[](1);
        priceDecimals[0] = 8; // Chainlink push feed decimals
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(uint160(CHAINLINK_ETH_USD_FEED))); // push-mode encoding

        return abi.encode(
            USDG,
            swapAdapter,
            address(0), // push mode (no Data Streams verifier)
            tokens,
            weights,
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
        calls[0] =
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.approve, (strategy, amount)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});
    }

    function _buildSettleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    function _deployWethBasket() internal returns (address strategy, uint256 proposalId) {
        bytes memory initData = _buildWethBasketInitData(TOTAL_AMOUNT);
        strategy = _cloneAndInit(template, initData);
        proposalId = _proposeVoteExecute(
            _buildExecCalls(strategy, TOTAL_AMOUNT), _buildSettleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION
        );
    }

    // ── Full lifecycle: propose → execute (buy WETH) → rebalanceDelta (push
    //    feed) → settle (WETH back to USDG) ──

    function test_portfolio_fullLifecycle_pushFeed() public {
        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        console2.log("Vault USDG before:", vaultBefore);

        (address strategy, uint256 proposalId) = _deployWethBasket();

        // Vault USDG dropped, strategy holds WETH.
        uint256 vaultAfterExec = IERC20(USDG).balanceOf(address(vault));
        assertLt(vaultAfterExec, vaultBefore, "vault spent USDG on execute");
        uint256 wethHeld = IERC20(WETH).balanceOf(strategy);
        console2.log("Strategy WETH after exec:", wethHeld);
        assertGt(wethHeld, 0, "strategy holds WETH");

        // rebalanceDelta with empty reports (push mode reads latestRoundData).
        // The proposal lifecycle warps the clock ~2 days forward (voting +
        // review), which exceeds the feed's 24h heartbeat on a static fork. Re-
        // stamp the ETH/USD feed's `updatedAt` to the current clock with its
        // real answer so the price path (not the staleness gate — that has its
        // own test) is what's exercised here.
        (, int256 ethAnswer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData();
        vm.mockCall(
            CHAINLINK_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), ethAnswer, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );

        // Single 100% WETH slot already at target → no swaps, but this exercises
        // the push-feed price path (ETH/USD) end-to-end without reverting.
        bytes[] memory reports = new bytes[](1);
        vm.prank(agent);
        PortfolioStrategy(strategy).rebalanceDelta(reports);
        assertGt(IERC20(WETH).balanceOf(strategy), 0, "still holds WETH post-rebalance");
        vm.clearMockedCalls();

        // Warp past duration and settle.
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION);
        governor.settleProposal(proposalId);

        uint256 vaultAfterSettle = IERC20(USDG).balanceOf(address(vault));
        console2.log("Vault USDG after settle:", vaultAfterSettle);
        assertEq(IERC20(WETH).balanceOf(strategy), 0, "strategy fully unwound");
        if (vaultAfterSettle >= vaultBefore) {
            console2.log("NET PROFIT:", vaultAfterSettle - vaultBefore);
        } else {
            console2.log("NET LOSS (fees/slippage):", vaultBefore - vaultAfterSettle);
        }
    }

    // ── Mixed basket: 50% WETH (mode 0, v3) + 50% TSLA (mode 2, v4) ──

    // At the pinned block the direct v4 TSLA pool trades ~8.5% above the
    // Chainlink TSLA/USD answer before impact (5% fee tier + drift), so the
    // oracle-anchored rebalanceDelta floor needs headroom above that.
    uint256 constant MIXED_SLIPPAGE_BPS = 1200;
    // Smaller than TOTAL_AMOUNT: the direct USDG/TSLA 5% pool is thin, and the
    // execute-leg's own price impact at 2500 USDG pushes the pool far enough
    // above the Chainlink price that the oracle-floored rebalance buy can't
    // fill. 500 USDG/leg keeps self-impact well inside MIXED_SLIPPAGE_BPS.
    uint256 constant MIXED_TOTAL_AMOUNT = 1_000e6;

    function _buildMixedBasketInitData(uint256 totalAmt) internal view returns (bytes memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = TSLA;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000; // 50%
        weights[1] = 5_000; // 50%
        bytes[] memory extraData = new bytes[](2);
        extraData[0] = abi.encodePacked(uint8(0), abi.encode(FEE_500)); // v3 single-hop
        extraData[1] = abi.encodePacked(uint8(2), abi.encode(V4_FEE_50000, V4_TICK_SPACING_1000)); // v4 single-hop
        uint8[] memory priceDecimals = new uint8[](2);
        priceDecimals[0] = 8;
        priceDecimals[1] = 8;
        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = bytes32(uint256(uint160(CHAINLINK_ETH_USD_FEED)));
        feedIds[1] = bytes32(uint256(uint160(CHAINLINK_TSLA_USD_FEED)));

        return abi.encode(
            USDG,
            swapAdapter,
            address(0), // push mode
            tokens,
            weights,
            totalAmt,
            MIXED_SLIPPAGE_BPS,
            extraData,
            priceDecimals,
            feedIds
        );
    }

    function test_portfolio_mixedBasket_v3AndV4() public {
        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        console2.log("Vault USDG before:", vaultBefore);

        bytes memory initData = _buildMixedBasketInitData(MIXED_TOTAL_AMOUNT);
        address strategy = _cloneAndInit(template, initData);
        uint256 proposalId = _proposeVoteExecute(
            _buildExecCalls(strategy, MIXED_TOTAL_AMOUNT), _buildSettleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION
        );

        // Both legs bought: WETH via v3, TSLA via v4.
        uint256 wethHeld = IERC20(WETH).balanceOf(strategy);
        uint256 tslaHeld = IERC20(TSLA).balanceOf(strategy);
        console2.log("Strategy WETH after exec:", wethHeld);
        console2.log("Strategy TSLA after exec:", tslaHeld);
        assertGt(wethHeld, 0, "strategy holds WETH (v3 leg)");
        assertGt(tslaHeld, 0, "strategy holds TSLA (v4 leg)");
        assertLt(IERC20(USDG).balanceOf(address(vault)), vaultBefore, "vault spent USDG");

        // Re-stamp both push feeds fresh after the multi-day governance warp
        // (voting + review exceeds the 24h heartbeat on a static fork).
        (, int256 ethAnswer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData();
        vm.mockCall(
            CHAINLINK_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), ethAnswer, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
        (, int256 tslaAnswer,,,) = AggregatorV3Interface(CHAINLINK_TSLA_USD_FEED).latestRoundData();
        console2.log("Live TSLA/USD answer:", uint256(tslaAnswer));
        vm.mockCall(
            CHAINLINK_TSLA_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), tslaAnswer, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );

        // Both legs already at their 50% target → rebalanceDelta exercises both
        // push-feed price paths (v3 + v4 kinds) without reverting.
        bytes[] memory reports = new bytes[](2);
        vm.prank(agent);
        PortfolioStrategy(strategy).rebalanceDelta(reports);
        assertGt(IERC20(WETH).balanceOf(strategy), 0, "still holds WETH post-rebalance");
        assertGt(IERC20(TSLA).balanceOf(strategy), 0, "still holds TSLA post-rebalance");
        vm.clearMockedCalls();

        // Warp past duration and settle — both legs unwind back to USDG.
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION);
        governor.settleProposal(proposalId);

        assertEq(IERC20(WETH).balanceOf(strategy), 0, "WETH fully unwound");
        assertEq(IERC20(TSLA).balanceOf(strategy), 0, "TSLA fully unwound");
        assertEq(IERC20(USDG).balanceOf(strategy), 0, "no USDG stranded in strategy");

        uint256 vaultAfterSettle = IERC20(USDG).balanceOf(address(vault));
        console2.log("Vault USDG after settle:", vaultAfterSettle);
        // Two 5% v4 legs (in + out) dominate the roundtrip cost, so a net loss
        // is expected; assert the lifecycle completed with a sane balance rather
        // than a specific PnL sign.
        assertGt(vaultAfterSettle, 0, "vault holds USDG after settle");
        if (vaultAfterSettle >= vaultBefore) {
            console2.log("NET PROFIT:", vaultAfterSettle - vaultBefore);
        } else {
            console2.log("NET LOSS (fees/slippage):", vaultBefore - vaultAfterSettle);
        }
    }

    // ── Mixed basket, TSLA via mode-3 native path: 50% WETH (v3) + 50% TSLA
    //    (v4 multi-hop USDG→native→TSLA) ──

    function _tslaMode3Extra() internal pure returns (bytes memory) {
        // USDG →(native/USDG 500/10)→ native ETH →(TSLA/native 50000/1000)→ TSLA.
        PathHop[] memory hops = new PathHop[](2);
        hops[0] = PathHop({currency: address(0), fee: 500, tickSpacing: 10});
        hops[1] = PathHop({currency: TSLA, fee: V4_FEE_50000, tickSpacing: V4_TICK_SPACING_1000});
        return abi.encodePacked(uint8(3), abi.encode(hops));
    }

    function _buildMixedBasketMode3InitData(uint256 totalAmt) internal view returns (bytes memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = TSLA;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        bytes[] memory extraData = new bytes[](2);
        extraData[0] = abi.encodePacked(uint8(0), abi.encode(FEE_500)); // v3 single-hop
        extraData[1] = _tslaMode3Extra(); // v4 multi-hop via native
        uint8[] memory priceDecimals = new uint8[](2);
        priceDecimals[0] = 8;
        priceDecimals[1] = 8;
        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = bytes32(uint256(uint160(CHAINLINK_ETH_USD_FEED)));
        feedIds[1] = bytes32(uint256(uint160(CHAINLINK_TSLA_USD_FEED)));

        return abi.encode(
            USDG,
            swapAdapter,
            address(0),
            tokens,
            weights,
            totalAmt,
            MIXED_SLIPPAGE_BPS,
            extraData,
            priceDecimals,
            feedIds
        );
    }

    function test_portfolio_mixedBasket_tslaViaMode3Native() public {
        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        console2.log("Vault USDG before:", vaultBefore);

        bytes memory initData = _buildMixedBasketMode3InitData(MIXED_TOTAL_AMOUNT);
        address strategy = _cloneAndInit(template, initData);
        uint256 proposalId = _proposeVoteExecute(
            _buildExecCalls(strategy, MIXED_TOTAL_AMOUNT), _buildSettleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION
        );

        // WETH via v3, TSLA via v4 mode-3 (native intermediate).
        uint256 wethHeld = IERC20(WETH).balanceOf(strategy);
        uint256 tslaHeld = IERC20(TSLA).balanceOf(strategy);
        console2.log("Strategy WETH after exec:", wethHeld);
        console2.log("Strategy TSLA after exec (mode-3 native):", tslaHeld);
        assertGt(wethHeld, 0, "strategy holds WETH (v3 leg)");
        assertGt(tslaHeld, 0, "strategy holds TSLA (v4 mode-3 leg)");
        assertEq(strategy.balance, 0, "no native ETH stranded in strategy");
        assertLt(IERC20(USDG).balanceOf(address(vault)), vaultBefore, "vault spent USDG");

        // Re-stamp both push feeds fresh after the multi-day governance warp.
        (, int256 ethAnswer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData();
        vm.mockCall(
            CHAINLINK_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), ethAnswer, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
        (, int256 tslaAnswer,,,) = AggregatorV3Interface(CHAINLINK_TSLA_USD_FEED).latestRoundData();
        vm.mockCall(
            CHAINLINK_TSLA_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), tslaAnswer, vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );

        bytes[] memory reports = new bytes[](2);
        vm.prank(agent);
        PortfolioStrategy(strategy).rebalanceDelta(reports);
        assertGt(IERC20(WETH).balanceOf(strategy), 0, "still holds WETH post-rebalance");
        assertGt(IERC20(TSLA).balanceOf(strategy), 0, "still holds TSLA post-rebalance");
        vm.clearMockedCalls();

        // Warp past duration and settle — both legs unwind back to USDG (the TSLA
        // leg settles through the same mode-3 native path in reverse).
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION);
        governor.settleProposal(proposalId);

        assertEq(IERC20(WETH).balanceOf(strategy), 0, "WETH fully unwound");
        assertEq(IERC20(TSLA).balanceOf(strategy), 0, "TSLA fully unwound");
        assertEq(IERC20(USDG).balanceOf(strategy), 0, "no USDG stranded in strategy");
        assertEq(strategy.balance, 0, "no native ETH stranded post-settle");

        uint256 vaultAfterSettle = IERC20(USDG).balanceOf(address(vault));
        console2.log("Vault USDG after settle:", vaultAfterSettle);
        assertGt(vaultAfterSettle, 0, "vault holds USDG after settle");
        if (vaultAfterSettle >= vaultBefore) {
            console2.log("NET PROFIT:", vaultAfterSettle - vaultBefore);
        } else {
            console2.log("NET LOSS (fees/slippage):", vaultBefore - vaultAfterSettle);
        }
    }

    // ── Stale feed → rebalanceDelta reverts with StalePrice ──

    function test_portfolio_rebalanceDelta_staleFeed_reverts() public {
        (address strategy,) = _deployWethBasket();

        // Freeze the live ETH/USD answer/updatedAt, then warp beyond the 26h
        // staleness bound. `latestRoundData` on the fork returns a fixed
        // updatedAt; warping the block clock past it makes it stale.
        // via_ir rule: read the clock via vm.getBlockTimestamp() at each site.
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData();
        console2.log("Live ETH/USD answer:", uint256(answer));
        console2.log("Live ETH/USD updatedAt:", updatedAt);

        vm.warp(updatedAt + 26 hours + 1);

        bytes[] memory reports = new bytes[](1);
        vm.prank(agent);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        PortfolioStrategy(strategy).rebalanceDelta(reports);
    }

    // ── Per-slot packed max age (Fix A) — a 96h-packed slot survives a 48h
    //    staleness gap that kills the 26h default ──

    /// @dev 100% WETH basket whose ETH/USD slot packs a per-slot max age. Age 0
    ///      → default 26h; nonzero overrides it.
    function _deployWethBasketAged(uint256 ageSeconds) internal returns (address strategy, uint256 proposalId) {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = abi.encodePacked(uint8(0), abi.encode(FEE_500));
        uint8[] memory priceDecimals = new uint8[](1);
        priceDecimals[0] = 8;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32((ageSeconds << 160) | uint256(uint160(CHAINLINK_ETH_USD_FEED)));

        bytes memory initData = abi.encode(
            USDG,
            swapAdapter,
            address(0),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE_BPS,
            extraData,
            priceDecimals,
            feedIds
        );
        strategy = _cloneAndInit(template, initData);
        proposalId = _proposeVoteExecute(
            _buildExecCalls(strategy, TOTAL_AMOUNT), _buildSettleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION
        );
    }

    function test_portfolio_packedAge_survives48hGap() public {
        (address strategy,) = _deployWethBasketAged(96 hours);

        // Stamp the ETH/USD feed's updatedAt 48h behind the current clock — past
        // the 26h default but within the packed 96h age. rebalanceDelta prices
        // it without reverting.
        (, int256 ethAnswer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData();
        uint256 staleAt = vm.getBlockTimestamp() - 48 hours;
        vm.mockCall(
            CHAINLINK_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), ethAnswer, staleAt, staleAt, uint80(1))
        );

        bytes[] memory reports = new bytes[](1);
        vm.prank(agent);
        PortfolioStrategy(strategy).rebalanceDelta(reports);
        assertGt(IERC20(WETH).balanceOf(strategy), 0, "WETH priced via packed 96h age");
        vm.clearMockedCalls();
    }

    function test_portfolio_defaultAge_reverts48hGap() public {
        // Same 48h gap, but a default-age (0 → 26h) slot reverts StalePrice.
        (address strategy,) = _deployWethBasketAged(0);

        (, int256 ethAnswer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData();
        uint256 staleAt = vm.getBlockTimestamp() - 48 hours;
        vm.mockCall(
            CHAINLINK_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), ethAnswer, staleAt, staleAt, uint80(1))
        );

        bytes[] memory reports = new bytes[](1);
        vm.prank(agent);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        PortfolioStrategy(strategy).rebalanceDelta(reports);
        vm.clearMockedCalls();
    }

    // ── Feed sanity: every push feed wired into chains/4663.json is live,
    //    8-decimal, positive, and fresh within 26h ──

    function test_feedSanity_allChainlinkPushFeeds() public view {
        _assertFeedHealthy("ETH/USD", CHAINLINK_ETH_USD_FEED);
        _assertFeedHealthy("USDG/USD", CHAINLINK_USDG_USD_FEED);
    }

    function _assertFeedHealthy(string memory label, address feed) internal view {
        assertEq(AggregatorV3Interface(feed).decimals(), 8, string.concat(label, ": decimals != 8"));
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        assertGt(answer, 0, string.concat(label, ": answer <= 0"));
        assertGt(updatedAt, 0, string.concat(label, ": updatedAt == 0"));
        // Freshness against the fork clock — validates the MAX_PUSH_PRICE_AGE
        // (26h) assumption against live data.
        uint256 age = vm.getBlockTimestamp() - updatedAt;
        console2.log(label, "age (s):", age);
        assertLe(age, 26 hours, string.concat(label, ": stale beyond 26h"));
    }
}
