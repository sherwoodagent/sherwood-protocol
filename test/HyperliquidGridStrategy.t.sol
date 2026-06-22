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
        // Sherlock #23 — settle requires initiateReturn first.
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();
        assertTrue(strategy.settled());
    }

    /// @notice Campaign finding F2 (HIGH) — `settle()` must revert in the SAME
    ///         block as `initiateReturn()` (async HC→EVM bridge delivers later;
    ///         same-block settle books a phantom loss). See the perp equivalent.
    function test_settle_revertsSameBlockAsInitiateReturn() public {
        _execAndPrep();
        vm.prank(proposer);
        strategy.initiateReturn();
        assertEq(strategy.returnsInitiatedBlock(), block.number, "init block recorded");

        vm.prank(vault);
        vm.expectRevert(HyperliquidGridStrategy.SettleTooSoon.selector);
        strategy.settle();

        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();
        assertTrue(strategy.settled(), "settles a block after initiateReturn");
    }

    /// @notice Sherlock run #1 finding #23 — settle() MUST revert if
    ///         returnsInitiated == false. Pre-fix, settle would call
    ///         _drainHC same-block and push zero balance, recording a phantom
    ///         total loss while USDC was still in flight on HC.
    function test_settle_revertsBeforeInitiateReturn() public {
        _execAndPrep();
        vm.prank(vault);
        vm.expectRevert(HyperliquidGridStrategy.ReturnsNotInitiated.selector);
        strategy.settle();
        assertFalse(strategy.settled());
    }

    function test_settle_pushesUsdcBack() public {
        // settle() now pushes EVM USDC after initiateReturn has drained HC —
        // governor's settle batch sees correct vault.totalAssets() for fee math.
        _execAndPrep();
        uint256 vaultBefore = usdc.balanceOf(vault);
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        vm.prank(vault);
        strategy.settle();
        assertEq(usdc.balanceOf(vault), vaultBefore + DEPOSIT);
        assertEq(usdc.balanceOf(address(strategy)), 0);
    }

    function test_sweepToVault_isNoOpAfterSettleHandledFunds() public {
        // After _settle pushed all EVM USDC, sweepToVault is a no-op (no
        // funds to push — late HC arrivals have not yet landed).
        _execAndPrep();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
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

    function test_initiateReturn_queuesSpotToEvmBridge() public {
        // _initiateReturn must queue a sendAsset (action 13) targeting the
        // USDC system address (0x2000...0000) so HC drains spot back to EVM.
        // Without this, USDC arriving on HC spot from the perp→spot class
        // transfer would strand on HC indefinitely.
        //
        // Sherlock #23: pre-fix, this assertion ran on settle() because settle
        // auto-drained. Post-fix, drain moves to initiateReturn — same event,
        // different trigger.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        // Sherlock #26: full accountValue (8_000e6) is now transferred, not
        // freeMargin (8000 - 2000 = 6000). marginUsed is released during
        // the in-batch force-close that precedes the class transfer on HC.
        m.setSummary(int64(int256(uint256(8_000e6))), uint64(2_000e6), 0, 0);

        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, SendAssetCall memory call) = _findSendAsset(logs);
        assertTrue(found, "initiateReturn must queue spot->EVM sendAsset bridge");
        assertEq(call.destination, address(0x2000000000000000000000000000000000000000));
        assertEq(call.subAccount, address(0));
        assertEq(call.sourceDex, type(uint32).max); // SPOT_DEX
        assertEq(call.destinationDex, type(uint32).max);
        assertEq(call.token, uint64(0)); // USDC
        // Sherlock #26: 8_000e6 (full equity) * 100 = 8_000e8 spot wei.
        assertEq(call.amount, uint64(8_000e6) * 100);
    }

    function test_sweepToVault_pullsLateHcArrivals() public {
        // settle() pushed the initial DEPOSIT. HC may auto-credit the
        // strategy's EVM USDC later (post-block bridge). sweepToVault()
        // recovers those late arrivals.
        _execAndPrep();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
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

    function test_initiateReturn_selfCancelsTrackedCloids() public {
        // Sherlock #23: cancel-tracked-cloids moved from settle to initiateReturn
        // along with the rest of _drainHC. Same end-state guarantee.
        _execAndPrep();
        _placeFourBtcOrders();
        // Sanity
        assertEq(strategy.liveCloidsLength(BTC_ASSET), 4);

        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);

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

    // ── HC precompile test helpers ──

    function _etchAccountMarginSummary() internal returns (MockAccountMarginSummaryPrecompile) {
        MockAccountMarginSummaryPrecompile m = new MockAccountMarginSummaryPrecompile();
        vm.etch(0x000000000000000000000000000000000000080F, address(m).code);
        return MockAccountMarginSummaryPrecompile(0x000000000000000000000000000000000000080F);
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
        vm.roll(block.number + 1);
    }

    function test_initiateReturn_revertsBeforeExecute() public {
        // Auth gate: state must be Executed (no _execute call yet).
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
    }

    function test_initiateReturn_proposerCanCallAnytime() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(8_000e6))), uint64(2_000e6), 0, 0);
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        assertTrue(strategy.returnsInitiated());
    }

    /// @notice PR #324 review R1 — `returnsInitiated` must flip BEFORE
    ///         `_drainHC()` runs. If the drain reverts (e.g. CoreWriter
    ///         precompile failure), the revert rolls back the flag write
    ///         too — but the proposer can retry. Pre-fix order (drain
    ///         first, flag after) had the same retry behaviour on a clean
    ///         revert, but offered no protection against a half-success
    ///         path (orders cancelled, class transfer never reaches the
    ///         flag flip). The reorder makes the invariant explicit:
    ///         `returnsInitiated == true` ⟺ caller of this tx intended
    ///         the drain.
    function test_initiateReturn_drainRevertLeavesFlagUnset_canRetry() public {
        _execAndPrep();

        // Mock CoreWriter to revert — any L1Write action inside _drainHC
        // (cancel + force-close orders) will bubble up.
        vm.mockCallRevert(
            address(0x3333333333333333333333333333333333333333),
            abi.encodeWithSignature("sendRawAction(bytes)"),
            "core-writer-down"
        );

        vm.prank(proposer);
        vm.expectRevert("core-writer-down");
        strategy.initiateReturn();
        vm.roll(block.number + 1);

        // Flag was rolled back with the revert — proposer can retry.
        assertFalse(strategy.returnsInitiated(), "flag rolled back on drain revert");

        // Recover CoreWriter and retry — succeeds.
        vm.clearMockedCalls();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        assertTrue(strategy.returnsInitiated(), "second attempt flips flag");
    }

    function test_initiateReturn_idempotent() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(8_000e6))), uint64(2_000e6), 0, 0);
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        // Second call: silent no-op (returns) — does NOT re-fire bridge actions.
        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0, "second initiateReturn must be no-op");
    }

    function test_initiateReturn_skipsClassTransferWhenNoPrecompile() public {
        // No AccountMarginSummary precompile etched → _initiateClassTransfer no-ops.
        // initiateReturn must still complete and flip the returnsInitiated flag.
        _execAndPrep();
        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        assertTrue(strategy.returnsInitiated());
        assertEq(_countClassTransferLogs(vm.getRecordedLogs()), 0);
    }

    function test_initiateReturn_usesPrecompileAmountForClassTransfer() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        int64 equity = int64(int256(uint256(9_800e6)));
        m.setSummary(equity, 0, 0, 0); // marginUsed=0 → freeMargin == equity

        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);

        (bool found, uint64 ntl, bool toPerp) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "expected class transfer RawAction");
        assertEq(ntl, uint64(equity));
        assertFalse(toPerp);
    }

    /// @notice Sherlock #26: class transfer is now the FULL accountValue,
    ///         not (accountValue - marginUsed). HC releases marginUsed when
    ///         it processes the queued force-close orders in the same batch,
    ///         before the class transfer fires.
    function test_initiateReturn_transfersFullAccountValue() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        int64 equity = int64(int256(uint256(9_800e6)));
        uint64 marginUsed = uint64(500e6); // residual locked margin from partial fill
        m.setSummary(equity, marginUsed, 0, 0);

        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);

        (bool found, uint64 ntl,) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "expected class transfer");
        // Sherlock #26: full equity transferred (was equity - marginUsed).
        assertEq(ntl, uint64(equity), "Sherlock #26: full accountValue, not freeMargin");
    }

    /// @notice Sherlock #26: even a fully-locked account fires the class
    ///         transfer for the full equity — force-closes will release
    ///         the margin in the same HC batch.
    function test_initiateReturn_transfersEvenWhenFullyLocked() public {
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        int64 equity = int64(int256(uint256(9_800e6)));
        m.setSummary(equity, uint64(equity), 0, 0); // marginUsed == equity
        vm.recordLogs();
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
        (bool found, uint64 ntl,) = _decodeClassTransfer(vm.getRecordedLogs());
        assertTrue(found, "transfer fires even when marginUsed == equity");
        assertEq(ntl, uint64(equity), "transfers full equity");
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
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
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
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
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

    function test_recoverHcResiduals_sameBlockGateSkips() public {
        // Same-block re-calls are silently skipped to prevent duplicate
        // spot→EVM bridge actions reading the same pre-block SPOT_BALANCE.
        _execAndPrep();
        MockAccountMarginSummaryPrecompile m = _etchAccountMarginSummary();
        m.setSummary(int64(int256(uint256(9_800e6))), uint64(0), 0, 0);
        vm.prank(proposer);
        strategy.initiateReturn();
        vm.roll(block.number + 1);
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
        vm.roll(block.number + 1);
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
