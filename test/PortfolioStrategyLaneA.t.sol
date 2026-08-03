// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {Position} from "../src/interfaces/IPriceRouter.sol";
import {PositionKinds} from "../src/libraries/PositionKinds.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";
import {ObservingSwapAdapter} from "./mocks/ObservingSwapAdapter.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title PortfolioStrategyLaneATest
/// @notice Unit suite for PortfolioStrategy's Lane A surface: position
///         enumeration lifecycle, conservative instant-liquidity quoting, and
///         the all-or-revert shortfall unwind (spec: portfolio-strategy-lane-a).
///
///   Fixture: push-feed mode (chainlinkVerifier == 0), 18-dec asset/tokens,
///   8-dec feeds. Marks and swap rates agree (TSLA 0.01, AMZN 0.02, NFLX
///   0.005 WETH) so mark-anchored floors clear exactly unless a test skews
///   the pool.
contract PortfolioStrategyLaneATest is Test {
    PortfolioStrategy public template;
    PortfolioStrategy public strategy;
    MockSwapAdapter public adapter;

    MockAggregatorV3 public fTsla;
    MockAggregatorV3 public fAmzn;
    MockAggregatorV3 public fNflx;

    ERC20Mock public weth; // vault asset
    ERC20Mock public tsla;
    ERC20Mock public amzn;
    ERC20Mock public nflx;

    address public vault = makeAddr("vault");
    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant MAX_SLIPPAGE = 100; // 1%
    uint256 constant BPS = 10_000;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        amzn = new ERC20Mock("Amazon Token", "AMZN", 18);
        nflx = new ERC20Mock("Netflix Token", "NFLX", 18);

        adapter = new MockSwapAdapter();
        _setRates(address(adapter));
        _fund(address(adapter));

        // 8-dec push feeds at the same marks as the swap rates.
        fTsla = new MockAggregatorV3(8, int256(1e6)); // 0.01 WETH
        fAmzn = new MockAggregatorV3(8, int256(2e6)); // 0.02 WETH
        fNflx = new MockAggregatorV3(8, int256(5e5)); // 0.005 WETH

        weth.mint(vault, 100e18);

        template = new PortfolioStrategy();
        strategy = _newPushStrategy(address(adapter));
    }

    // ── Fixture helpers ──

    function _setRates(address a) internal {
        MockSwapAdapter(a).setRate(address(weth), address(tsla), 100e18);
        MockSwapAdapter(a).setRate(address(weth), address(amzn), 50e18);
        MockSwapAdapter(a).setRate(address(weth), address(nflx), 200e18);
        MockSwapAdapter(a).setRate(address(tsla), address(weth), 0.01e18);
        MockSwapAdapter(a).setRate(address(amzn), address(weth), 0.02e18);
        MockSwapAdapter(a).setRate(address(nflx), address(weth), 0.005e18);
    }

    function _fund(address a) internal {
        tsla.mint(a, 100_000e18);
        amzn.mint(a, 100_000e18);
        nflx.mint(a, 100_000e18);
        weth.mint(a, 100_000e18);
    }

    function _feedId(address feed) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(feed)));
    }

    /// @dev New push-mode clone: 3-token basket 40/35/25, 8-dec feeds.
    function _newPushStrategy(address swapAdapter_) internal returns (PortfolioStrategy s) {
        s = PortfolioStrategy(Clones.clone(address(template)));
        s.initialize(vault, proposer, _initData(swapAdapter_, address(0), _pushFeedIds(), _pd8()));
    }

    /// @dev New Data-Streams-mode clone (nonzero verifier — no on-chain mark).
    function _newStreamsStrategy() internal returns (PortfolioStrategy s) {
        bytes32[] memory feedIds = new bytes32[](3);
        feedIds[0] = keccak256("ds.feed.tsla");
        feedIds[1] = keccak256("ds.feed.amzn");
        feedIds[2] = keccak256("ds.feed.nflx");
        uint8[] memory pd = new uint8[](3);
        pd[0] = 18;
        pd[1] = 18;
        pd[2] = 18;
        s = PortfolioStrategy(Clones.clone(address(template)));
        s.initialize(vault, proposer, _initData(address(adapter), makeAddr("verifier"), feedIds, pd));
    }

    function _pushFeedIds() internal view returns (bytes32[] memory feedIds) {
        feedIds = new bytes32[](3);
        feedIds[0] = _feedId(address(fTsla));
        feedIds[1] = _feedId(address(fAmzn));
        feedIds[2] = _feedId(address(fNflx));
    }

    function _pd8() internal pure returns (uint8[] memory pd) {
        pd = new uint8[](3);
        pd[0] = 8;
        pd[1] = 8;
        pd[2] = 8;
    }

    function _initData(address swapAdapter_, address verifier_, bytes32[] memory feedIds, uint8[] memory pd)
        internal
        view
        returns (bytes memory)
    {
        address[] memory tokens = new address[](3);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        tokens[2] = address(nflx);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 4000;
        weights[1] = 3500;
        weights[2] = 2500;
        bytes[] memory extraData = new bytes[](3);
        return abi.encode(
            address(weth), swapAdapter_, verifier_, tokens, weights, TOTAL_AMOUNT, MAX_SLIPPAGE, extraData, pd, feedIds
        );
    }

    function _execute(PortfolioStrategy s) internal {
        vm.prank(vault);
        weth.approve(address(s), TOTAL_AMOUNT);
        vm.prank(vault);
        s.execute();
    }

    // ==================== positions() lifecycle ====================

    function test_positions_emptyBeforeExecute() public view {
        assertEq(strategy.positions().length, 0, "Pending: Lane B float-only");
    }

    function test_positions_enumeratesBasketAfterExecute() public {
        _execute(strategy);
        Position[] memory ps = strategy.positions();
        assertEq(ps.length, 3, "one position per basket slot");
        address[3] memory expected = [address(tsla), address(amzn), address(nflx)];
        for (uint256 i; i < 3; ++i) {
            assertEq(ps[i].venue, expected[i], "venue = slot token");
            assertEq(ps[i].kind, PositionKinds.ERC20_SPOT, "canonical spot kind");
            assertEq(ps[i].ref.length, 0, "ref empty: registry selects the feed");
        }
    }

    function test_positions_emptyAfterSettle() public {
        _execute(strategy);
        vm.prank(vault);
        strategy.settle();
        assertEq(strategy.positions().length, 0, "Settled: back to Lane B");
    }

    /// @notice Design D5: a mid-rebalance basket must not be enumerable. The
    ///         observing adapter reads positions()/availableLiquidity from
    ///         inside the rebalance's first swap.
    function test_positions_emptyMidRebalance() public {
        ObservingSwapAdapter obs = new ObservingSwapAdapter();
        _setRates(address(obs));
        _fund(address(obs));
        PortfolioStrategy s = _newPushStrategy(address(obs));
        _execute(s);

        obs.arm(address(s), address(0));
        vm.prank(proposer);
        s.rebalance();

        assertEq(obs.observedPositions(), 0, "Lane A closed mid-rebalance");
        assertEq(obs.observedLiquidity(), 0, "idle-only (zero) mid-rebalance");
        // After the rebalance completes, enumeration resumes.
        assertEq(s.positions().length, 3, "Lane A reopens after rebalance");
    }

    /// @notice The `_rebalancing` flag also closes Lane A during a withdrawTo
    ///         basket sale — a half-sold basket must not be priced.
    function test_positions_emptyMidUnwind() public {
        ObservingSwapAdapter obs = new ObservingSwapAdapter();
        _setRates(address(obs));
        _fund(address(obs));
        PortfolioStrategy s = _newPushStrategy(address(obs));
        _execute(s);

        obs.arm(address(s), address(0));
        vm.prank(vault);
        s.withdrawTo(1e18);

        assertEq(obs.observedPositions(), 0, "Lane A closed mid-unwind");
    }

    // ==================== availableLiquidity() ====================

    function test_availableLiquidity_zeroBeforeExecute() public view {
        assertEq(strategy.availableLiquidity(), 0, "Pending: no idle, no basket");
    }

    /// @notice Basket estimate = min(quote, mark) less maxSlippageBps: 10 WETH
    ///         of basket at aligned quote/mark → 9.9 WETH deliverable.
    function test_availableLiquidity_quotedAndDiscounted() public {
        _execute(strategy);
        assertEq(strategy.availableLiquidity(), 9.9e18, "10 WETH basket x 99%");
    }

    function test_availableLiquidity_includesIdle() public {
        _execute(strategy);
        weth.mint(address(strategy), 1e18);
        assertEq(strategy.availableLiquidity(), 1e18 + 9.9e18, "idle + basket estimate");
    }

    /// @notice The basket estimate is anchored to the Chainlink push mark, NOT
    ///         the swap-adapter quote: a broken/unavailable quote must NOT
    ///         reduce advertised capacity. (In production every adapter's
    ///         `quote()` is a state-mutating simulator that a view staticcall
    ///         cannot survive, so a quote-dependent estimate would collapse the
    ///         whole basket term to idle-only on-chain.)
    function test_availableLiquidity_independentOfQuote() public {
        _execute(strategy);
        weth.mint(address(strategy), 1e18);
        adapter.setRate(address(amzn), address(weth), 0); // quote() would revert RateNotSet
        assertEq(strategy.availableLiquidity(), 1e18 + 9.9e18, "mark-anchored: quote irrelevant");
    }

    function test_availableLiquidity_degradesToIdle_onStaleMark() public {
        _execute(strategy);
        weth.mint(address(strategy), 1e18);
        vm.warp(vm.getBlockTimestamp() + 26 hours + 1); // past default push age
        assertEq(strategy.availableLiquidity(), 1e18, "stale mark degrades to idle");
    }

    function test_availableLiquidity_degradesToIdle_dataStreamsMode() public {
        PortfolioStrategy s = _newStreamsStrategy();
        _execute(s);
        weth.mint(address(s), 1e18);
        assertEq(s.availableLiquidity(), 1e18, "no on-chain mark: idle only");
    }

    /// @notice Never overstate: a pool quoting ABOVE the oracle mark is capped
    ///         at the mark (the router-priced value).
    function test_availableLiquidity_capsQuoteAtMark() public {
        _execute(strategy);
        adapter.setRate(address(tsla), address(weth), 0.02e18); // pool 2x the mark
        assertEq(strategy.availableLiquidity(), 9.9e18, "estimate capped at mark value");
    }

    function test_availableLiquidity_settled_isIdleOnly() public {
        _execute(strategy);
        vm.prank(vault);
        strategy.settle();
        assertEq(strategy.availableLiquidity(), 0, "settled strategy pushed everything back");
    }

    // ==================== withdrawTo ====================

    function test_withdrawTo_onlyVault() public {
        _execute(strategy);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.withdrawTo(1e18);
    }

    function test_withdrawTo_zeroAssets_reverts() public {
        _execute(strategy);
        vm.prank(vault);
        vm.expectRevert(PortfolioStrategy.InvalidAmount.selector);
        strategy.withdrawTo(0);
    }

    /// @notice Spec scenario: idle balance covers the request — the basket is
    ///         untouched.
    function test_withdrawTo_idleCovers_basketUntouched() public {
        _execute(strategy);
        weth.mint(address(strategy), 3e18);
        uint256 vaultBefore = weth.balanceOf(vault);

        vm.prank(vault);
        strategy.withdrawTo(2e18);

        assertEq(weth.balanceOf(vault) - vaultBefore, 2e18, "exactly the requested assets");
        assertEq(tsla.balanceOf(address(strategy)), 400e18, "basket untouched");
        assertEq(amzn.balanceOf(address(strategy)), 175e18, "basket untouched");
        assertEq(nflx.balanceOf(address(strategy)), 500e18, "basket untouched");
    }

    /// @notice Spec scenario: request beyond idle raises the remainder selling
    ///         basket tokens pro-rata within the slippage bound.
    function test_withdrawTo_basketSaleWithinSlippage() public {
        _execute(strategy);
        uint256 vaultBefore = weth.balanceOf(vault);

        vm.prank(vault);
        strategy.withdrawTo(2e18);

        assertEq(weth.balanceOf(vault) - vaultBefore, 2e18, "delivered at least the request, exactly transferred");

        // Pro-rata: every slot sold the same fraction (grossed target /
        // basket value ~= 20.2%), so weights are preserved.
        uint256 remTsla = tsla.balanceOf(address(strategy));
        uint256 remAmzn = amzn.balanceOf(address(strategy));
        uint256 remNflx = nflx.balanceOf(address(strategy));
        assertGt(remTsla, 0);
        assertApproxEqRel(remTsla * 1e18 / 400e18, remAmzn * 1e18 / 175e18, 1e12, "same sold fraction (tsla vs amzn)");
        assertApproxEqRel(remTsla * 1e18 / 400e18, remNflx * 1e18 / 500e18, 1e12, "same sold fraction (tsla vs nflx)");
        // Sold ~2.0202 WETH worth (1% gross-up), i.e. ~20.2% of the basket:
        // remaining TSLA ~= 400 * (1 - 0.020202...e18/0.1e18) ~= 319.1919e18.
        assertApproxEqRel(remTsla, 319.1919e18, 1e15, "~20.2% of TSLA sold");
    }

    function test_withdrawTo_idlePlusBasket() public {
        _execute(strategy);
        weth.mint(address(strategy), 1e18);
        uint256 vaultBefore = weth.balanceOf(vault);

        vm.prank(vault);
        strategy.withdrawTo(3e18);

        assertEq(weth.balanceOf(vault) - vaultBefore, 3e18);
        assertLt(tsla.balanceOf(address(strategy)), 400e18, "basket sold only for the shortfall");
    }

    /// @notice Spec scenario: an unfillable request reverts with no partial
    ///         delivery — the basket cannot raise more than it is worth.
    function test_withdrawTo_unfillable_reverts_noPartialDelivery() public {
        _execute(strategy);
        uint256 vaultBefore = weth.balanceOf(vault);

        vm.prank(vault);
        vm.expectRevert(PortfolioStrategy.InsufficientUnwindProceeds.selector);
        strategy.withdrawTo(10.5e18); // basket is worth 10 WETH

        assertEq(weth.balanceOf(vault), vaultBefore, "no partial delivery");
        assertEq(tsla.balanceOf(address(strategy)), 400e18, "state rolled back");
        assertEq(amzn.balanceOf(address(strategy)), 175e18, "state rolled back");
        assertEq(nflx.balanceOf(address(strategy)), 500e18, "state rolled back");
    }

    /// @notice Spec scenario: the pool trades 2% under the Chainlink mark while
    ///         the slippage bound is 1% — the oracle-anchored floor reverts the
    ///         leg, and with it the whole withdrawal.
    function test_withdrawTo_slippageBeyondBound_reverts() public {
        _execute(strategy);
        adapter.setRate(address(tsla), address(weth), 0.0098e18); // 2% under mark

        vm.prank(vault);
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.withdrawTo(2e18);

        assertEq(tsla.balanceOf(address(strategy)), 400e18, "no partial delivery");
    }

    function test_withdrawTo_staleMark_reverts() public {
        _execute(strategy);
        vm.warp(vm.getBlockTimestamp() + 26 hours + 1);

        vm.prank(vault);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        strategy.withdrawTo(1e18);
    }

    function test_withdrawTo_beforeExecute_reverts() public {
        vm.prank(vault);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.withdrawTo(1e18);
    }

    function test_withdrawTo_afterSettle_reverts() public {
        _execute(strategy);
        vm.prank(vault);
        strategy.settle();

        vm.prank(vault);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.withdrawTo(1e18);
    }

    function test_withdrawTo_dataStreamsMode_reverts() public {
        PortfolioStrategy s = _newStreamsStrategy();
        _execute(s);

        vm.prank(vault);
        vm.expectRevert(PortfolioStrategy.MarkUnavailable.selector);
        s.withdrawTo(1e18);
    }

    /// @notice Spec scenario "Settle unchanged": settlement after Lane A
    ///         partial unwinds still sells the remaining basket and pushes the
    ///         full remaining balance to the vault.
    function test_withdrawTo_thenSettle_returnsRemainder() public {
        _execute(strategy);
        uint256 vaultBefore = weth.balanceOf(vault);

        vm.prank(vault);
        strategy.withdrawTo(2e18);

        vm.prank(vault);
        strategy.settle();

        // Rates never moved, so exit + settle together return the full 10 WETH
        // (the unwind's slippage gross-up surplus stays in the flow, modulo
        // integer rounding dust).
        uint256 returned = weth.balanceOf(vault) - vaultBefore;
        assertApproxEqAbs(returned, TOTAL_AMOUNT, 10, "no value lost across unwind + settle");
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
        assertEq(tsla.balanceOf(address(strategy)), 0);
        assertEq(amzn.balanceOf(address(strategy)), 0);
        assertEq(nflx.balanceOf(address(strategy)), 0);
        assertEq(weth.balanceOf(address(strategy)), 0, "settle pushes everything");
    }
}
