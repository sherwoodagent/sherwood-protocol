// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TierRegistry} from "src/TierRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract TierRegistryTest is Test {
    TierRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal target;

    function setUp() public {
        reg = new TierRegistry(owner);
        // separate deployed contract as certification target (etch-safe: never etch the registry under test)
        target = address(new TierRegistry(owner));
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
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
        assertEq(boundBps, 50);
    }

    function test_certifyRevertsForTier2() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidTier.selector);
        reg.certify(target, bytes4(0x12345678), 2, 50, address(0));
    }

    function test_certifyRevertsForZeroBound() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.certify(target, bytes4(0x12345678), 0, 0, address(0));
    }

    function test_certifyRevertsForFullNotionalBound() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.certify(target, bytes4(0x12345678), 0, 10_000, address(0));
    }

    function test_certifyAcceptsBoundaryValues() public {
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x00000001), 0, 1, address(0));
        reg.certify(target, bytes4(0x00000002), 1, 9_999, address(0));
        vm.stopPrank();
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
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.TierCertified(target, bytes4(0x12345678), 1, 250, expectedHash);
        reg.certify(target, bytes4(0x12345678), 1, 250, address(0));
    }

    function test_recertifySameKeyOverwrites() public {
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        vm.stopPrank();
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 1);
        assertEq(boundBps, 500);
    }

    function test_certifyRevertsForEOATarget() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.certify(makeAddr("eoa"), bytes4(0x12345678), 0, 50, address(0));
    }

    function test_certifyRevertsForFundedEOATarget() public {
        // a funded EOA EXISTS, so EXTCODEHASH = keccak256("") != bytes32(0) (EIP-1052)
        address eoa = makeAddr("fundedEoa");
        vm.deal(eoa, 1 ether);
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.certify(eoa, bytes4(0x12345678), 0, 50, address(0));
    }

    function test_certifyOnlyOwner() public {
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
    }

    function test_codehashMismatchLazilyDemotesToTier2() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        // swap the code under the certified target
        vm.etch(target, hex"6001600101");
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
        assertEq(boundBps, 10_000);
    }

    function test_pokePersistsDemotionOnMismatch() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        vm.etch(target, hex"6001600101");
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.TierDemoted(target, bytes4(0x12345678));
        reg.poke(target, bytes4(0x12345678)); // permissionless
    }

    function test_pokedDemotionSurvivesCodeRestore() public {
        bytes memory originalCode = target.code;
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
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
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        vm.etch(target, hex"6001600101");
        reg.poke(target, bytes4(0x12345678));
        // governance recovery path: re-certify against the NEW code
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 200, address(0));
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 1);
        assertEq(boundBps, 200);
    }

    function test_pokeRevertsWhenNotCertified() public {
        vm.expectRevert(TierRegistry.NotCertified.selector);
        reg.poke(target, bytes4(0x12345678));
    }

    function test_pokeRevertsWhenCodehashStillMatches() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        vm.expectRevert(TierRegistry.CodehashMatches.selector);
        reg.poke(target, bytes4(0x12345678));
    }

    function test_ownerDemote() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 100, address(0));
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 2);
    }

    function test_demoteOnlyOwner() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
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
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        vm.prank(newOwner);
        reg.acceptOwnership();
        vm.prank(newOwner);
        reg.certify(target, bytes4(0x12345678), 0, 50, address(0));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x12345678));
        assertEq(tier, 0);
    }

    // ── Task 6: adapter-submitter bond ──

    function _bondSetup() internal returns (ERC20Mock wood, address submitter) {
        wood = new ERC20Mock();
        submitter = makeAddr("submitter");
        wood.mint(submitter, 100_000e18);
        vm.startPrank(owner);
        reg.setWood(address(wood));
        reg.setSubmitterBondWood(10_000e18);
        reg.setBondReleaseDelay(14 days);
        vm.stopPrank();
        vm.prank(submitter);
        wood.approve(address(reg), type(uint256).max);
    }

    function test_certify_pullsSubmitterBond() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.certify(target, bytes4(0x11111111), 1, 500, submitter);
        assertEq(wood.balanceOf(address(reg)), 10_000e18);
        (uint8 tier,) = reg.tierOf(target, bytes4(0x11111111));
        assertEq(tier, 1);
    }

    function test_certify_zeroBondConfigStillWorks() public {
        // Pre-bond deployments: submitterBondWood == 0 => no pull, certify as before.
        vm.prank(owner);
        reg.certify(target, bytes4(0x22222222), 1, 500, address(0));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x22222222));
        assertEq(tier, 1);
    }

    function test_demote_startsReleaseTimelock_claimAfterDelay() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.certify(target, bytes4(0x33333333), 1, 500, submitter);
        vm.prank(owner);
        reg.demote(target, bytes4(0x33333333));
        // immediate claim: blocked
        vm.prank(submitter);
        vm.expectRevert(TierRegistry.BondNotReleasable.selector);
        reg.claimSubmitterBond(target, bytes4(0x33333333));
        // after the delay: released
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(submitter);
        reg.claimSubmitterBond(target, bytes4(0x33333333));
        assertEq(wood.balanceOf(submitter), 100_000e18);
    }

    function test_recertify_whilePendingReleaseReverts() public {
        (, address submitter) = _bondSetup();
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x44444444), 1, 500, submitter);
        reg.demote(target, bytes4(0x44444444));
        vm.expectRevert(TierRegistry.BondPendingRelease.selector);
        reg.certify(target, bytes4(0x44444444), 1, 500, submitter);
        vm.stopPrank();
    }
}
