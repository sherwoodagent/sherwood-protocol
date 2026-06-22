// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AerodromeLPAdapter} from "../../src/pricing/adapters/AerodromeLPAdapter.sol";
import {Position} from "../../src/interfaces/IPriceRouter.sol";

contract MockAeroPool {
    uint256 internal r0;
    uint256 internal r1;
    uint256 internal supply;
    uint256 internal obsTs;
    uint256 internal twapQuote;
    uint256 internal spotQuote;
    address public token0;
    address public token1;
    mapping(address => uint256) public balanceOf;

    function setup(address t0, address t1, uint256 r0_, uint256 r1_, uint256 supply_) external {
        token0 = t0;
        token1 = t1;
        r0 = r0_;
        r1 = r1_;
        supply = supply_;
    }

    function setBalance(address a, uint256 b) external {
        balanceOf[a] = b;
    }

    function setObs(uint256 t) external {
        obsTs = t;
    }

    function setQuotes(uint256 twap, uint256 spot) external {
        twapQuote = twap;
        spotQuote = spot;
    }

    function getReserves() external view returns (uint256, uint256, uint256) {
        return (r0, r1, 0);
    }

    function totalSupply() external view returns (uint256) {
        return supply;
    }

    function quote(address, uint256, uint256 granularity) external view returns (uint256) {
        return granularity == 1 ? spotQuote : twapQuote;
    }

    function lastObservation() external view returns (uint256, uint256, uint256) {
        return (obsTs, 0, 0);
    }
}

contract MockAeroFactory {
    mapping(address => bool) public isPool;

    function setPool(address p, bool v) external {
        isPool[p] = v;
    }
}

contract MockGauge {
    mapping(address => uint256) public balanceOf;

    function setBalance(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

contract AerodromeLPAdapterTest is Test {
    AerodromeLPAdapter adapter;
    MockAeroPool pool;
    MockAeroFactory factory;
    MockGauge gauge;

    address constant USDC = address(0x011); // numeraire (token0)
    address constant WETH = address(0x022); // other (token1)
    address holder = makeAddr("holder");

    uint256 constant MAX_STALE = 1800; // 30 min
    uint16 constant MAX_DEV_BPS = 100; // 1%

    function setUp() public {
        vm.warp(100_000); // so staleness math doesn't underflow
        factory = new MockAeroFactory();
        gauge = new MockGauge();
        pool = new MockAeroPool();
        factory.setPool(address(pool), true);
        adapter = new AerodromeLPAdapter(address(factory), 4, MAX_STALE, MAX_DEV_BPS);

        // Pool: 1000 USDC / 1 WETH, 100 LP supply. Holder owns 10 LP (10%).
        pool.setup(USDC, WETH, 1_000e6, 1e18, 100e18);
        pool.setBalance(holder, 10e18);
        pool.setObs(block.timestamp); // fresh
        // Other leg = 10% of 1 WETH = 0.1 WETH, TWAP-valued at 100 USDC.
        pool.setQuotes(100e6, 100e6); // twap, spot (no deviation)
    }

    function _pos() internal view returns (Position memory) {
        return Position({venue: address(pool), kind: adapter.KIND(), ref: abi.encode(address(0), USDC)});
    }

    function test_kind() public view {
        assertEq(adapter.KIND(), keccak256("AERODROME_LP"));
    }

    function test_value_decomposesAndTwapPrices() public view {
        // numAmt (USDC leg) = 10% of 1000 USDC = 100e6; other leg TWAP = 100e6.
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertTrue(ok);
        assertEq(v, 200e6, "numeraire leg + TWAP-valued other leg");
    }

    function test_value_unlistedPool_returnsZeroFalse() public {
        factory.setPool(address(pool), false);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_value_staleObservation_returnsZeroFalse() public {
        pool.setObs(block.timestamp - MAX_STALE - 1);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0);
        assertFalse(ok, "stale TWAP rejected");
    }

    function test_value_deviationGateTrips_returnsZeroFalse() public {
        // Skew the LIVE reserves so the numeraire leg (`numAmt`, taken from
        // getReserves) deviates from the other leg's TWAP value — the same-block
        // reserve-skew the live-reserve gate defends (an observation-only gate
        // would miss it). 2000 USDC / 1 WETH → numAmt = 200e6 vs TWAP 100e6 (>1%).
        pool.setup(USDC, WETH, 2_000e6, 1e18, 100e18);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0);
        assertFalse(ok, "live-reserve-vs-TWAP deviation rejected");
    }

    function test_value_zeroBalance_returnsZeroTrue() public {
        pool.setBalance(holder, 0);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0);
        assertTrue(ok);
    }

    function test_value_numeraireNotPoolToken_returnsZeroFalse() public view {
        Position memory p =
            Position({venue: address(pool), kind: adapter.KIND(), ref: abi.encode(address(0), address(0x99))});
        (uint256 v, bool ok) = adapter.value(p, holder);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_value_countsGaugeStakedLp() public {
        // Move the holder's LP into the gauge: pool balance 0, gauge balance 10.
        pool.setBalance(holder, 0);
        gauge.setBalance(holder, 10e18);
        Position memory p =
            Position({venue: address(pool), kind: adapter.KIND(), ref: abi.encode(address(gauge), USDC)});
        (uint256 v, bool ok) = adapter.value(p, holder);
        assertTrue(ok);
        assertEq(v, 200e6, "gauge-staked LP counted");
    }

    function test_constructor_badConfigReverts() public {
        vm.expectRevert(AerodromeLPAdapter.BadConfig.selector);
        new AerodromeLPAdapter(address(0), 4, MAX_STALE, MAX_DEV_BPS);
        vm.expectRevert(AerodromeLPAdapter.BadConfig.selector);
        new AerodromeLPAdapter(address(factory), 0, MAX_STALE, MAX_DEV_BPS);
    }
}
