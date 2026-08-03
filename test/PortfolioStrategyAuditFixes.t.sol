// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {Erc20SpotAdapter} from "../src/pricing/Erc20SpotAdapter.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {PositionKinds} from "../src/libraries/PositionKinds.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

// ── Governance stubs ──
//
// The strategy reaches both registries by raw staticcall on `factory()` /
// `priceRouter()` and on `governor()` / `tierRegistry()`. Real
// SyndicateVault/SyndicateFactory/SyndicateGovernor carry far more surface than
// those four selectors, and pulling them in would couple this suite to their
// init wiring for no added coverage.

contract _StubFactory {
    address public priceRouter;

    constructor(address router_) {
        priceRouter = router_;
    }
}

contract _StubGovernor {
    address public tierRegistry;

    constructor(address registry_) {
        tierRegistry = registry_;
    }

    function setTierRegistry(address registry_) external {
        tierRegistry = registry_;
    }
}

contract _StubVault {
    address public factory;
    address public governor;

    constructor(address factory_, address governor_) {
        factory = factory_;
        governor = governor_;
    }
}

/// @dev A contract that answers `tierRegistry()` but is NOT a tier registry —
///      the "registry resolved but cannot vouch" case.
contract _NotARegistry {
    function somethingElse() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Rate-table swap adapter whose `quote()` can be switched off
///         independently of `swap()`.
/// @dev    Models the hostage the audit describes for `_settle`: the proposer
///         froze a route through a pool they solely LP and the quoter stops
///         answering for it, while a fill is still obtainable. `swap()` keeps
///         working so the test isolates the QUOTE availability question from
///         the fill availability question.
contract _ToggleQuoteSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant RATE_PRECISION = 1e18;

    mapping(bytes32 => uint256) public rates;
    bool public quoteBroken;
    /// @dev Makes the FILL land below the adapter's own QUOTE, which a pure
    ///      rate-table mock can never do. Without it no test can tell a floor
    ///      that is `max(quote, mark)` from one that is `min(quote, mark)`,
    ///      because a quote-derived floor never binds against its own quote.
    uint256 public fillDiscountBps;

    error RateNotSet();
    error SlippageExceeded();
    error QuoterDown();

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rates[_key(tokenIn, tokenOut)] = rate;
    }

    function breakQuote(bool broken) external {
        quoteBroken = broken;
    }

    function setFillDiscountBps(uint256 bps) external {
        fillDiscountBps = bps;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata)
        external
        returns (uint256 amountOut)
    {
        uint256 rate = rates[_key(tokenIn, tokenOut)];
        if (rate == 0) revert RateNotSet();
        amountOut = (amountIn * rate) / RATE_PRECISION;
        amountOut = (amountOut * (10_000 - fillDiscountBps)) / 10_000;
        if (amountOut < amountOutMin) revert SlippageExceeded();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata)
        external
        view
        returns (uint256)
    {
        if (quoteBroken) revert QuoterDown();
        uint256 rate = rates[_key(tokenIn, tokenOut)];
        if (rate == 0) revert RateNotSet();
        return (amountIn * rate) / RATE_PRECISION;
    }

    function _key(address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }
}

