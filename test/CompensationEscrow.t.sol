// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CompensationEscrow} from "src/CompensationEscrow.sol";
import {ICompensationEscrow} from "src/interfaces/ICompensationEscrow.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev Vault stand-in exposing the ERC20Votes reads the escrow apportions
///      against. Mirrors SyndicateVault's auto-delegated behaviour, where
///      `getPastVotes(h, t)` equals that holder's share balance at `t`.
contract MockVotesVault {
    mapping(address => mapping(uint256 => uint256)) public votesAt;
    mapping(uint256 => uint256) public totalAt;

    function setVotes(address holder, uint256 ts, uint256 v) external {
        votesAt[holder][ts] = v;
    }

    function setTotal(uint256 ts, uint256 v) external {
        totalAt[ts] = v;
    }

    function getPastVotes(address holder, uint256 ts) external view returns (uint256) {
        return votesAt[holder][ts];
    }

    function getPastTotalSupply(uint256 ts) external view returns (uint256) {
        return totalAt[ts];
    }
}

contract CompensationEscrowTest is Test {
    CompensationEscrow internal escrow;
    ERC20Mock internal wood;
    MockVotesVault internal vault;

    address internal owner = makeAddr("owner");
    address internal slasher = makeAddr("slasher");
    address internal backstop = makeAddr("backstop");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal snapTs;

    function setUp() public {
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        vault = new MockVotesVault();
        escrow = new CompensationEscrow(owner, address(wood));
        vm.startPrank(owner);
        escrow.setAuthorizedFunder(slasher);
        escrow.setBackstop(backstop);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 30 days);
        snapTs = vm.getBlockTimestamp() - 1 days; // a past block

        // Alice 70%, Bob 30% of a 1,000-share supply at the snapshot.
        vault.setTotal(snapTs, 1_000e18);
        vault.setVotes(alice, snapTs, 700e18);
        vault.setVotes(bob, snapTs, 300e18);

        wood.mint(slasher, 1_000_000e18);
        vm.prank(slasher);
        wood.approve(address(escrow), type(uint256).max);
    }

    function test_openCase_pullsProceedsAndRecords() public {
        vm.prank(slasher);
        uint256 caseId = escrow.openCase(address(vault), snapTs, 10_000e18);

        assertEq(wood.balanceOf(address(escrow)), 10_000e18);
        (address v, uint256 ts, uint256 proceeds, uint256 redeemed,) = escrow.caseOf(caseId);
        assertEq(v, address(vault));
        assertEq(ts, snapTs);
        assertEq(proceeds, 10_000e18);
        assertEq(redeemed, 0);
    }

    function test_openCase_onlyAuthorizedFunder() public {
        vm.expectRevert(ICompensationEscrow.NotAuthorizedFunder.selector);
        escrow.openCase(address(vault), snapTs, 10_000e18);
    }

    function test_openCase_rejectsFutureSnapshot() public {
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.SnapshotNotPast.selector);
        escrow.openCase(address(vault), vm.getBlockTimestamp(), 10_000e18);
    }

    function test_openCase_rejectsZeroProceeds() public {
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.NothingToCompensate.selector);
        escrow.openCase(address(vault), snapTs, 0);
    }

    /// @notice A snapshot with no supply can apportion nothing — reject it at
    ///         open rather than stranding WOOD in a case nobody can redeem.
    function test_openCase_rejectsEmptySnapshotSupply() public {
        uint256 emptyTs = snapTs - 1; // never populated
        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.EmptySnapshot.selector);
        escrow.openCase(address(vault), emptyTs, 10_000e18);
    }
}
