// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroManager} from "../src/strategies/LeveragedAeroManager.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mocks (fork-free). Reuse the shapes from LeveragedAeroCLProtocolFee.t.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract MockToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Gauge whose `getReward` mints a fixed AERO amount to the caller (the strategy under
///      delegatecall), so the test controls `aeroBal` (the floor's numerator).
contract MockGauge {
    address public rewardToken;
    uint256 public rewardAmt;

    constructor(address aero) {
        rewardToken = aero;
    }

    function setReward(uint256 a) external {
        rewardAmt = a;
    }

    function getReward(uint256) external {
        MockToken(rewardToken).mint(msg.sender, rewardAmt);
    }
}

/// @dev Aerodrome v2 router stub: burns the AERO in, mints exactly `usdcOut` USDC — lets the test
///      set the swap fill above or below the derived oracle floor.
contract MockAeroRouter {
    MockToken public aero;
    MockToken public usdc;
    uint256 public usdcOut;

    constructor(MockToken a, MockToken u) {
        aero = a;
        usdc = u;
    }

    function setUsdcOut(uint256 o) external {
        usdcOut = o;
    }

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, Route[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        aero.burn(msg.sender, amountIn);
        usdc.mint(to, usdcOut);
        amounts = new uint256[](1);
        amounts[0] = usdcOut;
    }
}

