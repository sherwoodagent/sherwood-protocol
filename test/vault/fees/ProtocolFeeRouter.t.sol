// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProtocolFeeRouter} from "../../../src/ProtocolFeeRouter.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";

/// @dev Re-enters the router from inside its own transfer.
contract ReenteringToken is ERC20 {
    ProtocolFeeRouter internal router;

    constructor() ERC20("Reenter", "RE") {}

    function setRouter(ProtocolFeeRouter r) external {
        router = r;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(router) && address(router) != address(0)) router.distribute(address(this));
    }
}

/// @notice Unit coverage for the protocol-leg fee router (SHE-239).
contract ProtocolFeeRouterTest is Test {
    ProtocolFeeRouter internal router;
    ERC20Mock internal usdg;
    ERC20Mock internal weth;

    address internal safe = makeAddr("safe");
    address internal foundation = makeAddr("foundation");
    address internal grants = makeAddr("grants");
    address internal coverage = makeAddr("coverage");
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        router = new ProtocolFeeRouter(safe);
        usdg = new ERC20Mock("USDG", "USDG", 6);
        weth = new ERC20Mock("WETH", "WETH", 18);
    }

    function _alloc(address t, uint16 bps) internal pure returns (ProtocolFeeRouter.Allocation memory) {
        return ProtocolFeeRouter.Allocation({target: t, bps: bps});
    }

    function _one(address t) internal pure returns (ProtocolFeeRouter.Allocation[] memory a) {
        a = new ProtocolFeeRouter.Allocation[](1);
        a[0] = _alloc(t, 10_000);
    }

    function _three(uint16 a, uint16 b, uint16 c) internal view returns (ProtocolFeeRouter.Allocation[] memory s) {
        s = new ProtocolFeeRouter.Allocation[](3);
        s[0] = _alloc(foundation, a);
        s[1] = _alloc(grants, b);
        s[2] = _alloc(coverage, c);
    }

    /// @dev `n` distinct targets summing to exactly 10_000; the last leg takes the remainder.
    function _legs(uint256 n) internal returns (ProtocolFeeRouter.Allocation[] memory a) {
        a = new ProtocolFeeRouter.Allocation[](n);
        uint256 each = 10_000 / n;
        for (uint256 i; i < n; ++i) {
            uint256 bps = i == n - 1 ? 10_000 - each * (n - 1) : each;
            // forge-lint: disable-next-line(unsafe-typecast)
            a[i] = _alloc(makeAddr(string.concat("leg", vm.toString(i))), uint16(bps));
        }
    }

    function _set(ProtocolFeeRouter.Allocation[] memory a) internal {
        vm.prank(safe);
        router.setAllocations(a);
    }

    // ── Hold mode ──

    /// @notice A fresh router holds: distribute moves nothing and emits Held.
    function test_holdModeDistributeMovesNothing() public {
        usdg.mint(address(router), 1_000e6);
        vm.recordLogs();
        vm.prank(anyone);
        router.distribute(address(usdg));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "Held only, no Distributed");
        assertEq(logs[0].topics[0], ProtocolFeeRouter.Held.selector);
        assertEq(abi.decode(logs[0].data, (uint256)), 1_000e6);
        assertEq(usdg.balanceOf(address(router)), 1_000e6);
        assertEq(router.allocations().length, 0);
    }

    /// @notice Setting an empty array returns a live router to hold mode.
    function test_emptyAllocationsReturnToHoldMode() public {
        _set(_one(foundation));
        _set(new ProtocolFeeRouter.Allocation[](0));
        usdg.mint(address(router), 500e6);
        router.distribute(address(usdg));
        assertEq(usdg.balanceOf(foundation), 0);
        assertEq(usdg.balanceOf(address(router)), 500e6);
    }

    // ── Allocation validation ──

    /// @notice Only the owner sets allocations.
    function test_setAllocationsIsOwnerOnly() public {
        ProtocolFeeRouter.Allocation[] memory a = _one(foundation);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        router.setAllocations(a);
    }

    /// @notice Legs summing to anything but 10_000 revert, both under and over.
    function test_setAllocationsRejectsAWrongSum() public {
        ProtocolFeeRouter.Allocation[] memory under = _three(3333, 3333, 3333);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.InvalidAllocationSum.selector, 9999));
        router.setAllocations(under);

        ProtocolFeeRouter.Allocation[] memory over = _three(3333, 3333, 3335);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.InvalidAllocationSum.selector, 10_001));
        router.setAllocations(over);
    }

    /// @notice A zero target reverts.
    function test_setAllocationsRejectsAZeroTarget() public {
        ProtocolFeeRouter.Allocation[] memory a = _one(address(0));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.InvalidTarget.selector, address(0)));
        router.setAllocations(a);
    }

    /// @notice The router cannot be its own leg: that share would loop back and re-split forever.
    function test_setAllocationsRejectsTheRouterItself() public {
        ProtocolFeeRouter.Allocation[] memory a = _three(4000, 4000, 2000);
        a[1].target = address(router);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.InvalidTarget.selector, address(router)));
        router.setAllocations(a);
    }

    /// @notice A zero-bps leg reverts.
    function test_setAllocationsRejectsAZeroBpsLeg() public {
        ProtocolFeeRouter.Allocation[] memory a = _three(5000, 5000, 0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.ZeroBps.selector, coverage));
        router.setAllocations(a);
    }

    /// @notice The same target twice reverts, even when not adjacent.
    function test_setAllocationsRejectsADuplicateTarget() public {
        ProtocolFeeRouter.Allocation[] memory a = _three(4000, 4000, 2000);
        a[2].target = foundation;
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.DuplicateTarget.selector, foundation));
        router.setAllocations(a);
    }

    /// @notice More than MAX_ALLOCATIONS legs revert.
    function test_setAllocationsRejectsTooManyLegs() public {
        uint256 n = router.MAX_ALLOCATIONS() + 1;
        ProtocolFeeRouter.Allocation[] memory a = new ProtocolFeeRouter.Allocation[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = _alloc(makeAddr(vm.toString(i)), 1);
        }
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.TooManyAllocations.selector, n));
        router.setAllocations(a);
    }

    /// @notice The leg cap is exactly eight: eight legs set, nine revert.
    function test_theLegCapIsExactlyEight() public {
        _set(_legs(8));
        assertEq(router.allocations().length, 8);
        ProtocolFeeRouter.Allocation[] memory nine = _legs(9);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeRouter.TooManyAllocations.selector, 9));
        router.setAllocations(nine);
    }

    /// @notice AllocationsSet carries the legs, the hash is keccak of the encoded legs, and Held names its token.
    function test_eventsCarryTheirArguments() public {
        ProtocolFeeRouter.Allocation[] memory a = _legs(2);
        vm.expectEmit(address(router));
        emit ProtocolFeeRouter.AllocationsSet(a);
        _set(a);
        assertEq(router.allocationsHash(), keccak256(abi.encode(a)));

        _set(new ProtocolFeeRouter.Allocation[](0));
        vm.expectEmit(address(router));
        emit ProtocolFeeRouter.Held(address(usdg), 0);
        router.distribute(address(usdg));
    }

    /// @notice A new set replaces the old one whole rather than appending.
    function test_setAllocationsReplacesThePreviousSet() public {
        _set(_three(5000, 3000, 2000));
        _set(_one(grants));
        ProtocolFeeRouter.Allocation[] memory got = router.allocations();
        assertEq(got.length, 1);
        assertEq(got[0].target, grants);
        assertEq(got[0].bps, 10_000);
    }

    // ── Distribution ──

    /// @notice Anyone can distribute, and each leg gets its bps share with the dust on the last.
    function test_distributeSplitsByBpsWithDustToTheLastLeg() public {
        _set(_three(3333, 3333, 3334));
        usdg.mint(address(router), 101);

        vm.expectEmit(address(router));
        emit ProtocolFeeRouter.Distributed(address(usdg), 101, router.allocationsHash());
        vm.prank(anyone);
        router.distribute(address(usdg));

        assertEq(usdg.balanceOf(foundation), 33);
        assertEq(usdg.balanceOf(grants), 33);
        assertEq(usdg.balanceOf(coverage), 35, "last leg takes 34 + the 1 unit of dust");
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    /// @notice Whatever the split and balance, distribute empties the router and pays out exactly the balance.
    function testFuzz_distributeConservesTheBalance(uint16 a, uint16 b, uint256 balance) public {
        a = uint16(bound(a, 1, 9_998));
        b = uint16(bound(b, 1, 9_999 - a));
        balance = bound(balance, 0, 1e36);
        _set(_three(a, b, uint16(10_000 - a - b)));
        usdg.mint(address(router), balance);

        router.distribute(address(usdg));

        assertEq(usdg.balanceOf(address(router)), 0);
        assertEq(usdg.balanceOf(foundation) + usdg.balanceOf(grants) + usdg.balanceOf(coverage), balance);
        assertEq(usdg.balanceOf(foundation), (balance * a) / 10_000);
        assertEq(usdg.balanceOf(grants), (balance * b) / 10_000);
    }

    /// @notice Distributing one token leaves every other token's balance in place.
    function test_distributeIsPerToken() public {
        _set(_one(foundation));
        usdg.mint(address(router), 10e6);
        weth.mint(address(router), 1e18);

        router.distribute(address(usdg));

        assertEq(usdg.balanceOf(foundation), 10e6);
        assertEq(weth.balanceOf(foundation), 0);
        assertEq(weth.balanceOf(address(router)), 1e18);
    }

    /// @notice distributeMany drains each listed token.
    function test_distributeManyDrainsEachToken() public {
        _set(_one(foundation));
        usdg.mint(address(router), 10e6);
        weth.mint(address(router), 1e18);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdg), address(weth));

        router.distributeMany(tokens);

        assertEq(usdg.balanceOf(foundation), 10e6);
        assertEq(weth.balanceOf(foundation), 1e18);
    }

    /// @notice A zero balance with live allocations is a quiet no-op.
    function test_distributeOfAnEmptyBalanceDoesNothing() public {
        _set(_one(foundation));
        vm.recordLogs();
        router.distribute(address(usdg));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @notice A token that re-enters distribute from its transfer reverts the whole call.
    function test_distributeRejectsReentry() public {
        ReenteringToken bad = new ReenteringToken();
        bad.setRouter(router);
        _set(_three(5000, 3000, 2000));
        bad.mint(address(router), 100);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.distribute(address(bad));
    }

    // ── Rescue and ownership ──

    /// @notice The owner can move any token out, fee assets included.
    function test_rescueMovesAnyTokenForTheOwner() public {
        usdg.mint(address(router), 7e6);
        vm.expectEmit(address(router));
        emit ProtocolFeeRouter.Rescued(address(usdg), foundation, 7e6);
        vm.prank(safe);
        router.rescue(address(usdg), foundation, 7e6);
        assertEq(usdg.balanceOf(foundation), 7e6);
    }

    /// @notice Nobody else can rescue.
    function test_rescueIsOwnerOnly() public {
        usdg.mint(address(router), 7e6);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        router.rescue(address(usdg), anyone, 7e6);
    }

    /// @notice Rescue to the zero address reverts.
    function test_rescueRejectsTheZeroAddress() public {
        usdg.mint(address(router), 7e6);
        vm.prank(safe);
        vm.expectRevert(ProtocolFeeRouter.ZeroAddress.selector);
        router.rescue(address(usdg), address(0), 7e6);
    }

    /// @notice The owner cannot renounce, so a hold-mode balance can never become ownerless.
    function test_renounceOwnershipIsDisabled() public {
        vm.prank(safe);
        vm.expectRevert(ProtocolFeeRouter.RenounceDisabled.selector);
        router.renounceOwnership();
        assertEq(router.owner(), safe);
    }

    /// @notice Ownership moves only when the new owner accepts.
    function test_ownershipIsTwoStep() public {
        vm.prank(safe);
        router.transferOwnership(foundation);
        assertEq(router.owner(), safe, "unaccepted transfer leaves the Safe in charge");
        assertEq(router.pendingOwner(), foundation);

        vm.prank(foundation);
        router.acceptOwnership();
        assertEq(router.owner(), foundation);

        ProtocolFeeRouter.Allocation[] memory a = _one(foundation);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        router.setAllocations(a);
    }
}
