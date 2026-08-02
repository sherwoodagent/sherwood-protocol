// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PortfolioStrategy} from "../src/strategies/PortfolioStrategy.sol";
import {PriceRouter} from "../src/pricing/PriceRouter.sol";
import {Erc20SpotAdapter} from "../src/pricing/Erc20SpotAdapter.sol";
import {PositionKinds} from "../src/libraries/PositionKinds.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev The two governance hops between the strategy and the feed registry.
///      Real `SyndicateVault`/`SyndicateFactory` carry far more surface than
///      this check reads, and pulling them in would couple this suite to their
///      init wiring; the strategy reaches both by raw staticcall on
///      `factory()` / `priceRouter()` alone.
contract _StubFactory {
    address public priceRouter;

    constructor(address router_) {
        priceRouter = router_;
    }

    function setPriceRouter(address router_) external {
        priceRouter = router_;
    }
}

contract _StubVault {
    address public factory;

    constructor(address factory_) {
        factory = factory_;
    }
}

/// @title PortfolioStrategyFeedBindingTest
/// @notice The push-mode feed a proposer declares per slot is the mark that
///         sizes and floors every instant-exit unwind, and matching
///         `decimals()` proves only that the address is *a* feed. This suite
///         pins the binding that makes it the RIGHT feed: each slot's declared
///         aggregator must be the one governance registered for that slot's
///         token in the `Erc20SpotAdapter` the `PriceRouter` prices
///         `ERC20_SPOT` with — enforced at init, re-checked on every mark
///         read, and published by `getFeedIds()`.
///
///   Adversary throughout: a proposer who points slot `i` at a cheap token's
///   aggregator, waits for the vault's instant lane to open, and exits into an
///   unwind sized off the mispriced mark.
///
///   Fixture: real proxied `PriceRouter` + real `Erc20SpotAdapter` (the raw
///   word-0 decode of `feedOf` is a real coupling and is tested against the
///   real registry, not a mock of it), 18-dec asset/tokens, 8-dec feeds whose
///   marks agree with the swap rates (TSLA 0.01, AMZN 0.02 WETH).
contract PortfolioStrategyFeedBindingTest is Test {
    PortfolioStrategy internal template;
    MockSwapAdapter internal swapAdapter;

    PriceRouter internal router;
    Erc20SpotAdapter internal spotAdapter;
    _StubFactory internal factoryStub;
    _StubVault internal vaultStub;

    ERC20Mock internal weth; // vault asset + adapter numeraire
    ERC20Mock internal tsla;
    ERC20Mock internal amzn;

    MockAggregatorV3 internal fTsla;
    MockAggregatorV3 internal fAmzn;
    /// @dev A well-formed 8-dec feed registered against NOTHING — the shape
    ///      the adversary substitutes.
    MockAggregatorV3 internal fRogue;

    address internal proposer = makeAddr("proposer");

    uint256 constant TOTAL_AMOUNT = 10e18;
    uint256 constant MAX_SLIPPAGE = 100; // 1%
    uint256 constant FEED_MAX_AGE = 24 hours;
    uint256 constant CAP = 1_000_000e18;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        amzn = new ERC20Mock("Amazon Token", "AMZN", 18);

        fTsla = new MockAggregatorV3(8, int256(1e6)); // 0.01 WETH
        fAmzn = new MockAggregatorV3(8, int256(2e6)); // 0.02 WETH
        fRogue = new MockAggregatorV3(8, int256(1e6));

        swapAdapter = new MockSwapAdapter();
        swapAdapter.setRate(address(weth), address(tsla), 100e18);
        swapAdapter.setRate(address(weth), address(amzn), 50e18);
        swapAdapter.setRate(address(tsla), address(weth), 0.01e18);
        swapAdapter.setRate(address(amzn), address(weth), 0.02e18);
        tsla.mint(address(swapAdapter), 1_000_000e18);
        amzn.mint(address(swapAdapter), 1_000_000e18);
        weth.mint(address(swapAdapter), 1_000_000e18);

        router = _newRouter();
        spotAdapter = new Erc20SpotAdapter(address(this), address(weth));
        router.registerAdapter(PositionKinds.ERC20_SPOT, address(spotAdapter));

        factoryStub = new _StubFactory(address(router));
        vaultStub = new _StubVault(address(factoryStub));
        weth.mint(address(vaultStub), 100e18);

        template = new PortfolioStrategy();
    }

    // ── Fixture helpers ──

    function _newRouter() internal returns (PriceRouter) {
        PriceRouter impl = new PriceRouter();
        return
            PriceRouter(
                address(new ERC1967Proxy(address(impl), abi.encodeCall(PriceRouter.initialize, (address(this)))))
            );
    }

    function _register(address token, address aggregator) internal {
        spotAdapter.setFeed(token, aggregator, FEED_MAX_AGE, CAP, address(0), 0);
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

    function _initData(address verifier, bytes32[] memory ids, uint8 dec) internal view returns (bytes memory) {
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
        return abi.encode(
            address(weth),
            address(swapAdapter),
            verifier,
            tokens,
            weights,
            TOTAL_AMOUNT,
            MAX_SLIPPAGE,
            extraData,
            pd,
            ids
        );
    }

    /// @dev Clone + init against `vault_`. Argument expressions are hoisted so
    ///      no pending cheatcode can be consumed in argument position.
    function _init(address vault_, bytes memory data) internal returns (PortfolioStrategy s) {
        s = PortfolioStrategy(Clones.clone(address(template)));
        s.initialize(vault_, proposer, data);
    }

    function _pushInit(bytes32[] memory ids) internal returns (PortfolioStrategy) {
        bytes memory data = _initData(address(0), ids, 8);
        return _init(address(vaultStub), data);
    }

    /// @dev Fund + execute a push-mode clone through the stub vault.
    function _execute(PortfolioStrategy s) internal {
        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        weth.approve(address(s), type(uint256).max);
        vm.prank(vaultAddr);
        s.execute();
    }

    // ── Init-time binding ──

    function test_init_revertsWhenSlotFeedIsNotTheRegisteredAggregator() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        bytes memory data = _initData(address(0), _ids(_packed(address(fRogue)), _packed(address(fAmzn))), 8);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.FeedNotRegistered.selector, address(tsla), address(fRogue), address(fTsla)
            )
        );
        s.initialize(address(vaultStub), proposer, data);
    }

    /// @dev Every slot is bound, not just the first.
    function test_init_revertsOnALaterSlot() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        bytes memory data = _initData(address(0), _ids(_packed(address(fTsla)), _packed(address(fRogue))), 8);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.FeedNotRegistered.selector, address(amzn), address(fRogue), address(fAmzn)
            )
        );
        s.initialize(address(vaultStub), proposer, data);
    }

    /// @dev The substitution the audit describes: TSLA's slot pointed at
    ///      AMZN's registered feed. Both feeds are real and well-formed, so
    ///      only the token binding distinguishes them.
    function test_init_revertsWhenSlotFeedIsAnotherSlotsRegisteredAggregator() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        bytes memory data = _initData(address(0), _ids(_packed(address(fAmzn)), _packed(address(fAmzn))), 8);
        PortfolioStrategy s = PortfolioStrategy(Clones.clone(address(template)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PortfolioStrategy.FeedNotRegistered.selector, address(tsla), address(fAmzn), address(fTsla)
            )
        );
        s.initialize(address(vaultStub), proposer, data);
    }

    function test_init_acceptsTheRegisteredAggregator() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        bytes32[] memory ids = _ids(_packed(address(fTsla)), _packed(address(fAmzn)));
        PortfolioStrategy s = _pushInit(ids);
        assertEq(s.getFeedIds()[0], ids[0], "slot 0 feed stored");
        assertEq(s.getFeedIds()[1], ids[1], "slot 1 feed stored");
    }

    /// @dev The bind compares the low 160 bits only — a slot packing a longer
    ///      per-slot staleness (equity feeds go quiet outside market hours) is
    ///      still the registered aggregator.
    function test_init_acceptsRegisteredAggregatorWithPackedAge() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        bytes32 packedAge = _packed(address(fTsla), 96 hours);
        PortfolioStrategy s = _pushInit(_ids(packedAge, _packed(address(fAmzn))));
        assertEq(s.getFeedIds()[0], packedAge, "packed age preserved");
    }

    /// @dev Documented conditional skip: an unlisted token has no registered
    ///      aggregator to bind against. Safe because the router prices that
    ///      position `(0, false)`, so the vault's instant lane never opens and
    ///      the unbound mark is never consumed — see the read-time tests below
    ///      for what happens once it IS listed.
    function test_init_skipsBindWhenTokenIsNotRegistered() public {
        _register(address(amzn), address(fAmzn));

        PortfolioStrategy s = _pushInit(_ids(_packed(address(fRogue)), _packed(address(fAmzn))));
        assertEq(s.getFeedIds()[0], _packed(address(fRogue)), "unbound slot accepted");
    }

    /// @dev Lane A unwired on the factory: nothing to bind against, and the
    ///      vault cannot price the basket either.
    function test_init_skipsBindWhenPriceRouterUnset() public {
        _register(address(tsla), address(fTsla));
        factoryStub.setPriceRouter(address(0));

        PortfolioStrategy s = _pushInit(_ids(_packed(address(fRogue)), _packed(address(fAmzn))));
        assertEq(s.getFeedIds()[0], _packed(address(fRogue)), "unbound slot accepted");
    }

    /// @dev A router with no adapter registered for `ERC20_SPOT`.
    function test_init_skipsBindWhenNoSpotAdapterRegistered() public {
        _register(address(tsla), address(fTsla));
        PriceRouter bare = _newRouter();
        factoryStub.setPriceRouter(address(bare));

        PortfolioStrategy s = _pushInit(_ids(_packed(address(fRogue)), _packed(address(fAmzn))));
        assertEq(s.getFeedIds()[0], _packed(address(fRogue)), "unbound slot accepted");
    }

    /// @dev A vault without the `factory()` surface (or codeless) must not
    ///      revert init — the walk fails soft, it never blocks a deployment.
    function test_init_skipsBindWhenVaultHasNoFactorySurface() public {
        _register(address(tsla), address(fTsla));
        address eoaVault = makeAddr("eoaVault");

        bytes memory data = _initData(address(0), _ids(_packed(address(fRogue)), _packed(address(fAmzn))), 8);
        PortfolioStrategy s = _init(eoaVault, data);
        assertEq(s.vault(), eoaVault, "init completed against a codeless vault");
    }

    /// @dev Data Streams mode carries no aggregator address to bind: the 32
    ///      bytes are a report id, and `_verifyPrice` binds them against the
    ///      signed report instead.
    function test_init_bindIsPushModeOnly() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        bytes32[] memory ids = _ids(keccak256("ds.tsla"), keccak256("ds.amzn"));
        bytes memory data = _initData(makeAddr("verifier"), ids, 18);
        PortfolioStrategy s = _init(address(vaultStub), data);
        assertEq(s.getFeedIds()[0], ids[0], "data streams feed id stored verbatim");
        assertEq(s.getFeedIds()[1], ids[1], "data streams feed id stored verbatim");
    }

    // ── getFeedIds ──

    function test_getFeedIds_lengthMatchesAllocations() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        PortfolioStrategy s = _pushInit(_ids(_packed(address(fTsla)), _packed(address(fAmzn))));
        assertEq(s.getFeedIds().length, s.allocationCount(), "one feed id per allocation");
    }

    /// @dev What a reviewer actually does with the getter: recover the
    ///      aggregator and the per-slot staleness from the packed word.
    function test_getFeedIds_decodesToAggregatorAndAge() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));

        PortfolioStrategy s = _pushInit(_ids(_packed(address(fTsla), 96 hours), _packed(address(fAmzn))));
        bytes32[] memory ids = s.getFeedIds();
        assertEq(address(uint160(uint256(ids[0]))), address(fTsla), "aggregator recovered");
        assertEq(uint256(ids[0]) >> 160, 96 hours, "per-slot age recovered");
        assertEq(address(uint160(uint256(ids[1]))), address(fAmzn), "aggregator recovered");
        assertEq(uint256(ids[1]) >> 160, 0, "default age recovered");
    }

    // ── Read-time re-bind ──

    /// @dev The residual window the init bind cannot see: the slot was unbound
    ///      at init because the token was unlisted, and governance lists it
    ///      later. Lane A would open on the router's aggregator while the
    ///      strategy still marks off the proposer's — so the mark shuts.
    /// @dev A slot the live registry does not list has no published depth cap,
    ///      so it contributes NO instant-exit capacity — before or after the
    ///      registry later lists it on a different aggregator. (Pre-depth-bound
    ///      this asserted the basket was priced until the registry disagreed;
    ///      the depth bound now shuts capacity a step earlier, for the separate
    ///      reason that nothing has justified a size for an unlisted token.)
    ///      The binding itself, for this same unlisted-then-listed window, is
    ///      proven by `test_withdrawTo_revertsWhenTokenIsListedLaterOnAnotherAggregator`.
    function test_availableLiquidity_unlistedSlotHasNoInstantCapacity() public {
        _register(address(amzn), address(fAmzn));
        PortfolioStrategy s = _pushInit(_ids(_packed(address(fRogue)), _packed(address(fAmzn))));
        _execute(s);

        uint256 idle = weth.balanceOf(address(s));
        assertEq(s.availableLiquidity(), idle, "unlisted token publishes no depth cap: idle-only");

        _register(address(tsla), address(fTsla));
        assertEq(s.availableLiquidity(), idle, "and stays shut once the registry disagrees");
    }

    function test_withdrawTo_revertsWhenTokenIsListedLaterOnAnotherAggregator() public {
        _register(address(amzn), address(fAmzn));
        PortfolioStrategy s = _pushInit(_ids(_packed(address(fRogue)), _packed(address(fAmzn))));
        _execute(s);
        _register(address(tsla), address(fTsla));

        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        vm.expectRevert(PortfolioStrategy.StalePrice.selector);
        s.withdrawTo(1e18);
    }

    /// @dev The other window: bound at init, then governance rotates the
    ///      registry's aggregator under a live basket. Fail-closed — the
    ///      strategy stops marking rather than unwinding against a feed the
    ///      protocol no longer prices with.
    function test_availableLiquidity_degradesAfterRegistryAggregatorRotation() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));
        PortfolioStrategy s = _pushInit(_ids(_packed(address(fTsla)), _packed(address(fAmzn))));
        _execute(s);

        uint256 idle = weth.balanceOf(address(s));
        assertGt(s.availableLiquidity(), idle, "bound basket prices");

        _register(address(tsla), address(fRogue));
        assertEq(s.availableLiquidity(), idle, "rotation shuts Lane A for the stale binding");
    }

    /// @dev The bound, still-registered basket keeps working end to end: the
    ///      re-bind must not cost a legitimate unwind.
    function test_withdrawTo_succeedsWhileTheBindingHolds() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));
        PortfolioStrategy s = _pushInit(_ids(_packed(address(fTsla)), _packed(address(fAmzn))));
        _execute(s);

        uint256 balBefore = weth.balanceOf(address(vaultStub));
        address vaultAddr = address(vaultStub);
        vm.prank(vaultAddr);
        s.withdrawTo(1e18);
        assertEq(weth.balanceOf(address(vaultStub)) - balBefore, 1e18, "unwind delivered exactly");
    }

    /// @dev The registry going away entirely (Lane A torn down at the factory)
    ///      leaves the strategy marking off its own declared feeds, matching
    ///      the pre-registry behaviour rather than bricking.
    function test_availableLiquidity_unaffectedWhenRegistryBecomesUnreachable() public {
        _register(address(tsla), address(fTsla));
        _register(address(amzn), address(fAmzn));
        PortfolioStrategy s = _pushInit(_ids(_packed(address(fTsla)), _packed(address(fAmzn))));
        _execute(s);

        uint256 bound = s.availableLiquidity();
        factoryStub.setPriceRouter(address(0));
        assertEq(s.availableLiquidity(), bound, "unreachable registry is not a mark failure");
    }
}
