// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {IPriceAdapter, Position} from "../../src/interfaces/IPriceRouter.sol";

/// @notice Adapter stub with configurable return + revert mode.
contract MockPriceAdapter is IPriceAdapter {
    uint256 internal _v;
    bool internal _ok;
    bool internal _revert;

    function set(uint256 v, bool ok) external {
        _v = v;
        _ok = ok;
    }

    function setRevert(bool r) external {
        _revert = r;
    }

    function value(Position calldata, address) external view returns (uint256, bool) {
        require(!_revert, "adapter boom");
        return (_v, _ok);
    }
}

/// @notice Mock strategy exposing a configurable `positions()` for valueStrategy.
contract MockPositionStrategy {
    Position[] internal _ps;
    bool internal _revert;

    function setPosition(bytes32 kind, address venue) external {
        delete _ps;
        _ps.push(Position({venue: venue, kind: kind, ref: ""}));
    }

    function setRevert(bool r) external {
        _revert = r;
    }

    function positions() external view returns (Position[] memory) {
        require(!_revert, "boom");
        return _ps;
    }
}

contract PriceRouterTest is Test {
    PriceRouter router;
    MockPriceAdapter adapter;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");
    bytes32 constant KIND = keccak256("MOCK_KIND");

    function setUp() public {
        PriceRouter impl = new PriceRouter();
        router = PriceRouter(address(new ERC1967Proxy(address(impl), abi.encodeCall(PriceRouter.initialize, (owner)))));
        adapter = new MockPriceAdapter();
        vm.prank(owner);
        router.registerAdapter(KIND, address(adapter));
    }

    function _pos() internal pure returns (Position memory) {
        return Position({venue: address(0xBEEF), kind: KIND, ref: ""});
    }

    // ── valuePosition ──

    function test_valuePosition_appliesHaircut() public {
        adapter.set(1000, true);
        vm.prank(owner);
        router.setHaircutBps(KIND, 100); // 1%
        (uint256 v, bool ok) = router.valuePosition(_pos(), address(this));
        assertEq(v, 990, "1% haircut applied");
        assertTrue(ok);
    }

    function test_valuePosition_noHaircut_passThrough() public {
        adapter.set(1000, true);
        (uint256 v, bool ok) = router.valuePosition(_pos(), address(this));
        assertEq(v, 1000);
        assertTrue(ok);
    }

    function test_valuePosition_unknownKind_returnsZeroFalse() public view {
        Position memory q = Position({venue: address(0xBEEF), kind: keccak256("UNKNOWN"), ref: ""});
        (uint256 v, bool ok) = router.valuePosition(q, address(this));
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_valuePosition_adapterNotOk_zeroesValue() public {
        adapter.set(1000, false); // adapter says not safely priceable
        (uint256 v, bool ok) = router.valuePosition(_pos(), address(this));
        assertEq(v, 0, "G2 Option A: value zeroed when not instantOK");
        assertFalse(ok);
    }

    function test_valuePosition_overCap_returnsZeroFalse() public {
        adapter.set(1000, true);
        vm.prank(owner);
        router.setInstantCap(KIND, 500);
        (uint256 v, bool ok) = router.valuePosition(_pos(), address(this));
        assertEq(v, 0, "over instant cap -> Lane B");
        assertFalse(ok);
    }

    function test_valuePosition_atCap_isInstantEligible() public {
        adapter.set(500, true);
        vm.prank(owner);
        router.setInstantCap(KIND, 500);
        (uint256 v, bool ok) = router.valuePosition(_pos(), address(this));
        assertEq(v, 500);
        assertTrue(ok);
    }

    function test_valuePosition_capZeroIsUnlimited() public {
        adapter.set(1e30, true);
        (uint256 v, bool ok) = router.valuePosition(_pos(), address(this));
        assertEq(v, 1e30);
        assertTrue(ok);
    }

    function test_valuePosition_adapterReverts_returnsZeroFalse() public {
        adapter.set(1000, true);
        adapter.setRevert(true);
        (uint256 v, bool ok) = router.valuePosition(_pos(), address(this));
        assertEq(v, 0, "fail-closed on adapter revert");
        assertFalse(ok);
    }

    // ── governance ──

    function test_setHaircut_monotoneIncreaseOnly() public {
        vm.startPrank(owner);
        router.setHaircutBps(KIND, 100);
        router.setHaircutBps(KIND, 200); // increase ok
        router.setHaircutBps(KIND, 200); // equal ok
        vm.expectRevert(PriceRouter.HaircutCannotDecrease.selector);
        router.setHaircutBps(KIND, 150); // decrease reverts
        vm.stopPrank();
    }

    function test_setHaircut_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(PriceRouter.HaircutTooHigh.selector);
        router.setHaircutBps(KIND, 10_001);
    }

    function test_registerAdapter_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(PriceRouter.ZeroAddress.selector);
        router.registerAdapter(KIND, address(0));
    }

    function test_registerAdapter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        router.registerAdapter(KIND, address(adapter));
    }

    function test_setHaircut_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        router.setHaircutBps(KIND, 100);
    }

    function test_setInstantCap_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        router.setInstantCap(KIND, 100);
    }

    function test_registerAdapter_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit PriceRouter.AdapterRegistered(KIND, address(adapter));
        vm.prank(owner);
        router.registerAdapter(KIND, address(adapter));
    }

    // ── init ──

    function test_initialize_setsOwner() public view {
        assertEq(router.owner(), owner);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        router.initialize(stranger);
    }

    // ── valueStrategy / Lane A eligibility ──

    function _strategyWith(bytes32 kind) internal returns (MockPositionStrategy s) {
        s = new MockPositionStrategy();
        s.setPosition(kind, address(0xBEEF));
    }

    function test_valueStrategy_disabledKind_returnsZeroFalse() public {
        adapter.set(1000, true); // priceable, but Lane A not enabled for the kind
        MockPositionStrategy s = _strategyWith(KIND);
        (uint256 v, bool ok) = router.valueStrategy(address(s));
        assertEq(v, 0);
        assertFalse(ok, "kind not Lane-A-enabled");
    }

    function test_valueStrategy_enabled_prices() public {
        adapter.set(1000, true);
        vm.prank(owner);
        router.setLaneAEnabled(KIND, true);
        MockPositionStrategy s = _strategyWith(KIND);
        (uint256 v, bool ok) = router.valueStrategy(address(s));
        assertEq(v, 1000);
        assertTrue(ok);
    }

    function test_valueStrategy_zeroValueAllPositions_returnsZeroFalse() public {
        adapter.set(0, true); // priceable but zero value (e.g. an unreported-venue omission)
        vm.prank(owner);
        router.setLaneAEnabled(KIND, true);
        MockPositionStrategy s = _strategyWith(KIND);
        (uint256 v, bool ok) = router.valueStrategy(address(s));
        assertEq(v, 0);
        assertFalse(ok, "G3: instant availability requires actually-priced value");
    }

    function test_valueStrategy_notOkPosition_returnsZeroFalse() public {
        adapter.set(1000, false); // adapter says not priceable
        vm.prank(owner);
        router.setLaneAEnabled(KIND, true);
        MockPositionStrategy s = _strategyWith(KIND);
        (uint256 v, bool ok) = router.valueStrategy(address(s));
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_valueStrategy_emptyPositions_returnsZeroFalse() public {
        MockPositionStrategy s = new MockPositionStrategy();
        (uint256 v, bool ok) = router.valueStrategy(address(s));
        assertEq(v, 0);
        assertFalse(ok, "no positions -> Lane B");
    }

    function test_valueStrategy_zeroStrategy_returnsZeroFalse() public view {
        (uint256 v, bool ok) = router.valueStrategy(address(0));
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_valueStrategy_positionsReverts_returnsZeroFalse() public {
        vm.prank(owner);
        router.setLaneAEnabled(KIND, true);
        MockPositionStrategy s = _strategyWith(KIND);
        s.setRevert(true);
        (uint256 v, bool ok) = router.valueStrategy(address(s));
        assertEq(v, 0);
        assertFalse(ok, "fail-closed on positions() revert");
    }

    function test_setLaneAEnabled_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        router.setLaneAEnabled(KIND, true);
    }
}
