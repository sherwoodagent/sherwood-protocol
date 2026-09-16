// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeploySherwood} from "../../script/Deploy.s.sol";
import {Posture, Inputs, Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {DeployAllFixture} from "../deploy/DeployAll.t.sol";

/// @notice `DeploySherwood` is an abstract mixin; this makes it concrete.
contract DeploySherwoodHarness is DeploySherwood {}

/// @title Deploy_multisigHandoff — MS-H5 regression
///
/// @notice The handoff moved out of `Deploy.s.sol` into `DeployAll._handoffAll`, and the
///         `OWNER_MULTISIG` preconditions moved out of env into the committed address book.
///         The MS-H5 scenarios are restated against those entry points here.
contract DeployMultisigHandoffTest is DeployAllFixture {
    /// @dev A Fork book carrying `OWNER_MULTISIG`, staged for the posture refusal. Gitignored.
    uint256 internal constant STAGED_FORK_CHAIN_ID = 424_242;

    function setUp() public {
        _stageCeremony();
    }

    /// @notice The management-fee pre-flight refuses a value the factory would reject anyway,
    ///         before anything is broadcast.
    function test_run_rejectsManagementFeeAboveTheFactoryCap() public {
        DeploySherwoodHarness s = new DeploySherwoodHarness();
        vm.expectRevert(bytes("PRE-FLIGHT: MANAGEMENT_FEE above MAX_MANAGEMENT_FEE_BPS (300)"));
        s.requireManagementFeeUnderCap(301);
        // Exactly at the cap is not over it.
        s.requireManagementFeeUnderCap(300);
    }

    /// @notice MS-H5 (C-1): the handoff moves all five one-step owners, arms the five two-step
    ///         ones and locks the deployer out.
    function test_handoffTransfersAllProxies() public {
        vm.chainId(FORK_CHAIN_ID);
        (Stack memory s,) = _runCeremony(Posture.Fork);
        _assertOneStepOwners(s, deployer);

        script.exposed_handoffAll(s, address(safe));

        _assertOneStepOwners(s, address(safe));
        // A two-step transfer never moves `owner()`; the Safe must accept.
        assertEq(Ownable(s.core.protocolConfig).owner(), deployer, "protocolConfig.owner unmoved");
        assertEq(Ownable(s.core.tierRegistry).owner(), deployer, "tierRegistry.owner unmoved");
        assertEq(Ownable(s.exposureLedger).owner(), deployer, "ledger.owner unmoved");
        _assertTwoStepPending(s, address(safe));

        // The deployer key is out of the one-step half immediately.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        Ownable(s.core.factoryProxy).transferOwnership(deployer);

        safe.accept(s.core.tierRegistry);
        assertEq(Ownable(s.core.tierRegistry).owner(), address(safe), "tierRegistry accepted");
    }

    /// @notice MS-H5: an `OWNER_MULTISIG` that is not a live contract is refused before any
    ///         deploy — an EOA key, or a Safe that was never deployed on this chain.
    function test_run_rejectsBadOwnerMultisig() public {
        vm.chainId(MAINNET_CHAIN_ID);
        Inputs memory i = _inputs(Posture.Mainnet);
        // The Safe the committed book names, on a chain where it was never deployed.
        i.ownerMultisig = _bookAddr("OWNER_MULTISIG");
        assertEq(i.ownerMultisig.code.length, 0, "no Safe at that address in this EVM");

        vm.expectRevert(bytes("OWNER_MULTISIG must be a contract (Safe), not an EOA"));
        script.exposed_preflight(i);

        // Non-vacuity: the SAME inputs clear the pre-flight once the Safe holds code.
        vm.etch(i.ownerMultisig, address(safe).code);
        script.exposed_preflight(i);
    }

    /// @notice Skipping the handoff is a POSTURE, never a flag, so a Fork book that carries
    ///         an `OWNER_MULTISIG` is refused rather than quietly handing off.
    function test_run_rejectsAForkBookCarryingAnOwnerMultisig() public {
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(STAGED_FORK_CHAIN_ID), ".json");
        vm.writeFile(
            path,
            string.concat(
                '{"DEPLOYER":"',
                vm.toString(deployer),
                '","OWNER_MULTISIG":"',
                vm.toString(address(safe)),
                '","chainId":',
                vm.toString(STAGED_FORK_CHAIN_ID),
                "}"
            )
        );

        vm.chainId(STAGED_FORK_CHAIN_ID);
        vm.prank(deployer);
        try script.run() {
            vm.removeFile(path);
            revert("a Fork book carrying OWNER_MULTISIG was accepted");
        } catch Error(string memory reason) {
            vm.removeFile(path);
            assertEq(
                reason, "Fork posture never hands off: remove OWNER_MULTISIG from this chain's address book", reason
            );
        }
    }

    /// @notice Fork posture: with no Safe to hand off to, the deployer stays the owner.
    function test_handoff_skipped_leavesDeployerAsOwner() public {
        vm.chainId(FORK_CHAIN_ID);
        (Stack memory s,) = _runCeremony(Posture.Fork);

        _assertOneStepOwners(s, deployer);
        _assertTwoStepPending(s, address(0));
        assertEq(Ownable(s.core.protocolConfig).owner(), deployer, "protocolConfig.owner");
        assertEq(Ownable(s.core.tierRegistry).owner(), deployer, "tierRegistry.owner");
        assertEq(Ownable(s.exposureLedger).owner(), deployer, "ledger.owner");
        assertEq(Ownable(s.challengeGame).owner(), deployer, "game.owner");
        assertEq(Ownable(s.tokenCourt).owner(), deployer, "court.owner");
    }
}
