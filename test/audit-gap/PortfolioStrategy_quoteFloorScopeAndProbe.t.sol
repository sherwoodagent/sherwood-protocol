// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PortfolioStrategy, ChainlinkReport} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal vault stand-in exposing `governor()` — same fixture shape
///         as `test/audit-2/PortfolioStrategy_floorsAndOracle.t.sol`, declared
///         locally so this suite has no cross-file test dependency.
contract MockVaultWithGovernor {
    /// @dev `BaseStrategy.onlyProposer` re-checks the vault's live agent set on
    ///      every proposer-gated call, so a vault stand-in must answer this or
    ///      `rebalance` / `rebalanceDelta` / `updateParams` all fail closed.
    function isAgent(address) external pure returns (bool) {
        return true;
    }

    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }
}

/// @notice Minimal governor stand-in exposing `tierRegistry()` plus a
///         deliberately permissive `IProposalStatus` pair so `execute()`'s
///         active-proposal binding check passes without per-test wiring.
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

    /// @dev Token↔price-source attestation, permissive by default so the
    ///      quote-floor and probe cases keep testing what they were written for.
    mapping(address => mapping(bytes32 => bool)) public deniedPair;

    function setPriceSourceForToken(address token, bytes32 src, bool allow) external {
        deniedPair[token][src] = !allow;
    }

    function isPriceSourceForToken(address token, bytes32 src) external view returns (bool) {
        return !deniedPair[token][src];
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

    function set(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @notice Mock Data Streams verifier proxy — same report shape as
///         `test/PortfolioStrategy.t.sol`'s: `signedReport` is
///         `(bytes32 feedId, int192 price)` and the mock echoes the feedId.
contract MockVerifierProxy {
    function verify(bytes calldata signedReport) external payable returns (bytes memory) {
        (bytes32 feedId, int192 price) = abi.decode(signedReport, (bytes32, int192));
        ChainlinkReport memory report = ChainlinkReport({
            feedId: feedId,
            validFromTimestamp: uint32(block.timestamp),
            observationsTimestamp: uint32(block.timestamp),
            nativeFee: 0,
            linkFee: 0,
            expiresAt: uint32(block.timestamp + 300),
            price: price,
            bid: price,
            ask: price
        });
        return abi.encode(report);
    }
}

/// @notice A swap adapter that FILLS but never QUOTES — `quote()` returns 0
///         unconditionally, exactly like the in-repo `SynthraDirectAdapter`
///         (a supported push-mode pairing). Swap math mirrors
///         `MockSwapAdapter`'s rate model so fills clear at a configurable
///         rate; the adapter must be pre-funded with output tokens.
contract SwapsButNeverQuotesAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    mapping(bytes32 => uint256) public rates;

    uint256 public constant RATE_PRECISION = 1e18;

    error RateNotSet();
    error SlippageExceeded();

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rates[keccak256(abi.encodePacked(tokenIn, tokenOut))] = rate;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        uint256 rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        if (rate == 0) revert RateNotSet();
        amountOut = (amountIn * rate) / RATE_PRECISION;
        if (amountOut < amountOutMin) revert SlippageExceeded();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function quote(address, address, uint256, bytes calldata) external pure override returns (uint256) {
        return 0;
    }
}

/// @notice Quotes at the FAIR rate, fills at `fillBps` of it.
/// @dev    `MockSwapAdapter` serves one rate to both `quote` and `swap`, so a
///         floor derived from its quote always matches its fill and the mock
///         cannot distinguish a held floor from a collapsed one. This one can:
///         the quote is the honest reference an oracle-independent floor is
///         built from, and the fill is the shortfall that floor must reject.
///
///         That split is the whole point of the quote floor. It is NOT sandwich
///         protection — a venue that lies consistently in both directions defeats
///         it by construction, and the contract says so. What it defends is the
///         proposer-declared PRICE SCALE: when an inflated `priceDecimals`
///         collapses the oracle-derived floor toward zero, a floor derived from
///         a quantity the proposer does not declare still has to be cleared.
contract QuotesFairFillsShortAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    mapping(bytes32 => uint256) public rates;
    uint256 public fillBps = 10_000;

    uint256 public constant RATE_PRECISION = 1e18;

    error RateNotSet();
    error SlippageExceeded();

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rates[keccak256(abi.encodePacked(tokenIn, tokenOut))] = rate;
    }

    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        uint256 rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        if (rate == 0) revert RateNotSet();
        amountOut = (((amountIn * rate) / RATE_PRECISION) * fillBps) / 10_000;
        if (amountOut < amountOutMin) revert SlippageExceeded();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata)
        external
        view
        override
        returns (uint256)
    {
        uint256 rate = rates[keccak256(abi.encodePacked(tokenIn, tokenOut))];
        if (rate == 0) revert RateNotSet();
        return (amountIn * rate) / RATE_PRECISION;
    }
}

