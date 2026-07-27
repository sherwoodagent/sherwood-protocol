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

    // ── ADR 2026-07-27: maxEnvelopeTier ──

    /// @notice Unset means NO ceiling, and the sentinel is deliberately NOT 0 —
    ///         0 is a valid, meaningful ceiling here ("tier-0 adapters only").
    ///         Contrast `maxStrategyDuration`, whose 0 DOES mean unset.
    function test_maxEnvelopeTierDefaultsToSentinelNotZero() public view {
        assertEq(cfg.maxEnvelopeTier(), cfg.NO_ENVELOPE_TIER_CEILING());
        assertEq(cfg.NO_ENVELOPE_TIER_CEILING(), type(uint8).max);
        assertTrue(cfg.NO_ENVELOPE_TIER_CEILING() > cfg.MAX_VALID_ENVELOPE_TIER());
        assertEq(cfg.maxStrategyDuration(), 0); // the sibling's 0-means-unset, for contrast
    }

    /// @notice Every valid tier is settable — including 0, the strictest
    ///         setting, which a 0-means-unset convention would silently lose.
    function test_setMaxEnvelopeTierAcceptsEveryValidTierAndTheSentinel() public {
        vm.startPrank(owner);
        for (uint8 t = 0; t <= 2; t++) {
            cfg.setMaxEnvelopeTier(t);
            assertEq(cfg.maxEnvelopeTier(), t);
        }
        cfg.setMaxEnvelopeTier(type(uint8).max);
        assertEq(cfg.maxEnvelopeTier(), type(uint8).max);
        vm.stopPrank();
    }

    /// @notice Anything that is neither a valid tier nor the sentinel is
    ///         refused, so a typo cannot land a ceiling with no meaning.
    function testFuzz_setMaxEnvelopeTierRejectsInvalidValues(uint8 bad) public {
        vm.assume(bad > 2 && bad != type(uint8).max);
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidMaxEnvelopeTier.selector);
        cfg.setMaxEnvelopeTier(bad);
    }

    function test_setMaxEnvelopeTierIsOwnerOnly() public {
        vm.expectRevert();
        cfg.setMaxEnvelopeTier(1);
        assertEq(cfg.maxEnvelopeTier(), cfg.NO_ENVELOPE_TIER_CEILING()); // unchanged
    }

    function test_setMaxEnvelopeTierEmitsParameterChangeFinalized() public {
        vm.expectEmit(true, false, false, true, address(cfg));
        emit IProtocolConfig.ParameterChangeFinalized(
            keccak256("maxEnvelopeTier"), uint256(type(uint8).max), uint256(1)
        );
        vm.prank(owner);
        cfg.setMaxEnvelopeTier(1);
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
