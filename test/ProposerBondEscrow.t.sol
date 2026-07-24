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

    function test_releaseBond_returnsToProposer() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    function test_releaseBond_governorOnlyAndOnce() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedGovernor.selector);
        escrow.releaseBond(1);
        vm.prank(governor);
        escrow.releaseBond(1);
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
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