/// @title PortfolioStrategy_quoteFloorScopeAndProbe
/// @notice Design-pin suite for the audit-gap fixes (PR #196) plus the two
///         review corrections layered on top of them:
///
///   1. The `rebalanceDelta` quote floor is DATA-STREAMS-ONLY. Push mode
///      validates the declared price scale against the feed's live
///      `decimals()` (so the collapse the floor guards against cannot happen
///      there), and push mode + a non-quoting adapter is a SUPPORTED pairing
///      — an unconditional `_quoteMinOut` call would revert
///      `QuoteUnavailable` on every `rebalanceDelta` and permanently brick
///      delta-rebalancing for it.
///
///   2. In Data Streams mode the quote floor must actually HOLD when the
///      proposer-declared `priceDecimals` is inflated and collapses the
///      oracle-derived floor (traced: a $200,000 position floored at 19 raw
///      USDC).
///
///   3. The `_initialize` non-quoting-adapter probe covers EVERY allocation
///      — routes are per-slot (`_swapExtraData[i]`), and a zero-weight slot
///      0 must not skip the probe entirely.
///
///   4. `_execute` re-certifies the adapter and price sources — a demotion
///      in the propose→execute window (reachable permissionlessly via
///      `TierRegistry.poke` / `demoteByChallenge`) must block execution.
contract PortfolioStrategy_quoteFloorScopeAndProbeTest is Test {
    PortfolioStrategy public template;

    ERC20Mock public weth;
    ERC20Mock public tsla;
    ERC20Mock public msft;

    address public proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant SLIPPAGE_100 = 100; // 1%
    uint256 constant START = 10_000_000;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        msft = new ERC20Mock("Microsoft Token", "MSFT", 18);
        template = new PortfolioStrategy();
        vm.warp(START);
    }

    // ── Helpers ──

    function _clone() internal returns (PortfolioStrategy) {
        return PortfolioStrategy(Clones.clone(address(template)));
    }

    function _initData(
        address adapter,
        address verifier,
        address[] memory tokens,
        uint256[] memory weights,
        bytes32[] memory feedIds
    ) internal view returns (bytes memory) {
        bytes[] memory extra = new bytes[](tokens.length);
        uint8[] memory priceDecs = new uint8[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            extra[i] = "";
            priceDecs[i] = 18;
        }
        return abi.encode(
            address(weth), adapter, verifier, tokens, weights, TOTAL_AMOUNT, SLIPPAGE_100, extra, priceDecs, feedIds
        );
    }

    function _oneToken(address token, bytes32 feedId)
        internal
        pure
        returns (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds)
    {
        tokens = new address[](1);
        tokens[0] = token;
        weights = new uint256[](1);
        weights[0] = 10_000;
        feedIds = new bytes32[](1);
        feedIds[0] = feedId;
    }

    function _twoTokens(uint256 w0, uint256 w1, bytes32 f0, bytes32 f1)
        internal
        view
        returns (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds)
    {
        tokens = new address[](2);
        tokens[0] = address(tsla);
        tokens[1] = address(msft);
        weights = new uint256[](2);
        weights[0] = w0;
        weights[1] = w1;
        feedIds = new bytes32[](2);
        feedIds[0] = f0;
        feedIds[1] = f1;
    }

    /// @dev Registry/governor/vault trio with the given addresses allowlisted.
    function _trio(address[] memory toAllow) internal returns (MockTierRegistry registry, MockVaultWithGovernor vault) {
        registry = new MockTierRegistry();
        for (uint256 i; i < toAllow.length; ++i) {
            registry.setAllowed(toAllow[i], true);
        }
        MockGovernorWithRegistry governor = new MockGovernorWithRegistry(address(registry));
        vault = new MockVaultWithGovernor(address(governor));
    }

    function _fundVaultAndApprove(address vault, PortfolioStrategy strategy) internal {
        weth.mint(vault, TOTAL_AMOUNT);
        vm.prank(vault);
        weth.approve(address(strategy), type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════════
    // 1 — quote floor scoping: push mode must NOT reach `_quoteMinOut`
    // ════════════════════════════════════════════════════════════════════

    /// @dev THE regression pin for the review's finding #1: push mode + a
    ///      non-quoting adapter (the `SynthraDirectAdapter` pairing) must
    ///      keep `rebalanceDelta` working. An unconditional quote floor
    ///      reverts `QuoteUnavailable` here on every call — the floor must
    ///      only run in Data Streams mode, where it is actually needed.
    function test_rebalanceDelta_pushMode_nonQuotingAdapter_stillRebalances() public {
        SwapsButNeverQuotesAdapter adapter = new SwapsButNeverQuotesAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(weth), address(msft), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);
        adapter.setRate(address(msft), address(weth), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        msft.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);

        MockAggregator feed0 = new MockAggregator(18, int256(1e18), START);
        MockAggregator feed1 = new MockAggregator(18, int256(1e18), START);

        address[] memory allow = new address[](3);
        allow[0] = address(adapter);
        allow[1] = address(feed0);
        allow[2] = address(feed1);
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) = _twoTokens(
            5_000, 5_000, bytes32(uint256(uint160(address(feed0)))), bytes32(uint256(uint160(address(feed1))))
        );

        PortfolioStrategy strategy = _clone();
        _fundVaultAndApprove(address(vault), strategy);
        strategy.initialize(address(vault), proposer, _initData(address(adapter), address(0), tokens, weights, feedIds));
        vm.prank(address(vault));
        strategy.execute();

        // TSLA doubles: slot 0 goes overweight, slot 1 underweight — both the
        // sell and buy legs (the two quote-floor call sites) must run. The
        // pool moves with the oracle (fair repricing, no manipulation), so
        // the oracle-anchored floors clear and the only thing that could
        // block the call is a stray `_quoteMinOut` — which is exactly what
        // this test pins against.
        feed0.set(int256(2e18), START);
        adapter.setRate(address(tsla), address(weth), 2e18);
        adapter.setRate(address(weth), address(tsla), 0.5e18);

        uint256 tslaBefore = tsla.balanceOf(address(strategy));

        bytes[] memory reports = new bytes[](2);
        reports[0] = "";
        reports[1] = "";
        vm.prank(proposer);
        strategy.rebalanceDelta(reports); // must NOT revert QuoteUnavailable

        assertLt(tsla.balanceOf(address(strategy)), tslaBefore, "overweight TSLA must have been sold");
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
    }

    // ════════════════════════════════════════════════════════════════════
    // 2 — Data Streams mode: the quote floor must HOLD
    // ════════════════════════════════════════════════════════════════════

    /// @dev The $200k→19-raw-USDC collapse, made observable. Declared
    ///      `priceDecimals` is 18 but the signed reports carry 8-decimal
    ///      prices — nothing in Data Streams mode cross-checks that (a
    ///      report has no decimals field), so `_tokensToValue` shrinks by
    ///      1e10 and the oracle-derived `minOut` collapses to dust. The
    ///      venue then "fills" at half the fair rate. Pre-fix the collapsed
    ///      floor let the 50% skim clear; post-fix the quote floor (derived
    ///      from a non-proposer-declared quantity) must reject it.
    function test_rebalanceDelta_dataStreams_quoteFloorBlocksSkimUnderMisscaledDecimals() public {
        MockSwapAdapter adapter = new MockSwapAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(weth), address(msft), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);
        adapter.setRate(address(msft), address(weth), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        msft.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);

        MockVerifierProxy verifier = new MockVerifierProxy();

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = address(verifier);
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _twoTokens(5_000, 5_000, bytes32(uint256(1)), bytes32(uint256(2)));

        PortfolioStrategy strategy = _clone();
        _fundVaultAndApprove(address(vault), strategy);
        strategy.initialize(
            address(vault), proposer, _initData(address(adapter), address(verifier), tokens, weights, feedIds)
        );
        vm.prank(address(vault));
        strategy.execute();

        // The venue turns adversarial on the sell side: fills at half rate.
        adapter.setRate(address(tsla), address(weth), 0.5e18);

        // 8-decimal report prices against an 18-decimal declaration: TSLA at
        // "$2", MSFT at "$1" — slot 0 overweight, sell leg runs, and its
        // oracle floor computes in the collapsed 1e8 scale.
        bytes[] memory reports = new bytes[](2);
        reports[0] = abi.encode(bytes32(uint256(1)), int192(2e8));
        reports[1] = abi.encode(bytes32(uint256(2)), int192(1e8));

        vm.prank(proposer);
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.rebalanceDelta(reports);
    }

    /// @dev Pashov 2026-08 finding #5 — the SAME collapse, on the settle path.
    ///      `_sellOverweight`/`_buyUnderweight` (the `rebalanceDelta` legs
    ///      pinned above) take `max(oracleFloor, quoteFloor)` in Data Streams
    ///      mode precisely because the declared scale is cross-checked against
    ///      nothing there. `_sellFloor`/`_buyFloor` reached `_quoteMinOut` only
    ///      when NO anchor existed, so the moment `_verifyPrice` seeded
    ///      `_lastGoodPrice` the settle path fell onto the unguarded
    ///      stale-anchor branch and the same 1e10 collapse went unfloored.
    ///
    ///      That seeding is free: a `rebalanceDelta` that executes ZERO swaps
    ///      still writes the anchor. And `settleProposal` is proposer-callable
    ///      an hour after execute, so the proposer both arms and fires it.
    ///
    ///      Post-fix the quote floor — derived from a quantity the proposer
    ///      does not declare — must reject the adversarial fill here too.
    function test_settle_dataStreams_quoteFloorBlocksSkimUnderMisscaledDecimals() public {
        QuotesFairFillsShortAdapter adapter = new QuotesFairFillsShortAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        adapter.setRate(address(weth), address(msft), 1e18);
        adapter.setRate(address(tsla), address(weth), 1e18);
        adapter.setRate(address(msft), address(weth), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        msft.mint(address(adapter), 1_000_000e18);
        weth.mint(address(adapter), 1_000_000e18);

        MockVerifierProxy verifier = new MockVerifierProxy();

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = address(verifier);
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _twoTokens(5_000, 5_000, bytes32(uint256(1)), bytes32(uint256(2)));

        PortfolioStrategy strategy = _clone();
        _fundVaultAndApprove(address(vault), strategy);
        strategy.initialize(
            address(vault), proposer, _initData(address(adapter), address(verifier), tokens, weights, feedIds)
        );
        vm.prank(address(vault));
        strategy.execute();

        // ARM: one honest, on-target `rebalanceDelta` seeds `_lastGoodPrice`
        // for both slots. Prices are equal and weights are equal, so this moves
        // nothing — the anchor is seeded regardless, which is the whole point.
        bytes[] memory reports = new bytes[](2);
        reports[0] = abi.encode(bytes32(uint256(1)), int192(1e8));
        reports[1] = abi.encode(bytes32(uint256(2)), int192(1e8));
        vm.prank(proposer);
        strategy.rebalanceDelta(reports);

        // FIRE: the venue starts filling at half its own quote and the proposer
        // self-settles. The stale-anchor floor computes in the collapsed 1e8
        // scale — 1e10 too small — so on its own it cannot stop the skim.
        adapter.setFillBps(5_000);

        vm.prank(address(vault));
        vm.expectRevert(QuotesFairFillsShortAdapter.SlippageExceeded.selector);
        strategy.settle();
    }

    // ════════════════════════════════════════════════════════════════════
    // 3 — init probe: non-quoting adapter in Data Streams mode
    // ════════════════════════════════════════════════════════════════════

    /// @dev Core wedge pin: Data Streams mode + `quote()` == 0 must be
    ///      rejected at bind time (`AdapterCannotQuoteInDataStreamsMode`),
    ///      where it costs a re-proposal — not discovered at settle time,
    ///      where it wedges the only non-emergency exit.
    function test_init_dataStreams_rejectsZeroQuoteAdapter() public {
        SwapsButNeverQuotesAdapter adapter = new SwapsButNeverQuotesAdapter();
        address verifier = address(new MockVerifierProxy());

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = verifier;
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _oneToken(address(tsla), bytes32(uint256(1)));

        PortfolioStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterCannotQuoteInDataStreamsMode.selector, address(adapter))
        );
        strategy.initialize(address(vault), proposer, _initData(address(adapter), verifier, tokens, weights, feedIds));
    }

    /// @dev A quote that REVERTS (here: `MockSwapAdapter.RateNotSet`) must be
    ///      rejected identically to one that returns 0 — the probe's `catch`
    ///      arm.
    function test_init_dataStreams_rejectsRevertingQuoteAdapter() public {
        MockSwapAdapter adapter = new MockSwapAdapter(); // no rates set → quote reverts
        address verifier = address(new MockVerifierProxy());

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = verifier;
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _oneToken(address(tsla), bytes32(uint256(1)));

        PortfolioStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterCannotQuoteInDataStreamsMode.selector, address(adapter))
        );
        strategy.initialize(address(vault), proposer, _initData(address(adapter), verifier, tokens, weights, feedIds));
    }

    /// @dev The pairing the probe must NOT reject: push mode + non-quoting
    ///      adapter is supported (the oracle is the primary floor there and
    ///      the quote only a degrade path). Rejecting it would outlaw the
    ///      in-repo `SynthraDirectAdapter`.
    function test_init_pushMode_allowsZeroQuoteAdapter() public {
        SwapsButNeverQuotesAdapter adapter = new SwapsButNeverQuotesAdapter();
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = address(feed);
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _oneToken(address(tsla), bytes32(uint256(uint160(address(feed)))));

        PortfolioStrategy strategy = _clone();
        strategy.initialize(address(vault), proposer, _initData(address(adapter), address(0), tokens, weights, feedIds));
    }

    /// @dev Review finding #2, part 1: a ZERO-WEIGHT slot 0 must not skip
    ///      the probe — only the weight SUM is validated at init, so
    ///      [0, 10000] is a legal basket. Slot 1's non-quoting route must
    ///      still be caught.
    function test_init_dataStreams_probeNotSkippedByZeroWeightSlot0() public {
        MockSwapAdapter adapter = new MockSwapAdapter();
        // Slot 1's route (weth→msft) deliberately unset → quote reverts.
        adapter.setRate(address(weth), address(tsla), 1e18);
        address verifier = address(new MockVerifierProxy());

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = verifier;
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _twoTokens(0, 10_000, bytes32(uint256(1)), bytes32(uint256(2)));

        PortfolioStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterCannotQuoteInDataStreamsMode.selector, address(adapter))
        );
        strategy.initialize(address(vault), proposer, _initData(address(adapter), verifier, tokens, weights, feedIds));
    }

    /// @dev Review finding #2, part 2: routes are PER-ALLOCATION. An adapter
    ///      that quotes slot 0 fine but not slot 1 must still be rejected —
    ///      probing only the first allocation would miss it.
    function test_init_dataStreams_probeCoversEverySlot() public {
        MockSwapAdapter adapter = new MockSwapAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18); // slot 0 quotes fine
        // slot 1 (weth→msft) unset → quote reverts
        address verifier = address(new MockVerifierProxy());

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = verifier;
        (, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _twoTokens(5_000, 5_000, bytes32(uint256(1)), bytes32(uint256(2)));

        PortfolioStrategy strategy = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterCannotQuoteInDataStreamsMode.selector, address(adapter))
        );
        strategy.initialize(address(vault), proposer, _initData(address(adapter), verifier, tokens, weights, feedIds));
    }

    // ════════════════════════════════════════════════════════════════════
    // 4 — `_execute` re-certifies adapter and price sources
    // ════════════════════════════════════════════════════════════════════

    /// @dev Demotion in the propose→execute window — reachable with no
    ///      governance action via the permissionless `TierRegistry.poke` /
    ///      `demoteByChallenge` — must block `_execute`, which would
    ///      otherwise `forceApprove` the whole allocation to the demoted
    ///      adapter. Blocking here strands nothing: no capital has moved and
    ///      the proposal simply expires at `executeBy`.
    function test_execute_revertsWhenAdapterDemotedAfterInit() public {
        MockSwapAdapter adapter = new MockSwapAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = address(feed);
        (MockTierRegistry registry, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _oneToken(address(tsla), bytes32(uint256(uint160(address(feed)))));

        PortfolioStrategy strategy = _clone();
        _fundVaultAndApprove(address(vault), strategy);
        strategy.initialize(address(vault), proposer, _initData(address(adapter), address(0), tokens, weights, feedIds));

        registry.setAllowed(address(adapter), false); // demoted post-init

        vm.prank(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterNotAllowed.selector, address(adapter), address(registry))
        );
        strategy.execute();
    }

    /// @dev Same window, price-source leg: a push feed revoked between init
    ///      and execute must block `_execute` too.
    function test_execute_revertsWhenPriceSourceRevokedAfterInit() public {
        MockSwapAdapter adapter = new MockSwapAdapter();
        adapter.setRate(address(weth), address(tsla), 1e18);
        tsla.mint(address(adapter), 1_000_000e18);
        MockAggregator feed = new MockAggregator(18, int256(1e18), START);

        address[] memory allow = new address[](2);
        allow[0] = address(adapter);
        allow[1] = address(feed);
        (MockTierRegistry registry, MockVaultWithGovernor vault) = _trio(allow);

        (address[] memory tokens, uint256[] memory weights, bytes32[] memory feedIds) =
            _oneToken(address(tsla), bytes32(uint256(uint160(address(feed)))));

        PortfolioStrategy strategy = _clone();
        _fundVaultAndApprove(address(vault), strategy);
        strategy.initialize(address(vault), proposer, _initData(address(adapter), address(0), tokens, weights, feedIds));

        registry.setAllowed(address(feed), false); // feed revoked post-init

        vm.prank(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.PriceSourceNotAllowed.selector, address(feed), address(registry))
        );
        strategy.execute();
    }
}
