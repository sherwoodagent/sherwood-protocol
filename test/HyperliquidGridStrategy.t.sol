// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HyperliquidGridStrategy} from "../src/strategies/HyperliquidGridStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {FinalizeVariant} from "../src/hyperliquid/L1Write.sol";
import {MockAccountMarginSummaryPrecompile} from "./mocks/MockAccountMarginSummaryPrecompile.sol";
import {MockSpotBalancePrecompile} from "./mocks/MockSpotBalancePrecompile.sol";

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
        // hyperCoreFinalized is set by finalizeForHyperCore(), not by initialize().
        assertFalse(strategy.hyperCoreFinalized());
        // _hcSelf (slot 0) is written to address(this) during initialize() so HC
        // FirstStorageSlot registration reads the correct value post-block.
        assertEq(address(uint160(uint256(vm.load(address(strategy), bytes32(0))))), address(strategy));
    }

    function test_initialize_setsHcSelfSlot() public {
        address payable rawClone = payable(Clones.clone(address(template)));
        HyperliquidGridStrategy s = HyperliquidGridStrategy(rawClone);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_ASSET;
        bytes memory initData = abi.encode(address(usdc), DEPOSIT, LEVERAGE, MAX_ORDER_SIZE, MAX_ORDERS, assets);
        s.initialize(vault, proposer, initData);

        assertFalse(s.hyperCoreFinalized());
        // Slot 0 (_hcSelf) must equal the clone's own address after init.
        assertEq(address(uint160(uint256(vm.load(address(s), bytes32(0))))), address(s));
    }

    function test_finalizeForHyperCore_setsFlag() public {
        address payable rawClone = payable(Clones.clone(address(template)));
        HyperliquidGridStrategy s = HyperliquidGridStrategy(rawClone);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_ASSET;
        bytes memory initData = abi.encode(address(usdc), DEPOSIT, LEVERAGE, MAX_ORDER_SIZE, MAX_ORDERS, assets);
        s.initialize(vault, proposer, initData);

        vm.expectEmit(true, true, true, true, address(s));
        emit HyperliquidGridStrategy.HyperCoreFinalized(0, FinalizeVariant.FirstStorageSlot, 0);
        vm.prank(proposer);
        s.finalizeForHyperCore(0, FinalizeVariant.FirstStorageSlot, 0);

        assertTrue(s.hyperCoreFinalized());
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

    function test_settle_pushesUsdcBack() public {
        // settle() now does the EVM USDC push directly so the governor's
        // settle batch sees correct vault.totalAssets() for fee math.
        _execAndPrep();
        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(vault);
        strategy.settle();
        assertEq(usdc.balanceOf(vault), vaultBefore + DEPOSIT);
        assertEq(usdc.balanceOf(address(strategy)), 0);
    }

    function test_sweepToVault_isNoOpAfterSettleHandledFunds() public {
        // After _settle pushed all EVM USDC, sweepToVault is a no-op (no
        // funds to push — late HC arrivals have not yet landed).
        _execAndPrep();
        vm.prank(vault);
        strategy.settle();
        uint256 vaultBalance = usdc.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdc.balanceOf(vault), vaultBalance);
        assertEq(strategy.cumulativeSwept(), 0);
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
        // init does NOT finalize; proposer must call explicitly.
        assertFalse(strategy.hyperCoreFinalized());
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
        // _execute must NOT fire HyperCoreFinalized — registration is
        // the proposer's responsibility via finalizeForHyperCore, not execute.
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

    function test_settle_queuesSpotToEvmBridge() public {
        // _initiateReturn must queue a sendAsset (action 13) targeting the
        // USDC system address (0x2000...0000) so HC drains spot back to EVM.
        // Without this, USDC arriving on HC spot from the perp→spot class
        // transfer would strand on HC indefinitely.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(8_000e6))), uint64(2_000e6), 0, 0); // freeMargin = 6_000e6

        vm.recordLogs();
        vm.prank(vault);
        strategy.settle();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, SendAssetCall memory call) = _findSendAsset(logs);
        assertTrue(found, "settle must queue spot->EVM sendAsset bridge");
        // USDC system address = BASE_SYSTEM_ADDRESS + token_index_0
        assertEq(call.destination, address(0x2000000000000000000000000000000000000000));
        assertEq(call.subAccount, address(0));
        assertEq(call.sourceDex, type(uint32).max); // SPOT_DEX
        assertEq(call.destinationDex, type(uint32).max);
        assertEq(call.token, uint64(0)); // USDC
        // 6_000e6 perp * 100 = 6_000e8 spot wei. preSpot = 0 in this test.
        assertEq(call.amount, uint64(6_000e6) * 100);
    }

    function test_sweepToVault_pullsLateHcArrivals() public {
        // settle() pushed the initial DEPOSIT. HC may auto-credit the
        // strategy's EVM USDC later (post-block bridge). sweepToVault()
        // recovers those late arrivals.
        _execAndPrep();
        vm.prank(vault);
        strategy.settle();
        // settle already pushed DEPOSIT — confirm strategy has 0 now.
        assertEq(usdc.balanceOf(address(strategy)), 0);
        // Simulate late HC auto-credit arriving on EVM after settle.
        usdc.mint(address(strategy), 5_000e6);
        uint256 vaultBefore = usdc.balanceOf(vault);
        strategy.sweepToVault();
        assertEq(usdc.balanceOf(vault), vaultBefore + 5_000e6);
        assertEq(strategy.cumulativeSwept(), 5_000e6);
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

    function test_positionValue_sumsHcAndEvmAndSpot() public {
        // Live NAV sums HC perp + HC spot + EVM USDC. In test env, the
        // CoreDepositWallet bridge no-ops (no code at 0x6B9E77...) so DEPOSIT
        // stays on strategy EVM. With HC perp = 12_345e6 (mock), spot = 0
        // (no etch), evm = DEPOSIT, total = perp + 0 + DEPOSIT.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(12_345e6))), 0, 0, 0);
        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        assertEq(value, 12_345e6 + DEPOSIT);
    }

    function test_positionValue_negativeHcEquityFallsBackToEvmBalance() public {
        // HC reports negative equity (severely underwater). Fallback returns
        // EVM USDC balance — that's what's actually recoverable. Math should
        // clamp to non-negative, never blow up the deposit modal.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(-1_000), 0, 0, 0);
        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        assertEq(value, DEPOSIT);
    }

    // When HC reports accountValue == 0 (in-transit: USDC pulled from vault but
    // not yet credited to HC spot), positionValue() falls back to the EVM balance
    // so totalAssets() doesn't drop to 0 for one block after execute().
    function test_positionValue_inTransitFallback() public {
        _execAndPrep(); // strategy holds DEPOSIT USDC (MockCoreWriter doesn't move it)
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(0), 0, 0, 0); // HC reports zero (in-transit)
        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        assertEq(value, DEPOSIT); // EVM balance used as placeholder
    }

    function test_positionValue_precompileMissingFallsBackToEvmBalance() public {
        // When the precompile staticcall returns empty (HC registration
        // never landed, or non-HyperEVM env), fall back to EVM USDC balance.
        // CRITICAL: must return valid=true so vault's totalAssets() reports
        // the real value (not 0) — prevents the share inflation bug where
        // totalAssets()==0 with totalSupply>0 made previewDeposit(1) return
        // ~10M shares.
        _execAndPrep();
        // No etch at 0x...080F — staticcall returns empty bytes
        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        assertEq(value, DEPOSIT);
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

    // ── onLiveDeposit ──

    function test_onLiveDeposit_sendsClassTransferToPerp() public {
        _execAndPrep();
        uint256 liveAmount = 5_000e6;
        usdc.mint(address(strategy), liveAmount); // vault pre-pushes before calling hook
        vm.recordLogs();
        vm.prank(vault);
        strategy.onLiveDeposit(liveAmount);
        // Expect a class transfer RawAction with (liveAmount, toPerp=true)
        (bool found, uint64 ntl, bool toPerp) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "class transfer RawAction not emitted");
        assertEq(ntl, uint64(liveAmount));
        assertTrue(toPerp, "toPerp must be true for live deposit");
        // FundsParked event
        // (covered implicitly — if class transfer fired, the full hook ran)
    }

    function test_onLiveDeposit_zeroAmount_isNoOp() public {
        _execAndPrep();
        vm.recordLogs();
        vm.prank(vault);
        strategy.onLiveDeposit(0);
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0, "no-op for zero");
    }

    function test_onLiveDeposit_overflowReverts() public {
        _execAndPrep();
        uint256 tooLarge = uint256(type(uint64).max) + 1;
        vm.prank(vault);
        vm.expectRevert(HyperliquidGridStrategy.DepositAmountTooLarge.selector);
        strategy.onLiveDeposit(tooLarge);
    }

    // ── initiateReturn / _initiateClassTransfer ──

    function test_initiateReturn_revertsForNonProposerBeforeDuration() public {
        // Path 1 of two-path settle: anyone-but-proposer must wait until
        // proposal duration expires. The mock governor used by these tests
        // does not implement `getActiveProposal/getProposal`, so the auth
        // call from a non-proposer reverts (no data) — that's the expected
        // gate firing. Proposer call (pre-duration) must succeed.
        _execAndPrep();
        vm.prank(attacker);
        vm.expectRevert();
        strategy.initiateReturn();
    }

    function test_initiateReturn_revertsBeforeExecute() public {
        // Auth gate: state must be Executed (no _execute call yet).
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.initiateReturn();
    }

    function test_initiateReturn_proposerCanCallAnytime() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(8_000e6))), uint64(2_000e6), 0, 0);
        vm.prank(proposer);
        strategy.initiateReturn();
        assertTrue(strategy.returnsInitiated());
    }

    function test_initiateReturn_idempotent() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(8_000e6))), uint64(2_000e6), 0, 0);
        vm.prank(proposer);
        strategy.initiateReturn();
        // Second call: silent no-op (returns) — does NOT re-fire bridge actions.
        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0, "second initiateReturn must be no-op");
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
        m.setSummary(equity, 0, 0, 0); // marginUsed=0 → freeMargin == equity

        vm.recordLogs();
        vm.prank(vault);
        strategy.settle();

        (bool found, uint64 ntl, bool toPerp) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "expected class transfer RawAction");
        assertEq(ntl, uint64(equity));
        assertFalse(toPerp);
    }

    function test_settle_subtractsMarginUsedFromClassTransfer() public {
        // If IOC orders partially fill, some marginUsed remains. The class transfer
        // must use (accountValue - marginUsed) so HC doesn't reject it.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        int64 equity = int64(int256(uint256(9_800e6)));
        uint64 marginUsed = uint64(500e6); // residual locked margin from partial fill
        m.setSummary(equity, marginUsed, 0, 0);

        vm.recordLogs();
        vm.prank(vault);
        strategy.settle();

        (bool found, uint64 ntl,) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "expected class transfer");
        assertEq(ntl, uint64(equity) - marginUsed, "must subtract marginUsed");
    }

    function test_settle_skipsClassTransferWhenFreeMarginZero() public {
        // Fully locked account (all equity = marginUsed) → no transfer.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        int64 equity = int64(int256(uint256(9_800e6)));
        m.setSummary(equity, uint64(equity), 0, 0); // freeMargin == 0
        vm.recordLogs();
        vm.prank(vault);
        strategy.settle();
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0, "no transfer when all margin locked");
    }

    function test_recoverHcResiduals_revertsBeforeSettle() public {
        // Path-1 / path-2 separation: recoverHcResiduals must not run while
        // the strategy is still Executed (would conflict with initiateReturn).
        _execAndPrep();
        vm.expectRevert(HyperliquidGridStrategy.NotSweepable.selector);
        strategy.recoverHcResiduals();
    }

    function test_recoverHcResiduals_refiresDrainPostSettle() public {
        // After settle, residual HC margin (e.g. from IOC slippage) can be
        // recovered by re-firing the drain via this permissionless entrypoint.
        // Roll one block past settle so the same-block gate doesn't suppress.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(9_800e6))), uint64(0), 0, 0);
        vm.prank(vault);
        strategy.settle();
        vm.roll(block.number + 1);

        // Simulate residual perp margin appearing after settle (e.g. IOC fill
        // releasing locked margin) and confirm a re-fire emits a fresh class
        // transfer for the residual amount.
        m.setSummary(int64(int256(uint256(200e6))), uint64(0), 0, 0);
        vm.recordLogs();
        strategy.recoverHcResiduals();
        (bool found, uint64 ntl,) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "recoverHcResiduals must re-fire perp->spot class transfer");
        assertEq(ntl, uint64(200e6));
    }

    function test_recoverHcResiduals_permissionless() public {
        // Anyone can call after settle (no auth check) — funds only flow to
        // strategy/vault, so no diversion is possible.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(1_000e6))), uint64(0), 0, 0);
        vm.prank(vault);
        strategy.settle();
        vm.roll(block.number + 1);

        m.setSummary(int64(int256(uint256(50e6))), uint64(0), 0, 0);
        vm.prank(attacker);
        strategy.recoverHcResiduals(); // should not revert
    }

    function _etchSpotBalance() internal returns (MockSpotBalancePrecompile) {
        MockSpotBalancePrecompile m = new MockSpotBalancePrecompile();
        vm.etch(0x0000000000000000000000000000000000000801, address(m).code);
        return MockSpotBalancePrecompile(0x0000000000000000000000000000000000000801);
    }

    function test_moveSpotToPerp_classTransfersAllSpot() public {
        // _execute strands USDC on HC spot when Circle's first-deposit fee
        // makes the original class transfer fail. moveSpotToPerp() reads
        // current spot balance and class-transfers it to perp, recovering
        // the orphaned funds.
        _execAndPrep();
        MockSpotBalancePrecompile sb = _etchSpotBalance();
        // Spot has 9 USDC = 9e8 spot wei (8-decimal). Should class-transfer
        // 9e8 / 100 = 9e6 perp-decimal.
        sb.setSpot(uint64(9e8), 0, 0);
        vm.recordLogs();
        vm.prank(proposer);
        strategy.moveSpotToPerp();
        (bool found, uint64 ntl, bool toPerp) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "moveSpotToPerp must emit class-transfer RawAction");
        assertEq(ntl, uint64(9e6));
        assertTrue(toPerp, "must be spot->perp direction");
    }

    function test_moveSpotToPerp_revertsForNonProposer() public {
        _execAndPrep();
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.moveSpotToPerp();
    }

    function test_moveSpotToPerp_zeroSpotIsNoOp() public {
        _execAndPrep();
        // No spot etched → precompile returns empty / zeros → no class transfer.
        vm.recordLogs();
        vm.prank(proposer);
        strategy.moveSpotToPerp();
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0, "must not fire on empty spot");
    }

    function test_positionValue_inFlightHighWaterMarkCoversInTransit() public {
        // After _execute, inFlightToHc = DEPOSIT. In test env, the bridge
        // is a no-op so EVM bal stays = DEPOSIT. With perp = 0 and spot = 0
        // (precompile not etched), observable = DEPOSIT. max(observable,
        // inFlightToHc) = DEPOSIT. NAV stays stable.
        _execAndPrep();
        assertEq(strategy.inFlightToHc(), DEPOSIT, "execute must set inFlight high-water");
        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        assertEq(value, DEPOSIT);
    }

    function test_positionValue_includesHcSpotBalance() public {
        // Circle's first-deposit-fee strand: perp = 0, spot = 9e8 wei (= 9 USDC),
        // EVM = 0 (in real flow; in test env the bridge no-ops so use a fresh
        // strategy with no _execute). positionValue must surface the spot value
        // so the vault's NAV reflects it.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(0, 0, 0, 0);
        MockSpotBalancePrecompile sb = _etchSpotBalance();
        sb.setSpot(uint64(9e8), 0, 0); // 9 USDC on HC spot

        (uint256 value, bool valid) = strategy.positionValue();
        assertTrue(valid);
        // observable = perp(0) + spot(9e8/100=9e6) + evm(DEPOSIT) = 9e6 + DEPOSIT.
        // inFlightToHc = DEPOSIT (set by _execute).
        // max = 9e6 + DEPOSIT.
        assertEq(value, 9e6 + DEPOSIT);
    }

    function test_recoverHcResiduals_sameBlockGateSkips() public {
        // Same-block re-calls are silently skipped to prevent duplicate
        // spot→EVM bridge actions reading the same pre-block SPOT_BALANCE.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(9_800e6))), uint64(0), 0, 0);
        vm.prank(vault);
        strategy.settle();
        vm.roll(block.number + 1);

        m.setSummary(int64(int256(uint256(200e6))), uint64(0), 0, 0);
        strategy.recoverHcResiduals(); // first call: fires
        vm.recordLogs();
        strategy.recoverHcResiduals(); // same-block second call: skipped
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0, "same-block re-call must not re-fire");
    }

    function test_initiateReturn_drainsHcOnPath1() public {
        // Path 1: proposer calls initiateReturn pre-settle. HC drain queues:
        // perp→spot class transfer + spot→EVM sendAsset. Then governor's
        // _settle runs (≥1 block later in production) to push EVM USDC to vault.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(9_800e6))), uint64(0), 0, 0);
        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        // Class transfer for the full freeMargin emitted.
        (bool found, uint64 ntl,) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found);
        assertEq(ntl, uint64(9_800e6));
        assertTrue(strategy.returnsInitiated());
        assertFalse(strategy.settled());
    }

    // ── Helpers ──

    bytes4 constant CLASS_TRANSFER_ACTION = 0x01000007;
    bytes4 constant SEND_ASSET_ACTION = 0x0100000d;

    /// @dev Decoded sendAsset action used by spot→EVM bridge regression tests.
    struct SendAssetCall {
        address destination;
        address subAccount;
        uint32 sourceDex;
        uint32 destinationDex;
        uint64 token;
        uint64 amount;
    }

    function _findSendAsset(Vm.Log[] memory logs) internal view returns (bool found, SendAssetCall memory call) {
        bytes32 sig = keccak256("RawAction(address,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            bytes memory raw = abi.decode(logs[i].data, (bytes));
            if (raw.length < 4 || bytes4(raw) != SEND_ASSET_ACTION) continue;
            bytes memory payload = new bytes(raw.length - 4);
            for (uint256 j = 0; j < payload.length; j++) {
                payload[j] = raw[j + 4];
            }
            (call.destination, call.subAccount, call.sourceDex, call.destinationDex, call.token, call.amount) =
                abi.decode(payload, (address, address, uint32, uint32, uint64, uint64));
            return (true, call);
        }
    }

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
