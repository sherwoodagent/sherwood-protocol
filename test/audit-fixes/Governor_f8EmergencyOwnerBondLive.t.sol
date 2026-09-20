// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {GovernorEmergencyTest} from "../governor/GovernorEmergency.t.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @title Governor_f8EmergencyOwnerBondLive
/// @notice v1 audit F8: both emergency gates also read `ownerBondLive`, the
///         predicate SHE-215 put on propose/execute, on top of the amount gates
///         they already had. Inherits the real-registry emergency fixture, so its
///         live-bond and zero-bond controls re-run here.
contract GovernorF8EmergencyOwnerBondLiveTest is GovernorEmergencyTest {
    using stdStorage for StdStorage;

    /// @notice Stamps `_ownerStakes[v].unstakeRequestedAt` directly: production
    ///         ordering makes `requestUnstakeOwner` unreachable while a proposal
    ///         is Executed, and this pins the gate, not that ordering.
    function _stampOwnerExit(address v) internal {
        uint256 slot = stdstore.target(address(swood)).sig("ownerStake(address)").with_key(v).find();
        bytes32 packed = vm.load(address(swood), bytes32(slot));
        // `unstakeRequestedAt` is the uint64 at byte offset 16 of the same slot.
        vm.store(address(swood), bytes32(slot), bytes32(uint256(packed) | (vm.getBlockTimestamp() << 128)));
    }

    /// @notice The open leg refuses an owner whose exit is already in flight,
    ///         even though the posted amount still clears `requiredOwnerBond`.
    function test_F8_emergencySettleWithCalls_refusesAnExitingOwnerBond() public {
        uint256 pid = _createExecutedProposal(7 days);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        _stampOwnerExit(address(vault));
        assertFalse(registry.ownerBondLive(address(vault)), "the bond is exiting");
        assertGe(
            registry.ownerStake(address(vault)),
            registry.requiredOwnerBond(address(vault)),
            "and the amount gates alone would have let it through"
        );

        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.OwnerBondInsufficient.selector);
        governor.emergencySettleWithCalls(pid, _customCalls());
    }

    /// @notice The execute leg is the one that runs owner-authored calls with an
    ///         egress budget: an exit opened during the review stops it.
    function test_F8_finalizeEmergencySettle_refusesAnExitingOwnerBond() public {
        uint256 pid = _createExecutedProposal(7 days);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, _customCalls());
        vm.warp(vm.getBlockTimestamp() + registry.reviewPeriod());

        _stampOwnerExit(address(vault));
        assertFalse(registry.ownerBondLive(address(vault)), "the bond is exiting");
        assertGt(registry.ownerStake(address(vault)), 0, "and the amount gate alone would have let it through");

        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.OwnerBondInsufficient.selector);
        governor.finalizeEmergencySettle(pid);
    }
}
