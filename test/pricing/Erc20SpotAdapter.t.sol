// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LaneAFixture} from "../helpers/LaneAFixture.sol";
import {Erc20SpotAdapter} from "../../src/pricing/Erc20SpotAdapter.sol";
import {PositionKinds} from "../../src/libraries/PositionKinds.sol";
import {Position} from "../../src/interfaces/IPriceRouter.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

/// @notice Stand-in for the strategy holder: exposes `vault()` so the
///         adapter's numeraire-binding chain (holder → vault → asset) resolves.
contract HolderStub {
    address internal immutable _vault;

    constructor(address vault_) {
        _vault = vault_;
    }

    function vault() external view returns (address) {
        return _vault;
    }
}

/// @notice Stand-in for the vault side of the binding chain.
contract VaultStub {
    address internal immutable _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }
}

/// @notice Feed that registers cleanly, then can be broken (reverting
///         latestRoundData) or re-scaled (decimals drift) after registration.
contract MutableFeed {
    uint8 public decimals;
    int256 internal _answer;
    bool internal _broken;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        _answer = answer_;
    }

    function setBroken(bool broken_) external {
        _broken = broken_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!_broken, "feed boom");
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Minimal Uniswap-v3-style pool mock: settable sqrtPriceX96, fixed
///         token pair, breakable slot0 for the divergence-gate tests.
contract MockUniV3Pool {
    address public token0;
    address public token1;
    uint160 internal _sqrtPriceX96;
    /// @dev Time-weighted price, independent of spot. Zero = "TWAP tracks
    ///      spot" (a pool that has held this price for the whole window).
    ///      Setting it apart from spot models an in-block manipulation: spot
    ///      moves, the window average does not.
    uint160 internal _twapSqrtPriceX96;
    bool internal _broken;
    bool internal _shortHistory;
    uint32 internal constant _BASE = 1_000_000;

    constructor(address token0_, address token1_, uint160 sqrtPriceX96_) {
        token0 = token0_;
        token1 = token1_;
        _sqrtPriceX96 = sqrtPriceX96_;
    }

    function setSqrtPrice(uint160 sqrtPriceX96_) external {
        _sqrtPriceX96 = sqrtPriceX96_;
    }

    function setBroken(bool broken_) external {
        _broken = broken_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        require(!_broken, "pool boom");
        return (_sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    /// @dev Cumulative ticks for a pool that has held `_sqrtPriceX96` flat for
    ///      the whole window, so `(cum[1] - cum[0]) / window` recovers exactly
    ///      the configured tick. `_BASE` is an arbitrary large elapsed time so
    ///      both cumulatives stay positive for positive ticks.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!_broken, "pool boom");
        require(!_shortHistory, "OLD");
        uint160 twapSqrtP = _twapSqrtPriceX96 == 0 ? _sqrtPriceX96 : _twapSqrtPriceX96;
        int56 tick = int56(TickMath.getTickAtSqrtRatio(twapSqrtP));
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = tick * int56(uint56(_BASE - secondsAgos[i]));
        }
    }

    /// @notice Simulate a pool whose observation buffer is shorter than the
    ///         requested window (Uniswap reverts `OLD`).
    function setShortHistory(bool short_) external {
        _shortHistory = short_;
    }

    /// @notice Move the instantaneous price WITHOUT moving the window average —
    ///         i.e. exactly what an attacker's in-block swap does.
    function setSpotOnly(uint160 spotSqrtPriceX96) external {
        if (_twapSqrtPriceX96 == 0) _twapSqrtPriceX96 = _sqrtPriceX96; // pin the pre-attack average
        _sqrtPriceX96 = spotSqrtPriceX96;
    }
}

/// @notice Token whose `balanceOf` reverts but registers cleanly (decimals ok).
contract RevertingBalanceToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        revert("balance boom");
    }
}

