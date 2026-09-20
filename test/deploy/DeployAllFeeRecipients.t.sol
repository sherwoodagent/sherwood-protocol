// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {DeployAllFixture} from "./DeployAll.t.sol";
import {Checkpoint} from "../../script/robinhood-mainnet/DeployAll.s.sol";
import {Posture, Inputs, Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @notice The handoff moves both fee legs with the owner, so a finished ceremony never leaves
///         the guardian budget payable to the deployer EOA (v1 audit F10).
contract DeployAllFeeRecipientsTest is DeployAllFixture {
    function setUp() public {
        _stageCeremony();
    }

    /// @notice A handed-off Mainnet run ends with both legs naming the Safe, and validation
    ///         accepts that end state instead of refusing it.
    function test_handoffPointsBothFeeLegsAtTheSafe() public {
        vm.chainId(MAINNET_CHAIN_ID);
        (Stack memory first,) = _runCeremony(Posture.Mainnet);
        _primeWoodFeed(first.woodUsdFeed);

        (Stack memory s, Checkpoint cp) = _runCeremony(Posture.Mainnet);
        assertTrue(cp == Checkpoint.Complete, "run 2 completes");

        ProtocolConfig config = ProtocolConfig(s.core.protocolConfig);
        assertEq(config.protocolFeeRecipient(), address(safe), "protocol leg pays the Safe");
        assertEq(config.guardiansFeeRecipient(), address(safe), "guardian leg pays the Safe");

        Inputs memory i = _inputs(Posture.Mainnet);
        script.exposed_validateAll(s, i, Checkpoint.Complete);
    }

    /// @notice Fork posture hands off to the deployer itself, so both legs stay where they were
    ///         seeded and the re-point writes nothing — the guard is `!= ownerMultisig`, and a
    ///         `== deployer` spelling would emit two no-op events here instead.
    function test_forkHandoffLeavesBothLegsAtTheDeployerAndWritesNothing() public {
        vm.chainId(FORK_CHAIN_ID);
        (Stack memory first,) = _runCeremony(Posture.Fork);
        assertEq(ProtocolConfig(first.core.protocolConfig).protocolFeeRecipient(), deployer, "protocol leg");
        assertEq(ProtocolConfig(first.core.protocolConfig).guardiansFeeRecipient(), deployer, "guardian leg");

        vm.recordLogs();
        _runCeremony(Posture.Fork);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "a resumed fork run sends no state-changing call");
    }
}
