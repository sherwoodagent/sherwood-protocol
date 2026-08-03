// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @notice Minimal vault stand-in exposing only `governor()`, mirroring the
///         one hop `_requireAllowedAdapter` reads off `vault()`. Has code
///         (unlike `makeAddr`) so the walk's first hop can resolve.
contract MockVaultWithGovernor {
    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }

    function setGovernor(address governor_) external {
        governor = governor_;
    }
}

/// @notice Minimal governor stand-in exposing only `tierRegistry()`.
contract MockGovernorWithRegistry {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }

    function setTierRegistry(address registry_) external {
        tierRegistry = registry_;
    }
}

/// @notice A governor with code but no `tierRegistry()` selector — the walk's
///         staticcall reverts (no matching function, no fallback), which
///         `_readAddress` must treat as unresolved rather than propagating.
contract MockGovernorNoRegistryGetter {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Minimal registry stand-in: owner-settable per-adapter allowlist.
contract MockTierRegistry {
    mapping(address => bool) public allowed;

    function setAllowed(address adapter, bool value) external {
        allowed[adapter] = value;
    }

    function isAdapterAllowed(address adapter) external view returns (bool) {
        return allowed[adapter];
    }
}

/// @notice A registry whose `isAdapterAllowed` always reverts — models a
///         wrong address wired as the registry.
contract RevertingRegistry {
    function isAdapterAllowed(address) external pure returns (bool) {
        revert("registry broken");
    }
}

/// @notice A registry whose `isAdapterAllowed` returns a malformed (wrong
///         length) payload — models a non-registry contract at that slot.
contract MalformedReturnRegistry {
    function isAdapterAllowed(address) external pure returns (bool, bool) {
        return (true, true);
    }
}

/// @notice Unit tests for the mock vault→governor→registry walk added to
///         `PortfolioStrategy._initialize` (issue #147) and the
///         `MIN_SLIPPAGE_BPS` floor. No fork dependency — every scenario in
///         design.md's "Test and fixture blast radius" ("New tests this
///         change owes") is exercised here against mock contracts.
contract PortfolioStrategyAdapterAllowlistTest is Test {
    PortfolioStrategy public template;
    MockSwapAdapter public adapter;

    ERC20Mock public weth;
    ERC20Mock public tsla;

    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant SLIPPAGE_100 = 100; // 1%, comfortably inside [50, 1000]

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        adapter = new MockSwapAdapter();
        template = new PortfolioStrategy();
    }

    // ── Helpers ──

    /// @dev Single-token basket in push mode, reusing `tsla` as its own feed
    ///      (its `decimals()` is 18, matching `priceDecimals`) — the same
    ///      pattern `test/audit-fixes/Strategy_init_frontrun.t.sol` uses so no
    ///      separate mock aggregator is needed for init-only scenarios.
    function _initData(uint256 maxSlippageBps_) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(uint160(address(tsla))));

        return abi.encode(
            address(weth),
            address(adapter),
            address(0), // push mode
            tokens,
            weights,
            TOTAL_AMOUNT,
            maxSlippageBps_,
            extra,
            priceDecs,
            feedIds
        );
    }

    function _clone() internal returns (PortfolioStrategy) {
        return PortfolioStrategy(Clones.clone(address(template)));
    }

    // ── Adapter allowlist: resolved registry ──

    function test_nonAllowlistedAdapter_refused() public {
        MockTierRegistry registry = new MockTierRegistry();
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        // Adapter deliberately NOT allowlisted.

        PortfolioStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterNotAllowed.selector, address(adapter), address(registry))
        );
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
    }

    function test_allowlistedAdapter_accepted() public {
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
        assertEq(strategy.vault(), address(vault));
        assertEq(address(strategy.swapAdapter()), address(adapter));
    }

    // ── Adapter allowlist: unresolved walk skips ──

    function test_codelessVault_skipsCheck() public {
        address codelessVault = makeAddr("codelessVault");
        PortfolioStrategy strategy = _clone();
        // No registry anywhere — must NOT revert AdapterNotAllowed.
        strategy.initialize(codelessVault, proposer, _initData(SLIPPAGE_100));
        assertEq(strategy.vault(), codelessVault);
    }

    function test_vaultGovernorReturnsZero_skipsCheck() public {
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(0));
        PortfolioStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
        assertEq(strategy.vault(), address(vault));
    }

    function test_governorWithoutRegistryGetter_skipsCheck() public {
        MockGovernorNoRegistryGetter governor = new MockGovernorNoRegistryGetter();
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
        assertEq(strategy.vault(), address(vault));
    }

    function test_governorTierRegistryZero_skipsCheck() public {
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(0));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
        assertEq(strategy.vault(), address(vault));
    }

    // ── Adapter allowlist: resolved-but-unreadable registry fails closed ──

    function test_revertingRegistry_failsClosed() public {
        RevertingRegistry registry = new RevertingRegistry();
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterNotAllowed.selector, address(adapter), address(registry))
        );
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
    }

    function test_malformedReturnRegistry_failsClosed() public {
        MalformedReturnRegistry registry = new MalformedReturnRegistry();
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterNotAllowed.selector, address(adapter), address(registry))
        );
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
    }

    // ── Slippage floor: init ──

    function test_initBelowFloor_49_reverts() public {
        PortfolioStrategy strategy = _clone();
        address codelessVault = makeAddr("codelessVault2");
        vm.expectRevert(PortfolioStrategy.InvalidSlippage.selector);
        strategy.initialize(codelessVault, proposer, _initData(49));
    }

    function test_initBelowFloor_zero_reverts() public {
        PortfolioStrategy strategy = _clone();
        address codelessVault = makeAddr("codelessVault3");
        vm.expectRevert(PortfolioStrategy.InvalidSlippage.selector);
        strategy.initialize(codelessVault, proposer, _initData(0));
    }

    function test_initAboveCeiling_stillReverts() public {
        PortfolioStrategy strategy = _clone();
        address codelessVault = makeAddr("codelessVault4");
        // Hoisted: a call in argument position would consume the pending
        // `vm.expectRevert` before `initialize` itself runs.
        bytes memory data = _initData(strategy.MAX_SLIPPAGE_CEILING_BPS() + 1);
        vm.expectRevert(PortfolioStrategy.InvalidSlippage.selector);
        strategy.initialize(codelessVault, proposer, data);
    }

    function test_initAtExactFloor_succeeds() public {
        PortfolioStrategy strategy = _clone();
        address codelessVault = makeAddr("codelessVault5");
        strategy.initialize(codelessVault, proposer, _initData(strategy.MIN_SLIPPAGE_BPS()));
        assertEq(strategy.maxSlippageBps(), strategy.MIN_SLIPPAGE_BPS());
    }

    // ── Slippage floor: updateParams tighten path ──

    function test_tightenBelowFloor_reverts_valueUnchanged() public {
        PortfolioStrategy strategy = _initAndExecuteSingleToken(SLIPPAGE_100, "tighten-below");

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory noRoutes = new bytes[](0);

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.InvalidSlippage.selector);
        strategy.updateParams(abi.encode(weights, uint256(49), noRoutes));

        assertEq(strategy.maxSlippageBps(), SLIPPAGE_100, "unchanged after a rejected tighten");
    }

    function test_tighten_zeroSentinel_keepsCurrentAlongsideWeights() public {
        PortfolioStrategy strategy = _initAndExecuteSingleToken(SLIPPAGE_100, "tighten-zero");

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory noRoutes = new bytes[](0);

        vm.prank(proposer);
        strategy.updateParams(abi.encode(weights, uint256(0), noRoutes));

        assertEq(strategy.maxSlippageBps(), SLIPPAGE_100, "zero sentinel is not floor-checked");
    }

    function test_floorBottomsOut_reassertSucceeds_belowFails() public {
        PortfolioStrategy strategy = _clone();
        address codelessVault = makeAddr("codelessVault-floor-bottom");
        weth.mint(codelessVault, TOTAL_AMOUNT);
        vm.prank(codelessVault);
        weth.approve(address(strategy), type(uint256).max);
        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);

        strategy.initialize(codelessVault, proposer, _initData(strategy.MIN_SLIPPAGE_BPS()));
        vm.prank(codelessVault);
        strategy.execute();

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory noRoutes = new bytes[](0);

        // Hoisted: `strategy.MIN_SLIPPAGE_BPS()` in argument position would
        // consume the pending `vm.prank`/`vm.expectRevert` before
        // `updateParams` itself runs.
        uint256 floor = strategy.MIN_SLIPPAGE_BPS();

        // Re-asserting the floor (equality) passes the tighten-only `>` check.
        bytes memory reassertData = abi.encode(weights, floor, noRoutes);
        vm.prank(proposer);
        strategy.updateParams(reassertData);
        assertEq(strategy.maxSlippageBps(), floor);

        // Anything strictly below the floor is refused.
        bytes memory belowFloorData = abi.encode(weights, floor - 1, noRoutes);
        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.InvalidSlippage.selector);
        strategy.updateParams(belowFloorData);
    }

    // ── Demotion after init does not brick settlement ──

    function test_demotionAfterInit_doesNotBrickSettle() public {
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        weth.mint(address(vault), TOTAL_AMOUNT);
        vm.prank(address(vault));
        weth.approve(address(strategy), type(uint256).max);

        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);

        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));

        vm.prank(address(vault));
        strategy.execute();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));

        // Demotion clears the allowlist entry for the adapter this strategy
        // is already bound to.
        registry.setAllowed(address(adapter), false);

        // settle() reads no allowlist — it must still complete.
        vm.prank(address(vault));
        strategy.settle();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
    }

    /// @dev Shared setup for the `updateParams` tighten tests: init + execute
    ///      a single-token basket against a codeless vault (hop-1 skip, so the
    ///      allowlist walk is inert here — these tests are about the slippage
    ///      floor, not the allowlist). `salt` keeps each `makeAddr` distinct
    ///      across calls in the same test run.
    function _initAndExecuteSingleToken(uint256 initSlippageBps, string memory salt)
        internal
        returns (PortfolioStrategy strategy)
    {
        strategy = _clone();
        address codelessVault = makeAddr(string(abi.encodePacked("codelessVault-", salt)));
        weth.mint(codelessVault, TOTAL_AMOUNT);
        vm.prank(codelessVault);
        weth.approve(address(strategy), type(uint256).max);
        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);

        strategy.initialize(codelessVault, proposer, _initData(initSlippageBps));
        vm.prank(codelessVault);
        strategy.execute();
    }
}
