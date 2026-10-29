// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ProtocolFeeRouter} from "../../../src/ProtocolFeeRouter.sol";
import {BlacklistingERC20Mock} from "../../mocks/BlacklistingERC20Mock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Stand-in governor: on `claimUnclaimedFees` it pays the caller a preset escrow (models the real
///      governor's pull, which only ever pays msg.sender).
contract EscrowPayer {
    BlacklistingERC20Mock[] public tokens;
    mapping(address => uint256) public owed;

    constructor(BlacklistingERC20Mock[] memory t) {
        tokens = t;
    }

    function book(address token, uint256 a) external {
        owed[token] += a;
    }

    function claimUnclaimedFees(address, address token) external {
        uint256 a = owed[token];
        owed[token] = 0;
        if (a != 0) BlacklistingERC20Mock(token).mint(msg.sender, a);
    }
}

contract RouterHandler is Test {
    ProtocolFeeRouter public router;
    address public safe;
    BlacklistingERC20Mock[] public tokens;
    EscrowPayer public payer;
    address[] public pool; // candidate targets (router itself included)
    address public rescueTo = address(0xBEEF);

    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostOut; // to targets, excluding self
    mapping(address => uint256) public ghostRescued;
    uint256 public ghostHoldOutflow;
    uint256 public ghostResidualWithoutSelf;
    uint256 public ghostDistributeWithSelf;
    uint256 public calls;

    constructor(ProtocolFeeRouter r, address s, BlacklistingERC20Mock[] memory t, EscrowPayer p) {
        router = r;
        safe = s;
        tokens = t;
        payer = p;
        pool.push(address(0xA1));
        pool.push(address(0xA2));
        pool.push(address(0xA3));
        pool.push(address(0xA4));
        pool.push(address(r));
    }

    function _tok(uint256 s) internal view returns (BlacklistingERC20Mock) {
        return tokens[s % tokens.length];
    }

    function _targetsBal(address token) internal view returns (uint256 sum) {
        for (uint256 i; i < pool.length; ++i) {
            if (pool[i] != address(router)) sum += BlacklistingERC20Mock(token).balanceOf(pool[i]);
        }
    }

    function _hasSelf() internal view returns (bool) {
        ProtocolFeeRouter.Allocation[] memory a = router.allocations();
        for (uint256 i; i < a.length; ++i) {
            if (a[i].target == address(router)) return true;
        }
        return false;
    }

    function donate(uint256 ts, uint256 amt) external {
        calls++;
        BlacklistingERC20Mock t = _tok(ts);
        amt = bound(amt, 0, 1e30);
        t.mint(address(router), amt);
        ghostIn[address(t)] += amt;
    }

    function claimEscrow(uint256 ts, uint256 amt) external {
        calls++;
        BlacklistingERC20Mock t = _tok(ts);
        amt = bound(amt, 0, 1e30);
        payer.book(address(t), amt);
        uint256 b0 = t.balanceOf(address(router));
        router.claimEscrowedFees(address(payer), address(0), address(t));
        assertEq(t.balanceOf(address(router)), b0 + amt, "claim lands in the router");
        ghostIn[address(t)] += amt;
    }

    function _afterOutflowCheck(address token, uint256 rb0, uint256 tb0, bool hold, bool self) internal {
        uint256 rb1 = BlacklistingERC20Mock(token).balanceOf(address(router));
        uint256 tb1 = _targetsBal(token);
        ghostOut[token] += tb1 - tb0;
        if (hold && rb1 < rb0) ghostHoldOutflow += rb0 - rb1;
        if (!hold && !self && rb1 != 0) ghostResidualWithoutSelf++;
        if (!hold && self) ghostDistributeWithSelf++;
        // Per-call conservation: router loss == target gain.
        assertEq(rb0 - rb1, tb1 - tb0, "distribute conserves value");
    }

    function distribute(uint256 ts) external {
        calls++;
        address t = address(_tok(ts));
        bool hold = router.allocations().length == 0;
        bool self = _hasSelf();
        uint256 rb0 = BlacklistingERC20Mock(t).balanceOf(address(router));
        uint256 tb0 = _targetsBal(t);
        router.distribute(t);
        _afterOutflowCheck(t, rb0, tb0, hold, self);
    }

    function distributeMany(uint256 seed) external {
        calls++;
        bool hold = router.allocations().length == 0;
        bool self = _hasSelf();
        uint256 n = tokens.length;
        address[] memory ts = new address[](n);
        uint256[] memory rb0 = new uint256[](n);
        uint256[] memory tb0 = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ts[i] = address(tokens[(seed % n + i) % n]);
            rb0[i] = BlacklistingERC20Mock(ts[i]).balanceOf(address(router));
            tb0[i] = _targetsBal(ts[i]);
        }
        router.distributeMany(ts);
        for (uint256 i; i < n; ++i) {
            _afterOutflowCheck(ts[i], rb0[i], tb0[i], hold, self);
        }
    }

    function setAllocations(uint256 seed) external {
        calls++;
        uint256 n = seed % 5; // 0..4 legs; 0 = hold
        ProtocolFeeRouter.Allocation[] memory a = new ProtocolFeeRouter.Allocation[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; ++i) {
            uint256 bps = i == n - 1 ? left : bound(uint256(keccak256(abi.encode(seed, i))), 1, left - (n - 1 - i));
            left -= bps;
            a[i] = ProtocolFeeRouter.Allocation({target: pool[(seed / 7 + i) % pool.length], bps: uint16(bps)});
        }
        vm.prank(safe);
        router.setAllocations(a);
    }

    function rescue(uint256 ts, uint256 amt) external {
        calls++;
        BlacklistingERC20Mock t = _tok(ts);
        uint256 bal = t.balanceOf(address(router));
        amt = bound(amt, 0, bal);
        vm.prank(safe);
        router.rescue(address(t), rescueTo, amt);
        ghostRescued[address(t)] += amt;
    }

    function strangerSetAllocations(address who) external {
        calls++;
        vm.assume(who != safe);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        router.setAllocations(new ProtocolFeeRouter.Allocation[](0));
    }

    function strangerRescue(address who, uint256 ts) external {
        calls++;
        vm.assume(who != safe);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        router.rescue(address(_tok(ts)), who, 1);
    }

    function nTokens() external view returns (uint256) {
        return tokens.length;
    }
}

