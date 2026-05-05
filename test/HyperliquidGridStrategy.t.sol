// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HyperliquidGridStrategy} from "../src/strategies/HyperliquidGridStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {FinalizeVariant} from "../src/hyperliquid/L1Write.sol";
import {MockSpotBalancePrecompile} from "./mocks/MockSpotBalancePrecompile.sol";
import {MockSpotBalanceCrediting} from "./mocks/MockSpotBalanceCrediting.sol";
import {MockAccountMarginSummaryPrecompile} from "./mocks/MockAccountMarginSummaryPrecompile.sol";

contract HyperliquidGridStrategyTest is Test {
    HyperliquidGridStrategy public template;
    HyperliquidGridStrategy public strategy;
    ERC20Mock public usdc;

    address public vault = makeAddr("vault");
    address public proposer = makeAddr("proposer");
    address public attacker = makeAddr("attacker");

    uint256 constant DEPOSIT = 10_000e6;
    uint32 constant LEVERAGE = 5;
    uint256 constant MAX_ORDER_SIZE = 100_000e6;
    uint32 constant MAX_ORDERS = 32;
    uint32 constant BTC_ASSET = 3;
    uint32 constant ETH_ASSET = 4;
    uint32 constant SOL_ASSET = 5;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);

        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(0x3333333333333333333333333333333333333333, address(cw).code);

        template = new HyperliquidGridStrategy();
        address payable clone = payable(Clones.clone(address(template)));
        strategy = HyperliquidGridStrategy(clone);

        uint32[] memory assets = new uint32[](3);
        assets[0] = BTC_ASSET;
        assets[1] = ETH_ASSET;
        assets[2] = SOL_ASSET;

        bytes memory initData = abi.encode(address(usdc), DEPOSIT, LEVERAGE, MAX_ORDER_SIZE, MAX_ORDERS, assets);
        strategy.initialize(vault, proposer, initData);

        usdc.mint(vault, 100_000e6);
        vm.prank(vault);
        usdc.approve(address(strategy), type(uint256).max);
    }

    // ── Initialization ──

    function test_initialize() public view {
        assertEq(strategy.vault(), vault);
        assertEq(strategy.proposer(), proposer);
        assertEq(address(strategy.asset()), address(usdc));
        assertEq(strategy.leverage(), LEVERAGE);
        assertEq(strategy.maxOrderSize(), MAX_ORDER_SIZE);
        assertEq(strategy.maxOrdersPerTick(), MAX_ORDERS);
        assertTrue(strategy.isAssetWhitelisted(BTC_ASSET));
        assertTrue(strategy.isAssetWhitelisted(ETH_ASSET));
        assertTrue(strategy.isAssetWhitelisted(SOL_ASSET));
        assertFalse(strategy.isAssetWhitelisted(99));
        // HC finalize runs during initialize via the slot-0 swap.
        assertTrue(strategy.hyperCoreFinalized());
    }

    function test_initialize_finalizesForHyperCore_atInitTime() public {
        address payable rawClone = payable(Clones.clone(address(template)));
        HyperliquidGridStrategy s = HyperliquidGridStrategy(rawClone);
        assertFalse(s.hyperCoreFinalized());

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_ASSET;
        bytes memory initData = abi.encode(address(usdc), DEPOSIT, LEVERAGE, MAX_ORDER_SIZE, MAX_ORDERS, assets);

        vm.expectEmit(true, true, true, true, address(s));
        emit HyperliquidGridStrategy.HyperCoreFinalized(0, FinalizeVariant.FirstStorageSlot, 0);
        s.initialize(vault, proposer, initData);

        assertTrue(s.hyperCoreFinalized());
        bytes32 slot0 = vm.load(address(s), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(slot0))), vault, "slot 0 must be restored to _vault");
    }

    function test_execute_pullsUsdcAndParksMargin() public {
        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        strategy.execute();
        assertEq(usdc.balanceOf(vault), vaultBefore - DEPOSIT);
        // After _execute, USDC was transferred to strategy then sent to HyperCore via precompile.
        // The MockCoreWriter just emits the event — strategy still holds the USDC in this mock.
        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT);
    }

    function _execAndPrep() internal {
        vm.prank(vault);
        strategy.execute();
    }

    function _gridOrder(uint32 ai, bool isBuy, uint64 px, uint64 sz, uint128 cloid)
        internal
        pure
        returns (HyperliquidGridStrategy.GridOrder memory)
    {
        return HyperliquidGridStrategy.GridOrder({assetIndex: ai, isBuy: isBuy, limitPx: px, sz: sz, cloid: cloid});
    }

    function test_updateParams_placeGrid_emitsOrderPlaced() public {
        _execAndPrep();
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](2);
        orders[0] = _gridOrder(BTC_ASSET, true, 76000_000000, 100, 1);
        orders[1] = _gridOrder(BTC_ASSET, false, 78000_000000, 100, 2);
        bytes memory data = abi.encode(uint8(1), orders);

        vm.expectEmit(false, false, false, true);
        emit HyperliquidGridStrategy.GridOrderPlaced(BTC_ASSET, true, 76000_000000, 100, 1);
        vm.prank(proposer);
        strategy.updateParams(data);
    }

    function test_updateParams_placeGrid_revertsOnTooManyOrders() public {
        _execAndPrep();
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](33);
        for (uint256 i = 0; i < 33; i++) {
            orders[i] = _gridOrder(BTC_ASSET, true, 76000_000000, 100, uint128(i));
        }
        bytes memory data = abi.encode(uint8(1), orders);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(HyperliquidGridStrategy.TooManyOrders.selector, 33, 32));
        strategy.updateParams(data);
    }

    function test_updateParams_placeGrid_revertsOnUnwhitelistedAsset() public {
        _execAndPrep();
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](1);
        orders[0] = _gridOrder(99, true, 76000_000000, 100, 1);
        bytes memory data = abi.encode(uint8(1), orders);
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(HyperliquidGridStrategy.AssetNotWhitelisted.selector, uint32(99)));
        strategy.updateParams(data);
    }

    function test_updateParams_cancelAll_emitsCancelled() public {
        _execAndPrep();
        uint128[] memory cloids = new uint128[](2);
        cloids[0] = 1;
        cloids[1] = 2;
        bytes memory data = abi.encode(uint8(2), BTC_ASSET, cloids);

        vm.expectEmit(false, false, false, true);
        emit HyperliquidGridStrategy.GridOrderCancelled(BTC_ASSET, 1);
        vm.prank(proposer);
        strategy.updateParams(data);
    }

    function test_updateParams_cancelAndPlace_atomicRebalance() public {
        _execAndPrep();
        uint128[] memory cloids = new uint128[](1);
        cloids[0] = 1;
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](1);
        orders[0] = _gridOrder(BTC_ASSET, true, 77000_000000, 100, 10);
        bytes memory data = abi.encode(uint8(3), BTC_ASSET, cloids, orders);

        vm.prank(proposer);
        strategy.updateParams(data);
    }

    function test_updateParams_revertsIfNotProposer() public {
        _execAndPrep();
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](1);
        orders[0] = _gridOrder(BTC_ASSET, true, 76000_000000, 100, 1);
        bytes memory data = abi.encode(uint8(1), orders);
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.updateParams(data);
    }

    function test_updateParams_invalidAction_reverts() public {
        _execAndPrep();
        bytes memory data = abi.encode(uint8(99));
        vm.prank(proposer);
        vm.expectRevert(HyperliquidGridStrategy.InvalidAction.selector);
        strategy.updateParams(data);
    }

    function test_settle_marksSettled() public {
        _execAndPrep();
        vm.prank(vault);
        strategy.settle();
        assertTrue(strategy.settled());
    }

    function test_sweepToVault_pushesUsdcBack() public {
        _execAndPrep();
        vm.prank(vault);
        strategy.settle();
        // Strategy still holds DEPOSIT in mock (USD class transfer is just an event).
        uint256 vaultBefore = usdc.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdc.balanceOf(vault), vaultBefore + DEPOSIT);
        assertGt(strategy.cumulativeSwept(), 0);
    }

    function test_sweepToVault_revertsIfNotSettled() public {
        _execAndPrep();
        vm.expectRevert(HyperliquidGridStrategy.NotSweepable.selector);
        strategy.sweepToVault();
    }

    function test_updateParams_placeGrid_revertsOnOrderTooLarge() public {
        _execAndPrep();
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](1);
        // Order notional = sz * limitPx / 1e6. MAX_ORDER_SIZE = 100_000e6 = 1e11.
        // sz=1000, limitPx=2e14 → notional = 1000 * 2e14 / 1e6 = 2e11 (200k USD), exceeds 100k.
        orders[0] = _gridOrder(BTC_ASSET, true, 200_000_000_000_000, 1000, 1);
        bytes memory data = abi.encode(uint8(1), orders);
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(HyperliquidGridStrategy.OrderTooLarge.selector, 200_000e6, MAX_ORDER_SIZE)
        );
        strategy.updateParams(data);
    }

    // ── HyperCore finalization ──

    function test_finalizeForHyperCore_emitsAndForwardsToL1Write() public {
        // init already finalized with default variant; an additional proposer
        // call (e.g. registering a non-USDC token) still emits and updates.
        assertTrue(strategy.hyperCoreFinalized());
        vm.expectEmit(true, true, true, true, address(strategy));
        emit HyperliquidGridStrategy.HyperCoreFinalized(7, FinalizeVariant.CustomStorageSlot, 42);
        vm.prank(proposer);
        strategy.finalizeForHyperCore(7, FinalizeVariant.CustomStorageSlot, 42);
        assertTrue(strategy.hyperCoreFinalized());
    }

    function test_finalizeForHyperCore_revertsIfNotProposer() public {
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.finalizeForHyperCore(0, FinalizeVariant.FirstStorageSlot, 0);
    }

    function test_execute_emitsNoFinalize_sinceInitAlreadyDidIt() public {
        // Auto-finalize moved from _execute to _initialize via the slot-0
        // swap, so executing the proposal must NOT fire any
        // HyperCoreFinalized event (init already did, and there is no
        // self-heal path left).
        vm.recordLogs();
        vm.prank(vault);
        strategy.execute();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("HyperCoreFinalized(uint64,uint8,uint64)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(
                entries[i].topics.length == 0 || entries[i].topics[0] != sig,
                "_execute must not fire HyperCoreFinalized; init owns that"
            );
        }
    }

    function test_execute_succeedsWhenHyperCoreSpotIsCredited() public {
        // Etch a stateful mock at the HC spot-balance precompile that mirrors
        // the strategy's USDC balance into HC spot (scaled 6→8 decimals). Pre-pull
        // reads 0; post-pull reads DEPOSIT * 100, which exceeds ntl=DEPOSIT — so
        // the spot-credit gate must NOT revert.
        MockSpotBalanceCrediting m = new MockSpotBalanceCrediting();
        vm.etch(0x0000000000000000000000000000000000000801, address(m).code);
        // Seed the etched contract's slot 0 with the USDC address so `fallback`
        // can read balanceOf via the live token.
        vm.store(
            0x0000000000000000000000000000000000000801, bytes32(uint256(0)), bytes32(uint256(uint160(address(usdc))))
        );

        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        strategy.execute();
        assertEq(usdc.balanceOf(vault), vaultBefore - DEPOSIT);
        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT);
    }

    function test_execute_revertsWhenHyperCoreSpotNotCredited() public {
        MockSpotBalancePrecompile spot = new MockSpotBalancePrecompile();
        spot.setSpot(0, 0, 0);
        vm.etch(0x0000000000000000000000000000000000000801, address(spot).code);

        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperliquidGridStrategy.HyperCoreSpotCreditFailed.selector, uint64(0), uint64(0), uint64(DEPOSIT)
            )
        );
        strategy.execute();
    }

    function test_sweepToVault_repeatableForPartialArrivals() public {
        _execAndPrep();
        vm.prank(vault);
        strategy.settle();
        // First sweep: full balance (DEPOSIT)
        strategy.sweepToVault();
        assertEq(strategy.cumulativeSwept(), DEPOSIT);
        // Simulate more USDC arriving from async transfer
        usdc.mint(address(strategy), 5_000e6);
        // Second sweep: should succeed without minReturn check
        uint256 vaultBefore = usdc.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdc.balanceOf(vault), vaultBefore + 5_000e6);
    }

    // ── On-chain CLOID tracking & self-cancel ──

    function _placeFourBtcOrders() internal {
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](4);
        orders[0] = _gridOrder(BTC_ASSET, true, 76000_000000, 100, 11);
        orders[1] = _gridOrder(BTC_ASSET, true, 75000_000000, 100, 12);
        orders[2] = _gridOrder(BTC_ASSET, false, 78000_000000, 100, 13);
        orders[3] = _gridOrder(BTC_ASSET, false, 79000_000000, 100, 14);
        bytes memory data = abi.encode(uint8(1), orders);
        vm.prank(proposer);
        strategy.updateParams(data);
    }

    function test_placeOrders_tracksLiveCloids() public {
        _execAndPrep();
        _placeFourBtcOrders();
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 4);
        uint128[] memory live = strategy.liveCloids(BTC_ASSET);
        assertEq(live.length, 4);
        // Order preserved by push order
        assertEq(uint256(live[0]), 11);
        assertEq(uint256(live[3]), 14);
    }

    function test_cancelOrders_untracksCloids() public {
        _execAndPrep();
        _placeFourBtcOrders();
        uint128[] memory cancelCloids = new uint128[](2);
        cancelCloids[0] = 12;
        cancelCloids[1] = 14;
        bytes memory data = abi.encode(uint8(2), BTC_ASSET, cancelCloids);
        vm.prank(proposer);
        strategy.updateParams(data);
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 2);
    }

    function test_cancelOrders_unknownCloid_isNoOp() public {
        _execAndPrep();
        _placeFourBtcOrders();
        uint128[] memory cancelCloids = new uint128[](1);
        cancelCloids[0] = 999; // never placed
        bytes memory data = abi.encode(uint8(2), BTC_ASSET, cancelCloids);
        vm.prank(proposer);
        // Should not revert; tracker unchanged.
        strategy.updateParams(data);
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 4);
    }

    function test_placeOrders_repeatedCloid_idempotent() public {
        _execAndPrep();
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](2);
        orders[0] = _gridOrder(BTC_ASSET, true, 76000_000000, 100, 42);
        orders[1] = _gridOrder(BTC_ASSET, true, 76000_000000, 100, 42);
        bytes memory data = abi.encode(uint8(1), orders);
        vm.prank(proposer);
        strategy.updateParams(data);
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 1);
    }

    function test_settle_selfCancelsTrackedCloids() public {
        _execAndPrep();
        _placeFourBtcOrders();
        // Sanity
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 4);

        vm.recordLogs();
        vm.prank(vault);
        strategy.settle();

        // Tracker drained for all assets
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 0);
        assertEq(strategy.liveCloidsLength(ETH_ASSET), 0);
        assertEq(strategy.liveCloidsLength(SOL_ASSET), 0);

        // GridOrderCancelled fired for each placed cloid
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("GridOrderCancelled(uint32,uint128)");
        uint256 found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                found++;
            }
        }
        assertEq(found, 4, "expected one cancel event per tracked cloid");
    }

    function test_cancelAndPlace_replacesTrackedCloid() public {
        _execAndPrep();
        _placeFourBtcOrders();

        uint128[] memory cancelCloids = new uint128[](1);
        cancelCloids[0] = 11;
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](1);
        orders[0] = _gridOrder(BTC_ASSET, true, 75500_000000, 100, 21);
        bytes memory data = abi.encode(uint8(3), BTC_ASSET, cancelCloids, orders);

        vm.prank(proposer);
        strategy.updateParams(data);

        // 4 placed - 1 cancelled + 1 replaced = 4
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 4);
    }

    function test_placeOrders_noCloid_isNotTracked() public {
        _execAndPrep();
        HyperliquidGridStrategy.GridOrder[] memory orders = new HyperliquidGridStrategy.GridOrder[](1);
        orders[0] = _gridOrder(BTC_ASSET, true, 76000_000000, 100, 0); // NO_CLOID
        bytes memory data = abi.encode(uint8(1), orders);
        vm.prank(proposer);
        strategy.updateParams(data);
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 0);
    }

    // ── Live NAV via positionValue ──

    function _etchAccountMarginSummary() internal returns (MockAccountMarginSummaryPrecompile) {
        MockAccountMarginSummaryPrecompile m = new MockAccountMarginSummaryPrecompile();
        vm.etch(0x000000000000000000000000000000000000080F, address(m).code);
        return MockAccountMarginSummaryPrecompile(0x000000000000000000000000000000000000080F);
    }

    function test_positionValue_returnsAccountMarginEquity() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(12_345e6))), 0, 0, 0);
        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        assertEq(value, 12_345e6);
    }

    function test_positionValue_clampsNegativeEquityToZero() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(-1_000), 0, 0, 0);
        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        assertEq(value, 0);
    }

    function test_positionValue_invalidWhenPrecompileMissing() public {
        _execAndPrep();
        // No etch at 0x...080F
        (uint256 value, bool valid) = strategy.positionValue();
        assertFalse(valid);
        assertEq(value, 0);
    }

    function test_positionValue_invalidBeforeExecute() public {
        // BaseStrategy gates `_positionValue` behind State.Executed. Without
        // calling execute, valid must be false even if the precompile is etched.
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(99_999e6))), 0, 0, 0);
        (uint256 value, bool valid) = strategy.positionValue();
        assertFalse(valid);
        assertEq(value, 0);
    }

    // ── initiateReturn / _initiateClassTransfer ──

    function test_initiateReturn_revertsIfNotSettled() public {
        _execAndPrep();
        vm.expectRevert(HyperliquidGridStrategy.NotSweepable.selector);
        strategy.initiateReturn();
    }

    function test_settle_skipsClassTransferWhenNoPrecompile() public {
        // No AccountMarginSummary precompile etched → _initiateClassTransfer no-ops.
        // Settle must still complete and mark settled=true.
        _execAndPrep();
        vm.recordLogs();
        vm.prank(vault);
        strategy.settle();
        assertTrue(strategy.settled());
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0);
    }

    function test_settle_usesPrecompileAmountForClassTransfer() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        int64 equity = int64(int256(uint256(9_800e6)));
        m.setSummary(equity, 0, 0, 0);

        vm.recordLogs();
        vm.prank(vault);
        strategy.settle();

        (bool found, uint64 ntl, bool toPerp) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "expected class transfer RawAction");
        assertEq(ntl, uint64(equity));
        assertFalse(toPerp);
    }

    function test_initiateReturn_resweepsResidualPerp() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(9_800e6))), 0, 0, 0);
        vm.prank(vault);
        strategy.settle();

        // Simulate residual equity left in perp after IOC slippage.
        m.setSummary(int64(int256(uint256(200e6))), 0, 0, 0);
        vm.recordLogs();
        strategy.initiateReturn();
        (bool found, uint64 ntl,) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found);
        assertEq(ntl, uint64(200e6));
    }

    // ── Helpers ──

    bytes4 constant CLASS_TRANSFER_ACTION = 0x01000007;

    function _countClassTransferLogs(Vm.Log[] memory logs) internal view returns (uint256 count) {
        bytes32 sig = keccak256("RawAction(address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            bytes memory raw = abi.decode(logs[i].data, (bytes));
            if (raw.length >= 4 && bytes4(raw) == CLASS_TRANSFER_ACTION) count++;
        }
    }

    function _decodeClassTransfer(Vm.Log[] memory logs) internal view returns (bool found, uint64 ntl, bool toPerp) {
        bytes32 sig = keccak256("RawAction(address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            bytes memory raw = abi.decode(logs[i].data, (bytes));
            if (raw.length < 4 || bytes4(raw) != CLASS_TRANSFER_ACTION) continue;
            bytes memory payload = new bytes(raw.length - 4);
            for (uint256 j = 0; j < payload.length; j++) {
                payload[j] = raw[j + 4];
            }
            (ntl, toPerp) = abi.decode(payload, (uint64, bool));
            return (true, ntl, toPerp);
        }
    }
}
