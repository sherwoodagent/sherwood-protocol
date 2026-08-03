// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

    function test_setAuthorizedDemoter_onlyOwner() public {
        vm.expectRevert();
        reg.setAuthorizedDemoter(makeAddr("rogue"));
    }

    function test_demoteByChallenge_onlyDemoter() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x77777777), 1, 500, address(0));
        vm.expectRevert(TierRegistry.NotAuthorizedDemoter.selector);
        reg.demoteByChallenge(target, bytes4(0x77777777));
    }

    /// @notice A passed challenge demotes the offending adapter back to the
    ///         tier-2 default without needing registry ownership (§3.4).
    function test_demoteByChallenge_demotes() public {
        address demoter = makeAddr("demoter");
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x77777777), 1, 500, address(0));
        reg.setAuthorizedDemoter(demoter);
        vm.stopPrank();

        (uint8 tierBefore,) = reg.tierOf(target, bytes4(0x77777777));
        assertEq(tierBefore, 1);

        vm.prank(demoter);
        reg.demoteByChallenge(target, bytes4(0x77777777));

        (uint8 tierAfter, uint16 boundAfter) = reg.tierOf(target, bytes4(0x77777777));
        assertEq(tierAfter, 2, "back to the arbitrary-calldata default");
        assertEq(boundAfter, 10_000);
    }

    /// @notice The demoter can only REVOKE. It must not be able to certify — that
    ///         is why this is a role rather than registry ownership.
    function test_demoter_cannotCertify() public {
        address demoter = makeAddr("demoter");
        vm.prank(owner);
        reg.setAuthorizedDemoter(demoter);
        vm.prank(demoter);
        vm.expectRevert();
        reg.certify(target, bytes4(0x88888888), 1, 500, address(0));
    }

    // ── Issue #77: demotion auto-clears the adapter allowlist ──

    /// @notice Owner `demote` clears the target's allowlist entry atomically,
    ///         reusing the existing `AdapterAllowedSet` event.
    function test_demote_clearsAdapterAllowlist() public {
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        reg.setAdapterAllowed(target, true);
        vm.stopPrank();
        assertTrue(reg.isAdapterAllowed(target));

        vm.expectEmit(true, false, false, true);
        emit TierRegistry.AdapterAllowedSet(target, false);
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target));
    }

    /// @notice `demoteByChallenge` clears the allowlist identically to owner
    ///         `demote` — both converge on `_demote`.
    function test_demoteByChallenge_clearsAdapterAllowlist() public {
        address demoter = makeAddr("demoter");
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        reg.setAdapterAllowed(target, true);
        reg.setAuthorizedDemoter(demoter);
        vm.stopPrank();
        assertTrue(reg.isAdapterAllowed(target));

        // hoist: any argument-position call would consume the one-shot prank
        vm.expectEmit(true, false, false, true);
        emit TierRegistry.AdapterAllowedSet(target, false);
        vm.prank(demoter);
        reg.demoteByChallenge(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target));
    }

    /// @notice Permissionless `poke` (on codehash drift) clears the allowlist
    ///         too — the third of the three `_demote`-converging paths.
    function test_poke_clearsAdapterAllowlist() public {
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        reg.setAdapterAllowed(target, true);
        vm.stopPrank();
        vm.etch(target, hex"6001600101");
        // issue #137: isAdapterAllowed self-heals lazily on read, exactly like
        // tierOf, so it already reports false here even though `poke` has not
        // run yet and `_adapterAllowed[target]` storage is still `true`. This
        // assertion used to be `assertTrue` and was pinning the stale-`true`
        // window that let a metamorphic redeploy keep standing funds-path
        // rights until someone happened to poke.
        assertFalse(reg.isAdapterAllowed(target));

        vm.expectEmit(true, false, false, true);
        emit TierRegistry.AdapterAllowedSet(target, false);
        vm.prank(makeAddr("rando"));
        reg.poke(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target));
    }

    /// @notice Demoting a target that was never allowlisted must NOT emit a
    ///         phantom `AdapterAllowedSet` — the guarded emission keeps the
    ///         channel truthful and existing `vm.expectEmit` assertions in
    ///         this file (which never allowlist before demoting) unaffected.
    function test_demote_neverAllowlisted_noAllowedSetEvent() public {
        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        assertFalse(reg.isAdapterAllowed(target));

        bytes32 allowedSetSig = keccak256("AdapterAllowedSet(address,bool)");
        vm.recordLogs();
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != allowedSetSig, "no phantom AdapterAllowedSet");
        }
    }

    /// @notice DELIBERATE over-breadth (design.md Decision 3): certification
    ///         is keyed (target, selector), the allowlist by bare address, so
    ///         demoting ONE selector de-allowlists the WHOLE adapter even
    ///         though its other selectors remain certified. This pins the
    ///         over-broad clear as specified behavior, not a bug — do not
    ///         "fix" it back to per-selector.
    function test_demoteOneSelector_clearsWholeAdapter_intended() public {
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        reg.certify(target, bytes4(0x87654321), 0, 200, address(0));
        reg.setAdapterAllowed(target, true);
        vm.stopPrank();

        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target), "whole adapter de-allowlisted by one selector's demotion");
        (uint8 survivingTier, uint16 survivingBound) = reg.tierOf(target, bytes4(0x87654321));
        assertEq(survivingTier, 0, "other selector remains certified");
        assertEq(survivingBound, 200);
    }

    /// @notice Re-certifying a demoted (target, selector) must NOT restore
    ///         the allowlist — `certify` never sets or restores
    ///         `_adapterAllowed`; the coupling is one-way and fail-closed.
    function test_recertify_doesNotRestoreAllowlist() public {
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        reg.setAdapterAllowed(target, true);
        reg.demote(target, bytes4(0x12345678)); // auto-clears the allowlist
        vm.stopPrank();
        assertFalse(reg.isAdapterAllowed(target));

        vm.prank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));

        assertFalse(reg.isAdapterAllowed(target), "re-certification must not re-grant the allowlist");
    }

    /// @notice The recovery path: after a demotion-triggered clear, the owner
    ///         can always explicitly re-allowlist the adapter.
    function test_ownerReallowsAfterClear() public {
        vm.startPrank(owner);
        reg.certify(target, bytes4(0x12345678), 1, 500, address(0));
        reg.setAdapterAllowed(target, true);
        reg.demote(target, bytes4(0x12345678));
        vm.stopPrank();
        assertFalse(reg.isAdapterAllowed(target));

        vm.prank(owner);
        reg.setAdapterAllowed(target, true);

        assertTrue(reg.isAdapterAllowed(target));
    }

    /// @notice issue #137, design.md D1/D2: a metamorphic same-address
    ///         bytecode swap on an allowlisted adapter self-heals to `false`
    ///         on the very next read — with NO demotion call of any kind
    ///         (no `poke`, no `demote`, no `demoteByChallenge`). The owner can
    ///         then re-attest the new code with a fresh grant, which refreshes
    ///         the snapshot and restores `true`.
    function test_metamorphicSwap_selfHealsWithoutPoke() public {
        address adapter = address(new TierRegistry(owner));
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true);
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, hex"6001600101");
        assertFalse(reg.isAdapterAllowed(adapter), "self-heals without any demotion call");

        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true); // re-attestation, not a demotion recovery
        assertTrue(reg.isAdapterAllowed(adapter), "re-grant refreshes the snapshot to the new code");
    }

    /// @notice design.md D2: for an allowlisted adapter that was NEVER
    ///         certified, `poke` is permanently unreachable (`NotCertified`),
    ///         so the lazy read-side self-heal is the ONLY automatic
    ///         protection — proving the fix cannot be "just call poke more".
    ///         Owner `setAdapterAllowed(adapter, false)` remains the manual
    ///         storage-cleanup path for this case.
    function test_uncertifiedAdapter_readSideGateIsOnlyProtection() public {
        address adapter = address(new TierRegistry(owner));
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true);
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, hex"6001600101");
        assertFalse(reg.isAdapterAllowed(adapter), "read-side gate closes the funds path");

        vm.expectRevert(TierRegistry.NotCertified.selector);
        reg.poke(adapter, bytes4(0x12345678));

        vm.prank(owner);
        reg.setAdapterAllowed(adapter, false);
        assertFalse(reg.isAdapterAllowed(adapter));
    }

    /// @notice design.md D3: normalization treats a non-existent account
    ///         (`bytes32(0)`) and an existing-but-codeless account
    ///         (`keccak256("")`) as one "no code" value. (a) a codeless
    ///         allowlisted payout address stays allowed after merely
    ///         receiving a native-balance donation — the anti-grief property
    ///         that `test/vault/SelectorGuard.t.sol`'s codeless adapter
    ///         fixture depends on; (b) code later appearing there fails
    ///         closed; (c) a contract whose code disappears (selfdestruct)
    ///         also fails closed.
    function test_zeroCodeNormalization() public {
        address payout = makeAddr("payout");
        vm.prank(owner);
        reg.setAdapterAllowed(payout, true);
        assertTrue(reg.isAdapterAllowed(payout), "codeless address allowlists cleanly");

        vm.deal(payout, 1 wei); // non-existent -> existing-codeless
        assertTrue(reg.isAdapterAllowed(payout), "a 1-wei donation must not grief the funds path closed");

        vm.etch(payout, hex"6001600101");
        assertFalse(reg.isAdapterAllowed(payout), "code appearing at a codeless allowlisted address fails closed");

        // Separate fixture: a contract that had code at grant time and later
        // has none (simulating a post-Dencun-rare but still possible
        // selfdestruct) also fails closed.
        address adapter = address(new TierRegistry(owner));
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true);
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, "");
        assertFalse(reg.isAdapterAllowed(adapter), "code disappearing (selfdestruct) fails closed");
    }

    /// @notice design.md D1: `setAdapterAllowed(adapter, false)` answers
    ///         false regardless of codehash state, and a stale snapshot left
    ///         behind under a cleared flag is inert — the next grant
    ///         overwrites it unconditionally with whatever code is live then.
    function test_revokeThenRegrant_snapshotOverwrittenByNextGrant() public {
        address adapter = address(new TierRegistry(owner));
        vm.startPrank(owner);
        reg.setAdapterAllowed(adapter, true);
        vm.stopPrank();
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, hex"6001600101"); // stale snapshot no longer matches
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, false);
        assertFalse(reg.isAdapterAllowed(adapter), "revoke answers false regardless of codehash state");

        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true); // re-grant snapshots the NEW code
        assertTrue(reg.isAdapterAllowed(adapter), "next grant overwrites the stale snapshot with current code");
    }

    /// @notice Issue #40 launch-gate pin: with `submitterBondWood` at its
    ///         default (0, unset by any deploy path), `certify` must lock
    ///         nothing and emit no `SubmitterBondLocked` — the unbonded,
    ///         governance-judged certification path this repo actually
    ///         deploys today.
    function test_certifyWithZeroBondLocksNothingAndEmitsNoBondEvent() public {
        assertEq(reg.submitterBondWood(), 0, "fresh TierRegistry defaults to unbonded");

        vm.recordLogs();
        vm.prank(owner);
        reg.certify(target, bytes4(0x40404040), 0, 50, address(0));

        assertEq(reg.totalBondedWood(), 0, "no bond locked when submitterBondWood is 0");
        // Exactly one event (TierCertified) — SubmitterBondLocked is emitted
        // ONLY inside the `bondAmount != 0` branch, so its absence here is
        // equivalent to "the only log is TierCertified".
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "certify with a disabled bond must emit only TierCertified, never SubmitterBondLocked");
    }
}
