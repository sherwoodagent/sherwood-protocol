// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HyperliquidPerpAdapter} from "../../src/pricing/adapters/HyperliquidPerpAdapter.sol";
import {Position} from "../../src/interfaces/IPriceRouter.sol";
import {MockAccountMarginSummaryPrecompile} from "../mocks/MockAccountMarginSummaryPrecompile.sol";

contract HyperliquidPerpAdapterTest is Test {
    HyperliquidPerpAdapter adapter;
    address constant PRECOMPILE = 0x000000000000000000000000000000000000080F;
    address holder = makeAddr("holder");

    function setUp() public {
        adapter = new HyperliquidPerpAdapter();
        MockAccountMarginSummaryPrecompile mock = new MockAccountMarginSummaryPrecompile();
        vm.etch(PRECOMPILE, address(mock).code);
    }

    function _pos() internal view returns (Position memory) {
        return Position({venue: PRECOMPILE, kind: adapter.KIND(), ref: abi.encode(uint32(0))});
    }

    function _setEquity(int64 eq) internal {
        MockAccountMarginSummaryPrecompile(PRECOMPILE).setSummary(eq, 0, 0, 0);
    }

    function test_kind_isHlPerp() public view {
        assertEq(adapter.KIND(), keccak256("HL_PERP"));
    }

    function test_value_returnsAccountEquity() public {
        _setEquity(50_000e6);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 50_000e6, "equity = accountValue (6dp USD)");
        assertTrue(ok);
    }

    function test_value_zeroEquity_returnsZeroTrue() public {
        _setEquity(0);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0);
        assertTrue(ok, "flat account validly worth 0");
    }

    function test_value_negativeEquity_returnsZeroTrue() public {
        _setEquity(-100); // liquidated / underwater
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0, "non-positive equity prices to 0");
        assertTrue(ok);
    }

    function test_value_noPrecompile_returnsZeroFalse() public {
        // No precompile (e.g. on Base) → staticcall returns empty → fail-closed.
        vm.etch(PRECOMPILE, hex"");
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0);
        assertFalse(ok, "fail-closed without the HyperCore precompile");
    }
}
