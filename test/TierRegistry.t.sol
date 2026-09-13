// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TierRegistry} from "src/TierRegistry.sol";

contract TierRegistryTest is Test {
    TierRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal target;

    bytes4 internal constant SEL = bytes4(0x12345678);

    function setUp() public {
        reg = new TierRegistry(owner);
        // separate deployed contract as certification target (etch-safe: never etch the registry under test)
        target = address(new TierRegistry(owner));
    }

    function _certifyNow(address target_, bytes4 selector_, uint8 tier_, uint16 bound_) internal {
        vm.prank(owner);
        reg.certify(target_, selector_, tier_, bound_, target_.codehash);
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
        _certifyNow(target, bytes4(0x12345678), 0, 50);
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
        assertEq(boundBps, 50);
    }

    function test_certifyRevertsForTier2() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidTier.selector);
        reg.certify(target, bytes4(0x12345678), 2, 50, target.codehash);
    }

    function test_certifyRevertsForZeroBound() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.certify(target, bytes4(0x12345678), 0, 0, target.codehash);
    }

    function test_certifyRevertsForFullNotionalBound() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.certify(target, bytes4(0x12345678), 0, 10_000, target.codehash);
    }

    function test_certifyAcceptsBoundaryValues() public {
        _certifyNow(target, bytes4(0x00000001), 0, 1);
        _certifyNow(target, bytes4(0x00000002), 1, 9_999);
        (uint8 t1, uint16 b1) = reg.tierOf(target, bytes4(0x00000001));
        (uint8 t2, uint16 b2) = reg.tierOf(target, bytes4(0x00000002));
        assertEq(t1, 0);
        assertEq(b1, 1);
        assertEq(t2, 1);
        assertEq(b2, 9_999);
    }

    function test_certifyEmitsEventWithCodehash() public {
        bytes32 expectedHash = target.codehash;
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.TierCertified(target, bytes4(0x12345678), 1, 250, expectedHash);
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 250, expectedHash);
    }

    function test_recertifySameKeyOverwrites() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50);
        _certifyNow(target, bytes4(0x12345678), 1, 500);
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 1);
        assertEq(boundBps, 500);
    }

    function test_certifyRevertsForEOATarget() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.certify(makeAddr("eoa"), bytes4(0x12345678), 0, 50, makeAddr("eoa").codehash);
    }

    function test_certifyRevertsForFundedEOATarget() public {
        // a funded EOA EXISTS, so EXTCODEHASH = keccak256("") != bytes32(0) (EIP-1052)
        address eoa = makeAddr("fundedEoa");
        vm.deal(eoa, 1 ether);
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.certify(eoa, bytes4(0x12345678), 0, 50, eoa.codehash);
    }

    function test_codehashMismatchLazilyDemotesToTier2() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50);
        // swap the code under the certified target
        vm.etch(target, hex"6001600101");
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
        assertEq(boundBps, 10_000);
    }

    function test_pokePersistsDemotionOnMismatch() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50);
        vm.etch(target, hex"6001600101");
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.TierDemoted(target, bytes4(0x12345678));
        reg.poke(target, bytes4(0x12345678)); // permissionless
    }

    function test_pokedDemotionSurvivesCodeRestore() public {
        bytes memory originalCode = target.code;
        _certifyNow(target, bytes4(0x12345678), 0, 50);
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
        _certifyNow(target, bytes4(0x12345678), 0, 50);
        vm.etch(target, hex"6001600101");
        reg.poke(target, bytes4(0x12345678));
        // governance recovery path: re-certify against the NEW code
        _certifyNow(target, bytes4(0x12345678), 1, 200);
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 1);
        assertEq(boundBps, 200);
    }

    function test_pokeRevertsWhenNotCertified() public {
        vm.expectRevert(TierRegistry.NotCertified.selector);
        reg.poke(target, bytes4(0x12345678));
    }

    function test_pokeRevertsWhenCodehashStillMatches() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50);
        vm.expectRevert(TierRegistry.CodehashMatches.selector);
        reg.poke(target, bytes4(0x12345678));
    }

    function test_ownerDemote() public {
        _certifyNow(target, bytes4(0x12345678), 1, 100);
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
    }

    function test_demoteOnlyOwner() public {
        _certifyNow(target, bytes4(0x12345678), 0, 50);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.demote(target, bytes4(0x12345678));
    }

    function test_twoStepOwnershipTransferGatesCertify() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        reg.transferOwnership(newOwner);
        // pending owner has no power until acceptance
        vm.prank(newOwner);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.certify(target, bytes4(0x12345678), 0, 50, target.codehash);
        vm.prank(newOwner);
        reg.acceptOwnership();
        vm.prank(newOwner);
        reg.certify(target, bytes4(0x12345678), 0, 50, target.codehash);
        (uint8 tier,) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
    }

    function test_certify_isOneOwnerCallAndTakesEffectImmediately() public {
        vm.prank(owner);
        reg.certify(address(target), SEL, 0, 5_000, address(target).codehash);
        (uint8 t, uint16 bound) = reg.tierOf(address(target), SEL);
        assertEq(t, 0, "certified tier");
        assertEq(bound, 5_000, "certified bound");
    }

    function test_certify_revertsWhenTheLiveCodehashIsNotTheReviewedOne() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.CodehashChanged.selector);
        reg.certify(address(target), SEL, 0, 5_000, keccak256("something else"));
    }

    function test_certify_isOwnerOnly() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        reg.certify(address(target), SEL, 0, 5_000, address(target).codehash);
    }

    function test_certify_reCertifyingOverwritesTheBoundWithNoPendingState() public {
        vm.startPrank(owner);
        reg.certify(address(target), SEL, 0, 5_000, address(target).codehash);
        reg.certify(address(target), SEL, 1, 2_000, address(target).codehash);
        vm.stopPrank();
        (uint8 t, uint16 bound) = reg.tierOf(address(target), SEL);
        assertEq(t, 1);
        assertEq(bound, 2_000);
    }
}