contract RouterInvariantTest is Test {
    ProtocolFeeRouter router;
    RouterHandler handler;
    BlacklistingERC20Mock[] tokens;
    address safe = makeAddr("safe");

    function setUp() public {
        router = new ProtocolFeeRouter(safe);
        tokens.push(new BlacklistingERC20Mock("A", "A", 6));
        tokens.push(new BlacklistingERC20Mock("B", "B", 18));
        EscrowPayer payer = new EscrowPayer(tokens);
        handler = new RouterHandler(router, safe, tokens, payer);
        targetContract(address(handler));
    }

    /// @notice Conservation: balance == in - out(to targets) - rescued, per token.
    function invariant_balanceConservation() public view {
        for (uint256 i; i < tokens.length; ++i) {
            address t = address(tokens[i]);
            assertEq(
                tokens[i].balanceOf(address(router)),
                handler.ghostIn(t) - handler.ghostOut(t) - handler.ghostRescued(t),
                "router balance conservation"
            );
        }
    }

    /// @notice Hold mode: nothing leaves except through owner rescue.
    function invariant_holdModeNoOutflow() public view {
        assertEq(handler.ghostHoldOutflow(), 0);
    }

    /// @notice Allocation mode without a self-leg: distribute leaves zero dust in the router.
    function invariant_distributeLeavesNothingWithoutSelfLeg() public view {
        assertEq(handler.ghostResidualWithoutSelf(), 0);
    }

    /// @notice Stored allocations are always empty or a valid <=8-leg, 10_000-bps, dup-free set.
    function invariant_allocationsWellFormed() public view {
        ProtocolFeeRouter.Allocation[] memory a = router.allocations();
        assertLe(a.length, 8);
        if (a.length == 0) return;
        uint256 sum;
        for (uint256 i; i < a.length; ++i) {
            assertTrue(a[i].target != address(0));
            assertGt(a[i].bps, 0);
            for (uint256 j; j < i; ++j) {
                assertTrue(a[i].target != a[j].target);
            }
            sum += a[i].bps;
        }
        assertEq(sum, 10_000);
    }

    function invariant_ownerFixed() public view {
        assertEq(router.owner(), safe);
    }

    /// @notice Fuzz: any valid split, any balance: legs get floor(bal*bps/1e4) except the last
    ///         which gets the remainder; sum exact.
    function testFuzz_splitExact(uint256 bal, uint256 seed, uint8 nRaw) public {
        uint256 n = bound(nRaw, 1, 8);
        bal = bound(bal, 0, type(uint256).max / 10_000);
        ProtocolFeeRouter.Allocation[] memory a = new ProtocolFeeRouter.Allocation[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; ++i) {
            uint256 bps = i == n - 1 ? left : bound(uint256(keccak256(abi.encode(seed, i))), 1, left - (n - 1 - i));
            left -= bps;
            a[i] = ProtocolFeeRouter.Allocation({target: address(uint160(0x1000 + i)), bps: uint16(bps)});
        }
        vm.prank(safe);
        router.setAllocations(a);
        tokens[0].mint(address(router), bal);
        router.distribute(address(tokens[0]));
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 got = tokens[0].balanceOf(a[i].target);
            if (i < n - 1) assertEq(got, bal * a[i].bps / 10_000);
            sum += got;
        }
        assertEq(sum, bal);
        assertEq(tokens[0].balanceOf(address(router)), 0);
    }
}