/// @dev Exposes compoundImpl so the AERO-swap oracle floor can be unit-tested in isolation.
contract CompoundFloorHarness is LeveragedAerodromeCLStrategy {
    function callCompoundImpl(uint256 minUsdcOut, uint256 minLiquidity, uint256 skimCap) external returns (uint256) {
        return LeveragedAeroManager.compoundImpl(minUsdcOut, minLiquidity, skimCap);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Vault / comptroller stubs used only by the init-validation tests (real initialize()).
// ─────────────────────────────────────────────────────────────────────────────
contract MockOwnedVault {
    address public owner;
    address public asset;

    constructor(address owner_, address asset_) {
        owner = owner_;
        asset = asset_;
    }
}

/// @dev Aggregator stub with a configurable `decimals()` for the init 8dp assertion.
contract MockAggregator {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @title  LeveragedAeroCLCompoundFloorTest
/// @notice Unit tests for the L9 compound oracle floor (PR #388): the manager derives
///         `floor = aeroBal × AERO/USD(8dp) / 1e20 × (1 − maxSlippageBps)` from a hardened Chainlink
///         read and POST-checks the measured swap fill (`usdcOut < floor → BelowOracleFloor`). A
///         sandwiched/thin-pool fill below the floor reverts even with `minUsdcOut = 1`.
contract LeveragedAeroCLCompoundFloorTest is Test {
    uint256 private constant STRAT_BASE = uint256(0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900);

    // Diamond field slots (packing-verified; see LeveragedAeroCLProtocolFee.t.sol).
    uint256 private constant SLOT_USDC = STRAT_BASE + 0;
    uint256 private constant SLOT_SEQFEED = STRAT_BASE + 10;
    uint256 private constant SLOT_MAX_DELAY = STRAT_BASE + 11;
    uint256 private constant SLOT_GRACE = STRAT_BASE + 12;
    uint256 private constant SLOT_GAUGE = STRAT_BASE + 15;
    // slot 16 packs {swapRouter@0..19, tickSpacing@20, targetLtvBps@23, maxLtvBps@25, minHealthBps@27,
    // maxSlippageBps@29, usdcCollateralFactorBps@31} (probe-verified). We only touch maxSlippageBps.
    uint256 private constant SLOT_RISK_PACKED = STRAT_BASE + 16;
    uint256 private constant MAXSLIP_BYTE_OFFSET = 29;
    uint256 private constant SLOT_TOKENID = STRAT_BASE + 18;
    uint256 private constant SLOT_AERO_FEED = STRAT_BASE + 23; // new LAST field (L9)

    // BaseStrategy sequential slots.
    uint256 private constant SLOT_VAULT = 1;
    uint256 private constant SLOT_PROPOSER_STATE_INIT = 2;
    uint256 private constant STATE_EXECUTED_INIT = (uint256(1) << 168) | (uint256(1) << 160);

    // Chainlink AERO/USD price (8dp).
    address private constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address private constant AERO_FEED = address(0xFEED);
    address private constant SEQ_FEED = address(0xF000);

    function _store(address t, uint256 slot, address a) private {
        vm.store(t, bytes32(slot), bytes32(uint256(uint160(a))));
    }

    function _storeUint(address t, uint256 slot, uint256 v) private {
        vm.store(t, bytes32(slot), bytes32(v));
    }

    /// @dev Set only `maxSlippageBps` (byte offset 29 within the packed risk slot). swapRouter (bytes
    ///      0..19 of the same slot) stays 0 in this fixture, so a bare write is safe.
    function _storeMaxSlippage(address t, uint16 bps) private {
        vm.store(t, bytes32(SLOT_RISK_PACKED), bytes32(uint256(bps) << (MAXSLIP_BYTE_OFFSET * 8)));
    }

    /// @dev Mock the sequencer (up, grace elapsed) + a fresh AERO/USD feed at `price` (8dp).
    function _mockFeeds(uint256 price) private {
        vm.mockCall(
            SEQ_FEED,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(0), uint256(1), block.timestamp, uint80(1))
        );
        _mockAeroFeed(price, block.timestamp);
    }

    function _mockAeroFeed(uint256 price, uint256 updatedAt) private {
        vm.mockCall(
            AERO_FEED,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(price), uint256(1), updatedAt, uint80(1))
        );
        vm.mockCall(AERO_FEED, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(8)));
    }

    /// @dev Build a delegatecall-ready harness with a gauge, an etched v2 router, and the feed/slippage
    ///      slots primed. `maxSlippageBps` and `aeroPrice` (8dp) parameterise the floor.
    function _fixture(uint16 maxSlippageBps, uint256 aeroPrice)
        private
        returns (CompoundFloorHarness h, MockToken usdc, MockGauge gauge, MockAeroRouter router)
    {
        vm.warp(block.timestamp + 7 days); // clear the sequencer grace window + avoid stale-mock underflow
        h = new CompoundFloorHarness();
        usdc = new MockToken("USDC");
        MockToken aero = new MockToken("AERO");
        gauge = new MockGauge(address(aero));

        MockAeroRouter impl = new MockAeroRouter(aero, usdc);
        vm.etch(AERO_V2_ROUTER, address(impl).code);
        router = MockAeroRouter(AERO_V2_ROUTER);
        vm.store(AERO_V2_ROUTER, bytes32(uint256(0)), bytes32(uint256(uint160(address(aero)))));
        vm.store(AERO_V2_ROUTER, bytes32(uint256(1)), bytes32(uint256(uint160(address(usdc)))));

        _store(address(h), SLOT_USDC, address(usdc));
        _store(address(h), SLOT_GAUGE, address(gauge));
        _store(address(h), SLOT_SEQFEED, SEQ_FEED);
        _store(address(h), SLOT_AERO_FEED, AERO_FEED);
        _storeUint(address(h), SLOT_MAX_DELAY, 48 hours);
        _storeUint(address(h), SLOT_GRACE, 0);
        _storeMaxSlippage(address(h), maxSlippageBps);
        _storeUint(address(h), SLOT_TOKENID, 42); // nonzero → not flat book
        _mockFeeds(aeroPrice);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 1 — sandwich regression (headline): fill below floor + minUsdcOut=1 reverts.
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev 500 AERO @ $0.90, 3% slippage → floor 436.5e6. A router fill of 300e6 (a thin-pool
    ///      sandwich) with a permissive caller `minUsdcOut = 1` MUST revert `BelowOracleFloor`.
    function test_compound_belowFloor_reverts() public {
        (CompoundFloorHarness h,, MockGauge gauge, MockAeroRouter router) = _fixture(300, 0.9e8);
        gauge.setReward(500e18);
        router.setUsdcOut(300e6); // < 436.5e6 floor

        vm.expectRevert(LeveragedAeroManager.BelowOracleFloor.selector);
        h.callCompoundImpl(1, 0, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 2 — boundary: a fill at/above floor passes.
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev A fill exactly at the floor (436.5e6) passes; the whole output is skimmable/redeployable.
    function test_compound_atFloor_passes() public {
        (CompoundFloorHarness h, MockToken usdc, MockGauge gauge, MockAeroRouter router) = _fixture(300, 0.9e8);
        gauge.setReward(500e18);
        router.setUsdcOut(436_500_000); // == floor (436.5e6)

        uint256 pay = h.callCompoundImpl(1, 0, 1_000e6); // skimCap generous → full withhold, no redeploy
        assertEq(pay, 436_500_000, "fill at floor withheld as skim (no revert)");
        assertEq(usdc.balanceOf(address(h)), 436_500_000, "no redeploy at boundary");
    }

    /// @dev A fill just above the floor also passes.
    function test_compound_aboveFloor_passes() public {
        (CompoundFloorHarness h, MockToken usdc, MockGauge gauge, MockAeroRouter router) = _fixture(300, 0.9e8);
        gauge.setReward(500e18);
        router.setUsdcOut(450e6); // > 436.5e6 floor

        uint256 pay = h.callCompoundImpl(1, 0, 1_000e6);
        assertEq(pay, 450e6, "above-floor fill accepted");
        assertEq(usdc.balanceOf(address(h)), 450e6, "no redeploy (full skim)");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 3 — stale feed fail-closes; fresh feed proceeds.
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev A stale AERO feed (updatedAt far in the past, age > maxDelay) reverts the whole compound
    ///      (ChainlinkReader.StaleOracle) — the intended fail-closed posture (defer the harvest).
    function test_compound_staleFeed_failsClosed() public {
        (CompoundFloorHarness h,, MockGauge gauge, MockAeroRouter router) = _fixture(300, 0.9e8);
        gauge.setReward(500e18);
        router.setUsdcOut(450e6); // would clear a fresh floor
        // Re-mock the AERO feed stale: updatedAt = now − 49h > 48h maxDelay.
        _mockAeroFeed(0.9e8, block.timestamp - 49 hours);

        vm.expectRevert(); // ChainlinkReader.StaleOracle (bubbled from _readUsd8)
        h.callCompoundImpl(1, 0, 0);
    }

    /// @dev The same fill with a FRESH feed proceeds (control for the stale case above).
    function test_compound_freshFeed_proceeds() public {
        (CompoundFloorHarness h, MockToken usdc, MockGauge gauge, MockAeroRouter router) = _fixture(300, 0.9e8);
        gauge.setReward(500e18);
        router.setUsdcOut(450e6);

        uint256 pay = h.callCompoundImpl(1, 0, 1_000e6);
        assertEq(pay, 450e6, "fresh feed -> compound proceeds");
        assertEq(usdc.balanceOf(address(h)), 450e6, "output retained for skim");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 5 — floor math (hand-computed).
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev aeroBal = 500e18, price = 0.90e8, maxSlippageBps = 300 → floor = 436.5e6. A fill one wei
    ///      below reverts; a fill exactly at the floor passes — pinning the exact boundary.
    function test_compound_floorMath_exactBoundary() public {
        uint256 aeroBal = 500e18;
        uint256 price = 0.9e8;
        uint16 slippage = 300;
        uint256 expectedFloor = Math.mulDiv(aeroBal, price, 1e20) * (10000 - slippage) / 10000;
        assertEq(expectedFloor, 436_500_000, "hand-computed floor = 436.5e6");

        // One wei below → revert.
        (CompoundFloorHarness h1,, MockGauge g1, MockAeroRouter r1) = _fixture(slippage, price);
        g1.setReward(aeroBal);
        r1.setUsdcOut(expectedFloor - 1);
        vm.expectRevert(LeveragedAeroManager.BelowOracleFloor.selector);
        h1.callCompoundImpl(1, 0, 0);

        // Exactly at floor → pass.
        (CompoundFloorHarness h2,, MockGauge g2, MockAeroRouter r2) = _fixture(slippage, price);
        g2.setReward(aeroBal);
        r2.setUsdcOut(expectedFloor);
        uint256 pay = h2.callCompoundImpl(1, 0, 1_000e6);
        assertEq(pay, expectedFloor, "fill == floor accepted");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 4 — init validation: zero feed reverts; wrong-decimals reverts.
    // ═════════════════════════════════════════════════════════════════════════

    function test_init_zeroAeroFeed_reverts() public {
        (
            LeveragedAerodromeCLStrategy strat,
            LeveragedAerodromeCLStrategy.InitParams memory p,
            address vault,
            address prop
        ) = _initFixture();
        p.aeroUsdFeed = address(0);
        vm.expectRevert(BaseStrategy.ZeroAddress.selector);
        strat.initialize(vault, prop, abi.encode(p));
    }

    function test_init_wrongDecimalsAeroFeed_reverts() public {
        (
            LeveragedAerodromeCLStrategy strat,
            LeveragedAerodromeCLStrategy.InitParams memory p,
            address vault,
            address prop
        ) = _initFixture();
        // Point aeroUsdFeed at a 6dp aggregator → UnexpectedFeedDecimals.
        p.aeroUsdFeed = address(new MockAggregator(6));
        vm.expectRevert(LeveragedAerodromeCLStrategy.UnexpectedFeedDecimals.selector);
        strat.initialize(vault, prop, abi.encode(p));
    }

    /// @dev The 8dp aggregator path clears the init decimals check (positive control).
    function test_init_eightDecimalsAeroFeed_ok() public {
        (
            LeveragedAerodromeCLStrategy strat,
            LeveragedAerodromeCLStrategy.InitParams memory p,
            address vault,
            address prop
        ) = _initFixture();
        p.aeroUsdFeed = address(new MockAggregator(8));
        strat.initialize(vault, prop, abi.encode(p)); // no revert
        assertEq(strat.layout().aeroUsdFeed, p.aeroUsdFeed, "aeroUsdFeed persisted");
    }

    /// @dev Fresh clone + a valid InitParams whose only variable is `aeroUsdFeed` (set by the caller).
    function _initFixture()
        private
        returns (
            LeveragedAerodromeCLStrategy strat,
            LeveragedAerodromeCLStrategy.InitParams memory p,
            address vault,
            address prop
        )
    {
        MockToken usdc = new MockToken("USDC");
        // MockToken has no decimals(); the L7 wiring check reads asset()==usdc and decimals()==6 — mock it.
        vm.mockCall(address(usdc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vault = address(new MockOwnedVault(makeAddr("owner"), address(usdc)));
        prop = makeAddr("proposer");
        address comptroller = makeAddr("comptroller");
        address mUsdc = makeAddr("mUsdc");
        vm.mockCall(
            comptroller, abi.encodeWithSignature("markets(address)", mUsdc), abi.encode(true, uint256(0.88e18), false)
        );

        strat = LeveragedAerodromeCLStrategy(payable(Clones.clone(address(new LeveragedAerodromeCLStrategy()))));
        p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: address(usdc),
            mUsdc: mUsdc,
            mCbBTC: makeAddr("mCbBTC"),
            mWeth: makeAddr("mWeth"),
            comptroller: comptroller,
            cbBTC: makeAddr("cbBTC"),
            weth: makeAddr("weth"),
            pool: makeAddr("pool"),
            npm: makeAddr("npm"),
            gauge: makeAddr("gauge"),
            swapRouter: makeAddr("swapRouter"),
            cbBTCFeed: makeAddr("cbBTCFeed"),
            wethFeed: makeAddr("wethFeed"),
            usdcFeed: makeAddr("usdcFeed"),
            sequencerFeed: makeAddr("sequencerFeed"),
            aeroUsdFeed: address(new MockAggregator(8)), // caller overrides per-test
            maxDelay: 48 hours,
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: 100,
            targetLtvBps: 5000,
            maxLtvBps: 6500,
            minHealthBps: 12000,
            maxSlippageBps: 100,
            managementFeeBps: 100,
            performanceFeeBps: 1000,
            feeRecipient: makeAddr("feeRecipient")
        });
    }
}
