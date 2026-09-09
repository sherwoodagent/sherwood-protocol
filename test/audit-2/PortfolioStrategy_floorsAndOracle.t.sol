// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

/// @notice Minimal vault stand-in exposing `governor()` and a revocable agent set.
contract MockVaultWithGovernor {
    mapping(address => bool) internal _revoked;

    function isAgent(address a) external view returns (bool) {
        return !_revoked[a];
    }

    function setAgent(address a, bool allowed) external {
        _revoked[a] = !allowed;
    }

    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }
}

/// @notice Governor stand-in: `tierRegistry()` plus a permissive `IProposalStatus` pair.
contract MockGovernorWithRegistry {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }

    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
    }
}

/// @notice Owner-settable per-address allowlist, standing in for TierRegistry.
contract MockTierRegistry {
    mapping(address => bool) public allowed;

    function setAllowed(address a, bool value) external {
        allowed[a] = value;
    }

    function isAdapterAllowed(address a) external view returns (bool) {
        return allowed[a];
    }

    function isCallableTarget(address a) external view returns (bool) {
        return allowed[a];
    }

    /// @dev Token-feed attestation, permissive by default.
    mapping(address => mapping(bytes32 => bool)) public deniedPair;

    function setPriceSourceForToken(address token, bytes32 src, bool allow) external {
        deniedPair[token][src] = !allow;
    }

    function isPriceSourceForToken(address token, bytes32 src) external view returns (bool) {
        return !deniedPair[token][src];
    }

    function classOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Configurable AggregatorV3-shaped push feed.
contract MockAggregator {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @title PortfolioStrategy_floorsAndOracle
/// @notice Every swap floor is the slot's feed price less `maxSlippageBps`; an
///         unreadable or stale feed reverts on every path, settle included; the
///         price-source allowlist is re-checked live on every rebalance and never on settle.
contract PortfolioStrategy_floorsAndOracleTest is Test {
    PortfolioStrategy public template;

    ERC20Mock public weth;
    ERC20Mock public tsla;

    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant SLIPPAGE_100 = 100; // 1%, comfortably inside [50, 1000]
    uint256 constant START = 10_000_000;
    uint256 constant DEFAULT_MAX_AGE = 26 hours;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        template = new PortfolioStrategy();
        vm.warp(START);
    }

    // ── Helpers ──

    function _clone() internal returns (PortfolioStrategy) {
        return PortfolioStrategy(Clones.clone(address(template)));
    }

    /// @dev Single-token, 100%-weight basket at a 1:1 (1e18) oracle scale, so
    ///      expected minOuts below are exact literals.
    function _initData(address adapter, address feed) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        address[] memory feeds = new address[](1);
        feeds[0] = feed;

        return abi.encode(address(weth), adapter, tokens, weights, TOTAL_AMOUNT, SLIPPAGE_100, extra, priceDecs, feeds);
    }

    /// @dev A working `MockSwapAdapter` pre-funded both directions at the fair 1:1 rate.
    function _deployFundedAdapter() internal returns (MockSwapAdapter adapter) {
        adapter = new MockSwapAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
    }

    struct Rig {
        PortfolioStrategy strategy;
        MockVaultWithGovernor vault;
        MockTierRegistry registry;
        MockSwapAdapter adapter;
        MockAggregator feed;
    }

    /// @dev Registry/governor/vault trio, initialized and EXECUTED against a live,
    ///      allowlisted, fresh 1e18 feed; each test perturbs one variable from here.
    function _rig() internal returns (Rig memory r) {
        r.adapter = _deployFundedAdapter();
        r.feed = new MockAggregator(18, int256(1e18), START);
        r.registry = new MockTierRegistry();
        r.registry.setAllowed(address(r.adapter), true);
        r.registry.setAllowed(address(r.feed), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(r.registry));
        r.vault = new MockVaultWithGovernor(address(governor));

        r.strategy = _clone();
        weth.mint(address(r.vault), TOTAL_AMOUNT);
        vm.prank(address(r.vault));
        weth.approve(address(r.strategy), type(uint256).max);

        r.strategy.initialize(address(r.vault), proposer, _initData(address(r.adapter), address(r.feed)));

        vm.prank(address(r.vault));
        r.strategy.execute();
    }

    // ════════════════════════════════════════════════════════════════════
    // Live proposer standing
    // ════════════════════════════════════════════════════════════════════

    /// @notice A de-registered agent loses `rebalanceDelta` on an already-deployed clone.
    function test_finding9_removedAgentLosesProposerRightsOnLiveClone() public {
        Rig memory r = _rig();

        vm.prank(proposer);
        r.strategy.rebalanceDelta(); // still an agent: ordinary path works

        r.vault.setAgent(proposer, false);

        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.ProposerNoLongerAgent.selector);
        r.strategy.rebalanceDelta();
    }

    // ════════════════════════════════════════════════════════════════════
    // Stale or unreadable feed reverts every priced path, settle included
    // ════════════════════════════════════════════════════════════════════

    /// @notice A feed past `MAX_PUSH_PRICE_AGE` makes `settle()` revert `StalePrice`; the
    ///         position and the Executed state are untouched, so a later settle can still run.
    function test_settle_revertsWhenFeedIsStale_proposalStaysExecuted() public {
        Rig memory r = _rig();
        assertEq(tsla.balanceOf(address(r.strategy)), TOTAL_AMOUNT, "execute should have filled 1:1");

        r.feed.setUpdatedAt(START - DEFAULT_MAX_AGE - 1 hours);
        vm.warp(START + 1);

        uint256 vaultWethBefore = weth.balanceOf(address(r.vault));

        vm.prank(address(r.vault));
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        r.strategy.settle();

        assertEq(tsla.balanceOf(address(r.strategy)), TOTAL_AMOUNT, "nothing sold");
        assertEq(weth.balanceOf(address(r.vault)), vaultWethBefore, "nothing moved");
        assertEq(uint256(r.strategy.state()), uint256(BaseStrategy.State.Executed));

        // The feed comes back: the same settle clears at the feed-priced floor.
        r.feed.setUpdatedAt(vm.getBlockTimestamp());
        vm.prank(address(r.vault));
        r.strategy.settle();
        assertEq(weth.balanceOf(address(r.vault)), vaultWethBefore + TOTAL_AMOUNT, "capital returned");
        assertEq(uint256(r.strategy.state()), uint256(BaseStrategy.State.Settled));
    }

    /// @notice A codeless feed is a typed-call revert, never a quote-anchored fallback.
    function test_settle_revertsWhenFeedIsCodeless() public {
        Rig memory r = _rig();

        vm.etch(address(r.feed), ""); // feed contract "disappears"

        vm.prank(address(r.vault));
        vm.expectRevert();
        r.strategy.settle();
        assertEq(tsla.balanceOf(address(r.strategy)), TOTAL_AMOUNT, "nothing sold");
    }

    /// @notice A feed whose decimals drift after init reverts `InvalidPriceDecimals` at settle.
    function test_settle_revertsWhenFeedDecimalsDrift() public {
        Rig memory r = _rig();

        r.feed.setDecimals(8); // was 18 at init; simulates a live proxy upgrade

        vm.prank(address(r.vault));
        vm.expectRevert(PortfolioStrategy.InvalidPriceDecimals.selector);
        r.strategy.settle();
    }

    /// @notice The max-age boundary: a reading exactly `MAX_PUSH_PRICE_AGE` old clears, one
    ///         second older reverts. Two rigs, forward-only warps.
    function test_settle_clearsAtMaxAge_revertsOneSecondPast() public {
        Rig memory rAt = _rig();
        Rig memory rPast = _rig();

        vm.warp(START + DEFAULT_MAX_AGE);
        uint256 before = weth.balanceOf(address(rAt.vault));
        vm.prank(address(rAt.vault));
        rAt.strategy.settle();
        assertEq(weth.balanceOf(address(rAt.vault)), before + TOTAL_AMOUNT, "age == max clears");

        vm.warp(START + DEFAULT_MAX_AGE + 1);
        vm.prank(address(rPast.vault));
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        rPast.strategy.settle();
    }

    /// @notice A week-old feed reverts settle whether the pool moved honestly or was pushed
    ///         against the vault — there is no widening band, only the feed.
    function test_settle_staleFeedRevertsRegardlessOfPoolMove() public {
        Rig memory rGap = _rig();
        Rig memory rAttack = _rig();

        vm.warp(START + 7 days + 1);

        rGap.adapter.setRate(address(tsla), address(weth), 0.8e18);
        vm.prank(address(rGap.vault));
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        rGap.strategy.settle();

        rAttack.adapter.setRate(address(tsla), address(weth), 0.5e18);
        vm.prank(address(rAttack.vault));
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        rAttack.strategy.settle();
    }

    /// @notice Fresh feed: a manipulated pool is rejected on the floor. Stale feed: the same
    ///         pool never reaches the swap, it reverts `StalePrice` first.
    function test_sellFloor_boundary_freshRejectsManipulation_staleRevertsBeforeSwap() public {
        Rig memory rFresh = _rig();
        rFresh.adapter.setRate(address(tsla), address(weth), 0.5e18); // pool moved 2x against the vault
        vm.prank(address(rFresh.vault));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        rFresh.strategy.settle();

        Rig memory rStale = _rig();
        rStale.adapter.setRate(address(tsla), address(weth), 0.5e18);
        rStale.feed.setUpdatedAt(START - DEFAULT_MAX_AGE - 1);
        vm.warp(START + 1);
        vm.prank(address(rStale.vault));
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        rStale.strategy.settle();
    }

    /// @notice The sell floor is `feedValue * (1 - maxSlippageBps)` for every pool skew: a fill
    ///         at or above it clears at the pool's rate, a fill below it reverts. Nothing about
    ///         the pool's own state moves the floor.
    function test_floorIsFeedPriceMinusMaxSlippage_independentOfPoolState(uint256 rate) public {
        rate = bound(rate, 0.5e18, 1.5e18);
        Rig memory r = _rig();
        r.adapter.setRate(address(tsla), address(weth), rate);

        uint256 floor = (TOTAL_AMOUNT * (10_000 - SLIPPAGE_100)) / 10_000; // feed 1e18, 1% band
        uint256 fill = (TOTAL_AMOUNT * rate) / 1e18;
        uint256 before = weth.balanceOf(address(r.vault));

        vm.prank(address(r.vault));
        if (fill < floor) {
            vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
            r.strategy.settle();
            assertEq(tsla.balanceOf(address(r.strategy)), TOTAL_AMOUNT, "rejected fill sold nothing");
        } else {
            r.strategy.settle();
            assertEq(weth.balanceOf(address(r.vault)) - before, fill, "accepted fill pays the pool rate");
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Buy legs are feed-anchored
    // ════════════════════════════════════════════════════════════════════

    /// @notice `executeProposal` is permissionless: a pool moved right before execute is
    ///         rejected by the feed-priced buy floor.
    function test_execute_buyLeg_revertsOnPoolManipulatedBeforeExecute() public {
        MockSwapAdapter adapter = _deployFundedAdapter();
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        registry.setAllowed(address(feed), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        weth.mint(address(vault), TOTAL_AMOUNT);
        vm.prank(address(vault));
        weth.approve(address(strategy), type(uint256).max);
        strategy.initialize(address(vault), proposer, _initData(address(adapter), address(feed)));

        adapter.setRate(address(weth), address(tsla), 0.01e18); // 100x against the vault

        vm.prank(address(vault));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.execute();
    }

    // ════════════════════════════════════════════════════════════════════
    // Price source re-validated live on every rebalance, never on settle
    // ════════════════════════════════════════════════════════════════════

    function test_rebalanceDelta_revertsWhenPriceSourceRevokedPostExecute() public {
        Rig memory r = _rig();
        r.registry.setAllowed(address(r.feed), false);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.PriceSourceNotAllowed.selector, address(r.feed), address(r.registry)
            )
        );
        r.strategy.rebalanceDelta();
    }

    /// @notice Revoking the feed in the registry does not touch the exit path.
    function test_settle_untouchedByPriceSourceRevocation() public {
        Rig memory r = _rig();
        r.registry.setAllowed(address(r.feed), false);

        uint256 vaultWethBefore = weth.balanceOf(address(r.vault));
        vm.prank(address(r.vault));
        r.strategy.settle();
        assertEq(weth.balanceOf(address(r.vault)), vaultWethBefore + TOTAL_AMOUNT);
    }
}
