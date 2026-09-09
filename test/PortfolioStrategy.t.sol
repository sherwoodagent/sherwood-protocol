// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {
    MockGovernorAlwaysActive,
    MockVaultGovernorStub,
    MockPermissiveTierRegistry
} from "./mocks/MockGovernorAlwaysActive.sol";

/// @notice Minimal Chainlink AggregatorV3 push-feed mock.
contract MockAggregatorV3 {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    /// @dev Simulate a proxy upgrade that changes the reported decimals.
    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

contract PortfolioStrategyTest is Test {
    PortfolioStrategy public template;
    PortfolioStrategy public strategy;
    MockSwapAdapter public adapter;
    MockAggregatorV3 public fTsla;
    MockAggregatorV3 public fAmzn;
    MockAggregatorV3 public fNflx;
    mapping(address token => address feed) public feedOf;

    ERC20Mock public weth; // vault asset
    ERC20Mock public tsla;
    ERC20Mock public amzn;
    ERC20Mock public nflx;

    /// @dev Issue #150 fix: `BaseStrategy.execute()` now resolves
    ///      `vault() -> governor()` and requires the governor's active
    ///      proposal to declare the executing clone as its strategy. This
    ///      suite is about `PortfolioStrategy`'s own math/lifecycle, not that
    ///      binding property, so `vault` is wired to a permissive
    ///      `MockGovernorAlwaysActive` (see that file for the dedicated,
    ///      non-permissive binding tests) instead of a bare `makeAddr`.
    address public vault;
    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18; // 10 WETH
    uint256 constant MAX_SLIPPAGE = 100; // 1%
    uint256 constant RATE_PRECISION = 1e18;

    function setUp() public {
        // Issue #150 fix wiring: vault -> governor() -> permissive strategyOf.
        // The governor also has to answer `tierRegistry()` now: init is
        // fail-closed on registry resolution, so a strategy whose walk dead-ends
        // reverts `TierRegistryUnresolved` before any of this suite's math runs.
        // This suite is about strategy math, not governance binding, so it
        // points at a permissive registry.
        MockGovernorAlwaysActive governorStub = new MockGovernorAlwaysActive();
        governorStub.setTierRegistry(address(new MockPermissiveTierRegistry()));
        vault = address(new MockVaultGovernorStub(address(governorStub)));

        // Deploy mock tokens
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        amzn = new ERC20Mock("Amazon Token", "AMZN", 18);
        nflx = new ERC20Mock("Netflix Token", "NFLX", 18);

        adapter = new MockSwapAdapter();

        // One 18-dec push feed per token, priced at the adapter's fair rate.
        fTsla = new MockAggregatorV3(18, int256(0.01e18), block.timestamp);
        fAmzn = new MockAggregatorV3(18, int256(0.02e18), block.timestamp);
        fNflx = new MockAggregatorV3(18, int256(0.005e18), block.timestamp);
        feedOf[address(tsla)] = address(fTsla);
        feedOf[address(amzn)] = address(fAmzn);
        feedOf[address(nflx)] = address(fNflx);

        // Set exchange rates (1 WETH = 100 TSLA, 50 AMZN, 200 NFLX)
        adapter.setRate(address(weth), address(tsla), 100e18);
        adapter.setRate(address(weth), address(amzn), 50e18);
        adapter.setRate(address(weth), address(nflx), 200e18);

        // Reverse rates for selling
        adapter.setRate(address(tsla), address(weth), 0.01e18); // 1 TSLA = 0.01 WETH
        adapter.setRate(address(amzn), address(weth), 0.02e18); // 1 AMZN = 0.02 WETH
        adapter.setRate(address(nflx), address(weth), 0.005e18); // 1 NFLX = 0.005 WETH

        // Fund vault with WETH
        weth.mint(vault, 100e18);

        // Fund adapter with stock tokens for swaps
        tsla.mint(address(adapter), 100_000e18);
        amzn.mint(address(adapter), 100_000e18);
        nflx.mint(address(adapter), 100_000e18);
        weth.mint(address(adapter), 100_000e18);

        // Deploy template and clone
        template = new PortfolioStrategy();
        address clone = Clones.clone(address(template));
        strategy = PortfolioStrategy(clone);

        // Initialize with 3-token basket: TSLA 40%, AMZN 35%, NFLX 25%
        _initStrategy(strategy);
    }

    function _initStrategy(PortfolioStrategy s) internal {
        address[] memory tokens = new address[](3);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        tokens[2] = address(nflx);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 4000; // 40%
        weights[1] = 3500; // 35%
        weights[2] = 2500; // 25%

        bytes[] memory extraData = new bytes[](3);
        extraData[0] = "";
        extraData[1] = "";
        extraData[2] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        s.initialize(vault, proposer, initData);
    }

    /// @dev `priceDecimals` array of length `n` filled with 18.
    function _pd(uint256 n) internal pure returns (uint8[] memory arr) {
        arr = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            arr[i] = 18;
        }
    }

    /// @dev The fixture feed bound to each token, in basket order.
    function _feedsForTokens(address[] memory tokens) internal view returns (address[] memory arr) {
        arr = new address[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            arr[i] = feedOf[tokens[i]];
        }
    }

    /// @dev `n` fresh feeds at `decimals_` reporting `answer` now.
    function _newFeeds(uint256 n, uint8 decimals_, int256 answer) internal returns (address[] memory arr) {
        arr = new address[](n);
        for (uint256 i; i < n; ++i) {
            arr[i] = address(new MockAggregatorV3(decimals_, answer, block.timestamp));
        }
    }

    // ==================== INITIALIZATION ====================

    function test_initialize() public view {
        assertEq(strategy.vault(), vault);
        assertEq(strategy.proposer(), proposer);
        assertEq(strategy.asset(), address(weth));
        assertEq(address(strategy.swapAdapter()), address(adapter));
        address[] memory feeds = strategy.getFeeds();
        assertEq(feeds[0], address(fTsla));
        assertEq(feeds[1], address(fAmzn));
        assertEq(feeds[2], address(fNflx));
        assertEq(strategy.totalAmount(), TOTAL_AMOUNT);
        assertEq(strategy.maxSlippageBps(), MAX_SLIPPAGE);
        assertEq(strategy.allocationCount(), 3);
        assertEq(strategy.name(), "Portfolio");
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Pending));

        PortfolioStrategy.TokenAllocation[] memory allocs = strategy.getAllocations();
        assertEq(allocs[0].token, address(tsla));
        assertEq(allocs[0].targetWeightBps, 4000);
        assertEq(allocs[1].token, address(amzn));
        assertEq(allocs[1].targetWeightBps, 3500);
        assertEq(allocs[2].token, address(nflx));
        assertEq(allocs[2].targetWeightBps, 2500);
    }

    function test_initialize_twice_reverts() public {
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        _initStrategy(strategy);
    }

    function test_initialize_invalidWeights_reverts() public {
        address clone = Clones.clone(address(template));

        address[] memory tokens = new address[](2);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 4000; // Sum = 9000, not 10000

        bytes[] memory extraData = new bytes[](2);
        extraData[0] = "";
        extraData[1] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        vm.expectRevert(PortfolioStrategy.InvalidWeights.selector);
        PortfolioStrategy(clone).initialize(vault, proposer, initData);
    }

    function test_initialize_tooManyTokens_reverts() public {
        address clone = Clones.clone(address(template));

        address[] memory tokens = new address[](21); // MAX_BASKET_SIZE + 1
        uint256[] memory weights = new uint256[](21);
        bytes[] memory extraData = new bytes[](21);

        for (uint256 i; i < 21; ++i) {
            tokens[i] = makeAddr(string(abi.encodePacked("token", i)));
            weights[i] = (i < 20) ? 476 : 10000 - (476 * 20); // roughly equal
            extraData[i] = "";
        }

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        vm.expectRevert(PortfolioStrategy.TooManyTokens.selector);
        PortfolioStrategy(clone).initialize(vault, proposer, initData);
    }

    function test_initialize_lengthMismatch_reverts() public {
        address clone = Clones.clone(address(template));

        address[] memory tokens = new address[](2);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);

        uint256[] memory weights = new uint256[](3); // mismatched length
        weights[0] = 5000;
        weights[1] = 3000;
        weights[2] = 2000;

        bytes[] memory extraData = new bytes[](2);
        extraData[0] = "";
        extraData[1] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        vm.expectRevert(PortfolioStrategy.LengthMismatch.selector);
        PortfolioStrategy(clone).initialize(vault, proposer, initData);
    }

    function test_initialize_zeroAsset_reverts() public {
        address clone = Clones.clone(address(template));

        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = "";

        bytes memory initData = abi.encode(
            address(0),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        vm.expectRevert(BaseStrategy.ZeroAddress.selector);
        PortfolioStrategy(clone).initialize(vault, proposer, initData);
    }

    /// @notice Sherlock run #1 finding #52 — basket cannot contain duplicate
    ///         token addresses. Pre-fix, the strategy aggregated the shared
    ///         on-chain balance into one slot while `rebalanceDelta` treated
    ///         each slot as a distinct target weight, mis-scaling current value
    ///         and corrupting the rebalance swap sizing.
    function test_initialize_duplicateToken_reverts() public {
        address clone = Clones.clone(address(template));

        // Two slots, both pointing at TSLA.
        address[] memory tokens = new address[](2);
        tokens[0] = address(tsla);
        tokens[1] = address(tsla);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        bytes[] memory extraData = new bytes[](2);
        extraData[0] = "";
        extraData[1] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        vm.expectRevert(abi.encodeWithSelector(PortfolioStrategy.DuplicateToken.selector, address(tsla)));
        PortfolioStrategy(clone).initialize(vault, proposer, initData);
    }

    function test_initialize_zeroAmount_reverts() public {
        address clone = Clones.clone(address(template));

        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            uint256(0),
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        vm.expectRevert(PortfolioStrategy.InvalidAmount.selector);
        PortfolioStrategy(clone).initialize(vault, proposer, initData);
    }

    // ==================== EXECUTE ====================

    function test_execute() public {
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);

        vm.prank(vault);
        strategy.execute();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
        assertTrue(strategy.executed());

        PortfolioStrategy.TokenAllocation[] memory allocs = strategy.getAllocations();

        // TSLA: 40% of 10 WETH = 4 WETH * 100 rate = 400 TSLA
        assertEq(allocs[0].tokenAmount, 400e18);
        assertEq(allocs[0].investedAmount, 4e18);
        assertEq(tsla.balanceOf(address(strategy)), 400e18);

        // AMZN: 35% of 10 WETH = 3.5 WETH * 50 rate = 175 AMZN
        assertEq(allocs[1].tokenAmount, 175e18);
        assertEq(allocs[1].investedAmount, 3.5e18);

        // NFLX: 25% of 10 WETH = 2.5 WETH * 200 rate = 500 NFLX
        assertEq(allocs[2].tokenAmount, 500e18);
        assertEq(allocs[2].investedAmount, 2.5e18);
    }

    function test_execute_onlyVault() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.execute();
    }

    function test_execute_twice_reverts() public {
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(vault);
        strategy.execute();

        vm.prank(vault);
        vm.expectRevert(BaseStrategy.AlreadyExecuted.selector);
        strategy.execute();
    }

    // ==================== SETTLE ====================

    function test_settle() public {
        // Execute first
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(vault);
        strategy.execute();

        uint256 vaultBefore = weth.balanceOf(vault);

        // Settle
        vm.prank(vault);
        strategy.settle();

        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));

        // All tokens sold, WETH returned to vault
        // 400 TSLA * 0.01 = 4 WETH
        // 175 AMZN * 0.02 = 3.5 WETH
        // 500 NFLX * 0.005 = 2.5 WETH
        // Total = 10 WETH (no profit/loss with these rates)
        uint256 returned = weth.balanceOf(vault) - vaultBefore;
        assertEq(returned, TOTAL_AMOUNT);
        assertEq(tsla.balanceOf(address(strategy)), 0);
        assertEq(amzn.balanceOf(address(strategy)), 0);
        assertEq(nflx.balanceOf(address(strategy)), 0);
    }

    function test_settle_withProfit() public {
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(vault);
        strategy.execute();

        // Simulate price appreciation: selling rates go up 20%
        adapter.setRate(address(tsla), address(weth), 0.012e18); // was 0.01
        adapter.setRate(address(amzn), address(weth), 0.024e18); // was 0.02
        adapter.setRate(address(nflx), address(weth), 0.006e18); // was 0.005

        uint256 vaultBefore = weth.balanceOf(vault);

        vm.prank(vault);
        strategy.settle();

        uint256 returned = weth.balanceOf(vault) - vaultBefore;
        assertGt(returned, TOTAL_AMOUNT); // profit!

        // 400 TSLA * 0.012 = 4.8 WETH
        // 175 AMZN * 0.024 = 4.2 WETH
        // 500 NFLX * 0.006 = 3.0 WETH
        // Total = 12.0 WETH (20% profit)
        assertEq(returned, 12e18);
    }

    function test_settle_onlyVault() public {
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(vault);
        strategy.execute();

        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.settle();
    }

    function test_settle_beforeExecute_reverts() public {
        vm.prank(vault);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.settle();
    }

    // ==================== UPDATE PARAMS ====================

    /// @notice Target weights are reviewed with the proposal: once executed, no re-targeting.
    function test_updateParams_weightsFrozenAfterExecute() public {
        _executeStrategy();

        uint256[] memory newWeights = new uint256[](3);
        newWeights[0] = 6000;
        newWeights[1] = 3000;
        newWeights[2] = 1000;

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.WeightsFrozen.selector);
        strategy.updateParams(abi.encode(newWeights, uint256(0), new bytes[](0)));

        PortfolioStrategy.TokenAllocation[] memory allocs = strategy.getAllocations();
        assertEq(allocs[0].targetWeightBps, 4000, "init weight kept");
        assertEq(allocs[1].targetWeightBps, 3500, "init weight kept");
        assertEq(allocs[2].targetWeightBps, 2500, "init weight kept");
    }

    /// @notice Control: the keep-current sentinels still go through with the weights frozen.
    function test_updateParams_emptyUpdateIsANoOp() public {
        _executeStrategy();

        vm.prank(proposer);
        strategy.updateParams(abi.encode(new uint256[](0), uint256(0), new bytes[](0)));

        assertEq(strategy.maxSlippageBps(), MAX_SLIPPAGE, "tolerance kept");
        assertEq(strategy.getAllocations()[0].targetWeightBps, 4000, "weight kept");
    }

    function test_updateParams_onlyProposer() public {
        _executeStrategy();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.updateParams(abi.encode(new uint256[](0), uint256(200), new bytes[](0)));
    }

    function test_updateParams_onlyWhenExecuted() public {
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.updateParams(abi.encode(new uint256[](0), uint256(200), new bytes[](0)));
    }

    /// @notice The `> 0` sentinel means "keep the current value" — it was never
    ///         a monotonicity guard. So the proposer could raise the tolerance
    ///         to 99.99% AFTER the proposal was reviewed and executed, then
    ///         self-settle into a sandwich they control: every floor in
    ///         `execute` / `settle` / `rebalance` / `rebalanceDelta` collapses to
    ///         a rounding error. This class of self-relaxation bug was already
    ///         fixed once before (Sherlock #49); this is the same pattern.
    function test_updateParams_slippageCannotBeLoosened() public {
        _executeStrategy();
        assertEq(strategy.maxSlippageBps(), MAX_SLIPPAGE, "fixture starts at 1%");

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.InvalidSlippage.selector);
        strategy.updateParams(abi.encode(new uint256[](0), uint256(MAX_SLIPPAGE + 1), new bytes[](0)));

        assertEq(strategy.maxSlippageBps(), MAX_SLIPPAGE, "tolerance unchanged after a rejected loosen");
    }

    /// @notice Tightening stays available — the guard bounds the direction, not
    ///         the ability to react.
    function test_updateParams_slippageCanBeTightened() public {
        _executeStrategy();

        vm.prank(proposer);
        strategy.updateParams(abi.encode(new uint256[](0), uint256(MAX_SLIPPAGE - 1), new bytes[](0)));

        assertEq(strategy.maxSlippageBps(), MAX_SLIPPAGE - 1, "tightening is allowed");
    }

    /// @notice Routes are reviewed as part of the proposal, so they are frozen once it executes.
    function test_updateParams_routesAreFrozenAfterExecute() public {
        _executeStrategy();
        bytes[] memory routesBefore = strategy.getSwapExtraData();

        bytes[] memory hostileRoutes = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            hostileRoutes[i] = abi.encode(uint24(10_000)); // a fee tier the proposer seeded
        }

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.RoutesFrozen.selector);
        strategy.updateParams(abi.encode(new uint256[](0), uint256(0), hostileRoutes));

        bytes[] memory routesAfter = strategy.getSwapExtraData();
        for (uint256 i; i < 3; ++i) {
            assertEq(routesAfter[i], routesBefore[i], "route must be unchanged");
        }
    }

    /// @notice The init bound was only `< BPS_DENOMINATOR`, so a proposal could
    ///         seat a 99.99% tolerance from the very start and never need to
    ///         relax it — the tighten-only guard alone would not have helped.
    function test_initialize_rejectsSlippageAboveTheProtocolCeiling() public {
        PortfolioStrategy fresh = PortfolioStrategy(Clones.clone(address(template)));

        address[] memory tokens = new address[](3);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        tokens[2] = address(nflx);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 4000;
        weights[1] = 3500;
        weights[2] = 2500;
        bytes[] memory extraData = new bytes[](3);

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            fresh.MAX_SLIPPAGE_CEILING_BPS() + 1,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );

        vm.expectRevert(PortfolioStrategy.InvalidSlippage.selector);
        fresh.initialize(vault, proposer, initData);
    }

    // ==================== REBALANCE DELTA ====================

    /// @notice With the weights fixed, `rebalanceDelta` trades only price drift: TSLA doubles,
    ///         the overweight slot is sold down and the other two are topped up to target.
    function test_rebalanceDelta() public {
        _executeStrategy();
        PortfolioStrategy.TokenAllocation[] memory before_ = strategy.getAllocations();

        _setPrice(tsla, fTsla, 0.02e18);

        vm.prank(proposer);
        strategy.rebalanceDelta();

        PortfolioStrategy.TokenAllocation[] memory after_ = strategy.getAllocations();
        assertLt(after_[0].tokenAmount, before_[0].tokenAmount, "TSLA sold down");
        assertGt(after_[1].tokenAmount, before_[1].tokenAmount, "AMZN topped up");
        assertGt(after_[2].tokenAmount, before_[2].tokenAmount, "NFLX topped up");
        _assertSharesAtTargets();
    }

    /// @notice The round-trip drain needs the target to move. 20 `rebalanceDelta` calls against
    ///         a route filling exactly at the floor, with a weight flip attempted before each,
    ///         leave the basket within one leg of slippage of where it started.
    function test_rebalanceDelta_cannotBeLoopedIntoADrainWhenWeightsAreFrozen() public {
        _setFloorFillingRoutes();
        _executeStrategy();
        uint256 start = _fairValue();
        assertGt(start, 0, "premise: basket bought");

        uint256[] memory allTsla = new uint256[](3);
        allTsla[0] = 10_000;
        uint256[] memory allAmzn = new uint256[](3);
        allAmzn[1] = 10_000;
        bytes memory flipA = abi.encodeCall(strategy.updateParams, (abi.encode(allTsla, uint256(0), new bytes[](0))));
        bytes memory flipB = abi.encodeCall(strategy.updateParams, (abi.encode(allAmzn, uint256(0), new bytes[](0))));

        for (uint256 i; i < 10; ++i) {
            // The flip is attempted, not required to land: the bound below is what is pinned.
            vm.prank(proposer);
            (bool okA,) = address(strategy).call(flipA);
            okA;
            vm.prank(proposer);
            strategy.rebalanceDelta();
            vm.prank(proposer);
            (bool okB,) = address(strategy).call(flipB);
            okB;
            vm.prank(proposer);
            strategy.rebalanceDelta();
        }

        assertGe(_fairValue(), (start * (10_000 - 2 * MAX_SLIPPAGE)) / 10_000, "basket drained through rebalanceDelta");
    }

    function test_rebalanceDelta_onlyProposer() public {
        _executeStrategy();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.rebalanceDelta();
    }

    // ==================== FULL LIFECYCLE ====================

    function test_fullLifecycle() public {
        // 1. Execute
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(vault);
        strategy.execute();

        // 2. Rebalance (no drift yet: a no-op)
        vm.prank(proposer);
        strategy.rebalanceDelta();

        // 3. Prices go up 10%
        adapter.setRate(address(tsla), address(weth), 0.011e18);
        adapter.setRate(address(amzn), address(weth), 0.022e18);
        adapter.setRate(address(nflx), address(weth), 0.0055e18);

        // 4. Settle
        uint256 vaultBefore = weth.balanceOf(vault);
        vm.prank(vault);
        strategy.settle();

        uint256 returned = weth.balanceOf(vault) - vaultBefore;
        assertGt(returned, TOTAL_AMOUNT); // profit from 10% appreciation
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
    }

    // ==================== CLONING ====================

    function test_clonesHaveIsolatedStorage() public {
        address clone2 = Clones.clone(address(template));
        PortfolioStrategy strategy2 = PortfolioStrategy(clone2);

        // Initialize with different params (single token, 100%)
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            5e18,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        strategy2.initialize(vault, proposer, initData);

        assertEq(strategy.allocationCount(), 3);
        assertEq(strategy2.allocationCount(), 1);
        assertEq(strategy.totalAmount(), 10e18);
        assertEq(strategy2.totalAmount(), 5e18);
    }

    // ==================== EDGE CASES ====================

    /// @notice Single-token portfolio: 100% TSLA — execute, rebalance, settle
    function test_singleTokenPortfolio() public {
        address clone = Clones.clone(address(template));
        PortfolioStrategy s = PortfolioStrategy(clone);

        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000; // 100%
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            5e18,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        s.initialize(vault, proposer, initData);

        assertEq(s.allocationCount(), 1);

        // Execute: 5 WETH → 500 TSLA
        vm.prank(vault);
        weth.approve(address(s), 5e18);
        vm.prank(vault);
        s.execute();

        PortfolioStrategy.TokenAllocation[] memory allocs = s.getAllocations();
        assertEq(allocs[0].tokenAmount, 500e18); // 5 WETH * 100 rate
        assertEq(allocs[0].investedAmount, 5e18);
        assertEq(tsla.balanceOf(address(s)), 500e18);

        // Rebalance (same weight, no drift: delta swaps nothing)
        vm.prank(proposer);
        s.rebalanceDelta();

        allocs = s.getAllocations();
        assertEq(allocs[0].tokenAmount, 500e18); // same — no price change

        // Settle
        uint256 vaultBefore = weth.balanceOf(vault);
        vm.prank(vault);
        s.settle();

        uint256 returned = weth.balanceOf(vault) - vaultBefore;
        assertEq(returned, 5e18); // no profit/loss
        assertEq(tsla.balanceOf(address(s)), 0);
    }

    /// @notice Max basket size (20 tokens) — should succeed
    function test_maxBasketSize_20tokens() public {
        address clone = Clones.clone(address(template));
        PortfolioStrategy s = PortfolioStrategy(clone);

        uint256 count = 20;
        address[] memory tokens = new address[](count);
        uint256[] memory weights = new uint256[](count);
        bytes[] memory extraData = new bytes[](count);

        // Create 20 mock tokens, set rates, fund adapter
        for (uint256 i; i < count; ++i) {
            ERC20Mock token = new ERC20Mock(
                string(abi.encodePacked("Token", vm.toString(i))), string(abi.encodePacked("T", vm.toString(i))), 18
            );
            tokens[i] = address(token);
            weights[i] = 500; // 5% each, 20 * 500 = 10000
            extraData[i] = "";

            // Set swap rates: 1 WETH → 10 token, 1 token → 0.1 WETH
            adapter.setRate(address(weth), address(token), 10e18);
            adapter.setRate(address(token), address(weth), 0.1e18);
            token.mint(address(adapter), 1_000_000e18);
        }

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            20e18,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _newFeeds(count, 18, int256(0.1e18))
        );
        s.initialize(vault, proposer, initData);

        assertEq(s.allocationCount(), 20);

        // Execute: 20 WETH split equally
        weth.mint(vault, 20e18); // extra WETH for this test
        vm.prank(vault);
        weth.approve(address(s), 20e18);
        vm.prank(vault);
        s.execute();

        // Each token: 5% of 20 WETH = 1 WETH * 10 rate = 10 tokens
        PortfolioStrategy.TokenAllocation[] memory allocs = s.getAllocations();
        for (uint256 i; i < count; ++i) {
            assertEq(allocs[i].tokenAmount, 10e18);
            assertEq(allocs[i].investedAmount, 1e18);
        }

        // Settle: all sold back at same rates → 20 WETH returned
        uint256 vaultBefore = weth.balanceOf(vault);
        vm.prank(vault);
        s.settle();

        uint256 returned = weth.balanceOf(vault) - vaultBefore;
        assertEq(returned, 20e18);
    }

    /// @notice Zero-weight token at initialization — valid (sum=10000), token skipped during execute
    function test_zeroWeightToken_execute() public {
        address clone = Clones.clone(address(template));
        PortfolioStrategy s = PortfolioStrategy(clone);

        address[] memory tokens = new address[](3);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        tokens[2] = address(nflx);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 6000; // 60%
        weights[1] = 4000; // 40%
        weights[2] = 0; // 0% — intentionally excluded

        bytes[] memory extraData = new bytes[](3);
        extraData[0] = "";
        extraData[1] = "";
        extraData[2] = "";

        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );

        // 6000 + 4000 + 0 = 10000 → valid init
        s.initialize(vault, proposer, initData);
        assertEq(s.allocationCount(), 3);

        // Execute: NFLX should get 0 allocation
        vm.prank(vault);
        weth.approve(address(s), TOTAL_AMOUNT);
        vm.prank(vault);
        s.execute();

        PortfolioStrategy.TokenAllocation[] memory allocs = s.getAllocations();

        // TSLA: 60% of 10 WETH = 6 WETH * 100 = 600 TSLA
        assertEq(allocs[0].tokenAmount, 600e18);
        assertEq(allocs[0].investedAmount, 6e18);

        // AMZN: 40% of 10 WETH = 4 WETH * 50 = 200 AMZN
        assertEq(allocs[1].tokenAmount, 200e18);
        assertEq(allocs[1].investedAmount, 4e18);

        // NFLX: 0% → skipped, no tokens bought
        assertEq(allocs[2].tokenAmount, 0);
        assertEq(allocs[2].investedAmount, 0);
        assertEq(nflx.balanceOf(address(s)), 0);
    }

    /// @notice A 0% slot that comes to hold tokens (here: a donation) is sold on `rebalanceDelta`
    ///         and not re-bought; the proceeds top up the weighted slots.
    function test_rebalanceDelta_zeroWeightSlotIsSoldNotRebought() public {
        PortfolioStrategy s = _initZeroWeightStrategy();
        _execute(s);
        PortfolioStrategy.TokenAllocation[] memory before_ = s.getAllocations();
        assertEq(before_[2].tokenAmount, 0, "premise: 0% slot empty at execute");

        nflx.mint(address(s), 100e18); // 0.5 WETH of drift into the 0% slot

        vm.prank(proposer);
        s.rebalanceDelta();

        PortfolioStrategy.TokenAllocation[] memory after_ = s.getAllocations();
        assertEq(after_[2].tokenAmount, 0, "0% slot re-bought");
        assertEq(nflx.balanceOf(address(s)), 0, "0% slot not sold");
        assertGt(after_[0].tokenAmount, before_[0].tokenAmount, "TSLA topped up");
        assertGt(after_[1].tokenAmount, before_[1].tokenAmount, "AMZN topped up");
        assertEq(after_[0].targetWeightBps, 6000);
        assertEq(after_[1].targetWeightBps, 4000);
        assertEq(after_[2].targetWeightBps, 0);
    }

    /// @notice Settle after a rebalance that emptied the 0% slot: only the two active slots sell.
    function test_settle_afterZeroWeightRebalance() public {
        PortfolioStrategy s = _initZeroWeightStrategy();
        _execute(s);
        nflx.mint(address(s), 100e18);
        vm.prank(proposer);
        s.rebalanceDelta();

        uint256 vaultBefore = weth.balanceOf(vault);
        vm.prank(vault);
        s.settle();

        uint256 returned = weth.balanceOf(vault) - vaultBefore;
        assertGt(returned, 0);
        assertEq(nflx.balanceOf(address(s)), 0);
        assertEq(tsla.balanceOf(address(s)), 0);
        assertEq(amzn.balanceOf(address(s)), 0);
    }

    /// @notice Three rounds of drift, each rebalanced back to the init weights; settle still
    ///         unwinds everything.
    function test_multipleRebalanceDeltas() public {
        _executeStrategy();

        _setPrice(tsla, fTsla, 0.02e18);
        vm.prank(proposer);
        strategy.rebalanceDelta();
        _assertSharesAtTargets();

        _setPrice(amzn, fAmzn, 0.01e18);
        vm.prank(proposer);
        strategy.rebalanceDelta();
        _assertSharesAtTargets();

        _setPrice(nflx, fNflx, 0.01e18);
        vm.prank(proposer);
        strategy.rebalanceDelta();
        _assertSharesAtTargets();

        uint256 vaultBefore = weth.balanceOf(vault);
        vm.prank(vault);
        strategy.settle();
        assertGt(weth.balanceOf(vault) - vaultBefore, 0);
        assertEq(tsla.balanceOf(address(strategy)), 0);
        assertEq(amzn.balanceOf(address(strategy)), 0);
        assertEq(nflx.balanceOf(address(strategy)), 0);
    }

    // ==================== GAS BENCHMARKS ====================

    /// @notice Gas cost at max basket size (20 tokens) — delta rebalance
    function test_gas_rebalanceDelta_20tokens() public {
        address clone = Clones.clone(address(template));
        PortfolioStrategy s = PortfolioStrategy(clone);

        uint256 count = 20;
        address[] memory tokens = new address[](count);
        uint256[] memory weights = new uint256[](count);
        bytes[] memory extraData = new bytes[](count);

        for (uint256 i; i < count; ++i) {
            ERC20Mock token = new ERC20Mock(
                string(abi.encodePacked("Token", vm.toString(i))), string(abi.encodePacked("T", vm.toString(i))), 18
            );
            tokens[i] = address(token);
            weights[i] = 500; // 5% each
            extraData[i] = "";

            adapter.setRate(address(weth), address(token), 10e18);
            adapter.setRate(address(token), address(weth), 0.1e18);
            token.mint(address(adapter), 1_000_000e18);
        }
        address[] memory feeds = _newFeeds(count, 18, int256(0.1e18));

        bytes memory initData = abi.encode(
            address(weth), address(adapter), tokens, weights, 20e18, MAX_SLIPPAGE, extraData, _pd(tokens.length), feeds
        );
        s.initialize(vault, proposer, initData);

        weth.mint(vault, 20e18);

        vm.prank(vault);
        weth.approve(address(s), 20e18);
        vm.prank(vault);
        s.execute();

        // Token 0 doubles: one sell, nineteen buys.
        _setPrice(ERC20Mock(tokens[0]), MockAggregatorV3(feeds[0]), 0.2e18);

        vm.prank(proposer);
        uint256 gasBefore = gasleft();
        s.rebalanceDelta();
        uint256 gasDelta = gasBefore - gasleft();

        emit log_named_uint("Gas: rebalanceDelta (Chainlink)   20 tokens", gasDelta);
    }

    /// @notice The sell-all/re-buy `rebalance()` is gone: its selector has no dispatch on a live clone.
    function test_rebalanceIsGone_selectorReverts() public {
        _executeStrategy();

        vm.prank(proposer);
        (bool ok,) = address(strategy).call(abi.encodeWithSignature("rebalance()"));
        assertFalse(ok, "rebalance() must not dispatch");

        vm.prank(proposer);
        (bool okDelta,) = address(strategy).call(abi.encodeWithSignature("rebalanceDelta()"));
        assertTrue(okDelta, "control: rebalanceDelta() still dispatches");
    }

    // ==================== HELPERS ====================

    function _executeStrategy() internal {
        vm.prank(vault);
        weth.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(vault);
        strategy.execute();
    }

    /// @dev Move a token's price at its feed and at the adapter (both directions).
    function _setPrice(ERC20Mock token, MockAggregatorV3 feed, uint256 priceInWeth) internal {
        feed.set(int256(priceInWeth), block.timestamp);
        adapter.setRate(address(token), address(weth), priceInWeth);
        adapter.setRate(address(weth), address(token), 1e36 / priceInWeth);
    }

    /// @dev Every fixture route fills exactly at the feed floor: feed x (1 - MAX_SLIPPAGE).
    function _setFloorFillingRoutes() internal {
        uint256 keep = 10_000 - MAX_SLIPPAGE;
        adapter.setRate(address(weth), address(tsla), (100e18 * keep) / 10_000);
        adapter.setRate(address(weth), address(amzn), (50e18 * keep) / 10_000);
        adapter.setRate(address(weth), address(nflx), (200e18 * keep) / 10_000);
        adapter.setRate(address(tsla), address(weth), (0.01e18 * keep) / 10_000);
        adapter.setRate(address(amzn), address(weth), (0.02e18 * keep) / 10_000);
        adapter.setRate(address(nflx), address(weth), (0.005e18 * keep) / 10_000);
    }

    /// @dev Basket value in WETH at the feeds, plus idle WETH.
    function _fairValue() internal view returns (uint256 total) {
        PortfolioStrategy.TokenAllocation[] memory allocs = strategy.getAllocations();
        for (uint256 i; i < allocs.length; ++i) {
            (, int256 answer,,,) = MockAggregatorV3(feedOf[allocs[i].token]).latestRoundData();
            total += (IERC20(allocs[i].token).balanceOf(address(strategy)) * uint256(answer)) / 1e18;
        }
        total += weth.balanceOf(address(strategy));
    }

    /// @dev Each slot's value share is at its init weight, to rounding.
    function _assertSharesAtTargets() internal view {
        PortfolioStrategy.TokenAllocation[] memory allocs = strategy.getAllocations();
        uint256 total = _fairValue();
        for (uint256 i; i < allocs.length; ++i) {
            (, int256 answer,,,) = MockAggregatorV3(feedOf[allocs[i].token]).latestRoundData();
            uint256 value = (IERC20(allocs[i].token).balanceOf(address(strategy)) * uint256(answer)) / 1e18;
            assertApproxEqAbs((value * 10_000) / total, allocs[i].targetWeightBps, 10, "slot off target");
        }
    }

    /// @dev Fresh clone at TSLA 60% / AMZN 40% / NFLX 0%.
    function _initZeroWeightStrategy() internal returns (PortfolioStrategy s) {
        s = PortfolioStrategy(Clones.clone(address(template)));
        address[] memory tokens = new address[](3);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        tokens[2] = address(nflx);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 6000;
        weights[1] = 4000;
        bytes memory initData = abi.encode(
            address(weth),
            address(adapter),
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            new bytes[](3),
            _pd(tokens.length),
            _feedsForTokens(tokens)
        );
        s.initialize(vault, proposer, initData);
    }

    // ==================== SHERLOCK #21 + #29: 1e8 FEED REGRESSION ====================

    /// @dev Sherlock #21/#29 regression — `rebalanceDelta` previously
    ///      divided by hard-coded `PRICE_PRECISION = 1e18` regardless of the
    ///      declared `_priceDecimals[i]`. For tokenized-stock Chainlink feeds
    ///      (8 decimals), the math under-scaled by 10^10 ×, producing a
    ///      `currentValue` snapshot that was effectively zero and breaking
    ///      every downstream weight check. With the per-allocation
    ///      `_tokensToValue` / `_valueToTokens` helpers, the rebalance
    ///      succeeds with 8-decimal feeds and lands within slippage of the
    ///      target weights.
    function test_rebalanceDelta_handles1e8FeedDecimals() public {
        // Deploy a fresh clone configured with 8-decimal price feeds. Tokens
        // (TSLA / AMZN / NFLX) remain 18-decimal — only the feed scale
        // changes. Asset (WETH) is 18-decimal.
        address clone = Clones.clone(address(template));
        PortfolioStrategy s = PortfolioStrategy(clone);

        address[] memory tokens = new address[](3);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        tokens[2] = address(nflx);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 4000;
        weights[1] = 3500;
        weights[2] = 2500;
        bytes[] memory extraData = new bytes[](3);
        uint8[] memory pd = new uint8[](3);
        pd[0] = 8; // Chainlink tokenized-stock feed
        pd[1] = 8;
        pd[2] = 8;
        // 8-dec prices at the adapter's fair rate: TSLA 0.01, AMZN 0.02, NFLX 0.005 WETH.
        address[] memory feeds = new address[](3);
        feeds[0] = address(new MockAggregatorV3(8, int256(1e6), block.timestamp));
        feeds[1] = address(new MockAggregatorV3(8, int256(2e6), block.timestamp));
        feeds[2] = address(new MockAggregatorV3(8, int256(5e5), block.timestamp));

        bytes memory initData = abi.encode(
            address(weth), address(adapter), tokens, weights, TOTAL_AMOUNT, MAX_SLIPPAGE, extraData, pd, feeds
        );
        s.initialize(vault, proposer, initData);

        vm.prank(vault);
        weth.approve(address(s), TOTAL_AMOUNT);
        vm.prank(vault);
        s.execute();
        PortfolioStrategy.TokenAllocation[] memory before_ = s.getAllocations();

        // TSLA doubles on its 8-dec feed and at the adapter.
        MockAggregatorV3(feeds[0]).set(int256(2e6), block.timestamp);
        adapter.setRate(address(tsla), address(weth), 0.02e18);
        adapter.setRate(address(weth), address(tsla), 50e18);

        vm.prank(proposer);
        s.rebalanceDelta();

        // Pre-fix this either reverted on division-by-zero / no-op'd / OR
        // ran swaps with effectively-zero minOuts. With the fix, the drift is traded back.
        PortfolioStrategy.TokenAllocation[] memory after_ = s.getAllocations();
        assertLt(after_[0].tokenAmount, before_[0].tokenAmount, "TSLA sold back toward 40%");
        assertGt(after_[1].tokenAmount, before_[1].tokenAmount, "AMZN topped up");
        assertGt(after_[2].tokenAmount, before_[2].tokenAmount, "NFLX topped up");
    }

    // ==================== FEED FAILURE MODES ====================

    /// @dev Fresh 8-dec-feed clone (Robinhood's live feed scale). Tokens and asset are 18-dec.
    function _init8DecStrategy()
        internal
        returns (PortfolioStrategy s, MockAggregatorV3 f0, MockAggregatorV3 f1, MockAggregatorV3 f2)
    {
        f0 = new MockAggregatorV3(8, int256(1e6), block.timestamp);
        f1 = new MockAggregatorV3(8, int256(2e6), block.timestamp);
        f2 = new MockAggregatorV3(8, int256(5e5), block.timestamp);

        s = PortfolioStrategy(Clones.clone(address(template)));

        address[] memory tokens = new address[](3);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        tokens[2] = address(nflx);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 4000;
        weights[1] = 3500;
        weights[2] = 2500;
        bytes[] memory extraData = new bytes[](3);
        uint8[] memory pd = new uint8[](3);
        pd[0] = 8;
        pd[1] = 8;
        pd[2] = 8;
        address[] memory feeds = new address[](3);
        feeds[0] = address(f0);
        feeds[1] = address(f1);
        feeds[2] = address(f2);

        s.initialize(
            vault,
            proposer,
            abi.encode(
                address(weth), address(adapter), tokens, weights, TOTAL_AMOUNT, MAX_SLIPPAGE, extraData, pd, feeds
            )
        );
    }

    function _execute(PortfolioStrategy s) internal {
        vm.prank(vault);
        weth.approve(address(s), TOTAL_AMOUNT);
        vm.prank(vault);
        s.execute();
    }

    /// @dev Single-slot (100% TSLA) init calldata bound to `feed` at 8 decimals.
    function _singleInitData(address feed) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extraData = new bytes[](1);
        uint8[] memory pd = new uint8[](1);
        pd[0] = 8;
        address[] memory feeds = new address[](1);
        feeds[0] = feed;
        return
            abi.encode(
                address(weth), address(adapter), tokens, weights, TOTAL_AMOUNT, MAX_SLIPPAGE, extraData, pd, feeds
            );
    }

    /// @notice A feed whose live `decimals()` disagrees with the declared scale is rejected at init.
    function test_init_decimalsMismatch_reverts() public {
        MockAggregatorV3 feed = new MockAggregatorV3(18, int256(1e6), block.timestamp);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        bytes memory initData = _singleInitData(address(feed));
        vm.expectRevert(PortfolioStrategy.InvalidPriceDecimals.selector);
        s.initialize(vault, proposer, initData);
    }

    /// @notice A zero feed address is rejected at init.
    function test_init_zeroFeed_reverts() public {
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        bytes memory initData = _singleInitData(address(0));
        vm.expectRevert(BaseStrategy.ZeroAddress.selector);
        s.initialize(vault, proposer, initData);
    }

    /// @notice `rebalanceDelta` prices every slot off its 8-dec feed and trades the drift back.
    function test_rebalanceDelta_8DecFeeds_happyPath() public {
        (PortfolioStrategy s, MockAggregatorV3 f0,,) = _init8DecStrategy();
        _execute(s);
        PortfolioStrategy.TokenAllocation[] memory before_ = s.getAllocations();

        f0.set(int256(2e6), block.timestamp);
        adapter.setRate(address(tsla), address(weth), 0.02e18);
        adapter.setRate(address(weth), address(tsla), 50e18);

        vm.prank(proposer);
        s.rebalanceDelta();

        PortfolioStrategy.TokenAllocation[] memory after_ = s.getAllocations();
        assertLt(after_[0].tokenAmount, before_[0].tokenAmount, "TSLA sold back toward 40%");
        assertGt(after_[1].tokenAmount, before_[1].tokenAmount, "AMZN topped up");
        assertGt(after_[2].tokenAmount, before_[2].tokenAmount, "NFLX topped up");
    }

    /// @notice One feed past `MAX_PUSH_PRICE_AGE` reverts the whole delta rebalance.
    function test_rebalanceDelta_stalePrice_reverts() public {
        (PortfolioStrategy s, MockAggregatorV3 f0,,) = _init8DecStrategy();
        _execute(s);

        f0.set(int256(1e6), vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 26 hours + 1);

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        s.rebalanceDelta();
    }

    /// @notice A non-positive answer reverts `InvalidPrice` on the delta path.
    function test_rebalanceDelta_zeroAnswer_reverts() public {
        (PortfolioStrategy s, MockAggregatorV3 f0,,) = _init8DecStrategy();
        _execute(s);

        f0.set(int256(0), vm.getBlockTimestamp());

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.InvalidPrice.selector);
        s.rebalanceDelta();
    }

    /// @notice Execute is refused while ANY traded slot's feed is stale, and clears once it is refreshed.
    function test_execute_revertsWhenAnyBasketFeedIsStale() public {
        (PortfolioStrategy s, MockAggregatorV3 f0, MockAggregatorV3 f1, MockAggregatorV3 f2) = _init8DecStrategy();
        vm.prank(vault);
        weth.approve(address(s), TOTAL_AMOUNT);

        // Only the middle slot goes dark; the other two stay fresh.
        vm.warp(vm.getBlockTimestamp() + 26 hours + 1);
        f0.set(int256(1e6), vm.getBlockTimestamp());
        f2.set(int256(5e5), vm.getBlockTimestamp());

        vm.prank(vault);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        s.execute();
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending), "no capital moved");
        assertEq(weth.balanceOf(vault), 100e18, "vault untouched");

        // Control: refresh the dark feed and the same execute fills.
        f1.set(int256(2e6), vm.getBlockTimestamp());
        vm.prank(vault);
        s.execute();
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Executed));
    }

    /// @notice A proxy upgrade that changes the feed's decimals after init reverts every priced path.
    function test_rebalanceDelta_decimalsDrift_reverts() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, int256(1e6), block.timestamp);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        s.initialize(vault, proposer, _singleInitData(address(feed)));
        _execute(s);

        feed.setDecimals(18);
        feed.set(int256(1e6), vm.getBlockTimestamp());

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.InvalidPriceDecimals.selector);
        s.rebalanceDelta();
    }
}
