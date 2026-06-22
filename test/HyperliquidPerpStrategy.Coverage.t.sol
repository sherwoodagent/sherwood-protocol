// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HyperliquidPerpStrategy} from "../src/strategies/HyperliquidPerpStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {Position, SpotBalance, AccountMarginSummary} from "../src/hyperliquid/L1Read.sol";

/// @notice Coverage-focused tests for branches not exercised by HyperliquidPerpStrategyTest.
///         Covers short actions, multi-asset actions, multi-asset settle path,
///         L1Read view functions, and PositionTooLarge for non-long branches.
contract HyperliquidPerpStrategyCoverageTest is Test {
    HyperliquidPerpStrategy public template;
    HyperliquidPerpStrategy public strategy;
    ERC20Mock public usdc;

    address public vault = makeAddr("vault");
    address public proposer = makeAddr("proposer");
    address public attacker = makeAddr("attacker");

    uint256 constant DEPOSIT = 10_000e6;
    uint32 constant PERP_ASSET = 3; // ETH
    uint32 constant LEVERAGE = 5;
    uint256 constant MAX_POSITION = 100_000e6;
    uint32 constant MAX_TRADES = 50;

    // Precompile addresses (mirrored from L1Read for vm.etch targets).
    address constant POSITION2_PRECOMPILE = 0x0000000000000000000000000000000000000813;
    address constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address constant MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);

        // Etch MockCoreWriter at the L1Write precompile.
        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(0x3333333333333333333333333333333333333333, address(cw).code);

        template = new HyperliquidPerpStrategy();
        address payable clone = payable(Clones.clone(address(template)));
        strategy = HyperliquidPerpStrategy(clone);

        bytes memory initData = abi.encode(address(usdc), DEPOSIT, PERP_ASSET, LEVERAGE, MAX_POSITION, MAX_TRADES);
        strategy.initialize(vault, proposer, initData);

        usdc.mint(vault, 100_000e6);
        vm.prank(vault);
        usdc.approve(address(strategy), type(uint256).max);
    }

    function _executeFirst() internal {
        vm.prank(vault);
        strategy.execute();
    }

    // ==================== ACTION_OPEN_SHORT (4) ====================

    function test_updateParams_openShort() public {
        _executeFirst();
        // (action, limitPx, sz, stopLossPx, stopLossSz)
        bytes memory data = abi.encode(uint8(4), uint64(3000e6), uint64(1e6), uint64(3200e6), uint64(1e6));
        vm.prank(proposer);
        strategy.updateParams(data);
        assertTrue(strategy.hasActiveStopLoss());
    }

    function test_updateParams_openShort_positionTooLarge_reverts() public {
        // Strategy with maxPositionSize = 1000e6
        address payable clone = payable(Clones.clone(address(template)));
        HyperliquidPerpStrategy s = HyperliquidPerpStrategy(clone);
        s.initialize(
            vault, proposer, abi.encode(address(usdc), DEPOSIT, PERP_ASSET, LEVERAGE, uint256(1000e6), MAX_TRADES)
        );
        usdc.mint(vault, DEPOSIT);
        vm.prank(vault);
        usdc.approve(address(s), type(uint256).max);
        vm.prank(vault);
        s.execute();

        // 3000e6 * 1e6 / 1e6 = 3000e6 > 1000e6
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(HyperliquidPerpStrategy.PositionTooLarge.selector, 3000e6, 1000e6));
        s.updateParams(abi.encode(uint8(4), uint64(3000e6), uint64(1e6), uint64(3200e6), uint64(1e6)));
    }

    function test_updateParams_openShort_cancelsExistingStopLoss() public {
        _executeFirst();

        // Open long first
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(1), uint64(3000e6), uint64(1e6), uint64(2800e6), uint64(1e6)));
        assertTrue(strategy.hasActiveStopLoss());

        // Open short — cancels the previous SL and stamps a new one
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(4), uint64(3000e6), uint64(1e6), uint64(3200e6), uint64(1e6)));
        assertTrue(strategy.hasActiveStopLoss());
    }

    // ==================== ACTION_UPDATE_STOP_LOSS_SHORT (5) ====================

    function test_updateParams_updateStopLossShort() public {
        _executeFirst();

        // Open short first to have an active stop loss
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(4), uint64(3000e6), uint64(1e6), uint64(3200e6), uint64(1e6)));

        // Update SL via action=5 (reduce-only buy)
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(5), uint64(3100e6), uint64(1e6)));
        assertTrue(strategy.hasActiveStopLoss());
    }

    function test_updateParams_updateStopLossShort_withoutActiveSL() public {
        // No prior stop loss — _cancelCurrentStopLoss is a no-op, new SL stamped.
        _executeFirst();
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(5), uint64(3100e6), uint64(1e6)));
        assertTrue(strategy.hasActiveStopLoss());
    }

    // ==================== ACTION_OPEN_LONG_MULTI (6) ====================

    function test_updateParams_openLongMulti() public {
        _executeFirst();
        uint32 BTC_ASSET = 7;
        // (action, assetIndex, limitPx, sz, stopLossPx, stopLossSz)
        bytes memory data =
            abi.encode(uint8(6), uint32(BTC_ASSET), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5));
        vm.prank(proposer);
        strategy.updateParams(data);
        assertTrue(strategy.hasActiveStopLoss());
        assertEq(strategy.perpAssetIndex(), BTC_ASSET); // updated to multi-asset index
        assertTrue(strategy.assetTraded(BTC_ASSET));
        assertEq(strategy.tradedAssets(0), BTC_ASSET);
    }

    function test_updateParams_openLongMulti_dedupes() public {
        _executeFirst();
        uint32 BTC_ASSET = 7;
        bytes memory data =
            abi.encode(uint8(6), uint32(BTC_ASSET), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5));

        vm.prank(proposer);
        strategy.updateParams(data);
        vm.prank(proposer);
        strategy.updateParams(data);

        // Second call must NOT push the asset twice. Reading index 1 should revert.
        assertEq(strategy.tradedAssets(0), BTC_ASSET);
        vm.expectRevert();
        strategy.tradedAssets(1);
    }

    function test_updateParams_openLongMulti_positionTooLarge_reverts() public {
        // maxPositionSize = 1000e6 → 60000e6 * 1e5 / 1e6 = 6_000_000e6 > 1000e6
        address payable clone = payable(Clones.clone(address(template)));
        HyperliquidPerpStrategy s = HyperliquidPerpStrategy(clone);
        s.initialize(
            vault, proposer, abi.encode(address(usdc), DEPOSIT, PERP_ASSET, LEVERAGE, uint256(1000e6), MAX_TRADES)
        );
        usdc.mint(vault, DEPOSIT);
        vm.prank(vault);
        usdc.approve(address(s), type(uint256).max);
        vm.prank(vault);
        s.execute();

        // 60000e6 * 1e5 / 1e6 = 6_000_000_000 (6e9) > 1000e6
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(HyperliquidPerpStrategy.PositionTooLarge.selector, uint256(6e9), uint256(1000e6))
        );
        s.updateParams(abi.encode(uint8(6), uint32(7), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5)));
    }

    // ==================== ACTION_OPEN_SHORT_MULTI (7) ====================

    function test_updateParams_openShortMulti() public {
        _executeFirst();
        uint32 SOL_ASSET = 11;
        bytes memory data =
            abi.encode(uint8(7), uint32(SOL_ASSET), uint64(150e6), uint64(10e6), uint64(160e6), uint64(10e6));
        vm.prank(proposer);
        strategy.updateParams(data);
        assertTrue(strategy.hasActiveStopLoss());
        assertEq(strategy.perpAssetIndex(), SOL_ASSET);
        assertTrue(strategy.assetTraded(SOL_ASSET));
    }

    function test_updateParams_openMultiTwoAssets_tracksBoth() public {
        _executeFirst();

        vm.prank(proposer);
        strategy.updateParams(
            abi.encode(uint8(6), uint32(7), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5))
        );
        vm.prank(proposer);
        strategy.updateParams(
            abi.encode(uint8(7), uint32(11), uint64(150e6), uint64(10e6), uint64(160e6), uint64(10e6))
        );

        assertTrue(strategy.assetTraded(7));
        assertTrue(strategy.assetTraded(11));
        assertEq(strategy.tradedAssets(0), 7);
        assertEq(strategy.tradedAssets(1), 11);
        assertEq(strategy.perpAssetIndex(), 11); // last write wins
    }

    // ==================== ACTION_CLOSE_MULTI (8) ====================

    function test_updateParams_closeMulti_long() public {
        _executeFirst();

        // Open long-multi first
        vm.prank(proposer);
        strategy.updateParams(
            abi.encode(uint8(6), uint32(7), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5))
        );
        assertTrue(strategy.hasActiveStopLoss());

        // Close it: isBuy=false closes a long
        // (action, assetIndex, isBuy, limitPx, sz)
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(8), uint32(7), false, uint64(61000e6), uint64(1e5)));
        assertFalse(strategy.hasActiveStopLoss());
    }

    function test_updateParams_closeMulti_short() public {
        _executeFirst();

        // Open short-multi first
        vm.prank(proposer);
        strategy.updateParams(
            abi.encode(uint8(7), uint32(11), uint64(150e6), uint64(10e6), uint64(160e6), uint64(10e6))
        );

        // Close: isBuy=true closes a short
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(8), uint32(11), true, uint64(149e6), uint64(10e6)));
        assertFalse(strategy.hasActiveStopLoss());
    }

    function test_updateParams_closeMulti_withoutOpen_succeeds() public {
        // No on-chain position tracking — proposer responsible. HC reduce-only no-ops.
        _executeFirst();
        vm.prank(proposer);
        strategy.updateParams(abi.encode(uint8(8), uint32(7), false, uint64(61000e6), uint64(1e5)));
    }

    // ==================== _settle MULTI-ASSET PATH ====================

    function test_settle_multiAsset_closesAllTradedAssets() public {
        _executeFirst();

        // Trade two distinct assets via multi actions.
        vm.prank(proposer);
        strategy.updateParams(
            abi.encode(uint8(6), uint32(7), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5))
        );
        vm.prank(proposer);
        strategy.updateParams(
            abi.encode(uint8(7), uint32(11), uint64(150e6), uint64(10e6), uint64(160e6), uint64(10e6))
        );

        // Settle should iterate tradedAssets and force-close orders for both.
        // Sherlock run #3 #3: settle requires initiateReturn() first.
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();
        assertTrue(strategy.settled());
        assertFalse(strategy.hasActiveStopLoss());
    }

    function test_settle_multiAsset_singleAsset() public {
        // Just one asset traded via multi → still uses the loop path.
        _executeFirst();
        vm.prank(proposer);
        strategy.updateParams(
            abi.encode(uint8(6), uint32(7), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5))
        );

        // Sherlock run #3 #3: settle requires initiateReturn() first.
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();
        assertTrue(strategy.settled());
    }

    // ==================== L1Read VIEW FUNCTIONS ====================

    function test_getPosition_returnsPrecompileData() public {
        // Etch a fallback that returns an abi-encoded Position.
        Position memory pos =
            Position({szi: int64(1e6), entryNtl: 3000e6, isolatedRawUsd: int64(0), leverage: 5, isIsolated: false});
        vm.mockCall(POSITION2_PRECOMPILE, abi.encode(address(strategy), uint32(PERP_ASSET)), abi.encode(pos));

        Position memory got = strategy.getPosition();
        assertEq(got.szi, int64(1e6));
        assertEq(got.entryNtl, 3000e6);
        assertEq(got.leverage, 5);
        assertFalse(got.isIsolated);
    }

    function test_getPosition_precompileFailure_reverts() public {
        // No mock + no etch → staticcall to empty address returns success=true with empty data,
        // which causes abi.decode to revert. Acceptable failure mode for the view.
        // Etch a reverting contract to force the require(success) path.
        vm.etch(POSITION2_PRECOMPILE, hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT
        vm.expectRevert();
        strategy.getPosition();
    }

    function test_getSpotBalance_returnsPrecompileData() public {
        SpotBalance memory bal = SpotBalance({total: uint64(5000e8), hold: uint64(0), entryNtl: uint64(4000e8)});
        vm.mockCall(SPOT_BALANCE_PRECOMPILE, abi.encode(address(strategy), uint64(0)), abi.encode(bal));

        SpotBalance memory got = strategy.getSpotBalance();
        assertEq(got.total, uint64(5000e8));
        assertEq(got.hold, uint64(0));
        assertEq(got.entryNtl, uint64(4000e8));
    }

    function test_getMarginSummary_returnsPrecompileData() public {
        AccountMarginSummary memory summary = AccountMarginSummary({
            accountValue: int64(10000e8), marginUsed: 2000e8, ntlPos: 8000e8, rawUsd: int64(10000e8)
        });
        vm.mockCall(MARGIN_SUMMARY_PRECOMPILE, abi.encode(uint32(0), address(strategy)), abi.encode(summary));

        AccountMarginSummary memory got = strategy.getMarginSummary();
        assertEq(got.accountValue, int64(10000e8));
        assertEq(got.marginUsed, 2000e8);
        assertEq(got.ntlPos, 8000e8);
        assertEq(got.rawUsd, int64(10000e8));
    }

    function test_getMarginSummary_precompileFailure_reverts() public {
        vm.etch(MARGIN_SUMMARY_PRECOMPILE, hex"60006000fd"); // revert
        vm.expectRevert();
        strategy.getMarginSummary();
    }

    // ==================== AUTH ON MULTI/SHORT ACTIONS ====================

    function test_updateParams_openShort_notProposer_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.updateParams(abi.encode(uint8(4), uint64(3000e6), uint64(1e6), uint64(3200e6), uint64(1e6)));
    }

    function test_updateParams_closeMulti_notProposer_reverts() public {
        _executeFirst();
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.updateParams(abi.encode(uint8(8), uint32(7), false, uint64(61000e6), uint64(1e5)));
    }

    function test_updateParams_openShort_notExecuted_reverts() public {
        // strategy is Pending — updateParams should hit BaseStrategy's NotExecuted before action dispatch.
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.updateParams(abi.encode(uint8(4), uint64(3000e6), uint64(1e6), uint64(3200e6), uint64(1e6)));
    }

    // ==================== DAILY TRADE COUNTER (action >= 1 path) ====================

    function test_maxTradesPerDay_appliesToShortActions() public {
        // maxTradesPerDay = 1
        address payable clone = payable(Clones.clone(address(template)));
        HyperliquidPerpStrategy s = HyperliquidPerpStrategy(clone);
        s.initialize(vault, proposer, abi.encode(address(usdc), DEPOSIT, PERP_ASSET, LEVERAGE, MAX_POSITION, uint32(1)));
        usdc.mint(vault, DEPOSIT);
        vm.prank(vault);
        usdc.approve(address(s), type(uint256).max);
        vm.prank(vault);
        s.execute();

        // Trade 1 — short open
        vm.prank(proposer);
        s.updateParams(abi.encode(uint8(4), uint64(3000e6), uint64(1e6), uint64(3200e6), uint64(1e6)));

        // Trade 2 — short stop-loss update — exceeds limit
        vm.prank(proposer);
        vm.expectRevert(HyperliquidPerpStrategy.MaxTradesExceeded.selector);
        s.updateParams(abi.encode(uint8(5), uint64(3100e6), uint64(1e6)));
    }

    function test_maxTradesPerDay_appliesToMultiActions() public {
        address payable clone = payable(Clones.clone(address(template)));
        HyperliquidPerpStrategy s = HyperliquidPerpStrategy(clone);
        s.initialize(vault, proposer, abi.encode(address(usdc), DEPOSIT, PERP_ASSET, LEVERAGE, MAX_POSITION, uint32(1)));
        usdc.mint(vault, DEPOSIT);
        vm.prank(vault);
        usdc.approve(address(s), type(uint256).max);
        vm.prank(vault);
        s.execute();

        vm.prank(proposer);
        s.updateParams(abi.encode(uint8(6), uint32(7), uint64(60000e6), uint64(1e5), uint64(58000e6), uint64(1e5)));

        vm.prank(proposer);
        vm.expectRevert(HyperliquidPerpStrategy.MaxTradesExceeded.selector);
        s.updateParams(abi.encode(uint8(8), uint32(7), false, uint64(61000e6), uint64(1e5)));
    }

    // ==================== ZERO-DEPOSIT INIT EDGE ====================

    function test_initialize_zeroMaxPosition_reverts() public {
        address payable clone = payable(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(usdc), DEPOSIT, PERP_ASSET, LEVERAGE, uint256(0), MAX_TRADES);
        vm.expectRevert(HyperliquidPerpStrategy.InvalidAmount.selector);
        HyperliquidPerpStrategy(clone).initialize(vault, proposer, initData);
    }

    function test_initialize_zeroMaxTrades_reverts() public {
        address payable clone = payable(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(usdc), DEPOSIT, PERP_ASSET, LEVERAGE, MAX_POSITION, uint32(0));
        vm.expectRevert(HyperliquidPerpStrategy.InvalidAmount.selector);
        HyperliquidPerpStrategy(clone).initialize(vault, proposer, initData);
    }
}
