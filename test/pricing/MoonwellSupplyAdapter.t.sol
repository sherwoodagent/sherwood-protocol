// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MoonwellSupplyAdapter} from "../../src/pricing/adapters/MoonwellSupplyAdapter.sol";
import {Position} from "../../src/interfaces/IPriceRouter.sol";

/// @notice Mock Moonwell Comptroller exposing the `markets(address)` getter
///         shape (isListed, collateralFactor, isComped).
contract MockMarketComptroller {
    mapping(address => bool) public listed;
    bool internal _revert;

    function setListed(address m, bool v) external {
        listed[m] = v;
    }

    function setRevert(bool r) external {
        _revert = r;
    }

    function markets(address m) external view returns (bool, uint256, bool) {
        require(!_revert, "comptroller boom");
        return (listed[m], 0.8e18, true);
    }
}

/// @notice Mock cToken: `balanceOf(address)` + `exchangeRateStored()` getters.
contract MockMTokenForAdapter {
    mapping(address => uint256) public balanceOf;
    uint256 public exchangeRateStored;

    function setBalance(address h, uint256 b) external {
        balanceOf[h] = b;
    }

    function setRate(uint256 r) external {
        exchangeRateStored = r;
    }
}

contract MoonwellSupplyAdapterTest is Test {
    MoonwellSupplyAdapter adapter;
    MockMarketComptroller comptroller;
    MockMTokenForAdapter mToken;

    address holder = makeAddr("holder");

    function setUp() public {
        comptroller = new MockMarketComptroller();
        adapter = new MoonwellSupplyAdapter(address(comptroller));
        mToken = new MockMTokenForAdapter();
        comptroller.setListed(address(mToken), true);
        mToken.setRate(2e14);
        mToken.setBalance(holder, 1_000e8); // 1000 mTokens at 8 decimals
    }

    function _pos() internal view returns (Position memory) {
        return Position({venue: address(mToken), kind: adapter.KIND(), ref: ""});
    }

    function test_constructor_zeroComptrollerReverts() public {
        vm.expectRevert(MoonwellSupplyAdapter.ZeroAddress.selector);
        new MoonwellSupplyAdapter(address(0));
    }

    function test_kind_isMoonwellSupply() public view {
        assertEq(adapter.KIND(), keccak256("MOONWELL_SUPPLY"));
    }

    function test_value_returnsBalanceTimesRate() public view {
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, (1_000e8 * 2e14) / 1e18, "value = cBal * rate / 1e18");
        assertTrue(ok);
    }

    function test_value_unlistedVenue_returnsZeroFalse() public {
        comptroller.setListed(address(mToken), false);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0, "unknown venue not priced");
        assertFalse(ok);
    }

    function test_value_foreignVenue_returnsZeroFalse() public view {
        // A venue the comptroller has never listed (a fake mToken address)
        Position memory p = Position({venue: address(0xDEAD), kind: adapter.KIND(), ref: ""});
        (uint256 v, bool ok) = adapter.value(p, holder);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_value_zeroBalance_returnsZeroTrue() public {
        mToken.setBalance(holder, 0);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0);
        assertTrue(ok, "a zero position is validly worth 0");
    }

    function test_value_comptrollerReverts_returnsZeroFalse() public {
        comptroller.setRevert(true);
        (uint256 v, bool ok) = adapter.value(_pos(), holder);
        assertEq(v, 0, "fail-closed when market registry read reverts");
        assertFalse(ok);
    }
}
