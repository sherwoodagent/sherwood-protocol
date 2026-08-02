// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {Erc20SpotAdapter} from "../../src/pricing/Erc20SpotAdapter.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {PositionKinds} from "../../src/libraries/PositionKinds.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {ObservingSwapAdapter} from "../mocks/ObservingSwapAdapter.sol";

/// @title LaneAEndToEndTest
/// @notice Task 2.6 integration: full vault lifecycle with Lane A over a REAL
///         PriceRouter + Erc20SpotAdapter + PortfolioStrategy (push-feed mode).
///         The governor is mocked (vm.mockCall, same pattern as
///         SyndicateVault.LaneA.t.sol) and execute/settle are pranked as the
///         vault — standing up the full governor/factory stack adds nothing to
///         the Lane A surface under test and is exercised elsewhere.
///
///   Wiring: USDC (6-dec) vault asset = adapter numeraire; TSLA/AMZN (18-dec)
///   tokenized stocks; 8-dec Chainlink push feeds shared by the strategy
///   (rebalance marks) and the adapter (NAV marks); swap rates aligned with
///   the marks so unwind floors clear exactly.
contract LaneAEndToEndTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    MockAgentRegistry agentRegistry;
    PriceRouter router;
    Erc20SpotAdapter spotAdapter;
    PortfolioStrategy strategy;
    ObservingSwapAdapter swapAdapter;

    ERC20Mock usdc;
    ERC20Mock tsla;
    ERC20Mock amzn;
    MockAggregatorV3 fTsla;
    MockAggregatorV3 fAmzn;

    address owner = makeAddr("owner");
    address routerOwner = makeAddr("routerOwner");
    address proposer = makeAddr("proposer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address constant MOCK_GOVERNOR = address(0xF00D);
    uint256 constant PID = 1;

    uint256 constant TOTAL_AMOUNT = 600e6; // strategy pulls 600 USDC
    uint256 constant MAX_AGE = 26 hours;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        tsla = new ERC20Mock("Tesla Stock", "TSLA", 18);
        amzn = new ERC20Mock("Amazon Stock", "AMZN", 18);

        // 8-dec push feeds: TSLA $200, AMZN $100 (in USDC terms).
        fTsla = new MockAggregatorV3(8, int256(200e8));
        fAmzn = new MockAggregatorV3(8, int256(100e8));

        // Swap venue aligned with the marks (1 TSLA = 200 USDC, 1 AMZN = 100).
        swapAdapter = new ObservingSwapAdapter();
        swapAdapter.setRate(address(usdc), address(tsla), 5e27); // 1 USDC -> 0.005 TSLA
        swapAdapter.setRate(address(usdc), address(amzn), 1e28); // 1 USDC -> 0.01 AMZN
        swapAdapter.setRate(address(tsla), address(usdc), 2e8); // 1 TSLA -> 200 USDC
        swapAdapter.setRate(address(amzn), address(usdc), 1e8); // 1 AMZN -> 100 USDC
        tsla.mint(address(swapAdapter), 1_000_000e18);
        amzn.mint(address(swapAdapter), 1_000_000e18);
        usdc.mint(address(swapAdapter), 1_000_000_000e6);

        // Real PriceRouter (proxied) + real spot adapter, Lane A enabled.
        PriceRouter routerImpl = new PriceRouter();
        router = PriceRouter(
            address(new ERC1967Proxy(address(routerImpl), abi.encodeCall(PriceRouter.initialize, (routerOwner))))
        );
        spotAdapter = new Erc20SpotAdapter(routerOwner, address(usdc));
        vm.startPrank(routerOwner);
        router.registerAdapter(PositionKinds.ERC20_SPOT, address(spotAdapter));
        router.setLaneAEnabled(PositionKinds.ERC20_SPOT, true);
        // Per-token caps well above the basket (divergence gate off: rates and
        // marks are aligned in this fixture; the gate has its own unit suite).
        spotAdapter.setFeed(address(tsla), address(fTsla), MAX_AGE, 1_000_000e6, address(0), 0);
        spotAdapter.setFeed(address(amzn), address(fAmzn), MAX_AGE, 1_000_000e6, address(0), 0);
        vm.stopPrank();

        // Real vault (proxied) + queue.
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        // Test contract is the factory: expose governor() + priceRouter().
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        _setLocked(false);

        // Real strategy clone, push-feed mode, 50/50 TSLA/AMZN.
        strategy = PortfolioStrategy(Clones.clone(address(new PortfolioStrategy())));
        strategy.initialize(address(vault), proposer, _strategyInitData());

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ── Fixture helpers ──

    function _strategyInitData() internal view returns (bytes memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        bytes[] memory extraData = new bytes[](2);
        uint8[] memory pd = new uint8[](2);
        pd[0] = 8;
        pd[1] = 8;
        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = bytes32(uint256(uint160(address(fTsla))));
        feedIds[1] = bytes32(uint256(uint160(address(fAmzn))));
        return abi.encode(
            address(usdc),
            address(swapAdapter),
            address(0), // push mode
            tokens,
            weights,
            TOTAL_AMOUNT,
            uint256(100), // 1% max slippage
            extraData,
            pd,
            feedIds
        );
    }

    function _setLocked(bool locked) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(locked ? PID : uint256(0))
        );
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(locked ? uint256(1) : 0));
        if (locked) {
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", PID), abi.encode(address(strategy))
            );
        }
    }

    /// @dev Deposit (pre-lock), then execute the basket as the vault would via
    ///      the governor batch [approve, execute], then lock on the proposal.
    function _depositExecuteLock() internal {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(address(vault));
        usdc.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(address(vault));
        strategy.execute();

        _setLocked(true);
    }

    // ── Full lifecycle ──

    function test_fullLifecycle_instantExitPullsShortfallThroughBasket() public {
        _depositExecuteLock();

        // Basket bought at the marks: 1.5 TSLA ($300) + 3 AMZN ($300).
        assertEq(tsla.balanceOf(address(strategy)), 1.5e18);
        assertEq(amzn.balanceOf(address(strategy)), 3e18);

        // Router prices the strategy vault-side: instantOK at $600.
        (uint256 nav, bool ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "Lane A open: every position priced");
        assertEq(nav, 600e6, "router-priced basket value");

        // Vault NAV = float + live basket value.
        assertEq(vault.totalAssets(), 1_000e6, "400 float + 600 live");
        assertEq(strategy.availableLiquidity(), 594e6, "600 basket x 99%");
        assertGe(vault.maxWithdraw(alice), 700e6, "float + strategy liquidity serviceable");

        // Instant exit above the 400 float: the vault pulls the 300 shortfall
        // through a pro-rata basket sale, same transaction.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(700e6, alice, alice);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 700e6, "exact assets delivered");
        assertEq(usdc.balanceOf(address(vault)), 0, "float fully consumed, shortfall pulled exactly");
        assertLt(tsla.balanceOf(address(strategy)), 1.5e18, "basket partially unwound");
        assertLt(amzn.balanceOf(address(strategy)), 3e18, "basket partially unwound");

        // Lane A still prices the reduced basket.
        (, bool stillOk) = router.valueStrategy(address(strategy));
        assertTrue(stillOk, "Lane A stays open after partial unwind");

        // Settle: remaining basket + unwind surplus return to the vault.
        vm.prank(address(vault));
        strategy.settle();
        _setLocked(false);

        assertEq(strategy.positions().length, 0, "settled: no positions");
        assertApproxEqAbs(vault.totalAssets(), 300e6, 10, "remaining value back as float");
        assertGt(vault.maxWithdraw(alice), 0, "remaining holder can exit at par");
    }

    function test_instantDeposit_duringLaneA_isLockedUntilSettle() public {
        _depositExecuteLock();

        // Bob enters instantly at live NAV during the proposal.
        vm.prank(bob);
        uint256 shares = vault.deposit(100e6, bob);
        assertGt(shares, 0, "instant Lane A entry mints");

        // G1 lockup: no exit (even queued) until the proposal settles.
        vm.prank(bob);
        vm.expectRevert(ISyndicateVault.SharesLocked.selector);
        vault.requestRedeem(shares, bob);
    }

    // ── Lane A closes: stale feed ──

    function test_staleFeed_closesLaneA_failClosed() public {
        _depositExecuteLock();
        assertEq(vault.totalAssets(), 1_000e6, "Lane A open at fresh marks");

        // Equity feeds stop heartbeating: one tick past the age bound.
        vm.warp(vm.getBlockTimestamp() + MAX_AGE + 1);

        (uint256 nav, bool ok) = router.valueStrategy(address(strategy));
        assertFalse(ok, "stale feed: instant-ineligible");
        assertEq(nav, 0);

        assertEq(vault.totalAssets(), 400e6, "degraded to float-only NAV");
        assertEq(vault.maxWithdraw(alice), 0, "instant exits closed (Lane B only)");
        vm.prank(bob);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(100e6, bob);

        // Feeds resume → Lane A reopens with no intervention.
        fTsla.setUpdatedAt(vm.getBlockTimestamp());
        fAmzn.setUpdatedAt(vm.getBlockTimestamp());
        assertEq(vault.totalAssets(), 1_000e6, "Lane A reopens on fresh marks");
        assertGt(vault.maxWithdraw(alice), 0);
    }

    // ── Lane A closes: rebalance in flight ──

    function test_rebalanceInFlight_closesLaneA_thenReopens() public {
        _depositExecuteLock();

        // Probe from inside the rebalance's first swap: enumeration suspended,
        // router fails closed, so any NAV read mid-rebalance is float-only.
        swapAdapter.arm(address(strategy), address(router));
        vm.prank(proposer);
        strategy.rebalance();

        assertEq(swapAdapter.observedPositions(), 0, "no positions mid-rebalance");
        assertFalse(swapAdapter.observedRouterOk(), "router fails closed mid-rebalance");
        assertEq(swapAdapter.observedRouterValue(), 0);

        // Rebalance done (same rates -> same basket): Lane A reopens.
        (uint256 nav, bool ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "Lane A reopens after rebalance");
        assertEq(nav, 600e6);
        assertEq(vault.totalAssets(), 1_000e6);
    }
}
