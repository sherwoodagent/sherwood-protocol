// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {RegistryTestHarness} from "../helpers/RegistryTestHarness.sol";

/// @notice NM fix review 6.13: the emergency veto electorate and every blocker's
///         weight are read at the proposal's review `snapshotAt`, not at an
///         instant the vault owner picks when opening the emergency review.
contract Registry_emergencyElectorateInstantTest is RegistryTestHarness {
    uint256 internal constant PROPOSAL_ID = 1;
    uint256 internal constant REVIEW_PERIOD = 24 hours;
    uint256 internal constant BLOCK_QUORUM_BPS = 3000; // 30%
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    MockERC4626Vault internal vault;
    address internal creator = address(0xC0FFEE);
    address internal padder = address(0xFADD3D);
    address internal g0 = address(0xAA01);
    address internal g1 = address(0xAA02);
    address internal g2 = address(0xAA03);

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, BLOCK_QUORUM_BPS);

        vault = new MockERC4626Vault();
        vault.setOwner(creator);
        vm.prank(regFactory);
        registry.addGovernor(address(governor), address(vault));

        wood.mint(creator, 10_000e18);
        vm.startPrank(creator);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(10_000e18);
        vm.stopPrank();
        vm.prank(regFactory);
        swood.bindOwnerStake(creator, address(vault));

        // Honest cohort: 30_000e18 total; g0 + g1 = 20_000e18 = 66% of it.
        _stakeGuardian(g0, 10_000e18, 1);
        _stakeGuardian(g1, 10_000e18, 2);
        _stakeGuardian(g2, 10_000e18, 3);
        skip(30 days);

        // Propose: the review snapshot lands here, one second after the cohort's checkpoints.
        uint256 voteEnd = vm.getBlockTimestamp() + 1 days;
        _registerReview(PROPOSAL_ID, voteEnd, voteEnd + REVIEW_PERIOD);

        // The strategy runs; the emergency comes much later.
        skip(20 days);
    }

    function _openEmergency() internal returns (uint64 reviewEnd_) {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](0);
        reviewEnd_ = uint64(vm.getBlockTimestamp() + REVIEW_PERIOD);
        vm.prank(address(governor));
        registry.openEmergency(PROPOSAL_ID, keccak256(abi.encode(calls)), calls);
    }

    function _block(address g) internal {
        vm.prank(g);
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
    }

    function _finalize(uint64 reviewEnd_) internal returns (bool blocked) {
        vm.warp(reviewEnd_);
        vm.prank(address(governor));
        (blocked,) = registry.finalizeEmergency(PROPOSAL_ID);
    }

    /// @notice Owner pads 1_000_000e18 one block before opening; the honest 66% Block still wins and burns the bond.
    function test_ownerPaddingBeforeOpen_doesNotDiluteTheVeto() public {
        _stakeGuardian(padder, 1_000_000e18, 9);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint64 reviewEnd_ = _openEmergency();
        _block(g0);
        _block(g1);

        assertTrue(_finalize(reviewEnd_), "honest 2/3 of the snapshot electorate must block");
        assertEq(swood.ownerStake(address(vault)), 0, "owner bond slashed");
        assertEq(wood.balanceOf(BURN_ADDRESS), 10_000e18, "owner bond burned");
    }

    /// @notice Control: a blocker staked at the snapshot votes at full weight against the snapshot electorate.
    function test_blockersStakedAtSnapshot_countAtFullWeight() public {
        uint64 reviewEnd_ = _openEmergency();
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.EmergencyBlockVoteCast(address(governor), PROPOSAL_ID, g0, 10_000e18);
        _block(g0);
        assertTrue(_finalize(reviewEnd_), "10k of a 30k electorate clears 30%");
    }

    /// @notice Stake added after the snapshot neither votes nor raises the bar.
    function test_stakeAfterSnapshot_cannotVoteNorRaiseTheBar() public {
        address late = address(0x1A7E);
        _stakeGuardian(late, 1_000_000e18, 9);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint64 reviewEnd_ = _openEmergency();

        vm.prank(late);
        vm.expectRevert(IGuardianRegistry.NotActiveGuardian.selector);
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        _block(g0);
        assertTrue(_finalize(reviewEnd_), "late stake must not enter the denominator");
    }
}
