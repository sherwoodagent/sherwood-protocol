// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {IProtocolConfig} from "../src/interfaces/IProtocolConfig.sol";

contract ProtocolConfigTest is Test {
    ProtocolConfig cfg;
    address owner = address(0xA11CE);
    address recipient = address(0xBEEF);

    function setUp() public {
        cfg = new ProtocolConfig(owner);
    }

    function test_defaultsAreZero() public view {
        assertEq(cfg.protocolFeeRecipient(), address(0));
        assertEq(cfg.guardiansFeeRecipient(), address(0));
    }

    function test_setProtocolFeeRecipient() public {
        vm.startPrank(owner);
        cfg.setProtocolFeeRecipient(recipient);
        vm.stopPrank();
        assertEq(cfg.protocolFeeRecipient(), recipient);
    }

    // The rate bound and the "recipient first" coupling both went away with
    // `protocolFeeBps` itself — the protocol's share is `mgmtSplit.protocolBps`
    // / `perfSplit.protocolBps` now, covered by test/fees/ProtocolConfigSplits.

    function test_onlyOwner() public {
        vm.expectRevert();
        cfg.setProtocolFeeRecipient(recipient);
    }

    /// @notice The protocol recipient may be cleared at any time — same reason
    ///         as the guardian one below: no rate remains for it to contradict.
    function test_protocolRecipientCanAlwaysBeCleared() public {
        vm.startPrank(owner);
        cfg.setProtocolFeeRecipient(recipient);
        assertEq(cfg.protocolFeeRecipient(), recipient);
        cfg.setProtocolFeeRecipient(address(0));
        vm.stopPrank();
        assertEq(cfg.protocolFeeRecipient(), address(0));
    }

    /// @notice The guardian recipient may be cleared at any time. There is no
    ///         longer a `guardianFeeBps` for it to be inconsistent with — the
    ///         guardian share comes from the splits — so the old "cannot clear
    ///         while the fee is active" coupling has nothing left to enforce.
    ///         A zero recipient unwires the leg; the governor folds that share
    ///         into the agent's remainder rather than escrowing to address(0).
    function test_guardianRecipientCanAlwaysBeCleared() public {
        vm.startPrank(owner);
        cfg.setGuardiansFeeRecipient(recipient);
        assertEq(cfg.guardiansFeeRecipient(), recipient);
        cfg.setGuardiansFeeRecipient(address(0));
        vm.stopPrank();
        assertEq(cfg.guardiansFeeRecipient(), address(0));
    }

    function test_ownership2Step() public {
        address newOwner = address(0xCAFE);
        vm.prank(owner);
        cfg.transferOwnership(newOwner);
        assertEq(cfg.owner(), owner); // not yet transferred
        vm.prank(newOwner);
        cfg.acceptOwnership();
        assertEq(cfg.owner(), newOwner);
    }
}