/// @title PortfolioStrategyAuditFixesTest
/// @notice Regression suite for four audit findings, all in
///         `PortfolioStrategy`:
///
///   #13 `_quoteMinOut` was a self-referential slippage floor — the quote came
///       from the same pool, in the same transaction, as the swap it floored,
///       so a proposer who moved the route pool moved the floor with it. The
///       floor is now the STRONGER of the adapter quote and the Chainlink push
///       mark (`_legMinOut`), so the pool cannot pull it below the mark.
///   #15 `swapAdapter_` was unvalidated proposer input that `_execute`
///       `forceApprove`s the vault's capital to, one hop outside
///       `SyndicateVault._guardBatchCalls`. It is now bound to the same
///       `TierRegistry` allowlist, resolved `vault() → governor() →
///       tierRegistry()`.
///   #17 the push-mode staleness bound came only from the proposer's packed
///       per-slot age (capped at 30 DAYS). It is now additionally bounded by
///       the `maxAge` governance registered for that token in the spot pricing
///       registry.
///   #18a `_settle` — the terminal unwind, with frozen routes — turned any
///       quoter failure into `revert QuoteUnavailable()` for the whole
///       settlement. It now falls back to the mark floor on that path alone.
///
///   Fixture: real proxied `PriceRouter` + real `Erc20SpotAdapter` + real
///   `TierRegistry` (the raw word-0/word-1 decode of `feedOf` and the
///   `isAdapterAllowed` probe are real couplings and are tested against the
///   real contracts, not mocks of them). 18-dec asset/tokens, 8-dec feeds whose
///   marks agree with the swap rates (TSLA 0.01, AMZN 0.02 WETH) so every floor
///   clears exactly unless a test deliberately skews the pool.
contract PortfolioStrategyAuditFixesTest is Test {
    PortfolioStrategy internal template;
    _ToggleQuoteSwapAdapter internal swapAdapter;

    PriceRouter internal router;
    Erc20SpotAdapter internal spotAdapter;
    TierRegistry internal tierRegistry;
    _StubFactory internal factoryStub;
    _StubGovernor internal governorStub;
    _StubVault internal vaultStub;

    ERC20Mock internal weth; // vault asset + adapter numeraire
    ERC20Mock internal tsla;
    ERC20Mock internal amzn;

    MockAggregatorV3 internal fTsla;
    MockAggregatorV3 internal fAmzn;

    address internal proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant MAX_SLIPPAGE = 100; // 1%
    uint256 constant CAP = 1_000_000e18;
    /// @dev Generous registry bound; the #17 tests re-register a tight one.
    uint256 constant FEED_MAX_AGE = 24 hours;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        amzn = new ERC20Mock("Amazon Token", "AMZN", 18);

        fTsla = new MockAggregatorV3(8, int256(1e6)); // 0.01 WETH
        fAmzn = new MockAggregatorV3(8, int256(2e6)); // 0.02 WETH

        swapAdapter = _newSwapAdapter();

        PriceRouter impl = new PriceRouter();
        router = PriceRouter(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(PriceRouter.initialize, (address(this)))))
        );
        spotAdapter = new Erc20SpotAdapter(address(this), address(weth));
        router.registerAdapter(PositionKinds.ERC20_SPOT, address(spotAdapter));
        _register(address(tsla), address(fTsla), FEED_MAX_AGE);
        _register(address(amzn), address(fAmzn), FEED_MAX_AGE);

        tierRegistry = new TierRegistry(address(this));
        tierRegistry.setAdapterAllowed(address(swapAdapter), true);

        factoryStub = new _StubFactory(address(router));
        governorStub = new _StubGovernor(address(tierRegistry));
        vaultStub = new _StubVault(address(factoryStub), address(governorStub));
        weth.mint(address(vaultStub), 100e18);

        template = new PortfolioStrategy();
    }

    // ── Fixture helpers ──

    /// @dev A funded adapter quoting/filling at the same prices as the marks.
    function _newSwapAdapter() internal returns (_ToggleQuoteSwapAdapter a) {
        a = new _ToggleQuoteSwapAdapter();
        a.setRate(address(weth), address(tsla), 100e18);
        a.setRate(address(weth), address(amzn), 50e18);
        a.setRate(address(tsla), address(weth), 0.01e18);
        a.setRate(address(amzn), address(weth), 0.02e18);
        tsla.mint(address(a), 1_000_000e18);
        amzn.mint(address(a), 1_000_000e18);
        weth.mint(address(a), 1_000_000e18);
    }

    function _register(address token, address aggregator, uint256 maxAge) internal {
        spotAdapter.setFeed(token, aggregator, maxAge, CAP, address(0), 0);
    }

    function _packed(address feed) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(feed)));
    }

    function _packed(address feed, uint256 maxAge) internal pure returns (bytes32) {
        return bytes32((maxAge << 160) | uint256(uint160(feed)));
    }

    function _ids(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _defaultIds() internal view returns (bytes32[] memory) {
        return _ids(_packed(address(fTsla)), _packed(address(fAmzn)));
    }

    /// @dev Both slots packed with the same per-slot staleness.
    function _agedIds(uint256 age) internal view returns (bytes32[] memory) {
        return _ids(_packed(address(fTsla), age), _packed(address(fAmzn), age));
    }

    function _initData(address adapter_, address verifier, bytes32[] memory ids, uint8 dec)
        internal
        view
        returns (bytes memory)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        bytes[] memory extraData = new bytes[](2);
        uint8[] memory pd = new uint8[](2);
        pd[0] = dec;
        pd[1] = dec;
        return
            abi.encode(
                address(weth), adapter_, verifier, tokens, weights, TOTAL_AMOUNT, MAX_SLIPPAGE, extraData, pd, ids
            );
    }

    /// @dev Clone + init. Argument expressions are hoisted so no pending
    ///      cheatcode can be consumed in argument position.
    function _init(address vault_, bytes memory data) internal returns (PortfolioStrategy s) {
        s = PortfolioStrategy(Clones.clone(address(template)));
        s.initialize(vault_, proposer, data);
    }

    /// @dev Push-mode clone against the fully-wired stub vault.
    function _pushInit() internal returns (PortfolioStrategy) {
        bytes memory data = _initData(address(swapAdapter), address(0), _defaultIds(), 8);
        return _init(address(vaultStub), data);
    }

    function _pushInitWithIds(bytes32[] memory ids) internal returns (PortfolioStrategy) {
        bytes memory data = _initData(address(swapAdapter), address(0), ids, 8);
        return _init(address(vaultStub), data);
    }

    /// @dev Data-Streams-mode clone: no on-chain mark exists in this mode.
    function _streamsInit() internal returns (PortfolioStrategy) {
        bytes32[] memory ids = _ids(keccak256("ds.tsla"), keccak256("ds.amzn"));
        bytes memory data = _initData(address(swapAdapter), makeAddr("verifier"), ids, 8);
        return _init(address(vaultStub), data);
    }

    function _execute(PortfolioStrategy s) internal {
        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        weth.approve(address(s), type(uint256).max);
        vm.prank(vaultAddr);
        s.execute();
    }

    // ==================================================================
    // #13 — the slippage floor must not be derivable from the route pool
    // ==================================================================

    /// @dev THE finding. `settleProposal` is proposer-callable an hour after
    ///      execute, so a proposer who pushes the route pool 5% below the mark
    ///      and then settles used to get a quote at the moved price AND a floor
    ///      derived from that moved price — the swap cleared and they kept the
    ///      gap. The mark-anchored floor makes the leg unfillable instead.
    function test_settle_markFloorRejectsPoolPushedBelowMark() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);

        // 5% under the 0.01 mark, against a 1% slippage tolerance.
        swapAdapter.setRate(address(tsla), address(weth), 0.0095e18);

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        vm.expectRevert(_ToggleQuoteSwapAdapter.SlippageExceeded.selector);
        s.settle();
    }

    /// @dev The buy leg inverts the mark's application (`_valueToTokens`, not
    ///      `_tokensToValue`). Getting that backwards would silently invert the
    ///      floor, so it is pinned separately: a pool handing over 5% FEWER
    ///      tokens per WETH than the mark must not execute.
    function test_execute_markFloorRejectsPoolPushedAboveMark() public {
        PortfolioStrategy s = _pushInit();
        swapAdapter.setRate(address(weth), address(tsla), 95e18); // mark says 100

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        weth.approve(address(s), type(uint256).max);
        vm.prank(vaultAddr);
        vm.expectRevert(_ToggleQuoteSwapAdapter.SlippageExceeded.selector);
        s.execute();
    }

    /// @dev `rebalance()` is `onlyProposer` with no cooldown — the most
    ///      repeatable of the three swap paths.
    function test_rebalance_markFloorRejectsPoolPushedBelowMark() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);
        swapAdapter.setRate(address(tsla), address(weth), 0.0095e18);

        vm.prank(proposer);
        vm.expectRevert(_ToggleQuoteSwapAdapter.SlippageExceeded.selector);
        s.rebalance();
    }

    /// @dev No-regression: the mark half is a FLOOR, not a target. A pool
    ///      trading ABOVE the mark still clears (the strategy simply receives
    ///      more), because the floor takes the stronger of the two bounds and
    ///      the quote bound always clears against its own pool.
    function test_settle_poolAboveMarkStillClears() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);
        swapAdapter.setRate(address(tsla), address(weth), 0.02e18); // 2x the mark

        uint256 before = weth.balanceOf(address(vaultStub));
        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        s.settle();
        assertGt(weth.balanceOf(address(vaultStub)) - before, TOTAL_AMOUNT, "upside is not floored away");
    }

    /// @dev No-regression: aligned pool and mark settle exactly as before.
    function test_settle_alignedPoolAndMarkRoundTrips() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);

        uint256 before = weth.balanceOf(address(vaultStub));
        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        s.settle();
        assertEq(weth.balanceOf(address(vaultStub)) - before, TOTAL_AMOUNT, "full round trip at aligned prices");
    }

    /// @dev DOCUMENTED RESIDUAL. Data Streams mode has no on-chain mark — the
    ///      price only exists inside a signed report that the `IStrategy`
    ///      execute/settle signatures cannot carry — so the floor there is
    ///      still quote-only and the same 5% push clears. This test exists to
    ///      make that residual visible rather than to bless it; the fix applies
    ///      to push mode, which is what Lane A deploys.
    function test_settle_dataStreamsMode_keepsQuoteOnlyFloor() public {
        PortfolioStrategy s = _streamsInit();
        _execute(s);
        swapAdapter.setRate(address(tsla), address(weth), 0.0095e18);

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        s.settle();
        assertEq(tsla.balanceOf(address(s)), 0, "no on-chain mark: quote-only floor still clears");
    }

    /// @dev MAX, NOT MIN — the test that distinguishes them. The mark is a
    ///      PROPOSER-declared feed, and where the registry does not list the
    ///      token that feed is unbound, so a mark reading LOW must not be able
    ///      to pull the floor BELOW the quote: `_legMinOut` must never return a
    ///      floor weaker than the quote-only one this contract enforced before.
    ///      Here BOTH slots' marks drift to half the real price after execute
    ///      and the venue then fills 2% under its own quote against a 1%
    ///      tolerance. The quote half of the floor rejects it. With
    ///      `min(quote, mark)` every halved mark would set that slot's floor at
    ///      ~50% and the whole settlement would clear at the discounted fill.
    function test_settle_wrongLowMarkCannotWeakenTheQuoteFloor() public {
        spotAdapter.removeFeed(address(tsla)); // unlisted → declared feed unbound
        MockAggregatorV3 drifting = new MockAggregatorV3(8, int256(1e6)); // honest at init

        PortfolioStrategy s = _pushInitWithIds(_ids(_packed(address(drifting)), _packed(address(fAmzn))));
        _execute(s);

        drifting.setAnswer(int256(5e5)); // marks TSLA at half its real price
        fAmzn.setAnswer(int256(1e6)); // and AMZN likewise, so no slot saves the run
        swapAdapter.setFillDiscountBps(200); // venue fills 2% under its own quote

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        vm.expectRevert(_ToggleQuoteSwapAdapter.SlippageExceeded.selector);
        s.settle();
    }

    // ==================================================================
    // #15 — swapAdapter_ is proposer input and gets the vault's approval
    // ==================================================================

    /// @dev THE finding. `_execute` `forceApprove`s `swapAdapter_` the whole of
    ///      `totalAmount`, one hop outside `SyndicateVault._guardBatchCalls`.
    ///      An adapter governance never allowlisted must not get that approval.
    function test_init_revertsWhenSwapAdapterIsNotAllowlisted() public {
        _ToggleQuoteSwapAdapter rogue = _newSwapAdapter(); // never allowlisted

        bytes memory data = _initData(address(rogue), address(0), _defaultIds(), 8);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AdapterNotAllowed.selector, address(rogue), address(tierRegistry))
        );
        s.initialize(address(vaultStub), proposer, data);
    }

    function test_init_acceptsAllowlistedSwapAdapter() public {
        PortfolioStrategy s = _pushInit();
        assertEq(address(s.swapAdapter()), address(swapAdapter), "allowlisted adapter stored");
    }

    /// @dev De-listing still blocks the NEXT strategy: the check reads the
    ///      registry live at init, not a snapshot taken elsewhere.
    function test_init_revertsAfterAdapterIsDelisted() public {
        tierRegistry.setAdapterAllowed(address(swapAdapter), false);

        bytes memory data = _initData(address(swapAdapter), address(0), _defaultIds(), 8);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.AdapterNotAllowed.selector, address(swapAdapter), address(tierRegistry)
            )
        );
        s.initialize(address(vaultStub), proposer, data);
    }

    /// @dev Documented conditional skip #1: a vault with no `governor()`
    ///      surface. Not proposer-forcible — `vault_` is supplied by the
    ///      initializing governor/factory, never by the init calldata.
    function test_init_skipsWhenVaultHasNoGovernorSurface() public {
        _ToggleQuoteSwapAdapter rogue = _newSwapAdapter();
        _StubVault bare = new _StubVault(address(factoryStub), address(0));

        bytes memory data = _initData(address(rogue), address(0), _defaultIds(), 8);
        PortfolioStrategy s = _init(address(bare), data);
        assertEq(address(s.swapAdapter()), address(rogue), "no registry resolves: check skipped");
    }

    /// @dev Documented conditional skip #2: the governor has no tier registry
    ///      wired — exactly the state in which `_guardBatchCalls` disables
    ///      ITSELF, so the batch could already approve anything anyway.
    function test_init_skipsWhenGovernorHasNoTierRegistry() public {
        _ToggleQuoteSwapAdapter rogue = _newSwapAdapter();
        _StubGovernor bare = new _StubGovernor(address(0));
        _StubVault v = new _StubVault(address(factoryStub), address(bare));

        bytes memory data = _initData(address(rogue), address(0), _defaultIds(), 8);
        PortfolioStrategy s = _init(address(v), data);
        assertEq(address(s.swapAdapter()), address(rogue), "unset registry: check skipped");
    }

    /// @dev Resolved but unreadable fails CLOSED: a registry that cannot vouch
    ///      for the adapter has not vouched for it. Treating an unreadable
    ///      registry as "skip" would be a bypass the moment a governor could be
    ///      pointed at any contract.
    function test_init_failsClosedWhenRegistryCannotVouch() public {
        _NotARegistry impostor = new _NotARegistry();
        _StubGovernor gov = new _StubGovernor(address(impostor));
        _StubVault v = new _StubVault(address(factoryStub), address(gov));

        bytes memory data = _initData(address(swapAdapter), address(0), _defaultIds(), 8);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.AdapterNotAllowed.selector, address(swapAdapter), address(impostor)
            )
        );
        s.initialize(address(v), proposer, data);
    }

    // ==================================================================
    // #17 — the slot's own max age must not outlive governance's
    // ==================================================================

    /// @dev THE finding. `_verifyPrice`'s push branch accepted any age the
    ///      proposer packed, bounded only by `MAX_PUSH_PRICE_AGE_CAP` — 30
    ///      DAYS — and there is no oracle-vs-pool divergence check anywhere in
    ///      this contract. During the stale-mark regime the proposer could
    ///      `rebalanceDelta` the basket into their own frozen route at the
    ///      stale mark. The registry's registered `maxAge` (1h here) now bounds
    ///      the slot's 96h.
    function test_rebalanceDelta_registryMaxAgeBoundsTheSlotAge() public {
        _register(address(tsla), address(fTsla), 1 hours);
        _register(address(amzn), address(fAmzn), 1 hours);
        PortfolioStrategy s = _pushInitWithIds(_agedIds(96 hours));
        _execute(s);

        // 2h old: inside the proposer's 96h, outside governance's 1h.
        vm.warp(vm.getBlockTimestamp() + 2 hours);

        bytes[] memory reports = new bytes[](2);
        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        s.rebalanceDelta(reports);
    }

    /// @dev The same bound reaches the instant-exit surface, which reads the
    ///      mark through `_pushMark`.
    function test_availableLiquidity_registryMaxAgeBoundsTheSlotAge() public {
        _register(address(tsla), address(fTsla), 1 hours);
        _register(address(amzn), address(fAmzn), 1 hours);
        PortfolioStrategy s = _pushInitWithIds(_agedIds(96 hours));
        _execute(s);
        assertGt(s.availableLiquidity(), 0, "fresh marks: basket advertised");

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertEq(s.availableLiquidity(), weth.balanceOf(address(s)), "registry-stale mark: idle only");
    }

    /// @dev ...and to the unwind itself.
    function test_withdrawTo_registryMaxAgeBoundsTheSlotAge() public {
        _register(address(tsla), address(fTsla), 1 hours);
        _register(address(amzn), address(fAmzn), 1 hours);
        PortfolioStrategy s = _pushInitWithIds(_agedIds(96 hours));
        _execute(s);
        vm.warp(vm.getBlockTimestamp() + 2 hours);

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        s.withdrawTo(1e18);
    }

    /// @dev The bound only TIGHTENS. A registry age looser than the slot's own
    ///      must not extend the slot: 30-day registry, 26h default slot, read
    ///      at +27h still stales.
    function test_rebalanceDelta_registryMaxAgeNeverLoosensTheSlotAge() public {
        _register(address(tsla), address(fTsla), 30 days);
        _register(address(amzn), address(fAmzn), 30 days);
        PortfolioStrategy s = _pushInit(); // packed age 0 → 26h default
        _execute(s);

        vm.warp(vm.getBlockTimestamp() + 27 hours);

        bytes[] memory reports = new bytes[](2);
        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        s.rebalanceDelta(reports);
    }

    /// @dev No-regression: a fresh mark inside BOTH bounds still prices.
    function test_rebalanceDelta_freshWithinBothBoundsStillPrices() public {
        _register(address(tsla), address(fTsla), 1 hours);
        _register(address(amzn), address(fAmzn), 1 hours);
        PortfolioStrategy s = _pushInitWithIds(_agedIds(96 hours));
        _execute(s);

        vm.warp(vm.getBlockTimestamp() + 30 minutes);

        bytes[] memory reports = new bytes[](2);
        vm.prank(proposer);
        s.rebalanceDelta(reports);
        assertGt(s.getAllocations()[0].tokenAmount, 0, "priced inside both bounds");
    }

    /// @dev DOCUMENTED RESIDUAL: a token the registry does not list publishes
    ///      no `maxAge`, so the slot's own bound stands. That token also gets
    ///      no Lane A (`Erc20SpotAdapter.value` returns `(0,false)` for an
    ///      unlisted venue), so the stale mark can mis-size an internal
    ///      rebalance but cannot move value in or out of the vault.
    function test_rebalanceDelta_unlistedTokenKeepsItsOwnSlotAge() public {
        spotAdapter.removeFeed(address(tsla));
        spotAdapter.removeFeed(address(amzn));
        PortfolioStrategy s = _pushInitWithIds(_agedIds(96 hours));
        _execute(s);

        vm.warp(vm.getBlockTimestamp() + 2 hours);

        bytes[] memory reports = new bytes[](2);
        vm.prank(proposer);
        s.rebalanceDelta(reports);
        assertGt(s.getAllocations()[0].tokenAmount, 0, "no registry opinion: slot age stands");
    }

    // ==================================================================
    // #18a — one unquotable leg must not brick the terminal settlement
    // ==================================================================

    /// @dev THE finding. Routes are frozen by `RoutesFrozen`, so a proposer who
    ///      picked a route through a pool they solely LP can make its quoter
    ///      stop answering AFTER execute. `_settle` is the terminal unwind:
    ///      turning that into `revert QuoteUnavailable()` holds the vault's
    ///      capital hostage forever, recoverable only through an owner +
    ///      guardian emergency path. Settlement now floors that leg at the mark
    ///      instead.
    function test_settle_fallsBackToMarkFloorWhenQuoteIsUnavailable() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);
        swapAdapter.breakQuote(true);

        uint256 before = weth.balanceOf(address(vaultStub));
        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        s.settle();

        assertEq(weth.balanceOf(address(vaultStub)) - before, TOTAL_AMOUNT, "settlement completed on the mark alone");
        assertEq(tsla.balanceOf(address(s)), 0, "every leg unwound");
        assertEq(amzn.balanceOf(address(s)), 0, "every leg unwound");
    }

    /// @dev The fallback is a FLOOR, not a waiver: with no quote AND a pool 5%
    ///      under the mark, the leg still fails rather than filling at any
    ///      price. Otherwise #18a's fix would hand #13's extraction back.
    function test_settle_markFallbackStillEnforcesSlippage() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);
        swapAdapter.setRate(address(tsla), address(weth), 0.0095e18);
        swapAdapter.breakQuote(true);

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        vm.expectRevert(_ToggleQuoteSwapAdapter.SlippageExceeded.selector);
        s.settle();
    }

    /// @dev `_execute` is NOT terminal: refusing to enter a route whose quoter
    ///      cannot price it strands nothing, so it keeps reverting.
    function test_execute_stillRevertsWhenQuoteIsUnavailable() public {
        PortfolioStrategy s = _pushInit();
        swapAdapter.breakQuote(true);

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        weth.approve(address(s), type(uint256).max);
        vm.prank(vaultAddr);
        vm.expectRevert(PortfolioStrategy.QuoteUnavailable.selector);
        s.execute();
    }

    /// @dev `rebalance()` is NOT terminal either — and it is the proposer's own
    ///      repeatable path, so it gets the strictest availability requirement.
    function test_rebalance_stillRevertsWhenQuoteIsUnavailable() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);
        swapAdapter.breakQuote(true);

        vm.prank(proposer);
        vm.expectRevert(PortfolioStrategy.QuoteUnavailable.selector);
        s.rebalance();
    }

    /// @dev DOCUMENTED RESIDUAL: with NEITHER a quote nor a mark (Data Streams
    ///      mode has no on-chain mark at all) settlement still reverts. That is
    ///      deliberate — an unfloored `minOut` on a route the proposer chose and
    ///      froze is a signed blank cheque, strictly worse than a stuck
    ///      settlement the owner + guardian path can still resolve.
    function test_settle_revertsWhenNeitherQuoteNorMarkIsAvailable() public {
        PortfolioStrategy s = _streamsInit();
        _execute(s);
        swapAdapter.breakQuote(true);

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        vm.expectRevert(PortfolioStrategy.QuoteUnavailable.selector);
        s.settle();
    }

    /// @dev The same residual with a stale — rather than absent — mark: push
    ///      mode, quoter down, feed past its bound. Settlement reverts.
    function test_settle_revertsWhenQuoteIsDownAndMarkIsStale() public {
        PortfolioStrategy s = _pushInit();
        _execute(s);
        swapAdapter.breakQuote(true);
        vm.warp(vm.getBlockTimestamp() + 27 hours); // past the 26h default

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        vm.expectRevert(PortfolioStrategy.QuoteUnavailable.selector);
        s.settle();
    }
}
