// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProposerBondEscrow} from "src/ProposerBondEscrow.sol";
import {IProposerBondEscrow} from "src/interfaces/IProposerBondEscrow.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockRegistryAuth {
    mapping(address => bool) public isAuthorizedGovernor;

    function set(address gov, bool ok) external {
        isAuthorizedGovernor[gov] = ok;
    }
}

contract ProposerBondEscrowTest is Test {
    ProposerBondEscrow internal escrow;
    ERC20Mock internal wood;
    MockRegistryAuth internal reg;
    address internal governor = makeAddr("governor");
    address internal proposer = makeAddr("proposer");

    function setUp() public {
        wood = new ERC20Mock();
        reg = new MockRegistryAuth();
        reg.set(governor, true);
        escrow = new ProposerBondEscrow(address(wood), address(reg));
        wood.mint(proposer, 1_000e18);
        vm.prank(proposer);
        wood.approve(address(escrow), type(uint256).max);
    }

    function test_lockBond_pullsWoodAndRecords() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        assertEq(wood.balanceOf(address(escrow)), 100e18);
        (address p, uint256 amt) = escrow.bondOf(governor, 1);
        assertEq(p, proposer);
        assertEq(amt, 100e18);
    }

    function test_lockBond_unauthorizedGovernorReverts() public {
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedGovernor.selector);
        escrow.lockBond(1, proposer, 100e18);
    }

    function test_lockBond_duplicateReverts() public {
        vm.startPrank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.expectRevert(IProposerBondEscrow.BondAlreadyLocked.selector);
        escrow.lockBond(1, proposer, 100e18);
        vm.stopPrank();
    }

    function test_lockBond_amountOverUint96Reverts() public {
        // Guard fires BEFORE safeTransferFrom, so no mint/approve of 2^96 WOOD
        // is needed and no funds move.
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.AmountTooLarge.selector);
        escrow.lockBond(1, proposer, uint256(type(uint96).max) + 1);
        assertEq(wood.balanceOf(address(escrow)), 0);
        (address p,) = escrow.bondOf(governor, 1);
        assertEq(p, address(0));
    }

    function test_releaseBond_returnsToProposer() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    function test_releaseBond_keyBoundToLockerAndOnce() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        // releaseBond has no live auth check: a non-locker caller's key is
        // key(caller, 1), which holds no bond — NoBond, not an auth error.
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
        vm.prank(governor);
        escrow.releaseBond(1);
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
    }

    function test_releaseBond_crossGovernorIsolation() public {
        address governorB = makeAddr("governorB");
        reg.set(governorB, true);
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(governorB);
        escrow.lockBond(1, proposer, 200e18);
        // A's release touches only A's bond; B's stays locked.
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(address(escrow)), 200e18);
        (address pA,) = escrow.bondOf(governor, 1);
        assertEq(pA, address(0));
        (address pB, uint256 amtB) = escrow.bondOf(governorB, 1);
        assertEq(pB, proposer);
        assertEq(amtB, 200e18);
        // An unauthorized address hits NoBond (its own empty key), not an
        // auth error — and cannot touch B's bond.
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(IProposerBondEscrow.ZeroAddress.selector);
        new ProposerBondEscrow(address(0), address(reg));
        vm.expectRevert(IProposerBondEscrow.ZeroAddress.selector);
        new ProposerBondEscrow(address(wood), address(0));
    }

    function test_lockBond_zeroProposerReverts() public {
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.ZeroAddress.selector);
        escrow.lockBond(1, address(0), 100e18);
    }

    /// Pins intended semantics: a zero-amount bond is accepted and releasable.
    function test_lockBond_zeroAmountAcceptedAndReleasable() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 0);
        (address p, uint256 amt) = escrow.bondOf(governor, 1);
        assertEq(p, proposer);
        assertEq(amt, 0);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        (address pAfter,) = escrow.bondOf(governor, 1);
        assertEq(pAfter, address(0));
    }

    /// A governor deauthorized AFTER locking can still release its open
    /// bonds — funds are never stranded by registry deauthorization.
    function test_releaseBond_afterGovernorDeauthorized() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        reg.set(governor, false);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    /// Fuzz the conservation invariant: balance == sum of locked-unreleased.
    function testFuzz_balanceMatchesOpenBonds(uint96 a1, uint96 a2, bool release1) public {
        uint256 b1 = uint256(a1) % 500e18 + 1;
        uint256 b2 = uint256(a2) % 500e18 + 1;
        vm.startPrank(governor);
        escrow.lockBond(1, proposer, b1);
        escrow.lockBond(2, proposer, b2);
        if (release1) escrow.releaseBond(1);
        vm.stopPrank();
        uint256 expected = release1 ? b2 : b1 + b2;
        assertEq(wood.balanceOf(address(escrow)), expected);
    }
}
