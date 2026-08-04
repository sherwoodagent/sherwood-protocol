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

/// @notice Minimal governor stand-in exposing `tierRegistry()` (the #147
///         adapter-allowlist walk) plus, since issue #150, a DELIBERATELY
///         PERMISSIVE `IProposalStatus` pair for `BaseStrategy.execute()`'s
///         active-proposal-binding check: `strategyOf` answers `msg.sender`
///         regardless of `pid`, so any clone that resolves to this governor
///         via a `MockVaultWithGovernor` passes the check without per-test
///         proposal wiring. This suite is about the adapter allowlist and the
///         slippage floor, not the binding property itself — see
///         `test/audit-fixes/Strategy_cloneRatchetBinding.t.sol` for the
///         dedicated, non-permissive tests of that.
contract MockGovernorWithRegistry {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }

    function setTierRegistry(address registry_) external {
        tierRegistry = registry_;
    }

    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
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

    /// @dev Token↔price-source attestation, permissive by default so the
    ///      adapter-allowlist cases keep testing the adapter axis in
    ///      isolation. The hostile fixtures below deliberately do NOT gain
    ///      this selector: `_requireAllowedAdapter` runs first, so those tests
    ///      still fail where they were written to fail.
    mapping(address => mapping(bytes32 => bool)) public deniedPair;

    function setPriceSourceForToken(address token, bytes32 src, bool allow) external {
        deniedPair[token][src] = !allow;
    }

    function isPriceSourceForToken(address token, bytes32 src) external view returns (bool) {
        return !deniedPair[token][src];
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

/// @notice Minimal Chainlink push-feed aggregator, local to this file so the
///         rebalanceDelta happy-path regression test (issue #147) can price a
///         real allocation. `rebalance()` never calls `_verifyPrice`, and the
///         demoted-adapter `rebalanceDelta` test reverts before `_verifyPrice`
///         runs, so only one test in this file ever calls `latestRoundData`.
contract AllowlistMockAggregator {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @notice Unit tests for the mock vault→governor→registry walk added to
///         `PortfolioStrategy._initialize` (issue #147) and the
///         `MIN_SLIPPAGE_BPS` floor. No fork dependency — every scenario in
///         design.md's "Test and fixture blast radius" ("New tests this
///         change owes") is exercised here against mock contracts.
///
///         Also covers the Pashov-audit follow-up remediation on issue #147:
///         `rebalance()`/`rebalanceDelta()` now re-check the bound adapter's
///         allowlist status live (fail-closed on demotion), distinct from
///         `_initialize`'s one-shot check and from `_execute`/`_settle`'s
///         deliberate no-recheck.
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

    /// @dev Same single-token push-mode basket as `_initData`, but with a
    ///      caller-supplied feed address — needed by any test whose strategy
    ///      reaches `latestRoundData()` on the feed, whether via
    ///      `rebalanceDelta`'s `_verifyPrice` or via `settle()`/`rebalance()`'s
    ///      `_sellFloor` -> `_pushFeedPrice` (Finding #10). `_initData`'s
    ///      tsla-as-its-own-feed shortcut only works for tests that never
    ///      reach either path, since `tsla` (`ERC20Mock`) has no
    ///      `latestRoundData()`.
    function _initDataWithFeed(uint256 maxSlippageBps_, address feed) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(uint160(feed)));

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

    /// @dev Shared setup for the rebalance/rebalanceDelta live-recheck tests
    ///      (issue #147 Pashov finding): init + execute against a FULLY
    ///      RESOLVED vault→governor→registry walk with the adapter
    ///      allowlisted — same fixture shape as
    ///      `test_demotionAfterInit_doesNotBrickSettle`, so settle's
    ///      deliberate no-recheck and rebalance's new recheck are exercised
    ///      against the same kind of registry. `rebalance()` never calls
    ///      `_verifyPrice`, but its sell leg does reach `_pushFeedPrice` via
    ///      `_sellFloor` (Finding #10), which needs a feed that actually
    ///      implements `latestRoundData()` — hence the real
    ///      `AllowlistMockAggregator` below rather than `_initData`'s
    ///      tsla-as-its-own-feed shortcut.
    function _initAndExecuteWithResolvedRegistry(uint256 initSlippageBps)
        internal
        returns (PortfolioStrategy strategy, MockTierRegistry registry, MockVaultWithGovernor vault)
    {
        registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);

        // NOT `_initData`'s tsla-as-its-own-feed shortcut: `rebalance()`'s
        // sell leg reaches `_sellFloor` -> `_pushFeedPrice`, which calls
        // `latestRoundData()` on the push-mode feed (Finding #10's
        // oracle-anchored sell floor, added after this fixture and its
        // doc comment were written). `tsla` is a plain `ERC20Mock` with no
        // `latestRoundData()`, so a strategy built with `_initData` reverts
        // with no return data the moment `rebalance()`/`settle()` tries to
        // sell it — a real `AllowlistMockAggregator` is needed here, the
        // same as `_initAndExecuteWithResolvedRegistryAndAggregator` already
        // uses for the `rebalanceDelta` happy path.
        AllowlistMockAggregator feed = new AllowlistMockAggregator(18, int256(1e18), block.timestamp);
        registry.setAllowed(address(feed), true);

        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        vault = new MockVaultWithGovernor(address(governor));

        strategy = _clone();
        weth.mint(address(vault), TOTAL_AMOUNT);
        vm.prank(address(vault));
        weth.approve(address(strategy), type(uint256).max);

        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);

        strategy.initialize(address(vault), proposer, _initDataWithFeed(initSlippageBps, address(feed)));

        vm.prank(address(vault));
        strategy.execute();
    }

    /// @dev Same as `_initAndExecuteWithResolvedRegistry` but wires a real
    ///      `AllowlistMockAggregator` as the feed, for the rebalanceDelta
    ///      happy-path regression test, which DOES reach `_verifyPrice`.
    function _initAndExecuteWithResolvedRegistryAndAggregator(uint256 initSlippageBps)
        internal
        returns (
            PortfolioStrategy strategy,
            MockTierRegistry registry,
            MockVaultWithGovernor vault,
            AllowlistMockAggregator feed
        )
    {
        registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        vault = new MockVaultWithGovernor(address(governor));

        feed = new AllowlistMockAggregator(18, int256(1e18), block.timestamp);
        // Issue #147's price-source binding (audit-181 Finding #5a): the
        // caller-supplied feed must be allowlisted too, exactly like the
        // adapter, or `initialize` reverts `PriceSourceNotAllowed` before the
        // adapter allowlist re-check is ever exercised.
        registry.setAllowed(address(feed), true);

        strategy = _clone();
        weth.mint(address(vault), TOTAL_AMOUNT);
        vm.prank(address(vault));
        weth.approve(address(strategy), type(uint256).max);

        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);

        strategy.initialize(address(vault), proposer, _initDataWithFeed(initSlippageBps, address(feed)));

        vm.prank(address(vault));
        strategy.execute();
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
        // `_initData` reuses `tsla` as its own push-mode feed (see the helper's
        // doc comment) — issue #147's price-source binding (audit-181 Finding
        // #5a) requires that address to be allowlisted too, exactly like the
        // adapter.
        registry.setAllowed(address(tsla), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
        assertEq(strategy.vault(), address(vault));
        assertEq(address(strategy.swapAdapter()), address(adapter));
    }

    // ── Adapter allowlist: unresolved walk skips ──

    // ── INIT IS NOW FAIL-CLOSED ON REGISTRY RESOLUTION ──
    //
    // These four cases previously asserted that an unresolvable registry made
    // `initialize` SKIP its governance bindings and succeed. That concession
    // was deliberate and correct while every clone was individually
    // allowlisted by the owner before it could be called — a human read the
    // configuration first.
    //
    // Codehash-class certification removes that review: one certification
    // covers every clone that will ever exist, and its claim is that the
    // template's bound holds under EVERY initialization. A clone initialized
    // while the registry was unreachable carries an adapter, price sources,
    // and token↔feed pairings that were never checked against governance, yet
    // would inherit the class bound from its bytecode. So init now refuses.
    //
    // The skip behavior is retained at rebalance and settle, where blocking
    // would strand vault capital — see `_initialize`'s block comment.

    function test_codelessVault_initFailsClosed() public {
        address codelessVault = makeAddr("codelessVault");
        PortfolioStrategy strategy = _clone();
        vm.expectRevert(PortfolioStrategy.TierRegistryUnresolved.selector);
        strategy.initialize(codelessVault, proposer, _initData(SLIPPAGE_100));
    }

    function test_vaultGovernorReturnsZero_initFailsClosed() public {
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(0));
        PortfolioStrategy strategy = _clone();
        vm.expectRevert(PortfolioStrategy.TierRegistryUnresolved.selector);
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
    }

    function test_governorWithoutRegistryGetter_initFailsClosed() public {
        MockGovernorNoRegistryGetter governor = new MockGovernorNoRegistryGetter();
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();
        vm.expectRevert(PortfolioStrategy.TierRegistryUnresolved.selector);
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
    }

    function test_governorTierRegistryZero_initFailsClosed() public {
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(0));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();
        vm.expectRevert(PortfolioStrategy.TierRegistryUnresolved.selector);
        strategy.initialize(address(vault), proposer, _initData(SLIPPAGE_100));
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
        // Needs a resolvable registry now that init is fail-closed — this test
        // is about the slippage floor, not about registry resolution.
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        registry.setAllowed(address(tsla), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault_ = new MockVaultWithGovernor(address(governor));
        strategy.initialize(address(vault_), proposer, _initData(strategy.MIN_SLIPPAGE_BPS()));
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
        // Issue #150 fix: `execute()` needs a vault whose `governor()`
        // resolves. The registry used to be left unset here so the
        // adapter-allowlist walk would skip — that shortcut is gone now that
        // init is fail-closed on registry resolution, so this wires a
        // permissive registry instead. This test is still about the slippage
        // floor, not the allowlist; the entries below just get it past init.
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        registry.setAllowed(address(tsla), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vaultStub = new MockVaultWithGovernor(address(governor));
        weth.mint(address(vaultStub), TOTAL_AMOUNT);
        vm.prank(address(vaultStub));
        weth.approve(address(strategy), type(uint256).max);
        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);

        strategy.initialize(address(vaultStub), proposer, _initData(strategy.MIN_SLIPPAGE_BPS()));
        vm.prank(address(vaultStub));
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

        // NOT `_initData`'s tsla-as-its-own-feed shortcut: `settle()` reaches
        // `_sellFloor` -> `_pushFeedPrice`, which calls `latestRoundData()`
        // on the push-mode feed (Finding #10's oracle-anchored sell floor,
        // added after this test and its price-source-binding comment were
        // written). `tsla` is a plain `ERC20Mock` with no `latestRoundData()`,
        // so it reverts with no return data the moment `settle()` tries to
        // sell it — a real `AllowlistMockAggregator` is needed here instead,
        // allowlisted exactly like the adapter.
        AllowlistMockAggregator feed = new AllowlistMockAggregator(18, int256(1e18), block.timestamp);
        registry.setAllowed(address(feed), true);

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

        strategy.initialize(address(vault), proposer, _initDataWithFeed(SLIPPAGE_100, address(feed)));

        vm.prank(address(vault));
        strategy.execute();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));

        // Demotion clears the allowlist entry for the adapter this strategy
        // is already bound to. The price source stays allowlisted — this
        // test is about the adapter demotion not bricking settle, not about
        // the price-source binding.
        registry.setAllowed(address(adapter), false);

        // settle() reads no adapter allowlist — it must still complete.
        vm.prank(address(vault));
        strategy.settle();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Settled));
    }

    // ── rebalance/rebalanceDelta live re-check (Pashov audit, issue #147) ──
    //
    // The gap: `_execute`/`_settle` deliberately never re-check the allowlist
    // (see `test_demotionAfterInit_doesNotBrickSettle` above), but that
    // reasoning does NOT extend to `rebalance`/`rebalanceDelta` — both are
    // proposer-callable an unbounded number of times while `Executed`, and
    // blocking one strands no capital (`settle()` stays reachable either
    // way). These four tests prove the new fail-closed re-check at both call
    // sites, plus a regression guard that the happy path is untouched.

    function test_demotedAdapter_rebalance_reverts() public {
        (PortfolioStrategy strategy, MockTierRegistry registry,) = _initAndExecuteWithResolvedRegistry(SLIPPAGE_100);

        // Demotion after execute clears the allowlist entry for the adapter
        // this strategy is already bound to.
        registry.setAllowed(address(adapter), false);

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterNotAllowed.selector, address(adapter), address(registry))
        );
        strategy.rebalance();
    }

    function test_demotedAdapter_rebalanceDelta_reverts() public {
        (PortfolioStrategy strategy, MockTierRegistry registry,) = _initAndExecuteWithResolvedRegistry(SLIPPAGE_100);

        registry.setAllowed(address(adapter), false);

        // The revert fires before any report is consumed (the re-check runs
        // ahead of `_verifyPrice`), so an empty push-mode report is fine.
        bytes[] memory reports = new bytes[](1);
        reports[0] = "";

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterNotAllowed.selector, address(adapter), address(registry))
        );
        strategy.rebalanceDelta(reports);
    }

    /// @dev Regression guard: a resolved, still-allowlisted adapter must not
    ///      be newly blocked by the live re-check.
    function test_allowlistedAdapter_rebalance_stillSucceeds() public {
        (PortfolioStrategy strategy,,) = _initAndExecuteWithResolvedRegistry(SLIPPAGE_100);

        vm.prank(proposer);
        strategy.rebalance();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed), "rebalance does not change state");
    }

    /// @dev Regression guard for the delta path, which (unlike `rebalance`)
    ///      also exercises `_verifyPrice` after the allowlist re-check passes
    ///      — needs a real aggregator, hence the dedicated fixture.
    function test_allowlistedAdapter_rebalanceDelta_stillSucceeds() public {
        (PortfolioStrategy strategy,,,) = _initAndExecuteWithResolvedRegistryAndAggregator(SLIPPAGE_100);

        bytes[] memory reports = new bytes[](1);
        reports[0] = "";

        vm.prank(proposer);
        strategy.rebalanceDelta(reports);
        assertEq(
            uint256(strategy.state()), uint256(BaseStrategy.State.Executed), "rebalanceDelta does not change state"
        );
    }

    /// @dev Shared setup for the `updateParams` tighten tests: init + execute
    ///      a single-token basket against a vault whose governor has no
    ///      registry wired (`tierRegistry() == address(0)`, hop-2 skip, so the
    ///      allowlist walk is inert here — these tests are about the slippage
    ///      floor, not the allowlist). Issue #150 fix: `execute()` needs
    ///      `governor()` to resolve, which a bare `makeAddr` no longer
    ///      provides, hence the `MockVaultWithGovernor` wrapper. `salt` keeps
    ///      each deployment distinct across calls in the same test run (no
    ///      longer load-bearing for address uniqueness, kept for readability).
    function _initAndExecuteSingleToken(uint256 initSlippageBps, string memory salt)
        internal
        returns (PortfolioStrategy strategy)
    {
        salt; // silence unused-param warning now that makeAddr no longer consumes it
        strategy = _clone();
        // Init is fail-closed on registry resolution, so this fixture wires a
        // real (permissive) registry instead of the `address(0)` stub it used
        // while the unresolvable case merely skipped its bindings. The
        // allowlist entries are what `_initData`'s basket needs: the swap
        // adapter, and `tsla` doubling as its own push feed.
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(address(adapter), true);
        registry.setAllowed(address(tsla), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vaultStub = new MockVaultWithGovernor(address(governor));
        weth.mint(address(vaultStub), TOTAL_AMOUNT);
        vm.prank(address(vaultStub));
        weth.approve(address(strategy), type(uint256).max);
        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);

        strategy.initialize(address(vaultStub), proposer, _initData(initSlippageBps));
        vm.prank(address(vaultStub));
        strategy.execute();
    }
}