/// @title Erc20SpotAdapterTest
/// @notice Unit suite for the ERC-20 spot pricing adapter: decimal matrix,
///         freshness gauntlet, fail-closed guards, registry access control,
///         and the wrong-feed adversary from the erc20-spot-pricing spec.
contract Erc20SpotAdapterTest is LaneAFixture {
    Erc20SpotAdapter internal adapter;
    ERC20Mock internal usdc; // 6-dec numeraire
    address internal adapterOwner = makeAddr("adapterOwner");
    address internal stranger = makeAddr("stranger");
    address internal holder;

    uint256 internal constant MAX_AGE = 1 days;

    function setUp() public {
        _deployRouter();
        usdc = _newToken("USDC", 6);
        adapter = new Erc20SpotAdapter(adapterOwner, address(usdc));
        _registerKind(PositionKinds.ERC20_SPOT, address(adapter), true);
        // Holder whose vault's asset is the numeraire — the happy-path binding.
        holder = address(new HolderStub(address(new VaultStub(address(usdc)))));
    }

    // ── Helpers ──

    function _pos(address venue) internal pure returns (Position memory) {
        return Position({venue: venue, kind: PositionKinds.ERC20_SPOT, ref: ""});
    }

    uint256 internal constant NO_CAP = type(uint96).max;

    /// @dev Register with an effectively-unlimited cap and the divergence gate
    ///      off — the baseline config the pre-cap tests assume.
    function _register(address token, address feed, uint256 maxAge) internal {
        vm.prank(adapterOwner);
        adapter.setFeed(token, feed, maxAge, NO_CAP, address(0), 0);
    }

    function _registerFull(
        address token,
        address feed,
        uint256 maxAge,
        uint256 cap,
        address pool,
        uint256 divergenceBps
    ) internal {
        vm.prank(adapterOwner);
        adapter.setFeed(token, feed, maxAge, cap, pool, divergenceBps);
    }

    // ── Divergence-gate helpers ──

    /// @dev Babylonian integer sqrt (test-side only).
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev sqrtPriceX96 producing pool spot `poolNum` (numeraire raw units
    ///      per whole token) for the given side of the pair.
    function _sqrtPForPrice(uint256 poolNum, uint8 tokenDec, bool tokenIsToken0) internal pure returns (uint160) {
        uint256 ratioX128 = tokenIsToken0 ? (poolNum << 128) / (10 ** tokenDec) : ((10 ** tokenDec) << 128) / poolNum;
        return uint160(_sqrt(ratioX128 << 64));
    }

    /// @dev Deploy an 18-dec token at a deterministic address (below or above
    ///      the numeraire) so the token0/token1 side under test is fixed, plus
    ///      its $150 8-dec feed and a reference pool at `poolNum`.
    function _pooledFixture(bool tokenIsToken0, uint256 poolNum, uint256 divergenceBps)
        internal
        returns (ERC20Mock token, MockAggregatorV3 feed, MockUniV3Pool pool)
    {
        address where = tokenIsToken0 ? address(uint160(0xAAAA)) : address(type(uint160).max);
        deployCodeTo("test/mocks/ERC20Mock.sol:ERC20Mock", abi.encode("TOK", "TOK", uint8(18)), where);
        token = ERC20Mock(where);
        // Fixture sanity: the side is decided by address order vs numeraire.
        assertEq(address(token) < address(usdc), tokenIsToken0, "fixture ordering");

        feed = _newFeed(8, int256(150e8));
        uint160 sqrtP = _sqrtPForPrice(poolNum, 18, tokenIsToken0);
        pool = tokenIsToken0
            ? new MockUniV3Pool(address(token), address(usdc), sqrtP)
            : new MockUniV3Pool(address(usdc), address(token), sqrtP);
        _registerFull(address(token), address(feed), MAX_AGE, NO_CAP, address(pool), divergenceBps);
        token.mint(holder, 1e18);
    }

    /// @dev Deploy token(tokenDec) + feed(feedDec) at $150, register, mint 2
    ///      whole tokens to the holder, and assert value == 300 numeraire
    ///      units (2 × $150) at 6 decimals.
    function _matrixCase(uint8 tokenDec, uint8 feedDec) internal {
        ERC20Mock token = _newToken("TOK", tokenDec);
        MockAggregatorV3 feed = _newFeed(feedDec, int256(150 * 10 ** uint256(feedDec)));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 2 * 10 ** uint256(tokenDec));

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "priced");
        assertEq(v, 300e6, "2 tokens x $150 in 6-dec numeraire units");
    }

    // ── Decimal matrix (token 6/8/18 x feed 8/18) ──

    function test_value_token6_feed8() public {
        _matrixCase(6, 8);
    }

    function test_value_token8_feed8() public {
        _matrixCase(8, 8);
    }

    function test_value_token18_feed8() public {
        _matrixCase(18, 8);
    }

    function test_value_token6_feed18() public {
        _matrixCase(6, 18);
    }

    function test_value_token8_feed18() public {
        _matrixCase(8, 18);
    }

    function test_value_token18_feed18() public {
        _matrixCase(18, 18);
    }

    // ── Quantity comes from the venue ──

    function test_value_zeroBalance_isZeroOk() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "zero holding is a valid zero value");
        assertEq(v, 0);
    }

    function test_value_numeraireVenue_valuedAtPar_noRegistryEntry() public {
        // The unit of account prices at 1 by definition (design open question:
        // USDG needs no feed entry when it IS the vault asset).
        usdc.mint(holder, 123e6);
        (uint256 v, bool ok) = adapter.value(_pos(address(usdc)), holder);
        assertTrue(ok);
        assertEq(v, 123e6);
    }

    // ── Staleness boundary ──

    function test_value_staleness_exactlyMaxAgeOk_onePastFails() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        uint256 t0 = vm.getBlockTimestamp();

        // Exactly maxAge old: still priceable.
        vm.warp(t0 + MAX_AGE);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "age == maxAge is fresh");
        assertEq(v, 150e6);

        // One second past: fails closed.
        vm.warp(t0 + MAX_AGE + 1);
        (v, ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "age == maxAge + 1 is stale");
        assertEq(v, 0);
    }

    function test_value_futureUpdatedAt_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        feed.setUpdatedAt(vm.getBlockTimestamp() + 1);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "clock-skewed future price fails closed");
        assertEq(v, 0);
    }

    // ── Broken feed ──

    function test_value_feedReverts_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MutableFeed feed = new MutableFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        feed.setBroken(true);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "reverting feed never reverts the valuation");
        assertEq(v, 0);
    }

    function test_value_nonPositiveAnswer_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(0));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "zero answer");
        assertEq(v, 0);

        feed.setAnswer(-1);
        (v, ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "negative answer");
        assertEq(v, 0);
    }

    function test_value_answeredInRoundBehindRoundId_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        feed.setRoundId(2); // answeredInRound stays 1 < roundId 2
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "carried-over answer from a superseded round");
        assertEq(v, 0);
    }

    function test_value_zeroStartedAt_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        feed.setStartedAt(0);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "incomplete round");
        assertEq(v, 0);
    }

    // ── Malformed / adversarial positions ──

    function test_value_unregisteredToken_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        token.mint(holder, 1e18);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "no registry entry");
        assertEq(v, 0);
    }

    function test_value_zeroVenue_failsClosed() public {
        (uint256 v, bool ok) = adapter.value(_pos(address(0)), holder);
        assertFalse(ok);
        assertEq(v, 0);
    }

    function test_value_wrongKind_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        Position memory p = Position({venue: address(token), kind: PositionKinds.MORPHO_BLUE_SUPPLY, ref: ""});
        (uint256 v, bool ok) = adapter.value(p, holder);
        assertFalse(ok, "foreign kind misrouted here fails closed");
        assertEq(v, 0);
    }

    function test_value_nonEmptyRef_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        MockAggregatorV3 richFeed = _newFeed(8, int256(150_000e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        // A ref-borne feed locator must never select the feed (design D2).
        Position memory p =
            Position({venue: address(token), kind: PositionKinds.ERC20_SPOT, ref: abi.encode(address(richFeed))});
        (uint256 v, bool ok) = adapter.value(p, holder);
        assertFalse(ok, "ref cannot smuggle a feed");
        assertEq(v, 0);
    }

    /// @notice The spec's wrong-feed adversary: token A is registered with a
    ///         (rich) feed; a strategy holding token B reports token B hoping
    ///         it prices off A's feed. The registry is keyed by venue token,
    ///         so B has no entry and values (0, false).
    function test_value_wrongFeedAdversary_blocked() public {
        ERC20Mock tokenA = _newToken("A", 18);
        MockAggregatorV3 feedA = _newFeed(8, int256(150_000e8)); // very rich mark
        _register(address(tokenA), address(feedA), MAX_AGE);

        ERC20Mock tokenB = _newToken("B", 18);
        tokenB.mint(holder, 1_000_000e18); // real balance, worthless token

        (uint256 v, bool ok) = adapter.value(_pos(address(tokenB)), holder);
        assertFalse(ok, "B cannot borrow A's feed");
        assertEq(v, 0);
    }

    function test_value_balanceOfReverts_failsClosed() public {
        RevertingBalanceToken token = new RevertingBalanceToken();
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "reverting balanceOf never reverts the valuation");
        assertEq(v, 0);
    }

    function test_value_feedDecimalsDrift_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MutableFeed feed = new MutableFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        // Sanity: prices before the drift.
        (, bool okBefore) = adapter.value(_pos(address(token)), holder);
        assertTrue(okBefore);

        // Proxy "upgrade" to a different scale after registration.
        feed.setDecimals(18);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "live decimals != registration snapshot");
        assertEq(v, 0);
    }

    function test_value_holderBinding_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);

        // EOA holder: no vault() surface.
        address eoa = makeAddr("eoaHolder");
        token.mint(eoa, 1e18);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), eoa);
        assertFalse(ok, "holder without vault() fails closed");
        assertEq(v, 0);

        // Holder whose vault asset is NOT the numeraire: mixed-unit guard.
        ERC20Mock weth = _newToken("WETH", 18);
        address wrongHolder = address(new HolderStub(address(new VaultStub(address(weth)))));
        token.mint(wrongHolder, 1e18);
        (v, ok) = adapter.value(_pos(address(token)), wrongHolder);
        assertFalse(ok, "vault asset != numeraire fails closed");
        assertEq(v, 0);
    }

    function test_value_overflow_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, type(uint256).max);

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "absurd balance degrades instead of reverting NAV");
        assertEq(v, 0);
    }

    // ── View-only valuation ──

    function test_value_isViewOnly_staticcallSucceeds() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        Position memory p = _pos(address(token));
        (bool s, bytes memory d) = address(adapter).staticcall(abi.encodeCall(adapter.value, (p, holder)));
        assertTrue(s, "valuation runs under STATICCALL (no state changes)");
        (uint256 v, bool ok) = abi.decode(d, (uint256, bool));
        assertTrue(ok);
        assertEq(v, 150e6);
    }

    // ── Registry access control + validation ──

    function test_setFeed_onlyOwner() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setFeed(address(token), address(feed), MAX_AGE, NO_CAP, address(0), 0);
    }

    function test_removeFeed_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.removeFeed(address(usdc));
    }

    function test_setFeed_maxAgeBounds() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));

        vm.startPrank(adapterOwner);
        vm.expectRevert(Erc20SpotAdapter.InvalidMaxAge.selector);
        adapter.setFeed(address(token), address(feed), 1 hours - 1, NO_CAP, address(0), 0);
        vm.expectRevert(Erc20SpotAdapter.InvalidMaxAge.selector);
        adapter.setFeed(address(token), address(feed), 30 days + 1, NO_CAP, address(0), 0);
        // Exact bounds accepted.
        adapter.setFeed(address(token), address(feed), 1 hours, NO_CAP, address(0), 0);
        adapter.setFeed(address(token), address(feed), 30 days, NO_CAP, address(0), 0);
        vm.stopPrank();
    }

    function test_setFeed_zeroAddresses_revert() public {
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        vm.startPrank(adapterOwner);
        vm.expectRevert(Erc20SpotAdapter.ZeroAddress.selector);
        adapter.setFeed(address(0), address(feed), MAX_AGE, NO_CAP, address(0), 0);
        vm.expectRevert(Erc20SpotAdapter.ZeroAddress.selector);
        adapter.setFeed(address(usdc), address(0), MAX_AGE, NO_CAP, address(0), 0);
        vm.stopPrank();
    }

    function test_setFeed_decimalsOutOfRange_revert() public {
        ERC20Mock token37 = _newToken("T37", 37);
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        MockAggregatorV3 feed37 = _newFeed(37, int256(150e8));

        vm.startPrank(adapterOwner);
        vm.expectRevert(Erc20SpotAdapter.InvalidDecimals.selector);
        adapter.setFeed(address(token37), address(feed), MAX_AGE, NO_CAP, address(0), 0);
        vm.expectRevert(Erc20SpotAdapter.InvalidDecimals.selector);
        adapter.setFeed(address(token), address(feed37), MAX_AGE, NO_CAP, address(0), 0);
        vm.stopPrank();
    }

    function test_removeFeed_delists() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 1e18);

        (, bool okBefore) = adapter.value(_pos(address(token)), holder);
        assertTrue(okBefore);

        vm.prank(adapterOwner);
        adapter.removeFeed(address(token));

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "delisted token is instant-ineligible");
        assertEq(v, 0);
    }

    // ── Per-token instant cap (design D9b) ──

    function test_value_overCap_failsClosed() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _registerFull(address(token), address(feed), MAX_AGE, 100e6, address(0), 0); // $100 cap
        token.mint(holder, 1e18); // $150 position

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "position beyond measured depth is instant-ineligible");
        assertEq(v, 0);
    }

    function test_value_atCap_passes() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _registerFull(address(token), address(feed), MAX_AGE, 150e6, address(0), 0); // cap == value
        token.mint(holder, 1e18);

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "cap is inclusive");
        assertEq(v, 150e6);
    }

    function test_setFeed_zeroCap_reverts() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        vm.prank(adapterOwner);
        vm.expectRevert(Erc20SpotAdapter.InvalidCap.selector);
        adapter.setFeed(address(token), address(feed), MAX_AGE, 0, address(0), 0);
    }

    // ── Oracle-vs-pool divergence gate (design D9c) ──

    function test_value_divergenceWithinBound_passes_token0Side() public {
        // Pool at the oracle mark exactly (divergence ~0 < 100bps).
        (ERC20Mock token,,) = _pooledFixture(true, 150e6, 100);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "aligned pool passes the gate");
        assertEq(v, 150e6);
    }

    function test_value_divergenceBeyondBound_failsClosed_token0Side() public {
        // Pool 2% under the $150 mark with a 100bps bound: the held oracle
        // mark is not executable, Lane A must close.
        (ERC20Mock token,,) = _pooledFixture(true, 147e6, 100);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "held mark above executable price fails closed");
        assertEq(v, 0);
    }

    function test_value_divergenceWithinBound_passes_token1Side() public {
        (ERC20Mock token,,) = _pooledFixture(false, 150e6, 100);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "token1-side ordering handled");
        assertEq(v, 150e6);
    }

    function test_value_divergenceBeyondBound_failsClosed_token1Side() public {
        (ERC20Mock token,,) = _pooledFixture(false, 153e6, 100); // pool 2% above
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "divergence gate is direction-agnostic");
        assertEq(v, 0);
    }

    // ── TWAP anchoring: the gate must ignore in-block spot (audit #1) ──

    /// @notice Attacker moves the pool ONTO a stale-high oracle mark inside
    ///         their own transaction to re-open Lane A. With a TWAP the window
    ///         average is unmoved, so the gate stays shut.
    function test_value_spotManipulationCannotOpenGate() public {
        // Real market is 2% under the $150 held mark → gate correctly shut.
        (ERC20Mock token,, MockUniV3Pool pool) = _pooledFixture(true, 147e6, 100);
        (, bool okBefore) = adapter.value(_pos(address(token)), holder);
        assertFalse(okBefore, "precondition: divergent pool closes Lane A");

        // Attacker's in-block swap pushes spot exactly onto the oracle mark.
        pool.setSpotOnly(_sqrtPForPrice(150e6, 18, true));

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "TWAP ignores the manipulated spot - gate stays shut");
        assertEq(v, 0);
    }

    /// @notice Inverse direction: attacker shoves spot far off a HEALTHY mark
    ///         to force (0,false) and revert a victim's instant exit. The TWAP
    ///         keeps Lane A open, so the cheap griefing DoS is closed too.
    function test_value_spotManipulationCannotCloseGate() public {
        (ERC20Mock token,, MockUniV3Pool pool) = _pooledFixture(true, 150e6, 100);

        pool.setSpotOnly(_sqrtPForPrice(120e6, 18, true)); // 20% shove

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "TWAP ignores the shove - victim's exit still priced");
        assertEq(v, 150e6);
    }

    /// @notice A sustained (window-length) divergence is still caught — the
    ///         TWAP resists manipulation without going blind to real drift.
    function test_value_sustainedDivergenceStillFailsClosed() public {
        (ERC20Mock token,,) = _pooledFixture(true, 147e6, 100);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "genuine sustained divergence still closes the lane");
        assertEq(v, 0);
    }

    /// @notice A pool whose observation buffer cannot serve TWAP_WINDOW is
    ///         rejected loudly at registration rather than silently pinning its
    ///         token to Lane B forever.
    function test_setFeed_rejectsPoolWithShortHistory() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        MockUniV3Pool pool = new MockUniV3Pool(address(token), address(usdc), _sqrtPForPrice(150e6, 18, true));
        pool.setShortHistory(true);

        vm.prank(adapterOwner);
        vm.expectRevert(bytes("OLD"));
        adapter.setFeed(address(token), address(feed), MAX_AGE, NO_CAP, address(pool), 100);
    }

    function test_value_gateOff_ignoresPools() public {
        // referencePool == 0: no pool consulted, plain feed pricing.
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _registerFull(address(token), address(feed), MAX_AGE, NO_CAP, address(0), 0);
        token.mint(holder, 1e18);

        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertTrue(ok, "gate off is a valid config");
        assertEq(v, 150e6);
    }

    function test_value_poolReverts_failsClosed() public {
        (ERC20Mock token,, MockUniV3Pool pool) = _pooledFixture(true, 150e6, 100);
        pool.setBroken(true);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "unreadable pool fails closed, never reverts");
        assertEq(v, 0);
    }

    function test_value_poolZeroPrice_failsClosed() public {
        (ERC20Mock token,, MockUniV3Pool pool) = _pooledFixture(true, 150e6, 100);
        pool.setSqrtPrice(0);
        (uint256 v, bool ok) = adapter.value(_pos(address(token)), holder);
        assertFalse(ok, "zero pool price fails closed");
        assertEq(v, 0);
    }

    function test_setFeed_divergenceBoundValidation() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        MockUniV3Pool pool = new MockUniV3Pool(address(token), address(usdc), _sqrtPForPrice(150e6, 18, true));

        vm.startPrank(adapterOwner);
        // Pool set: bound must be nonzero and <= 100%.
        vm.expectRevert(Erc20SpotAdapter.InvalidDivergenceBound.selector);
        adapter.setFeed(address(token), address(feed), MAX_AGE, NO_CAP, address(pool), 0);
        vm.expectRevert(Erc20SpotAdapter.InvalidDivergenceBound.selector);
        adapter.setFeed(address(token), address(feed), MAX_AGE, NO_CAP, address(pool), 10_001);
        // Pool off: a stray bound is a config error.
        vm.expectRevert(Erc20SpotAdapter.InvalidDivergenceBound.selector);
        adapter.setFeed(address(token), address(feed), MAX_AGE, NO_CAP, address(0), 100);
        vm.stopPrank();
    }

    function test_setFeed_poolPairMismatch_reverts() public {
        ERC20Mock token = _newToken("TOK", 18);
        ERC20Mock other = _newToken("OTHER", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        // Pool over the wrong pair: gate would compare an unrelated market.
        MockUniV3Pool wrongPool = new MockUniV3Pool(address(other), address(usdc), _sqrtPForPrice(150e6, 18, true));

        vm.prank(adapterOwner);
        vm.expectRevert(Erc20SpotAdapter.InvalidPool.selector);
        adapter.setFeed(address(token), address(feed), MAX_AGE, NO_CAP, address(wrongPool), 100);
    }

    // ── Router wiring ──

    function test_value_throughRouter() public {
        ERC20Mock token = _newToken("TOK", 18);
        MockAggregatorV3 feed = _newFeed(8, int256(150e8));
        _register(address(token), address(feed), MAX_AGE);
        token.mint(holder, 2e18);

        (uint256 v, bool ok) = router.valuePosition(_pos(address(token)), holder);
        assertTrue(ok, "router prices via the registered adapter");
        assertEq(v, 300e6);
    }
}
