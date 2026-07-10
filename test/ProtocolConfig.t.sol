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
        assertEq(cfg.protocolFeeBps(), 0);
        assertEq(cfg.protocolFeeRecipient(), address(0));
        assertEq(cfg.guardianFeeBps(), 0);
        assertEq(cfg.guardiansFeeRecipient(), address(0));
    }

    function test_setProtocolFeeRecipientThenBps() public {
        vm.startPrank(owner);
        cfg.setProtocolFeeRecipient(recipient);
        cfg.setProtocolFeeBps(100);
        vm.stopPrank();
        assertEq(cfg.protocolFeeBps(), 100);
        assertEq(cfg.protocolFeeRecipient(), recipient);
    }

    function test_protocolFeeBpsRequiresRecipientFirst() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidProtocolFeeRecipient.selector);
        cfg.setProtocolFeeBps(100);
    }

    function test_protocolFeeBpsBound() public {
        vm.startPrank(owner);
        cfg.setProtocolFeeRecipient(recipient);
        vm.expectRevert(IProtocolConfig.InvalidProtocolFeeBps.selector);
        cfg.setProtocolFeeBps(1001);
        vm.stopPrank();
    }

    function test_guardianFeeBpsBound() public {
        vm.startPrank(owner);
        cfg.setGuardiansFeeRecipient(recipient);
        vm.expectRevert(IProtocolConfig.InvalidGuardianFeeBps.selector);
        cfg.setGuardianFeeBps(501);
        vm.stopPrank();
    }

    function test_onlyOwner() public {
        vm.expectRevert();
        cfg.setProtocolFeeRecipient(recipient);
    }

    function test_cannotClearRecipientWhileFeeActive() public {
        vm.startPrank(owner);
        cfg.setProtocolFeeRecipient(recipient);
        cfg.setProtocolFeeBps(100);
        vm.expectRevert(IProtocolConfig.InvalidProtocolFeeRecipient.selector);
        cfg.setProtocolFeeRecipient(address(0));
        cfg.setProtocolFeeBps(0); // zero out fee first
        cfg.setProtocolFeeRecipient(address(0)); // now allowed
        vm.stopPrank();
    }

    function test_cannotClearGuardianRecipientWhileFeeActive() public {
        vm.startPrank(owner);
        cfg.setGuardiansFeeRecipient(recipient);
        cfg.setGuardianFeeBps(100);
        vm.expectRevert(IProtocolConfig.InvalidGuardiansFeeRecipient.selector);
        cfg.setGuardiansFeeRecipient(address(0));
        cfg.setGuardianFeeBps(0);
        cfg.setGuardiansFeeRecipient(address(0)); // now allowed
        vm.stopPrank();
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
