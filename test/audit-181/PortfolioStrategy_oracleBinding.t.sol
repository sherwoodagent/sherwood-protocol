// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

/// @notice Minimal vault stand-in exposing `governor()` — the one hop
///         `_requireAllowedAdapter`/`_requireAllowedPriceSource` and
///         `BaseStrategy.execute()`'s active-proposal check both read off
///         `vault()`. Mirrors `test/PortfolioStrategyAdapterAllowlist.t.sol`'s
///         fixture shape exactly, so this file needs no shared-mock edits.
contract MockVaultWithGovernor {
    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }
}

/// @notice Minimal governor stand-in exposing `tierRegistry()` (the #147 /
///         audit-181 Finding #5 allowlist walk) plus a DELIBERATELY
///         PERMISSIVE `IProposalStatus` pair so `execute()`'s active-proposal
///         binding check (issue #150) passes without per-test proposal
///         wiring — this file is about the price-source allowlist and the
///         sell-side return-value check, not the binding property itself.
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

    /// @dev Token↔price-source attestation. Permissive by default so the
    ///      existing oracle-binding cases keep exercising what they were
    ///      written for; `setPriceSourceForToken` lets a test deny one
    ///      specific pairing when that is the thing under test.
    mapping(address => mapping(bytes32 => bool)) public deniedPair;

    function setPriceSourceForToken(address token, bytes32 src, bool allow) external {
        deniedPair[token][src] = !allow;
    }

    function isPriceSourceForToken(address token, bytes32 src) external view returns (bool) {
        return !deniedPair[token][src];
    }
}

/// @notice Configurable AggregatorV3-shaped push feed. `~40 lines` — exactly
///         the cheap-forgery shape Finding #5(a) describes as sufficient to
///         open a spread when the price source isn't bound to governance.
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

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @notice Swap adapter that fills the buy leg (asset -> token) 1:1 but
///         silently returns zero on the sell leg (token -> asset), pulling
///         `tokenIn` via `transferFrom` without sending anything back —
///         models a degenerate/broken swap venue that doesn't itself enforce
///         `amountOutMin`, so it can only be caught by the CALLER checking
///         its return value (Finding #10's second half).
contract DirectionalZeroSellAdapter {
    address public immutable buyIn;
    address public immutable buyOut;

    constructor(address buyIn_, address buyOut_) {
        buyIn = buyIn_;
        buyOut = buyOut_;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        /* amountOutMin */
        bytes calldata
    )
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (tokenIn == buyIn && tokenOut == buyOut) {
            amountOut = amountIn;
            IERC20(tokenOut).transfer(msg.sender, amountOut);
            return amountOut;
        }
        // Sell leg: pulls tokenIn, sends nothing back, returns 0. No
        // amountOutMin enforcement of its own — the caller (PortfolioStrategy)
        // is the only backstop.
        return 0;
    }

    function quote(address, address, uint256 amountIn, bytes calldata) external pure returns (uint256) {
        return amountIn;
    }
}

