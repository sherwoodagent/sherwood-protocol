// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TierRegistry} from "src/TierRegistry.sol";

contract TierRegistryTest is Test {
    TierRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal target;

    function setUp() public {
        reg = new TierRegistry(owner);
        // separate deployed contract as certification target (etch-safe: never etch the registry under test)
        target = address(new TierRegistry(owner));
    }

    /// @dev Shared fixture helper (design.md / tasks.md 2.1): reaches the same
    ///      end state as the old instant `certify` via the new two-step flow
    ///      — propose as owner, warp past the pinned `readyAt`, execute. Uses
    ///      `vm.getBlockTimestamp()` (never a cached `block.timestamp` local)
    ///      because this repo's optimizer CSEs `block.timestamp` across
    ///      `vm.warp`. Pranks the final `certify` call as `submitter_` when
    ///      one is set (audit finding #3: execution is submitter-gated once a
    ///      bond is pinned) — every caller of this helper only ever pins a
    ///      bond when `submitter_ != address(0)`, so this exactly mirrors
    ///      each test's intent without changing any assertions.
    function _certifyNow(address target_, bytes4 selector_, uint8 tier_, uint16 bound_, address submitter_) internal {
        vm.prank(owner);
        reg.proposeCertification(target_, selector_, tier_, bound_, submitter_, target_.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        if (submitter_ != address(0)) {
            vm.prank(submitter_);
        }
        reg.certify(target_, selector_);
    }

    function test_unknownSelectorDefaultsToTier2FullNotional() public view {
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0xdeadbeef));
        assertEq(tier, 2);
        assertEq(boundBps, 10_000); // full notional
    }

    function test_keyIsDeterministic() public view {
        bytes32 k1 = reg.key(target, bytes4(0x12345678));
        bytes32 k2 = reg.key(target, bytes4(0x12345678));
        assertEq(k1, k2);
        assertTrue(k1 != reg.key(target, bytes4(0x12345679)));
    }

    function test_certifyThenTierOfReportsCertified() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
        assertEq(boundBps, 50);
    }

    function test_proposeCertificationRevertsForTier2() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidTier.selector);
        reg.proposeCertification(target, bytes4(0x12345678), 2, 50, address(0), target.codehash);
    }

    function test_proposeCertificationRevertsForZeroBound() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.proposeCertification(target, bytes4(0x12345678), 0, 0, address(0), target.codehash);
    }

    function test_proposeCertificationRevertsForFullNotionalBound() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.proposeCertification(target, bytes4(0x12345678), 0, 10_000, address(0), target.codehash);
    }

    function test_certifyAcceptsBoundaryValues() public {
        _certifyNow(target, bytes4(0x00000001), 0, 1, address(0));
        _certifyNow(target, bytes4(0x00000002), 1, 9_999, address(0));
        (uint8 t1, uint16 b1) = reg.tierOf(target, bytes4(0x00000001));
        (uint8 t2, uint16 b2) = reg.tierOf(target, bytes4(0x00000002));
        assertEq(t1, 0);
        assertEq(b1, 1);
        assertEq(t2, 1);
        assertEq(b2, 9_999);
    }

    function test_certifyEmitsEventWithCodehash() public {
        bytes32 expectedHash = target.codehash;
        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0x12345678), 1, 250, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.TierCertified(target, bytes4(0x12345678), 1, 250, expectedHash);
        reg.certify(target, bytes4(0x12345678));
    }

    function test_recertifySameKeyOverwrites() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 1);
        assertEq(boundBps, 500);
    }

    function test_proposeCertificationRevertsForEOATarget() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.proposeCertification(makeAddr("eoa"), bytes4(0x12345678), 0, 50, address(0), makeAddr("eoa").codehash);
    }

    function test_proposeCertificationRevertsForFundedEOATarget() public {
        // a funded EOA EXISTS, so EXTCODEHASH = keccak256("") != bytes32(0) (EIP-1052)
        address eoa = makeAddr("fundedEoa");
        vm.deal(eoa, 1 ether);
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.proposeCertification(eoa, bytes4(0x12345678), 0, 50, address(0), eoa.codehash);
    }

    function test_proposeCertificationOnlyOwner() public {
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.proposeCertification(target, bytes4(0x12345678), 0, 50, address(0), target.codehash);
    }

    function test_certifyIsPermissionless() public {
        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0x12345678), 0, 50, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        // anyone, not the owner, executes
        vm.prank(makeAddr("rando"));
        reg.certify(target, bytes4(0x12345678));
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
        assertEq(boundBps, 50);
    }

    function test_codehashMismatchLazilyDemotesToTier2() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        // swap the code under the certified target
        vm.etch(target, hex"6001600101");
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
        assertEq(boundBps, 10_000);
    }

    function test_pokePersistsDemotionOnMismatch() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        vm.etch(target, hex"6001600101");
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.TierDemoted(target, bytes4(0x12345678));
        reg.poke(target, bytes4(0x12345678)); // permissionless
    }

    function test_pokedDemotionSurvivesCodeRestore() public {
        bytes memory originalCode = target.code;
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        vm.etch(target, hex"6001600101");
        reg.poke(target, bytes4(0x12345678));
        // restore the certified bytecode: if poke had only masked lazily, tierOf
        // would report tier 0 again — the config must actually be deleted
        vm.etch(target, originalCode);
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
        assertEq(boundBps, 10_000);
    }

    function test_recertifyAfterPokeRestoresTier() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        vm.etch(target, hex"6001600101");
        reg.poke(target, bytes4(0x12345678));
        // governance recovery path: re-certify against the NEW code
        _certifyNow(target, bytes4(0x12345678), 1, 200, address(0));
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 1);
        assertEq(boundBps, 200);
    }

    function test_pokeRevertsWhenNotCertified() public {
        vm.expectRevert(TierRegistry.NotCertified.selector);
        reg.poke(target, bytes4(0x12345678));
    }

    function test_pokeRevertsWhenCodehashStillMatches() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        vm.expectRevert(TierRegistry.CodehashMatches.selector);
        reg.poke(target, bytes4(0x12345678));
    }

    function test_ownerDemote() public {
        _certifyNow(target, bytes4(0x12345678), 1, 100, address(0));
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
    }

    function test_demoteOnlyOwner() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50, address(0));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.demote(target, bytes4(0x12345678));
    }

    function test_twoStepOwnershipTransferGatesPropose() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        reg.transferOwnership(newOwner);
        // pending owner has no power until acceptance
        vm.prank(newOwner);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.proposeCertification(target, bytes4(0x12345678), 0, 50, address(0), target.codehash);
        vm.prank(newOwner);
        reg.acceptOwnership();
        vm.prank(newOwner);
        reg.proposeCertification(target, bytes4(0x12345678), 0, 50, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, bytes4(0x12345678));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
    }
}
