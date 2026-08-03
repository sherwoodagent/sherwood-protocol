// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TierRegistry} from "src/TierRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Issue #45 — timelock-certification-grant. Dedicated coverage for the
///         NEW two-step behavior itself (propose / delay / permissionless
///         execute / cancel / codehash-pinning / delay governance / bond
///         timing). Existing `certify` call sites elsewhere in the suite were
///         converted to the two-step flow via a `_certifyNow` fixture helper
///         and don't re-test this mechanism — this file is where the
///         mechanism is actually pinned. See openspec/changes/
///         timelock-certification-grant/{proposal,design,tasks}.md.
contract TierRegistryCertificationTimelockTest is Test {
    TierRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal target;
    bytes4 internal constant SEL = bytes4(0x12345678);

    function setUp() public {
        reg = new TierRegistry(owner);
        // separate deployed contract as certification target (etch-safe: never etch the registry under test)
        target = address(new TierRegistry(owner));
    }

    // ── 3.1 Propose ──

    function test_propose_recordsPendingWithoutChangingEffectiveTier() public {
        bytes32 expectedHash = target.codehash;
        uint64 expectedReadyAt = uint64(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.expectEmit(true, true, false, true);
        emit TierRegistry.CertificationProposed(target, SEL, 0, 50, address(0), 0, expectedHash, expectedReadyAt);
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));

        // announcement is not certification
        (uint8 tier, uint16 bound) = reg.tierOf(target, SEL);
        assertEq(tier, 2, "still tier 2 while pending");
        assertEq(bound, 10_000);

        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        assertEq(p.tier, 0);
        assertEq(p.extractableBoundBps, 50);
        assertEq(p.submitter, address(0));
        assertEq(p.readyAt, expectedReadyAt);
        assertEq(p.bondAmount, 0);
        assertEq(p.codehash, expectedHash);
    }

    function test_propose_onlyOwner() public {
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.proposeCertification(target, SEL, 0, 50, address(0));
    }

    function test_propose_revertsForTier2() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidTier.selector);
        reg.proposeCertification(target, SEL, 2, 50, address(0));
    }

    function test_propose_revertsForZeroOrFullNotionalBound() public {
        vm.startPrank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.proposeCertification(target, SEL, 0, 0, address(0));
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.proposeCertification(target, SEL, 0, 10_000, address(0));
        vm.stopPrank();
    }

    function test_propose_revertsForNonContractTarget() public {
        vm.startPrank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.proposeCertification(makeAddr("eoa"), SEL, 0, 50, address(0));

        address fundedEoa = makeAddr("fundedEoa");
        vm.deal(fundedEoa, 1 ether);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.proposeCertification(fundedEoa, SEL, 0, 50, address(0));
        vm.stopPrank();
    }

    function test_propose_revertsForZeroAddressSubmitterWhenBonded() public {
        ERC20Mock wood = new ERC20Mock();
        vm.startPrank(owner);
        reg.setWood(address(wood));
        reg.setSubmitterBondWood(10_000e18);
        vm.expectRevert(TierRegistry.ZeroAddressSubmitter.selector);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        vm.stopPrank();
    }

    function test_reproposal_overwritesEverythingAndRestartsTheClock() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        TierRegistry.PendingCertification memory first = reg.pendingCertificationOf(target, SEL);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        address submitter = makeAddr("submitter");
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 900, submitter);
        TierRegistry.PendingCertification memory second = reg.pendingCertificationOf(target, SEL);

        assertTrue(second.readyAt > first.readyAt, "re-announcement restarts the clock, never shortens it");
        assertEq(second.tier, 1);
        assertEq(second.extractableBoundBps, 900);
        assertEq(second.submitter, submitter);
    }

    // ── 3.2 Execute ──

    function test_certify_revertsBeforeReadyAt() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay() - 1);
        vm.expectRevert(TierRegistry.CertifyDelayNotElapsed.selector);
        reg.certify(target, SEL);
    }

    function test_certify_revertsWithNoPending() public {
        vm.expectRevert(TierRegistry.NoPendingCertification.selector);
        reg.certify(target, SEL);
    }

    function test_certify_succeedsExactlyAtReadyAtByThirdParty() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        vm.warp(p.readyAt); // exactly at readyAt, not one second later

        vm.prank(makeAddr("rando")); // permissionless: not the owner
        reg.certify(target, SEL);

        (uint8 tier, uint16 bound) = reg.tierOf(target, SEL);
        assertEq(tier, 0);
        assertEq(bound, 50);

        TierRegistry.PendingCertification memory cleared = reg.pendingCertificationOf(target, SEL);
        assertEq(cleared.readyAt, 0, "pending deleted after execution");
    }

    // ── 3.3 Codehash pinning ──

    function test_certify_codehashChangeMidWindow_voidsAndIsRecoverable() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        // metamorphic redeploy: bytecode changes at the same address
        vm.etch(target, hex"6001600101");

        vm.expectRevert(TierRegistry.CodehashChanged.selector);
        reg.certify(target, SEL);

        // the stale pending record grants nothing, but it also isn't deleted
        // by the failed execution (reverts don't write state)
        TierRegistry.PendingCertification memory stillPending = reg.pendingCertificationOf(target, SEL);
        assertTrue(stillPending.readyAt != 0, "voided pending is inert, not auto-deleted");
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 2, "never certified");

        // re-proposal against the NEW code then succeeds cleanly
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 200, address(0));
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);
        (uint8 tierAfter, uint16 boundAfter) = reg.tierOf(target, SEL);
        assertEq(tierAfter, 1);
        assertEq(boundAfter, 200);
    }

    // ── 3.4 Cancel ──

    function test_cancel_clearsPending_subsequentCertifyReverts() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.CertificationCancelled(target, SEL);
        reg.cancelCertification(target, SEL);

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert(TierRegistry.NoPendingCertification.selector);
        reg.certify(target, SEL);
    }

    function test_cancel_doesNotDisturbLiveCertificationOrBond() public {
        // live certification with a bond
        ERC20Mock wood = new ERC20Mock();
        address submitter = makeAddr("submitter");
        wood.mint(submitter, 1_000e18);
        vm.startPrank(owner);
        reg.setWood(address(wood));
        reg.setSubmitterBondWood(1_000e18);
        vm.stopPrank();
        vm.prank(submitter);
        wood.approve(address(reg), type(uint256).max);

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);
        (uint8 tierBefore, uint16 boundBefore) = reg.tierOf(target, SEL);

        // a replacement is proposed, then cancelled
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 900, submitter);
        vm.prank(owner);
        reg.cancelCertification(target, SEL);

        (uint8 tierAfter, uint16 boundAfter) = reg.tierOf(target, SEL);
        assertEq(tierAfter, tierBefore, "existing certification unchanged");
        assertEq(boundAfter, boundBefore);
        TierRegistry.SubmitterBond memory b = reg.bondOf(target, SEL);
        assertEq(b.submitter, submitter, "bond unaffected by cancelling the replacement");
        assertEq(b.amount, 1_000e18);
    }

    function test_cancel_onlyOwner() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        reg.cancelCertification(target, SEL);
    }

    function test_cancel_revertsWithNoPending() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NoPendingCertification.selector);
        reg.cancelCertification(target, SEL);
    }

    // ── 3.5 Delay governance ──

    function test_setCertifyDelay_boundsEnforced() public {
        vm.startPrank(owner);
        vm.expectRevert(TierRegistry.InvalidDelay.selector);
        reg.setCertifyDelay(1 days - 1);
        vm.expectRevert(TierRegistry.InvalidDelay.selector);
        reg.setCertifyDelay(30 days + 1);
        reg.setCertifyDelay(1 days); // boundaries legal
        reg.setCertifyDelay(30 days);
        vm.stopPrank();
        assertEq(reg.certifyDelay(), 30 days);
    }

    function test_setCertifyDelay_onlyOwner() public {
        vm.expectRevert();
        reg.setCertifyDelay(7 days);
    }

    function test_setCertifyDelay_doesNotMoveAnAlreadyPinnedReadyAt() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        uint64 originalReadyAt = p.readyAt;

        // hoist: a call in argument position would consume the one-shot prank
        uint256 floorDelay = reg.MIN_CERTIFY_DELAY();
        vm.prank(owner);
        reg.setCertifyDelay(floorDelay); // floor the delay after announcing

        // still pinned to the ORIGINAL readyAt, not recomputed from the new delay
        TierRegistry.PendingCertification memory after_ = reg.pendingCertificationOf(target, SEL);
        assertEq(after_.readyAt, originalReadyAt);

        // past the new floor delay but before the original readyAt: still reverts
        vm.warp(vm.getBlockTimestamp() + floorDelay);
        assertTrue(vm.getBlockTimestamp() < originalReadyAt, "sanity: still before the pinned readyAt");
        vm.expectRevert(TierRegistry.CertifyDelayNotElapsed.selector);
        reg.certify(target, SEL);

        // once the ORIGINAL readyAt passes, it succeeds
        vm.warp(originalReadyAt);
        reg.certify(target, SEL);
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 0);
    }

    // ── 3.6 Bond timing ──

    function _bondSetup() internal returns (ERC20Mock wood, address submitter) {
        wood = new ERC20Mock();
        submitter = makeAddr("submitter");
        wood.mint(submitter, 100_000e18);
        vm.startPrank(owner);
        reg.setWood(address(wood));
        reg.setSubmitterBondWood(10_000e18);
        vm.stopPrank();
        vm.prank(submitter);
        wood.approve(address(reg), type(uint256).max);
    }

    function test_bond_pulledOnlyAtExecution_notAtPropose() public {
        (ERC20Mock wood, address submitter) = _bondSetup();

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter);
        assertEq(wood.balanceOf(address(reg)), 0, "no WOOD moves at propose time");
        assertEq(reg.totalBondedWood(), 0);

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);
        assertEq(wood.balanceOf(address(reg)), 10_000e18, "pulled exactly at execution");
        assertEq(reg.totalBondedWood(), 10_000e18);
    }

    function test_bond_configChangeMidWindow_doesNotRepriceThePull() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter);

        // owner raises the live bond config after the proposal pinned 10_000e18
        vm.prank(owner);
        reg.setSubmitterBondWood(50_000e18);

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);
        assertEq(wood.balanceOf(address(reg)), 10_000e18, "pinned amount, not the live (raised) config");
    }

    function test_bond_zeroPinnedAmountSkipsThePull_evenAfterConfigRaised() public {
        // propose while submitterBondWood == 0
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));

        // owner arms a bond config AFTER the proposal already pinned zero
        ERC20Mock wood = new ERC20Mock();
        vm.startPrank(owner);
        reg.setWood(address(wood));
        reg.setSubmitterBondWood(10_000e18);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL); // must not revert on a zero-address submitter
        assertEq(wood.balanceOf(address(reg)), 0);
        assertEq(reg.totalBondedWood(), 0);
        TierRegistry.SubmitterBond memory b = reg.bondOf(target, SEL);
        assertEq(b.amount, 0, "no bond recorded for a zero-pinned amount");
    }

    function test_bond_lapsedApproval_revertsRetryably() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.prank(submitter);
        wood.approve(address(reg), 0); // revoke approval during the window

        vm.expectRevert();
        reg.certify(target, SEL);

        // pending record is untouched, and retry succeeds once approval is restored
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        assertTrue(p.readyAt != 0, "pending survives the failed pull");

        vm.prank(submitter);
        wood.approve(address(reg), type(uint256).max);
        reg.certify(target, SEL);
        assertEq(wood.balanceOf(address(reg)), 10_000e18);
    }

    // ── 3.7 Bond conflicts at execution ──

    function test_certify_revertsBondActive_overALiveBond() public {
        (, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 500, submitter);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);

        // a replacement proposal is legal (not bond-gated) but execution is refused
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 100, submitter);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert(TierRegistry.BondActive.selector);
        reg.certify(target, SEL);
    }

    function test_certify_bondPendingRelease_thenSucceedsAfterClaim() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.startPrank(owner);
        reg.setBondReleaseDelay(1 days); // floor, so it lapses within the certify delay's re-warp
        vm.stopPrank();

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 500, submitter);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);

        vm.prank(owner);
        reg.demote(target, SEL); // starts the release timelock

        // propose the replacement while the old bond is still releasing —
        // legal per D5, the two timelocks run concurrently
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 100, submitter);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.expectRevert(TierRegistry.BondPendingRelease.selector);
        reg.certify(target, SEL);

        // release delay (1 day) < certifyDelay (>= 1 day, default 3 days)
        // already elapsed by the warp above, so the claim now succeeds
        reg.claimSubmitterBond(target, SEL);
        reg.certify(target, SEL);
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 0);
        assertEq(wood.balanceOf(address(reg)), 10_000e18, "new bond pulled after the old one released");
    }

    // ── 3.8 Demotion unaffected ──

    function test_demotionPaths_unaffectedByAnUnrelatedPendingCertification() public {
        // an unrelated (target2, sel2) is fully certified
        address target2 = address(new TierRegistry(owner));
        bytes4 sel2 = bytes4(0x22222222);
        vm.prank(owner);
        reg.proposeCertification(target2, sel2, 1, 100, address(0));
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target2, sel2);

        // a pending (but not yet executed) certification exists for `target`/SEL
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        TierRegistry.PendingCertification memory pendingBefore = reg.pendingCertificationOf(target, SEL);

        // owner demote on target2 still runs instantly, unaffected by the
        // unrelated pending certification on target/SEL
        vm.prank(owner);
        reg.demote(target2, sel2);
        (uint8 tier2,) = reg.tierOf(target2, sel2);
        assertEq(tier2, 2, "instant demotion, no delay");

        // the unrelated pending record for (target, SEL) is untouched by demoting target2
        TierRegistry.PendingCertification memory pendingAfter = reg.pendingCertificationOf(target, SEL);
        assertEq(pendingAfter.readyAt, pendingBefore.readyAt);
        assertEq(pendingAfter.tier, pendingBefore.tier);
    }

    function test_poke_stillPermissionlessAndInstant_whileAnUnrelatedCertificationIsPending() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0));
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);

        // a pending replacement is announced but not yet ready
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 900, address(0));

        vm.etch(target, hex"6001600101");
        vm.prank(makeAddr("rando"));
        reg.poke(target, SEL); // instant, permissionless, unaffected by the pending replacement
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 2);

        // the pending replacement itself is untouched by the poke
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        assertTrue(p.readyAt != 0);
    }
}