/// @title PortfolioStrategy_oracleBinding
/// @notice Regression tests for audit-181 issue #181 Findings #5 and #10 on
///         `PortfolioStrategy`:
///           (a) an unbound Chainlink price source (Data Streams verifier or
///               push-mode aggregator) must be rejected at init, exactly like
///               `swapAdapter_` already is (Finding #5a).
///           (b) a push feed reporting a future `updatedAt` must not panic
///               the guarded staleness subtraction (Finding #5b) — see the
///               divergence note on `_pushFeedPrice` for why the fixed
///               behavior accepts (age-0) rather than reverting `StalePrice`
///               for this case specifically, matching the repo-wide
///               repo-wide guarded-subtraction convention.
///           (c) a sell-side swap that silently returns zero output must
///               revert `SwapFailed`, matching the buy side (Finding #10).
contract PortfolioStrategy_oracleBindingTest is Test {
    PortfolioStrategy public template;

    ERC20Mock public weth;
    ERC20Mock public tsla;

    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant SLIPPAGE_100 = 100; // 1%, comfortably inside [50, 1000]
    uint256 constant START = 10_000_000;

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

    /// @dev Single-token, 100%-weight push-mode basket, so
    ///      over/underweight math is a no-op at target and rebalanceDelta
    ///      completes cleanly once pricing succeeds.
    function _pushModeInitData(address adapter, address feed, uint256 maxSlippageBps_)
        internal
        view
        returns (bytes memory)
    {
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
            adapter,
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

    /// @dev Same shape but Data Streams mode: `chainlinkVerifier_` non-zero,
    ///      `feedIds[0]` an arbitrary non-zero Data Streams feed id (the
    ///      price-source binding check runs before any report is ever
    ///      consumed, so no working verifier is needed to exercise it).
    function _dataStreamsInitData(address adapter, address verifier, uint256 maxSlippageBps_)
        internal
        view
        returns (bytes memory)
    {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        extra[0] = "";
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 18;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(0xBEEF));

        return abi.encode(
            address(weth), adapter, verifier, tokens, weights, TOTAL_AMOUNT, maxSlippageBps_, extra, priceDecs, feedIds
        );
    }

    /// @dev Deploys the registry/governor/vault trio, clones, initializes and
    ///      executes a push-mode strategy against a live, allowlisted feed —
    ///      the common setup for the (b) and (c) scenarios below.
    function _initAndExecutePushMode(address adapter, MockAggregator feed)
        internal
        returns (PortfolioStrategy strategy, MockVaultWithGovernor vault)
    {
        MockTierRegistry registry = new MockTierRegistry();
        registry.setAllowed(adapter, true);
        registry.setAllowed(address(feed), true);
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        vault = new MockVaultWithGovernor(address(governor));

        strategy = _clone();
        weth.mint(address(vault), TOTAL_AMOUNT);
        vm.prank(address(vault));
        weth.approve(address(strategy), type(uint256).max);

        strategy.initialize(address(vault), proposer, _pushModeInitData(adapter, address(feed), SLIPPAGE_100));

        vm.prank(address(vault));
        strategy.execute();
    }

    /// @dev A real, working 1:1 `MockSwapAdapter`, pre-funded with `tsla` so
    ///      `_execute()`'s buy leg can actually fill — needed anywhere
    ///      `_initAndExecutePushMode` is used, since a codeless placeholder
    ///      address makes `_quoteMinOut`'s `try swapAdapter.quote(...)`
    ///      revert `QuoteUnavailable` before execute ever completes.
    function _deployFundedAdapter() internal returns (MockSwapAdapter adapter) {
        adapter = new MockSwapAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);
    }

    // ── (a) Unbound price source rejected at init ──

    /// @dev Push mode: the swap adapter IS allowlisted, but the per-slot
    ///      aggregator is not — must revert `PriceSourceNotAllowed`, exactly
    ///      mirroring `AdapterNotAllowed` for `swapAdapter_`. Pre-fix,
    ///      `_initialize` validated the adapter but not the price source, so
    ///      this proposer-controlled `MockAggregator` would have been wired
    ///      in with zero governance vouching.
    function test_init_revertsWhenPushFeedAggregatorNotAllowlisted() public {
        MockTierRegistry registry = new MockTierRegistry();
        address adapter = makeAddr("adapter");
        registry.setAllowed(adapter, true);
        // Deliberately NOT allowlisting the feed.
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        PortfolioStrategy strategy = _clone();

        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.PriceSourceNotAllowed.selector, address(feed), address(registry))
        );
        strategy.initialize(address(vault), proposer, _pushModeInitData(adapter, address(feed), SLIPPAGE_100));
    }

    /// @dev Data Streams mode: the swap adapter IS allowlisted, but the
    ///      verifier is not — must revert `PriceSourceNotAllowed` before any
    ///      allocation is written, matching the push-mode case above.
    function test_init_revertsWhenDataStreamsVerifierNotAllowlisted() public {
        MockTierRegistry registry = new MockTierRegistry();
        address adapter = makeAddr("adapter");
        address verifier = makeAddr("verifier");
        registry.setAllowed(adapter, true);
        // Deliberately NOT allowlisting the verifier.
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));

        PortfolioStrategy strategy = _clone();

        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.PriceSourceNotAllowed.selector, verifier, address(registry))
        );
        strategy.initialize(address(vault), proposer, _dataStreamsInitData(adapter, verifier, SLIPPAGE_100));
    }

    // ── Token↔price-source pairing (change: codehash-class-certification) ──
    //
    // The allowlist answers "may this oracle be used at all". These cover the
    // second question: "…for THIS token". Without the pairing, an allowlisted
    // feed can be pointed at any token, so a slot's minimum-output floor is
    // derived from the wrong reference and value leaks on every swap while the
    // configured slippage tolerance still reads as satisfied.
    //
    // Held closed today by per-clone owner review. Codehash-class
    // certification removes that review, which is why the guard has to exist
    // in code before `PortfolioStrategy` can carry a class certification.

    /// @dev Push mode: adapter AND feed are both allowlisted — the old checks
    ///      pass entirely — but the feed is not attested to price `tsla`.
    function test_init_revertsWhenPushFeedNotPairedWithToken() public {
        MockTierRegistry registry = new MockTierRegistry();
        address adapter = makeAddr("adapter");
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        registry.setAllowed(adapter, true);
        registry.setAllowed(address(feed), true);
        // Everything the pre-existing guards check is satisfied; only the
        // pairing is denied.
        registry.setPriceSourceForToken(address(tsla), bytes32(uint256(uint160(address(feed)))), false);

        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();

        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.PriceSourceNotPairedWithToken.selector,
                address(tsla),
                bytes32(uint256(uint160(address(feed)))),
                address(registry)
            )
        );
        strategy.initialize(address(vault), proposer, _pushModeInitData(adapter, address(feed), SLIPPAGE_100));
    }

    /// @dev Data Streams mode, where this matters MORE than in push mode: only
    ///      the verifier is allowlisted, feed ids are opaque, so the pairing is
    ///      the only thing tying a slot's report to a slot's token.
    function test_init_revertsWhenDataStreamsFeedNotPairedWithToken() public {
        MockTierRegistry registry = new MockTierRegistry();
        address adapter = makeAddr("adapter");
        address verifier = makeAddr("verifier");
        registry.setAllowed(adapter, true);
        registry.setAllowed(verifier, true);
        registry.setPriceSourceForToken(address(tsla), bytes32(uint256(0xBEEF)), false);

        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();

        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.PriceSourceNotPairedWithToken.selector,
                address(tsla),
                bytes32(uint256(0xBEEF)),
                address(registry)
            )
        );
        strategy.initialize(address(vault), proposer, _dataStreamsInitData(adapter, verifier, SLIPPAGE_100));
    }

    /// @dev The packed max-age must NOT be part of the attestation key: one
    ///      attestation has to cover an aggregator regardless of the staleness
    ///      bound a proposer chose for a given slot. Otherwise every max-age
    ///      variant needs its own attestation and operators paper over the
    ///      friction by attesting broadly, hollowing out the guard.
    function test_init_pairingIgnoresPackedMaxAge() public {
        MockTierRegistry registry = new MockTierRegistry();
        address adapter = makeAddr("adapter");
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        registry.setAllowed(adapter, true);
        registry.setAllowed(address(feed), true);
        // Deny by the BARE aggregator address, while the init data will carry
        // that address packed together with a max-age.
        registry.setPriceSourceForToken(address(tsla), bytes32(uint256(uint160(address(feed)))), false);

        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();

        // The denial still bites, proving the lookup normalizes away the age.
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.PriceSourceNotPairedWithToken.selector,
                address(tsla),
                bytes32(uint256(uint160(address(feed)))),
                address(registry)
            )
        );
        strategy.initialize(address(vault), proposer, _pushModeInitData(adapter, address(feed), SLIPPAGE_100));
    }

    /// @dev Init is fail-closed on registry resolution. A clone initialized
    ///      while the registry is unreachable would carry an adapter, price
    ///      sources, and pairings that were never checked against governance —
    ///      survivable under per-clone owner review, not under a class
    ///      certification whose claim covers EVERY initialization.
    function test_init_revertsWhenRegistryUnresolvable() public {
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(0));
        MockVaultWithGovernor vault = new MockVaultWithGovernor(address(governor));
        PortfolioStrategy strategy = _clone();
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);

        vm.expectRevert(PortfolioStrategy.TierRegistryUnresolved.selector);
        strategy.initialize(
            address(vault), proposer, _pushModeInitData(makeAddr("adapter"), address(feed), SLIPPAGE_100)
        );
    }

    /// @dev Sanity companion: with BOTH the adapter and the feed allowlisted,
    ///      init succeeds — proves the new check is a bind, not a blanket
    ///      revert.
    function test_init_succeedsWhenPriceSourceAllowlisted() public {
        MockSwapAdapter adapter = _deployFundedAdapter();
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        (PortfolioStrategy strategy,) = _initAndExecutePushMode(address(adapter), feed);
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
    }

    // ── (b) Future updatedAt must not panic ──

    /// @dev Old code: `block.timestamp - updatedAt` with `updatedAt >
    ///      block.timestamp` underflows a `uint256` subtraction under
    ///      checked arithmetic (Solidity 0.8.x) and reverts with a raw
    ///      Panic(0x11), not a named error. New code clamps the age to 0
    ///      (matching the repo-wide
    ///      `ExposureLedger.sol` convention: a feed clock ahead of a lagging
    ///      L2 `block.timestamp` is the freshest possible answer) and
    ///      completes without reverting. `rebalanceDelta` with an empty
    ///      report is the externally-reachable path to `_pushFeedPrice` in
    ///      push mode.
    function test_pushFeedPrice_futureUpdatedAt_doesNotPanic() public {
        // A funded adapter is only needed to get through `execute()`'s buy
        // leg — the single allocation is already at its 100% target
        // afterward, so `rebalanceDelta`'s sell/buy loops no-op and never
        // call the adapter again.
        MockSwapAdapter adapter = _deployFundedAdapter();
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        (PortfolioStrategy strategy,) = _initAndExecutePushMode(address(adapter), feed);

        // Feed clock 1 hour ahead of block.timestamp.
        feed.setUpdatedAt(START + 1 hours);

        bytes[] memory reports = new bytes[](1);
        reports[0] = "";
        // Must NOT revert (old code panics here with Panic(0x11)).
        vm.prank(proposer);
        strategy.rebalanceDelta(reports);
    }

    /// @dev Companion: genuine staleness (updatedAt far in the past,
    ///      exceeding the default 26h max age) must still revert
    ///      `StalePrice` — the fix only removes the underflow panic on a
    ///      FUTURE timestamp, it doesn't weaken the staleness check itself.
    function test_pushFeedPrice_reallyStale_stillRevertsStalePrice() public {
        MockSwapAdapter adapter = _deployFundedAdapter();
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        (PortfolioStrategy strategy,) = _initAndExecutePushMode(address(adapter), feed);

        feed.setUpdatedAt(START - 27 hours);

        bytes[] memory reports = new bytes[](1);
        reports[0] = "";
        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        strategy.rebalanceDelta(reports);
    }

    // ── (c) Zero-output sell must revert SwapFailed ──

    /// @dev `_settle`'s sell leg discarded the swap return value pre-fix, so
    ///      a swap that silently returns 0 (pulling `tokenIn` and sending
    ///      nothing back, without itself enforcing `amountOutMin`) would
    ///      settle "successfully" while the strategy's tokens vanished into
    ///      the adapter. Post-fix, `_settle` captures the return and reverts
    ///      `SwapFailed` on zero, matching `_execute`'s buy-side check.
    function test_settle_zeroOutputSell_revertsSwapFailed() public {
        DirectionalZeroSellAdapter adapter = new DirectionalZeroSellAdapter(address(weth), address(tsla));
        // Fund the adapter so its buy leg (weth -> tsla) can transfer out the
        // tsla it owes `_execute()`.
        tsla.mint(address(adapter), 1_000_000e18);
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);
        (PortfolioStrategy strategy, MockVaultWithGovernor vault) = _initAndExecutePushMode(address(adapter), feed);

        // Execute's buy leg (weth -> tsla) filled 1:1 via the adapter's buy
        // branch, so the strategy now holds a non-zero tsla balance to sell.
        assertGt(tsla.balanceOf(address(strategy)), 0);

        vm.prank(address(vault));
        vm.expectRevert(PortfolioStrategy.SwapFailed.selector);
        strategy.settle();
    }
}
