// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TierRegistry} from "src/TierRegistry.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Split out of TierRegistry.t.sol (issue #174): submitter-bond
///         mechanics (pull/release/claim/conservation) — no test behavior
///         change, same fixture pattern as the sibling
///         TierRegistryCertificationTimelock.t.sol split (own setUp/helpers,
///         no shared abstract base — Solidity inlines inherited code into
///         every concrete contract's deployed bytecode regardless, so a base
///         contract wouldn't shrink the compiled unit that hit the ICE).
contract TierRegistryBondMechanicsTest is Test {
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
        _certifyNow(target, bytes4(0x11111111), 1, 500, submitter);
        assertEq(wood.balanceOf(address(reg)), 10_000e18);
        (uint8 tier,) = reg.tierOf(target, bytes4(0x11111111));
        assertEq(tier, 1);
    }

    function test_certify_zeroBondConfigStillWorks() public {
        // Pre-bond deployments: submitterBondWood == 0 => no pull, certify as before.
        _certifyNow(target, bytes4(0x22222222), 1, 500, address(0));
        (uint8 tier,) = reg.tierOf(target, bytes4(0x22222222));
        assertEq(tier, 1);
    }

    function test_demote_startsReleaseTimelock_claimAfterDelay() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        _certifyNow(target, bytes4(0x33333333), 1, 500, submitter);
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
        _certifyNow(target, bytes4(0x44444444), 1, 500, submitter);
        vm.prank(owner);
        reg.demote(target, bytes4(0x44444444));
        // proposing is NOT bond-gated (D5): the announcement may run while the
        // old bond is still releasing.
        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0x44444444), 1, 500, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert(TierRegistry.BondPendingRelease.selector);
        // pranked as the pinned submitter so the revert exercised is
        // genuinely `BondPendingRelease`, not `NotSubmitter` (finding #3)
        // masking it.
        vm.prank(submitter);
        reg.certify(target, bytes4(0x44444444));
    }

    function test_recertify_whileBondActiveReverts() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        address otherSubmitter = makeAddr("otherSubmitter");
        wood.mint(otherSubmitter, 100_000e18);
        vm.prank(otherSubmitter);
        wood.approve(address(reg), type(uint256).max);

        _certifyNow(target, bytes4(0x55555555), 1, 500, submitter);

        // re-propose + execute with a DIFFERENT submitter: reverts at
        // execution, must not overwrite the live bond
        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0x55555555), 0, 100, otherSubmitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert(TierRegistry.BondActive.selector);
        // pranked as the pinned (new) submitter so the revert exercised is
        // genuinely `BondActive`, not `NotSubmitter` (finding #3) masking it.
        vm.prank(otherSubmitter);
        reg.certify(target, bytes4(0x55555555));

        // re-propose + execute with the SAME submitter: also reverts
        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0x55555555), 0, 100, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert(TierRegistry.BondActive.selector);
        vm.prank(submitter);
        reg.certify(target, bytes4(0x55555555));

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

        _certifyNow(target, bytes4(0x66666666), 1, 500, submitter);
        vm.prank(owner);
        reg.demote(target, bytes4(0x66666666));
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(submitter);
        reg.claimSubmitterBond(target, bytes4(0x66666666));

        // key is clear: a fresh certify with a new submitter succeeds and pulls the new bond
        _certifyNow(target, bytes4(0x66666666), 0, 100, newSubmitter);
        (uint8 tier, uint16 boundBps) = reg.tierOf(target, bytes4(0x66666666));
        assertEq(tier, 0);
        assertEq(boundBps, 100);
        assertEq(wood.balanceOf(newSubmitter), 90_000e18);
        assertEq(wood.balanceOf(address(reg)), 10_000e18);
    }

    // ── Review hardening: conservation, setter bounds, permissionless claim ──

    function test_pokePath_bondLifecycle() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        _certifyNow(target, bytes4(0x77777777), 1, 500, submitter);
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
        _certifyNow(target, bytes4(0x88888888), 1, 500, submitter);
        vm.prank(owner);
        reg.demote(target, bytes4(0x88888888));
        vm.warp(block.timestamp + 14 days + 1);
        reg.claimSubmitterBond(target, bytes4(0x88888888));
        // record deleted: second claim reverts BondNotReleasable (releasableAt back to 0)
        vm.expectRevert(TierRegistry.BondNotReleasable.selector);
        reg.claimSubmitterBond(target, bytes4(0x88888888));
    }

    function test_proposeCertification_zeroAddressSubmitterRevertsWhenBonded() public {
        _bondSetup();
        vm.prank(owner);
        vm.expectRevert(TierRegistry.ZeroAddressSubmitter.selector);
        reg.proposeCertification(target, bytes4(0x99999999), 1, 500, address(0), target.codehash);
    }

    function test_certify_noApprovalReverts() public {
        (ERC20Mock wood,) = _bondSetup();
        address broke = makeAddr("noApproval");
        wood.mint(broke, 100_000e18); // funded but never approved the registry
        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0xaaaaaaaa), 1, 500, broke, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectRevert();
        // pranked as the pinned submitter (finding #3 gates execution to
        // msg.sender == p.submitter whenever a bond is pinned) so the revert
        // exercised here is genuinely the lapsed-allowance failure, not
        // `NotSubmitter` masking it.
        vm.prank(broke);
        reg.certify(target, bytes4(0xaaaaaaaa));
    }

    function test_bondEventsEmitted() public {
        (, address submitter) = _bondSetup();
        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0xbbbbbbbb), 1, 500, submitter, target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        vm.expectEmit(true, true, true, true);
        emit TierRegistry.SubmitterBondLocked(target, bytes4(0xbbbbbbbb), submitter, 10_000e18);
        vm.prank(submitter); // finding #3: execution is submitter-gated once a bond is pinned
        reg.certify(target, bytes4(0xbbbbbbbb));
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
        _certifyNow(target, bytes4(0xcccccccc), 1, 500, submitter);
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
            _certifyNow(target, sels[i], 1, 500, sub);
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

    /// @notice Issue #40 launch-gate pin: with `submitterBondWood` at its
    ///         default (0, unset by any deploy path), `certify` must lock
    ///         nothing and emit no `SubmitterBondLocked` — the unbonded,
    ///         governance-judged certification path this repo actually
    ///         deploys today.
    function test_certifyWithZeroBondLocksNothingAndEmitsNoBondEvent() public {
        assertEq(reg.submitterBondWood(), 0, "fresh TierRegistry defaults to unbonded");

        vm.prank(owner);
        reg.proposeCertification(target, bytes4(0x40404040), 0, 50, address(0), target.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());

        vm.recordLogs();
        reg.certify(target, bytes4(0x40404040));

        assertEq(reg.totalBondedWood(), 0, "no bond locked when submitterBondWood is 0");
        // Exactly one event (TierCertified) — SubmitterBondLocked is emitted
        // ONLY inside the `bondAmount != 0` branch, so its absence here is
        // equivalent to "the only log is TierCertified".
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "certify with a disabled bond must emit only TierCertified, never SubmitterBondLocked");
    }

    // ── Class bonds across an epoch re-point ──

    /// @dev Class analogue of `_certifyNow`: propose as owner, warp past the
    ///      pinned `readyAt`, execute as the pinned submitter.
    function _certifyClassNow(address template_, bytes4 selector_, address submitter_) internal {
        vm.prank(owner);
        reg.proposeClassCertification(template_, selector_, 1, 500, submitter_, template_.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        if (submitter_ != address(0)) {
            vm.prank(submitter_);
        }
        reg.certifyClass(template_, selector_);
    }

    /// @notice The normal class-bond path: demote, wait out the release delay,
    ///         claim. Unchanged by the orphan rule below.
    function test_classDemote_startsReleaseTimelock_claimAfterDelay() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        bytes4 sel = bytes4(0xc1c1c1c1);
        _certifyClassNow(target, sel, submitter);
        assertEq(reg.totalBondedWood(), 10_000e18, "bond locked at certification");

        vm.prank(owner);
        reg.demoteClass(target, sel);
        vm.expectRevert(TierRegistry.BondNotReleasable.selector);
        reg.claimClassSubmitterBond(target, sel);

        vm.warp(vm.getBlockTimestamp() + 14 days + 1);
        reg.claimClassSubmitterBond(target, sel);
        assertEq(wood.balanceOf(submitter), 100_000e18, "submitter made whole");
        assertEq(reg.totalBondedWood(), 0, "and the ledger follows the payout");
    }

    /// @notice A re-point orphans the class configs certified against the old
    ///         template code. The bond behind an orphaned selector warrants
    ///         nothing any more: it is claimable at once, and once claimed the
    ///         selector can be certified again against the new code.
    function test_classBond_orphanedByRepointIsClaimableAndTheSelectorRecertifies() public {
        (ERC20Mock wood, address submitter) = _bondSetup();
        bytes4 selA = bytes4(0xaaaaaaaa);
        bytes4 selB = bytes4(0xbbbbbbbb);

        _certifyClassNow(target, selA, submitter);
        (uint8 tA,) = reg.classTierOf(target, selA);
        assertEq(tA, 1, "precondition: A certified against the old template code");

        // The template's code moves and a sibling selector is certified
        // against it: A's config is orphaned, so nothing can demote it.
        vm.etch(target, hex"600160005260206000f3");
        _certifyClassNow(target, selB, submitter);
        (uint8 tA2,) = reg.classTierOf(target, selA);
        assertEq(tA2, 2, "A no longer resolves");
        assertEq(reg.totalBondedWood(), 20_000e18, "both bonds are still on the books");
        assertEq(wood.balanceOf(submitter), 80_000e18);

        reg.claimClassSubmitterBond(target, selA);
        assertEq(wood.balanceOf(submitter), 90_000e18, "the orphaned bond is paid back");
        assertEq(reg.totalBondedWood(), 10_000e18, "leaving only B's bond");
        assertEq(reg.classBondOf(target, selA).amount, 0, "and the record is gone");

        _certifyClassNow(target, selA, submitter);
        (uint8 tA3,) = reg.classTierOf(target, selA);
        assertEq(tA3, 1, "A certifies again against the new code");
        assertEq(reg.totalBondedWood(), 20_000e18, "under a fresh bond");
        assertEq(wood.balanceOf(submitter), 80_000e18);
    }
}
