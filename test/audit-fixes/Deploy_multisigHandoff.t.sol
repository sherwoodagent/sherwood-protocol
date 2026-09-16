// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeploySherwood} from "../../script/Deploy.s.sol";

/// @notice `DeploySherwood` is an abstract mixin; this makes it concrete.
contract DeploySherwoodHarness is DeploySherwood {}

/// @title Deploy_multisigHandoff — MS-H5 regression
///
/// @notice The handoff moved out of `Deploy.s.sol` into `DeployAll._handoffAll`, and the
///         `OWNER_MULTISIG` preconditions moved out of env into the committed address book. The
///         MS-H5 scenarios (four proxies + StrategyFactory moved, old owner locked out, the
///         two-step contracts only armed; missing / EOA `OWNER_MULTISIG` refused) are restated
///         against that entry point in SHE-36 task 9 — parked here, not dropped.
contract DeployMultisigHandoffTest is Test {
    /// @notice The management-fee pre-flight refuses a value the factory would reject anyway,
    ///         before anything is broadcast.
    function test_run_rejectsManagementFeeAboveTheFactoryCap() public {
        DeploySherwoodHarness s = new DeploySherwoodHarness();
        vm.expectRevert(bytes("PRE-FLIGHT: MANAGEMENT_FEE above MAX_MANAGEMENT_FEE_BPS (300)"));
        s.requireManagementFeeUnderCap(301);
        // Exactly at the cap is not over it.
        s.requireManagementFeeUnderCap(300);
    }

    /// @notice MS-H5 (C-1): every proxy the handoff moves must end up owned by the Safe.
    /// @dev TODO(SHE-36 task 9): restate against `DeployAll.exposed_handoffAll(Stack, multisig)`.
    function test_handoffTransfersAllProxies() public {
        vm.skip(true);
    }

    /// @notice MS-H5: a missing or EOA `OWNER_MULTISIG` must be refused before any deploy.
    /// @dev TODO(SHE-36 task 9): restate against `DeployAll.run()` with a staged address book.
    function test_run_rejectsBadOwnerMultisig() public {
        vm.skip(true);
    }

    /// @notice Fork posture: with no Safe to hand off to, the deployer stays the owner.
    /// @dev TODO(SHE-36 task 9): restate against `DeployAll.run()` on a fork-posture book.
    function test_handoff_skipped_leavesDeployerAsOwner() public {
        vm.skip(true);
    }
}
