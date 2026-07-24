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

    function test_recertify_whileBondActiveReverts() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        address otherSubmitter = makeAddr("otherSubmitter");
        wood.mint(otherSubmitter, 100_000e18);
        vm.prank(otherSubmitter);
        wood.approve(address(reg), type(uint256).max);

        vm.startPrank(owner);
        reg.certify(target, bytes4(0x55555555), 1, 500, submitter);
        // re-certify with a DIFFERENT submitter: reverts, must not overwrite the live bond
        vm.expectRevert(TierRegistry.BondActive.selector);
        reg.certify(target, bytes4(0x55555555), 0, 100, otherSubmitter);
        // re-certify with the SAME submitter: also reverts
        vm.expectRevert(TierRegistry.BondActive.selector);
        reg.certify(target, bytes4(0x55555555), 0, 100, submitter);
        vm.stopPrank();

        // old bond record intact: registry still holds exactly one bond, and the
        // original submitter can still traverse demote -> timelock -> claim in full
        assertEq(wood.balanceOf(address(reg)), 10_000e18);
        vm.prank(owner);
        reg.demote(target, bytes4(0x55555555));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(submitter);
        reg.claimSubmitterBond(target, bytes4(0x55555555));
        assertEq(wood.balanceOf(submitter), 100_000e18);
        assertEq(wood.balanceOf(address(reg)), 0);
    }

    function test_recertify_afterClaimSucceeds() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        address newSubmitter = makeAddr("newSubmitter");
        wood.mint(newSubmitter, 100_000e18);
        vm.prank(newSubmitter);
        wood.approve(address(reg), type(uint256).max);

        vm.startPrank(owner);
        reg.certify(target, bytes4(0x66666666), 1, 500, submitter);
        reg.demote(target, bytes4(0x66666666));
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(submitter);
        reg.claimSubmitterBond(target, bytes4(0x66666666));

        // key is clear: a fresh certify with a new submitter succeeds and pulls the new bond
        vm.prank(owner);
        reg.certify(target, bytes4(0x66666666), 0, 100, newSubmitter);
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x66666666));
        assertEq(tier, 0);
        assertEq(boundBps, 100);
        assertEq(wood.balanceOf(newSubmitter), 90_000e18);
        assertEq(wood.balanceOf(address(reg)), 10_000e18);
    }

    // ── Review hardening: conservation, setter bounds, permissionless claim ──

    function test_pokePath_bondLifecycle() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.certify(target, bytes4(0x77777777), 1, 500, submitter);
        // mutate the target's code so the certified codehash no longer matches
        vm.etch(target, hex"6001600101");
        // permissionless poke from a rando starts the release timelock
        vm.prank(makeAddr("rando"));
        reg.poke(target, bytes4(0x77777777));
        TierRegistry.SubmitterBond memory b = reg.bondOf(target, bytes4(0x77777777));
        assertEq(b.submitter, submitter);
        assertEq(b.amount, 10_000e18);
        assertEq(b.releasableAt, uint64(block.timestamp + 14 days));
        // permissionless claim after the delay pays the SUBMITTER, not the caller
        vm.warp(block.timestamp + 14 days);
        vm.prank(makeAddr("anotherRando"));
        reg.claimSubmitterBond(target, bytes4(0x77777777));
        assertEq(wood.balanceOf(submitter), 100_000e18);
        assertEq(wood.balanceOf(makeAddr("anotherRando")), 0);
        assertEq(reg.totalBondedWood(), 0);
    }

    function test_doubleClaimReverts() public {
        (, address submitter) = _bondSetup();
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x88888888), 1, 500, submitter);
        reg.demote(target, bytes4(0x88888888));
        vm.stopPrank();
        vm.warp(block.timestamp + 14 days + 1);
        reg.claimSubmitterBond(target, bytes4(0x88888888));
        // record deleted: second claim reverts BondNotReleasable (releasableAt back to 0)
        vm.expectRevert(TierRegistry.BondNotReleasable.selector);
        reg.claimSubmitterBond(target, bytes4(0x88888888));
    }

    function test_certify_zeroAddressSubmitterRevertsWhenBonded() public {
        _bondSetup();
        vm.prank(owner);
        vm.expectRevert(TierRegistry.ZeroAddressSubmitter.selector);
        reg.certify(target, bytes4(0x99999999), 1, 500, address(0));
    }

    function test_certify_noApprovalReverts() public {
        (ERC20Mock wood,) = _bondSetup();
        address broke = makeAddr("noApproval");
        wood.mint(broke, 100_000e18); // funded but never approved the registry
        vm.prank(owner);
        vm.expectRevert();
        reg.certify(target, bytes4(0xaaaaaaaa), 1, 500, broke);
    }

    function test_bondEventsEmitted() public {
        (, address submitter) = _bondSetup();
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TierRegistry.SubmitterBondLocked(target, bytes4(0xbbbbbbbb), submitter, 10_000e18);
        reg.certify(target, bytes4(0xbbbbbbbb), 1, 500, submitter);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit TierRegistry.SubmitterBondReleaseStarted(
            target, bytes4(0xbbbbbbbb), submitter, uint64(block.timestamp + 14 days)
        );
        reg.demote(target, bytes4(0xbbbbbbbb));
        vm.warp(block.timestamp + 14 days);
        vm.expectEmit(true, true, true, true);
        emit TierRegistry.SubmitterBondClaimed(target, bytes4(0xbbbbbbbb), submitter, 10_000e18);
        reg.claimSubmitterBond(target, bytes4(0xbbbbbbbb));
    }

    function test_setSubmitterBondWood_tooLargeReverts() public {
        _bondSetup();
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BondTooLarge.selector);
        reg.setSubmitterBondWood(uint256(type(uint96).max) + 1);
    }

    function test_setBondReleaseDelay_boundsEnforced() public {
        vm.startPrank(owner);
        vm.expectRevert(TierRegistry.InvalidDelay.selector);
        reg.setBondReleaseDelay(1 days - 1);
        vm.expectRevert(TierRegistry.InvalidDelay.selector);
        reg.setBondReleaseDelay(365 days + 1);
        reg.setBondReleaseDelay(1 days); // boundaries legal
        reg.setBondReleaseDelay(365 days);
        vm.stopPrank();
        assertEq(reg.bondReleaseDelay(), 365 days);
    }

    function test_setWood_revertsWhileBondsOutstanding() public {
        (, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.certify(target, bytes4(0xcccccccc), 1, 500, submitter);
        address newWood = address(new ERC20Mock());
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BondsOutstanding.selector);
        reg.setWood(newWood);
    }

    function test_setWood_zeroWhileArmedReverts() public {
        _bondSetup(); // arms submitterBondWood = 10_000e18
        vm.prank(owner);
        vm.expectRevert(TierRegistry.BondConfigUnset.selector);
        reg.setWood(address(0));
    }

    /// Conservation invariant (spec §4): WOOD held == sum of active +
    /// pending-release bonds, across random certify/demote/warp/claim
    /// interleavings on 3 keys.
    function testFuzz_woodBalanceMatchesBonds(uint8 certifyMask, uint8 demoteMask, uint8 claimMask, uint32 warpSeed)
        public
    {
        (ERC20Mock wood,) = _bondSetup();
        bytes4[3] memory sels = [bytes4(0xf0000001), bytes4(0xf0000002), bytes4(0xf0000003)];
        for (uint256 i = 0; i < 3; i++) {
            address sub = makeAddr(string(abi.encodePacked("fuzzSub", i)));
            wood.mint(sub, 100_000e18);
            vm.prank(sub);
            wood.approve(address(reg), type(uint256).max);
            if (certifyMask & (1 << i) == 0) continue;
            vm.prank(owner);
            reg.certify(target, sels[i], 1, 500, sub);
            if (demoteMask & (1 << i) != 0) {
                vm.prank(owner);
                reg.demote(target, sels[i]);
                if (claimMask & (1 << i) != 0) {
                    vm.warp(block.timestamp + 14 days + 1 + (uint256(warpSeed) % 30 days));
                    reg.claimSubmitterBond(target, sels[i]); // permissionless
                }
            }
        }
        assertEq(wood.balanceOf(address(reg)), reg.totalBondedWood());
    }
}
