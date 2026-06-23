// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {IMoonwellMarket} from "../../../src/interfaces/IMoonwellMarket.sol";

// ---------------------------------------------------------------------------
// Minimal discovery-only interfaces (not imported from src/ — these are
// read-only view subsets; full write interfaces live in src/interfaces/).
// ---------------------------------------------------------------------------

interface ICLFactoryView {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

interface ICLPoolView {
    function liquidity() external view returns (uint128);
    function gauge() external view returns (address);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

interface ICLGaugeView {
    function rewardToken() external view returns (address);
}

interface INpmView {
    function factory() external view returns (address);
}

interface IRouterView {
    function factory() external view returns (address);
}

interface IVoterView {
    function gauges(address pool) external view returns (address);
}

interface IAgg {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title SlipstreamDiscoveryForkTest
 * @notice Fork tests that verify all Base mainnet Slipstream + Moonwell addresses
 *         recorded in BaseAddresses.sol against a live Tenderly vnet.
 *
 *         Requires TENDERLY_FORK_RPC_URL in the environment (set in contracts/.env).
 *         Tests are skipped (not failed) when the env var is absent — safe for CI.
 *
 * @dev Run with:
 *   forge test --match-path '*SlipstreamDiscovery.fork.t.sol' -vvv
 *
 *   NOTE: Do NOT assert block.chainid == 8453 — Tenderly vnets report chainId 9998453.
 */
contract SlipstreamDiscoveryForkTest is Test {
    bool private _skip;

    function setUp() public {
        string memory rpc = vm.envOr("TENDERLY_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            _skip = true;
            return;
        }
        vm.createSelectFork(rpc);
    }

    // -------------------------------------------------------------------------
    // Test 1: Pool discovery via factory.getPool
    // -------------------------------------------------------------------------

    function test_poolDiscovery() public {
        if (_skip) return;

        ICLFactoryView factory = ICLFactoryView(BaseAddresses.SLIPSTREAM_CL_FACTORY);

        // Factory returns the ts=100 pool when queried with CBBTC+WETH+100
        address ts100 = factory.getPool(BaseAddresses.CBBTC, BaseAddresses.WETH, 100);
        assertEq(ts100, BaseAddresses.CBBTC_WETH_POOL, "ts=100 pool address mismatch");

        // Factory returns the ts=1 pool when queried with CBBTC+WETH+1
        address ts1 = factory.getPool(BaseAddresses.CBBTC, BaseAddresses.WETH, 1);
        assertEq(ts1, BaseAddresses.CBBTC_WETH_POOL_TS1, "ts=1 pool address mismatch");

        // ts=100 pool has deeper liquidity than ts=1 pool
        uint128 liq100 = ICLPoolView(BaseAddresses.CBBTC_WETH_POOL).liquidity();
        uint128 liq1 = ICLPoolView(BaseAddresses.CBBTC_WETH_POOL_TS1).liquidity();
        assertGt(liq100, liq1, "ts=100 pool should have more liquidity than ts=1");

        emit log_named_uint("CBBTC_WETH_POOL liquidity (ts=100)", liq100);
        emit log_named_uint("CBBTC_WETH_POOL_TS1 liquidity (ts=1)", liq1);
    }

    // -------------------------------------------------------------------------
    // Test 2: Pool slot0 / observe / token selectors
    // -------------------------------------------------------------------------

    function test_poolSelectors() public {
        if (_skip) return;

        ICLPoolView pool = ICLPoolView(BaseAddresses.CBBTC_WETH_POOL);

        // Token ordering: token0=WETH, token1=cbBTC
        assertEq(pool.token0(), BaseAddresses.WETH, "token0 should be WETH");
        assertEq(pool.token1(), BaseAddresses.CBBTC, "token1 should be cbBTC");

        // Tick spacing matches the constant
        assertEq(pool.tickSpacing(), BaseAddresses.CBBTC_WETH_TICK_SPACING, "tickSpacing mismatch");

        // Gauge address matches BaseAddresses
        assertEq(pool.gauge(), BaseAddresses.CBBTC_WETH_GAUGE, "gauge address mismatch");

        // slot0 decodes without revert; sqrtPriceX96 > 0 (pool is initialized)
        (uint160 sqrtPriceX96,,,,,) = pool.slot0();
        assertGt(sqrtPriceX96, 0, "sqrtPriceX96 should be > 0");
        emit log_named_uint("sqrtPriceX96", sqrtPriceX96);

        // observe([3600, 0]) decodes without revert (1-hour TWAP window)
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 3600;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        assertTrue(tickCumulatives.length == 2, "observe should return 2 values");
        emit log_named_int("tickCumulatives[0] (1h ago)", tickCumulatives[0]);
        emit log_named_int("tickCumulatives[1] (now)", tickCumulatives[1]);
    }

    // -------------------------------------------------------------------------
    // Test 3: Gauge and Voter cross-checks
    // -------------------------------------------------------------------------

    function test_gaugeAndVoter() public {
        if (_skip) return;

        // Gauge reward token is AERO
        address rewardToken = ICLGaugeView(BaseAddresses.CBBTC_WETH_GAUGE).rewardToken();
        assertEq(rewardToken, BaseAddresses.AERO, "gauge rewardToken should be AERO");

        // Voter maps the pool to the expected gauge
        address gaugeFromVoter = IVoterView(BaseAddresses.AERODROME_VOTER).gauges(BaseAddresses.CBBTC_WETH_POOL);
        assertEq(gaugeFromVoter, BaseAddresses.CBBTC_WETH_GAUGE, "voter gauge mapping mismatch");
    }

    // -------------------------------------------------------------------------
    // Test 4: NPM and Router factory pointers
    // -------------------------------------------------------------------------

    function test_npmAndRouter() public {
        if (_skip) return;

        // NPM.factory() should point back to the CL factory
        address npmFactory = INpmView(BaseAddresses.SLIPSTREAM_NPM).factory();
        assertEq(npmFactory, BaseAddresses.SLIPSTREAM_CL_FACTORY, "NPM factory mismatch");

        // SwapRouter.factory() should point back to the CL factory
        address routerFactory = IRouterView(BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER).factory();
        assertEq(routerFactory, BaseAddresses.SLIPSTREAM_CL_FACTORY, "SwapRouter factory mismatch");
    }

    // -------------------------------------------------------------------------
    // Test 5: Sequencer uptime feed
    // -------------------------------------------------------------------------

    function test_sequencerFeed() public {
        if (_skip) return;

        IAgg feed = IAgg(BaseAddresses.SEQUENCER_UPTIME_FEED);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        // answer is 0 (sequencer up) or 1 (sequencer down) — nothing else is valid
        assertTrue(answer == 0 || answer == 1, "sequencer answer must be 0 or 1");
        assertGt(updatedAt, 0, "updatedAt should be > 0");

        emit log_named_int("sequencer answer (0=up, 1=down)", answer);
        emit log_named_uint("sequencer updatedAt", updatedAt);
    }

    // -------------------------------------------------------------------------
    // Test 6: Moonwell market selectors
    // -------------------------------------------------------------------------

    function test_moonwellSelectors() public {
        if (_skip) return;

        // mUSDC exchangeRateStored > 0 (market is initialized and has accrued interest)
        uint256 mUsdcRate = IMoonwellMarket(BaseAddresses.MOONWELL_MUSDC).exchangeRateStored();
        assertGt(mUsdcRate, 0, "mUSDC exchangeRateStored should be > 0");
        emit log_named_uint("mUSDC exchangeRateStored", mUsdcRate);

        // mcbBTC borrow balance for this test contract is 0 (we haven't borrowed)
        uint256 borrowBal = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(this));
        assertEq(borrowBal, 0, "fresh address should have 0 borrow balance");

        // Comptroller has deployed code
        assertTrue(BaseAddresses.MOONWELL_COMPTROLLER.code.length > 0, "Comptroller has no code");

        // NPM.positions() and mint/borrow/repay/stake selectors verified in §3 fork harness (_openRealBook)
        // Do NOT call enterMarkets here — state-changing; validated in the full integration harness.
    }
}
