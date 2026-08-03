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
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);

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
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
    }

    function test_propose_revertsForTier2() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidTier.selector);
        reg.proposeCertification(target, SEL, 2, 50, address(0), target.codehash);
    }

    function test_propose_revertsForZeroOrFullNotionalBound() public {
        vm.startPrank(owner);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.proposeCertification(target, SEL, 0, 0, address(0), target.codehash);
        vm.expectRevert(TierRegistry.BoundRequired.selector);
        reg.proposeCertification(target, SEL, 0, 10_000, address(0), target.codehash);
        vm.stopPrank();
    }

    function test_propose_revertsForNonContractTarget() public {
        vm.startPrank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.proposeCertification(makeAddr("eoa"), SEL, 0, 50, address(0), makeAddr("eoa").codehash);

        address fundedEoa = makeAddr("fundedEoa");
        vm.deal(fundedEoa, 1 ether);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        reg.proposeCertification(fundedEoa, SEL, 0, 50, address(0), fundedEoa.codehash);
        vm.stopPrank();
    }

    function test_propose_revertsForZeroAddressSubmitterWhenBonded() public {
        ERC20Mock wood = new ERC20Mock();
        vm.startPrank(owner);
        reg.setWood(address(wood));
        reg.setSubmitterBondWood(10_000e18);
        vm.expectRevert(TierRegistry.ZeroAddressSubmitter.selector);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        vm.stopPrank();
    }

    function test_reproposal_overwritesEverythingAndRestartsTheClock() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        TierRegistry.PendingCertification memory first = reg.pendingCertificationOf(target, SEL);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        address submitter = makeAddr("submitter");
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 900, submitter, target.codehash);
        TierRegistry.PendingCertification memory second = reg.pendingCertificationOf(target, SEL);

        assertTrue(second.readyAt > first.readyAt, "re-announcement restarts the clock, never shortens it");
        assertEq(second.tier, 1);
        assertEq(second.extractableBoundBps, 900);
        assertEq(second.submitter, submitter);
    }

    // ── 3.2 Execute ──

    function test_certify_revertsBeforeReadyAt() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
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
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
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
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
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
        reg.proposeCertification(target, SEL, 1, 200, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);
        (uint8 tierAfter, uint16 boundAfter) = reg.tierOf(target, SEL);
        assertEq(tierAfter, 1);
        assertEq(boundAfter, 200);
    }

    // ── 3.4 Cancel ──

    function test_cancel_clearsPending_subsequentCertifyReverts() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);

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
        reg.proposeCertification(target, SEL, 0, 50, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitter); // finding #3: execution is submitter-gated once a bond is pinned
        reg.certify(target, SEL);
        (uint8 tierBefore, uint16 boundBefore) = reg.tierOf(target, SEL);

        // a replacement is proposed, then cancelled
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 900, submitter, target.codehash);
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
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
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
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
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
        reg.proposeCertification(target, SEL, 0, 50, submitter, target.codehash);
        assertEq(wood.balanceOf(address(reg)), 0, "no WOOD moves at propose time");
        assertEq(reg.totalBondedWood(), 0);

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitter); // finding #3: execution is submitter-gated once a bond is pinned
        reg.certify(target, SEL);
        assertEq(wood.balanceOf(address(reg)), 10_000e18, "pulled exactly at execution");
        assertEq(reg.totalBondedWood(), 10_000e18);
    }

    function test_bond_configChangeMidWindow_doesNotRepriceThePull() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter, target.codehash);

        // owner raises the live bond config after the proposal pinned 10_000e18
        vm.prank(owner);
        reg.setSubmitterBondWood(50_000e18);

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitter); // finding #3: execution is submitter-gated once a bond is pinned
        reg.certify(target, SEL);
        assertEq(wood.balanceOf(address(reg)), 10_000e18, "pinned amount, not the live (raised) config");
    }

    function test_bond_zeroPinnedAmountSkipsThePull_evenAfterConfigRaised() public {
        // propose while submitterBondWood == 0
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);

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
        reg.proposeCertification(target, SEL, 0, 50, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.prank(submitter);
        wood.approve(address(reg), 0); // revoke approval during the window

        vm.expectRevert();
        // pranked as the pinned submitter so the revert exercised here is
        // genuinely the lapsed-allowance failure, not `NotSubmitter`
        // (finding #3) masking it.
        vm.prank(submitter);
        reg.certify(target, SEL);

        // pending record is untouched, and retry succeeds once approval is restored
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        assertTrue(p.readyAt != 0, "pending survives the failed pull");

        vm.prank(submitter);
        wood.approve(address(reg), type(uint256).max);
        vm.prank(submitter);
        reg.certify(target, SEL);
        assertEq(wood.balanceOf(address(reg)), 10_000e18);
    }

    // ── 3.7 Bond conflicts at execution ──

    function test_certify_revertsBondActive_overALiveBond() public {
        (, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 500, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitter); // finding #3: execution is submitter-gated once a bond is pinned
        reg.certify(target, SEL);

        // a replacement proposal is legal (not bond-gated) but execution is refused
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 100, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert(TierRegistry.BondActive.selector);
        vm.prank(submitter);
        reg.certify(target, SEL);
    }

    function test_certify_bondPendingRelease_thenSucceedsAfterClaim() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        vm.startPrank(owner);
        reg.setBondReleaseDelay(1 days); // floor, so it lapses within the certify delay's re-warp
        vm.stopPrank();

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 500, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitter); // finding #3: execution is submitter-gated once a bond is pinned
        reg.certify(target, SEL);

        vm.prank(owner);
        reg.demote(target, SEL); // starts the release timelock

        // propose the replacement while the old bond is still releasing —
        // legal per D5, the two timelocks run concurrently
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 100, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.expectRevert(TierRegistry.BondPendingRelease.selector);
        vm.prank(submitter);
        reg.certify(target, SEL);

        // release delay (1 day) < certifyDelay (>= 1 day, default 3 days)
        // already elapsed by the warp above, so the claim now succeeds
        reg.claimSubmitterBond(target, SEL);
        vm.prank(submitter);
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
        reg.proposeCertification(target2, sel2, 1, 100, address(0), target2.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target2, sel2);

        // a pending (but not yet executed) certification exists for `target`/SEL
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
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
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);

        // a pending replacement is announced but not yet ready
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 900, address(0), target.codehash);

        vm.etch(target, hex"6001600101");
        vm.prank(makeAddr("rando"));
        reg.poke(target, SEL); // instant, permissionless, unaffected by the pending replacement
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 2);

        // the pending replacement itself is untouched by the poke
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        assertTrue(p.readyAt != 0);
    }

    // ── Audit remediation (PR #156 Pashov review) ──

    /// @notice Finding #1 [92]: the bond token is pinned at proposal time, so
    ///         an ordinary `setWood` migration during the certify-delay
    ///         window can never make `certify` pull the pinned AMOUNT
    ///         denominated in a token the submitter never approved for this
    ///         certification. Mirrors the audit's own proof: propose while
    ///         `wood == TokenA`, swap to TokenB mid-window (legal, since
    ///         `totalBondedWood == 0` before execution), then certify must
    ///         pull TokenA from the submitter — never TokenB — even though
    ///         TokenB is now the live `wood`.
    function test_finding1_bondTokenPinnedSurvivesSetWoodMidWindow() public {
        ERC20Mock tokenA = new ERC20Mock();
        ERC20Mock tokenB = new ERC20Mock();
        address submitter = makeAddr("submitter");
        tokenA.mint(submitter, 100_000e18);
        tokenB.mint(submitter, 100_000e18);

        vm.startPrank(owner);
        reg.setWood(address(tokenA));
        reg.setSubmitterBondWood(10_000e18);
        vm.stopPrank();
        vm.prank(submitter);
        tokenA.approve(address(reg), type(uint256).max);
        // the submitter never approves TokenB — proving the exploit path
        // (pulling from a stale TokenB allowance) is unavailable even if
        // attempted, and the honest path (pulling TokenA) still works.

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter, target.codehash);
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        assertEq(address(p.bondToken), address(tokenA), "bondToken pinned to the token live at proposal time");

        // ordinary, honest token migration mid-window: legal because
        // totalBondedWood == 0 (nothing has executed yet)
        vm.prank(owner);
        reg.setWood(address(tokenB));
        assertEq(address(reg.wood()), address(tokenB), "sanity: wood really did move to TokenB");

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.prank(submitter);
        reg.certify(target, SEL);

        assertEq(tokenA.balanceOf(address(reg)), 10_000e18, "pulled the PINNED token (A), not live wood (B)");
        assertEq(tokenB.balanceOf(address(reg)), 0, "TokenB untouched: certify never reads live wood for the pull");
        TierRegistry.SubmitterBond memory b = reg.bondOf(target, SEL);
        assertEq(b.amount, 10_000e18);
    }

    /// @notice Finding #2 [85]: a same-key pending certification must not
    ///         survive that key's for-cause demotion. Mirrors the audit's
    ///         proof: a live tier-1 certification gets a "renewal" proposed
    ///         at looser tier-0 terms, then `demoteByChallenge` convicts the
    ///         LIVE certification — the pending renewal must be cancelled by
    ///         the same `_demote`, not left to execute later and silently
    ///         override the conviction.
    function test_finding2_demoteByChallenge_cancelsPendingRenewal() public {
        address demoter = makeAddr("demoter");
        vm.prank(owner);
        reg.setAuthorizedDemoter(demoter);

        // live tier-1 certification
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 500, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);
        (uint8 tierBefore,) = reg.tierOf(target, SEL);
        assertEq(tierBefore, 1);

        // a "renewal" is proposed at looser tier-0 terms while the tier-1
        // certification is still live
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 9_000, address(0), target.codehash);
        TierRegistry.PendingCertification memory pendingBefore = reg.pendingCertificationOf(target, SEL);
        assertTrue(pendingBefore.readyAt != 0, "renewal is pending");

        // the challenge game convicts the LIVE certification before the
        // renewal's readyAt
        vm.expectEmit(true, true, false, true);
        emit TierRegistry.CertificationCancelled(target, SEL);
        vm.prank(demoter);
        reg.demoteByChallenge(target, SEL);

        (uint8 tierAfter,) = reg.tierOf(target, SEL);
        assertEq(tierAfter, 2, "conviction demotes to the tier-2 default");

        // the pending renewal must be gone — NOT survive to execute later
        // and silently re-certify the just-convicted target at looser terms
        TierRegistry.PendingCertification memory pendingAfter = reg.pendingCertificationOf(target, SEL);
        assertEq(pendingAfter.readyAt, 0, "pending renewal cancelled by the conviction");

        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert(TierRegistry.NoPendingCertification.selector);
        reg.certify(target, SEL);
    }

    /// @notice Finding #2, owner `demote` path: the same cancellation must
    ///         happen for an ordinary owner demotion, not just the challenge
    ///         path — `_demote` is the single convergence point for both.
    function test_finding2_ownerDemote_cancelsPendingRenewal() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 500, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 9_000, address(0), target.codehash);
        assertTrue(reg.pendingCertificationOf(target, SEL).readyAt != 0);

        vm.prank(owner);
        reg.demote(target, SEL);

        assertEq(reg.pendingCertificationOf(target, SEL).readyAt, 0, "owner demote also cancels the pending renewal");
    }

    /// @notice Finding #2, `poke` path: a permissionless codehash-drift
    ///         demotion must also cancel a same-key pending renewal.
    function test_finding2_poke_cancelsPendingRenewal() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 500, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 9_000, address(0), target.codehash);
        assertTrue(reg.pendingCertificationOf(target, SEL).readyAt != 0);

        vm.etch(target, hex"6001600101");
        vm.prank(makeAddr("rando"));
        reg.poke(target, SEL);

        assertEq(reg.pendingCertificationOf(target, SEL).readyAt, 0, "poke also cancels the pending renewal");
    }

    /// @notice Finding #2: demoting a DIFFERENT key must never touch this
    ///         key's pending certification — the cancellation is scoped to
    ///         the demoted key only. (Complements the existing "demotion
    ///         unaffected" 3.8 tests, which cover the un-demoted side; this
    ///         covers that the new cancel logic doesn't leak across keys.)
    function test_finding2_demote_doesNotCancelUnrelatedKeysPending() public {
        bytes4 otherSel = bytes4(0x99999999);
        vm.prank(owner);
        reg.proposeCertification(target, otherSel, 1, 500, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, otherSel);

        // unrelated pending on SEL
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);

        vm.prank(owner);
        reg.demote(target, otherSel);

        assertTrue(reg.pendingCertificationOf(target, SEL).readyAt != 0, "unrelated key's pending survives");
    }

    /// @notice Finding #3 [85]: once a bond is pinned, only the pinned
    ///         `submitter` may trigger `certify` — a third party must not be
    ///         able to pull the bond off the submitter's standing allowance
    ///         for a certification that party never consented to.
    function test_finding3_nonSubmitterCannotTriggerBondedCertify() public {
        (, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.prank(makeAddr("rando"));
        vm.expectRevert(TierRegistry.NotSubmitter.selector);
        reg.certify(target, SEL);

        // the submitter itself can still trigger it
        vm.prank(submitter);
        reg.certify(target, SEL);
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 0);
    }

    /// @notice Finding #3: even the registry owner — who chose `submitter`
    ///         in the first place — cannot stand in for them at execution.
    ///         Only `msg.sender == p.submitter` satisfies the gate.
    function test_finding3_ownerCannotTriggerBondedCertifyEither() public {
        (, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotSubmitter.selector);
        reg.certify(target, SEL);
    }

    /// @notice Finding #3, negative control: the unbonded case must remain
    ///         fully permissionless — the submitter-gate exists only to
    ///         protect actual fund custody, so a certification with no bond
    ///         at stake must still execute for anyone. (Reaffirms
    ///         `test_certify_succeedsExactlyAtReadyAtByThirdParty`
    ///         explicitly in the context of this remediation.)
    function test_finding3_unbondedCertifyStaysPermissionless() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.prank(makeAddr("anyRando"));
        reg.certify(target, SEL); // must NOT revert NotSubmitter

        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 0);
    }

    /// @notice Finding #5 [80]: `certify` must refuse to execute once
    ///         `MAX_CERTIFY_WINDOW` has elapsed past `readyAt` — bounding how
    ///         stale the pinned bond's real-world value may get before it can
    ///         still post. Mirrors the audit's proof (submitter waits out a
    ///         price collapse before triggering): here we simply prove the
    ///         expiry fires exactly at the boundary, regardless of price.
    function test_finding5_certifyExpiresAfterMaxCertifyWindow() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);

        // still executable exactly at the boundary
        vm.warp(p.readyAt + reg.MAX_CERTIFY_WINDOW());
        vm.prank(makeAddr("rando"));
        reg.certify(target, SEL);
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 0, "still executable exactly at readyAt + MAX_CERTIFY_WINDOW");
    }

    function test_finding5_certifyRevertsOneSecondPastMaxCertifyWindow() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);

        vm.warp(p.readyAt + reg.MAX_CERTIFY_WINDOW() + 1);
        vm.expectRevert(TierRegistry.CertificationExpired.selector);
        reg.certify(target, SEL);

        // the stale pending is not deleted by the failed execution — it is
        // simply permanently unexecutable from here on, same discipline as
        // a codehash-voided pending
        TierRegistry.PendingCertification memory stillPending = reg.pendingCertificationOf(target, SEL);
        assertTrue(stillPending.readyAt != 0);
        (uint8 tier,) = reg.tierOf(target, SEL);
        assertEq(tier, 2, "never certified");
    }

    /// @notice Finding #5: an expired pending is recoverable exactly like a
    ///         codehash-voided one — the owner re-proposes and the fresh
    ///         announcement executes normally.
    function test_finding5_expiredPendingIsRecoverableViaReproposal() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        vm.warp(p.readyAt + reg.MAX_CERTIFY_WINDOW() + 1);
        vm.expectRevert(TierRegistry.CertificationExpired.selector);
        reg.certify(target, SEL);

        vm.prank(owner);
        reg.proposeCertification(target, SEL, 1, 200, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        reg.certify(target, SEL);
        (uint8 tier, uint16 bound) = reg.tierOf(target, SEL);
        assertEq(tier, 1);
        assertEq(bound, 200);
    }

    /// @notice Finding #6 [75]: `proposeCertification` must revert
    ///         `CodehashChanged` when the caller's `expectedCodehash` (what
    ///         the owner actually reviewed off-chain) no longer matches the
    ///         target's LIVE codehash at the moment the transaction mines —
    ///         closing the TOCTOU gap where a third party redeploys
    ///         different bytecode between review and mining.
    function test_finding6_proposeRevertsOnExpectedCodehashMismatch() public {
        bytes32 reviewedHash = target.codehash;

        // a third party — the target's own deployer, not this registry's
        // owner — redeploys different bytecode at the same address between
        // the owner's off-chain review and the proposal transaction mining
        vm.etch(target, hex"6001600101");
        assertTrue(target.codehash != reviewedHash, "sanity: bytecode really did change");

        vm.prank(owner);
        vm.expectRevert(TierRegistry.CodehashChanged.selector);
        reg.proposeCertification(target, SEL, 0, 50, address(0), reviewedHash);

        // no pending record was written by the reverted call
        assertEq(reg.pendingCertificationOf(target, SEL).readyAt, 0);
    }

    /// @notice Finding #6, positive control: passing the CURRENT live
    ///         codehash as `expectedCodehash` (the honest, no-TOCTOU case)
    ///         must succeed exactly as before.
    function test_finding6_proposeSucceedsWhenExpectedCodehashMatches() public {
        vm.prank(owner);
        reg.proposeCertification(target, SEL, 0, 50, address(0), target.codehash);
        TierRegistry.PendingCertification memory p = reg.pendingCertificationOf(target, SEL);
        assertEq(p.codehash, target.codehash);
    }
}
