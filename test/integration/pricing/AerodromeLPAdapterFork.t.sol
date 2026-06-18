// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AerodromeLPAdapter, IAeroPool} from "../../../src/pricing/adapters/AerodromeLPAdapter.sol";
import {Position} from "../../../src/interfaces/IPriceRouter.sol";

/// @title  AerodromeLPAdapterForkTest
/// @notice Fork tests for the Aerodrome LP adapter against the real Base pools
///         verified on-chain in the PR thread: a volatile WETH/USDC pool and a
///         stable USDC/USDbC pool. Confirms the native `quote()` TWAP +
///         decomposition price a real LP position with no custodial recorder.
/// @dev    Run: forge test --fork-url $BASE_RPC_URL --match-contract AerodromeLPAdapterForkTest
contract AerodromeLPAdapterForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant WETH_USDC = 0xcDAC0d6c6C59727a65F871236188350531885C43; // volatile
    address constant USDC_USDbC = 0x27a8Afa3Bd49406e48a074350fB7b2020c43B2bD; // stable

    AerodromeLPAdapter adapter;
    address holder = makeAddr("holder");

    function setUp() public {
        // Generous gate params so the happy path is robust at a pinned block;
        // the exact gate thresholds are exercised precisely in the unit tests.
        adapter = new AerodromeLPAdapter(AERO_FACTORY, 4, 7 days, 2000);
    }

    function _pos(address pool) internal view returns (Position memory) {
        return Position({venue: pool, kind: adapter.KIND(), ref: abi.encode(address(0), USDC)});
    }

    function _priceWithOnePercent(address pool) internal {
        // Give the holder 1% of the pool's LP supply and price it.
        uint256 supply = IAeroPool(pool).totalSupply();
        uint256 lp = supply / 100;
        deal(pool, holder, lp);
        assertEq(IAeroPool(pool).balanceOf(holder), lp, "LP dealt");

        (uint256 v, bool ok) = adapter.value(_pos(pool), holder);
        assertTrue(ok, "real pool priced instant-eligible");
        assertGt(v, 0, "non-zero LP value");
    }

    function test_fork_pricesVolatileWethUsdc() public {
        _priceWithOnePercent(WETH_USDC);
    }

    function test_fork_pricesStableUsdcUsdbc() public {
        _priceWithOnePercent(USDC_USDbC);
    }

    function test_fork_unlistedPool_returnsZeroFalse() public {
        // USDC itself is not an Aerodrome pool.
        (uint256 v, bool ok) = adapter.value(_pos(USDC), holder);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_fork_valueScalesWithLpShare() public {
        // 2% of supply should be worth ~2x the 1% value (proportional decomposition).
        uint256 supply = IAeroPool(WETH_USDC).totalSupply();
        deal(WETH_USDC, holder, supply / 100);
        (uint256 v1,) = adapter.value(_pos(WETH_USDC), holder);
        deal(WETH_USDC, holder, supply / 50);
        (uint256 v2,) = adapter.value(_pos(WETH_USDC), holder);
        assertApproxEqRel(v2, v1 * 2, 0.02e18, "value scales with LP share");
    }
}
