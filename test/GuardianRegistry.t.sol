// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {StakedWoodDelegation} from "../src/StakedWoodDelegation.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Post-split note (Task 7.1): WOOD custody, guardian staking, owner bonds, DPoS
// delegation, vote checkpoints, slashing + burn all moved to `StakedWood`
// (sWOOD). The pure-staking / owner-bond / burn test contracts that used to
// live here (`GuardianRegistryStakeTest`, `…UnstakeTest`, `…OwnerPrepareTest`,
// `…OwnerBindTest`, `…OwnerUnstakeTest`, `…BondTest`, `…BurnTest`) were DELETED
// — that behaviour is now covered by `StakedWood.t.sol`,
// `StakedWoodDelegation.t.sol`, and `StakedWoodSlashing.t.sol`.
//
// The remaining contracts (init / review / vote / resolve / emergency / appeal
// / pause / param) are migrated onto `RegistryTestHarness`: they deploy BOTH
// the registry and sWOOD and stake guardians through `swood`. Two semantic
// changes versus the pre-split assertions:
//   • `ReviewResolved` / `EmergencyReviewResolved` emit `slashedAmount = 0` —
//     the registry no longer computes the slash; sWOOD owns slashing math.
//   • Burn assertions read `wood.balanceOf(BURN)` (sWOOD burns the WOOD).
// ─────────────────────────────────────────────────────────────────────────────

contract GuardianRegistryInitTest is RegistryTestHarness {
    function setUp() public {
        _deployRegistryAndSwood(24 hours, 3000);
    }

    function test_initialize_setsFields() public view {
        assertEq(registry.owner(), regOwner);
        assertTrue(registry.isAuthorizedGovernor(address(governor)));
        assertEq(registry.factory(), regFactory);
        assertEq(address(registry.swood()), address(swood));
        assertEq(registry.reviewPeriod(), 24 hours);
        assertEq(registry.blockQuorumBps(), 3000);
        assertFalse(registry.paused());
        assertGt(registry.epochGenesis(), 0);
    }

    function test_initialize_revertsOnZeroSwood() public {
        GuardianRegistry impl = new GuardianRegistry(6 hours);
        bytes memory initData =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(0), 24 hours, 3000));
        vm.expectRevert(IGuardianRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }
}

contract GuardianRegistryOpenReviewTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 1;

    // Guardians staked in setUp. `small` cohort (3 × 10_000e18 = 30_000e18) is
    // below MIN_COHORT_STAKE_AT_OPEN (50_000e18); `full` cohort (5 × 10_000e18)
    // exactly meets the threshold.
    address[5] guardians = [address(0xAA01), address(0xAA02), address(0xAA03), address(0xAA04), address(0xAA05)];

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, 3000);
    }

    function _stakeN(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _stakeGuardian(guardians[i], 10_000e18, 1 + i);
        }
        // ToB C-1: openReview snapshots stake at `block.timestamp - 1`. Warp so
        // the checkpoints written above are visible.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function test_openReview_revertsBeforeVoteEnd() public {
        _stakeN(5);
        governor.setProposal(
            PROPOSAL_ID, vm.getBlockTimestamp() + 1 hours, vm.getBlockTimestamp() + 1 hours + REVIEW_PERIOD
        );
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        registry.openReview(address(governor), PROPOSAL_ID);
    }

    function test_openReview_revertsIfProposalMissing() public {
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        registry.openReview(address(governor), PROPOSAL_ID);
    }

    function test_openReview_snapshotsTotalStakeAtOpen() public {
        _stakeN(5); // 50_000e18 total
        uint256 ve = vm.getBlockTimestamp();
        governor.setProposal(PROPOSAL_ID, ve, ve + REVIEW_PERIOD);

        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ReviewOpened(PROPOSAL_ID, 50_000e18);
        registry.openReview(address(governor), PROPOSAL_ID);

        assertEq(swood.totalGuardianStake(), 50_000e18);
    }

    function test_openReview_flagsCohortTooSmall() public {
        _stakeN(3); // 30_000e18 < 50_000e18 threshold
        uint256 ve = vm.getBlockTimestamp();
        governor.setProposal(PROPOSAL_ID, ve, ve + REVIEW_PERIOD);

        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.CohortTooSmallToReview(PROPOSAL_ID, 30_000e18);
        registry.openReview(address(governor), PROPOSAL_ID);
    }

    function test_openReview_idempotent() public {
        _stakeN(5);
        uint256 ve = vm.getBlockTimestamp();
        governor.setProposal(PROPOSAL_ID, ve, ve + REVIEW_PERIOD);
        registry.openReview(address(governor), PROPOSAL_ID);

        // Bump totalGuardianStake by staking a 6th guardian post-open.
        _stakeGuardian(address(0xA6), 10_000e18, 42);
        assertEq(swood.totalGuardianStake(), 60_000e18);

        // Second call is a no-op — must NOT re-snapshot (no ReviewOpened again).
        vm.recordLogs();
        registry.openReview(address(governor), PROPOSAL_ID);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }
}

contract GuardianRegistryVoteTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 1;
    uint256 voteEnd;
    uint256 reviewEnd;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, 3000);

        // Stake 5 guardians × 10_000e18 = 50_000e18 to exactly meet
        // MIN_COHORT_STAKE_AT_OPEN.
        for (uint256 i = 0; i < 5; i++) {
            _stakeGuardian(_guardian(i), 10_000e18, 1 + i);
        }

        // Age-weighted voting: mature the cohort to par so vote-weight
        // assertions below read the full staked amount.
        skip(30 days);

        // ToB C-1: openReview snapshots at `block.timestamp - 1`.
        vm.warp(vm.getBlockTimestamp() + 1);

        voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        governor.setProposal(PROPOSAL_ID, voteEnd, reviewEnd);
    }

    function _guardian(uint256 i) internal pure returns (address) {
        return address(uint160(0xAA00 + i + 1));
    }

    function _openReview() internal {
        registry.openReview(address(governor), PROPOSAL_ID);
    }

    function test_voteOnProposal_approve_updatesApprovers_andWeight() public {
        _openReview();
        address g = _guardian(0);

        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.GuardianVoteCast(PROPOSAL_ID, g, IGuardianRegistry.GuardianVoteType.Approve, 10_000e18);
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function test_voteOnProposal_block_updatesBlockers_andWeight() public {
        _openReview();
        address g = _guardian(1);

        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.GuardianVoteCast(PROPOSAL_ID, g, IGuardianRegistry.GuardianVoteType.Block, 10_000e18);
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
    }

    function test_voteOnProposal_revertsIfReviewNotOpen() public {
        address g = _guardian(0);
        vm.prank(g);
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function test_voteOnProposal_revertsAfterReviewEnd() public {
        _openReview();
        vm.warp(reviewEnd);
        address g = _guardian(0);
        vm.prank(g);
        vm.expectRevert(IGuardianRegistry.ReviewNotOpen.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function test_voteOnProposal_revertsIfNotActiveGuardian() public {
        _openReview();
        address stranger = address(0xDEADBEEF);
        vm.prank(stranger);
        vm.expectRevert(IGuardianRegistry.NotActiveGuardian.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function test_voteOnProposal_snapshotsStake_topUpDeflatesNotInflates() public {
        _openReview();
        address g = _guardian(0);

        // Top up AFTER openReview: the RAW checkpoint is frozen at
        // `r.openedAt`, so the extra 5_000e18 can never inflate vote weight.
        // But the top-up re-anchors the live `stakedAt` forward (weighted
        // average, spec 2026-07-19 §4), and `_ageFactorBps` reads the live
        // anchor — so the past snapshot DEFLATES (drift is deflation-only,
        // never inflation).
        _stakeGuardian(g, 5_000e18, 42);
        assertEq(swood.guardianStake(g), 15_000e18);

        // Vote weight = raw pre-open checkpoint (10_000e18) × re-anchored age
        // factor. Top-up at openedAt+1 shifts stakedAt forward by
        // ceil(5_000·(30d+1)/15_000) = 864_001s → age at openedAt =
        // 2_592_000 − 864_001 = 1_727_999s → factor = 2500 +
        // ⌊7500·1_727_999/2_592_000⌋ = 7499 bps → 7_499e18.
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.GuardianVoteCast(PROPOSAL_ID, g, IGuardianRegistry.GuardianVoteType.Block, 7_499e18);
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
    }

    function test_voteOnProposal_revertsIfSupportIsNone() public {
        _openReview();
        address g = _guardian(0);
        vm.prank(g);
        vm.expectRevert();
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.None);
    }

    function test_voteOnProposal_capHitEmitsEventAndReverts() public {
        // Stake 100 fresh guardians BEFORE openReview so C-1's
        // `openedAt = block.timestamp - 1` snapshot can see their stake.
        uint256 cap = registry.MAX_APPROVERS_PER_PROPOSAL();
        for (uint256 i = 0; i < cap; i++) {
            _stakeGuardian(address(uint160(0x100000 + i)), 10_000e18, 1 + i);
        }
        address last = address(uint160(0x100000 + cap));
        _stakeGuardian(last, 10_000e18, 999);

        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 newVoteEnd = vm.getBlockTimestamp();
        governor.setProposal(PROPOSAL_ID, newVoteEnd, newVoteEnd + REVIEW_PERIOD);
        _openReview();

        for (uint256 i = 0; i < cap; i++) {
            vm.prank(address(uint160(0x100000 + i)));
            registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
        }

        vm.expectEmit(true, false, false, false);
        emit IGuardianRegistry.ApproverCapReached(PROPOSAL_ID);
        vm.prank(last);
        vm.expectRevert(IGuardianRegistry.NewSideFull.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        // 101st Block succeeds — blockers uncapped at this size.
        vm.prank(last);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
    }

    /// @notice ToB I-2 regression: blockers are capped at
    /// `MAX_BLOCKERS_PER_PROPOSAL` so the `_emitBlockerAttribution` loop in
    /// `resolveReview` is bounded.
    function test_voteOnProposal_blockerCapHitEmitsEventAndReverts() public {
        uint256 cap = registry.MAX_BLOCKERS_PER_PROPOSAL();
        for (uint256 i = 0; i < cap; i++) {
            _stakeGuardian(address(uint160(0x300000 + i)), 10_000e18, 1 + i);
        }
        address last = address(uint160(0x300000 + cap));
        _stakeGuardian(last, 10_000e18, 999);

        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 newPid = 42;
        governor.setProposal(newPid, vm.getBlockTimestamp(), vm.getBlockTimestamp() + REVIEW_PERIOD);
        registry.openReview(address(governor), newPid);

        for (uint256 i = 0; i < cap; i++) {
            vm.prank(address(uint160(0x300000 + i)));
            registry.voteOnProposal(address(governor), newPid, IGuardianRegistry.GuardianVoteType.Block);
        }

        vm.expectEmit(true, false, false, false);
        emit IGuardianRegistry.BlockerCapReached(newPid);
        vm.prank(last);
        vm.expectRevert(IGuardianRegistry.NewSideFull.selector);
        registry.voteOnProposal(address(governor), newPid, IGuardianRegistry.GuardianVoteType.Block);
    }
}

contract GuardianRegistryVoteChangeTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 1;
    uint256 voteEnd;
    uint256 reviewEnd;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, 3000);

        for (uint256 i = 0; i < 5; i++) {
            _stakeGuardian(_guardian(i), 10_000e18, 1 + i);
        }

        // ToB C-1: warp past stake checkpoints so openReview can see them.
        vm.warp(vm.getBlockTimestamp() + 1);

        voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        governor.setProposal(PROPOSAL_ID, voteEnd, reviewEnd);
        registry.openReview(address(governor), PROPOSAL_ID);
    }

    function _guardian(uint256 i) internal pure returns (address) {
        return address(uint160(0xAA00 + i + 1));
    }

    function test_voteChange_approveToBlock_updatesArraysAndTallies() public {
        address g = _guardian(0);
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        // Top up stake AFTER first vote: should NOT be reflected on swap.
        _stakeGuardian(g, 5_000e18, 42);

        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.GuardianVoteChanged(
            PROPOSAL_ID, g, IGuardianRegistry.GuardianVoteType.Approve, IGuardianRegistry.GuardianVoteType.Block
        );
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);

        // Switch back to Approve → still original 10_000e18 weight.
        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.GuardianVoteChanged(
            PROPOSAL_ID, g, IGuardianRegistry.GuardianVoteType.Block, IGuardianRegistry.GuardianVoteType.Approve
        );
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function test_voteChange_sameSide_revertsNoVoteChange() public {
        address g = _guardian(0);
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        vm.prank(g);
        vm.expectRevert(IGuardianRegistry.NoVoteChange.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    function test_voteChange_inLockoutWindow_reverts() public {
        address g = _guardian(0);
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        uint256 lockoutStart = reviewEnd - (REVIEW_PERIOD * 1000) / 10_000;
        vm.warp(lockoutStart);

        vm.prank(g);
        vm.expectRevert(IGuardianRegistry.VoteChangeLockedOut.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
    }

    /// @notice Sherlock run #1 finding #42 — first-time voters MUST be subject
    ///         to the same late-vote lockout as vote-changers.
    function test_firstVote_inLockoutWindow_reverts() public {
        uint256 lockoutStart = reviewEnd - (REVIEW_PERIOD * 1000) / 10_000;
        vm.warp(lockoutStart);

        vm.prank(_guardian(0));
        vm.expectRevert(IGuardianRegistry.VoteChangeLockedOut.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
    }

    function test_firstVote_justBeforeLockout_succeeds() public {
        uint256 lockoutStart = reviewEnd - (REVIEW_PERIOD * 1000) / 10_000;
        vm.warp(lockoutStart - 1);

        vm.prank(_guardian(0));
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
    }

    function test_voteChange_justBeforeLockout_succeeds() public {
        address g = _guardian(0);
        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        uint256 lockoutStart = reviewEnd - (REVIEW_PERIOD * 1000) / 10_000;
        vm.warp(lockoutStart - 1);

        vm.prank(g);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
    }

    function test_voteChange_blockToApprove_revertsIfApproverCapFull() public {
        uint256 cap = registry.MAX_APPROVERS_PER_PROPOSAL();
        for (uint256 i = 0; i < cap; i++) {
            _stakeGuardian(address(uint160(0x200000 + i)), 10_000e18, 1 + i);
        }
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 newPid = 2;
        governor.setProposal(newPid, vm.getBlockTimestamp(), vm.getBlockTimestamp() + REVIEW_PERIOD);
        registry.openReview(address(governor), newPid);

        address blockVoter = _guardian(0);
        vm.prank(blockVoter);
        registry.voteOnProposal(address(governor), newPid, IGuardianRegistry.GuardianVoteType.Block);

        for (uint256 i = 0; i < cap; i++) {
            vm.prank(address(uint160(0x200000 + i)));
            registry.voteOnProposal(address(governor), newPid, IGuardianRegistry.GuardianVoteType.Approve);
        }

        // Block voter tries to switch → must revert NewSideFull WITHOUT
        // mutating the old side (check-first-then-apply).
        vm.prank(blockVoter);
        vm.expectRevert(IGuardianRegistry.NewSideFull.selector);
        registry.voteOnProposal(address(governor), newPid, IGuardianRegistry.GuardianVoteType.Approve);

        // Verify blockVoter still holds their Block vote (old side intact).
        vm.prank(blockVoter);
        vm.expectRevert(IGuardianRegistry.NoVoteChange.selector);
        registry.voteOnProposal(address(governor), newPid, IGuardianRegistry.GuardianVoteType.Block);
    }
}

contract GuardianRegistryResolveTest is RegistryTestHarness {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 1;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%
    uint256 voteEnd;
    uint256 reviewEnd;

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, BLOCK_QUORUM_BPS);

        // Stake 5 guardians × 10_000e18 = 50_000e18 — matches
        // MIN_COHORT_STAKE_AT_OPEN.
        for (uint256 i = 0; i < 5; i++) {
            _stakeGuardian(_guardian(i), 10_000e18, 1 + i);
        }

        // Age-weighted voting: mature the cohort to par so quorum/slash math
        // below runs on full stake weight.
        skip(30 days);

        // ToB C-1: warp past stake checkpoints so openReview can see them.
        vm.warp(vm.getBlockTimestamp() + 1);

        voteEnd = vm.getBlockTimestamp();
        reviewEnd = voteEnd + REVIEW_PERIOD;
        governor.setProposal(PROPOSAL_ID, voteEnd, reviewEnd);
    }

    function _guardian(uint256 i) internal pure returns (address) {
        return address(uint160(0xAA00 + i + 1));
    }

    /// @dev Slash severity is DETERMINISTIC (spec 2026-07-19 Part D): a
    ///      quadratic ramp of block-side decisiveness from the block quorum
    ///      (floor `minSlashBps`) to SUPERMAJORITY_BPS (ceiling `maxSlashBps`).
    ///      The 2-blocker shapes below land at 40% decisiveness:
    ///        bBps = 20_000/50_000 = 4000; q = 3000; lo = 1000; hi = 9999
    ///        t    = (4000 − 3000)·1e18/(6667 − 3000) ≈ 0.272702e18
    ///        sev  = 1000 + ⌊8999 · t²/1e36⌋ = 1000 + 669 = 1669 bps
    ///      Tests that exercise the severity curve itself live in
    ///      `GuardianRegistrySeverity.t.sol`.
    function _openAndVote(IGuardianRegistry.GuardianVoteType[5] memory sides) internal {
        registry.openReview(address(governor), PROPOSAL_ID);
        for (uint256 i = 0; i < 5; i++) {
            if (sides[i] == IGuardianRegistry.GuardianVoteType.None) continue;
            vm.prank(_guardian(i));
            registry.voteOnProposal(address(governor), PROPOSAL_ID, sides[i]);
        }
    }

    function test_resolveReview_revertsBeforeReviewEnd() public {
        registry.openReview(address(governor), PROPOSAL_ID);
        vm.warp(reviewEnd - 1);
        vm.expectRevert(IGuardianRegistry.ReviewNotReadyForResolve.selector);
        registry.resolveReview(address(governor), PROPOSAL_ID);
    }

    function test_resolveReview_noReviewOpened_returnsFalse() public {
        vm.warp(reviewEnd);
        // Post-split: the registry no longer computes the slash, so
        // `slashedAmount` is always 0 in `ReviewResolved`.
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ReviewResolved(PROPOSAL_ID, false, 0);
        bool blocked = registry.resolveReview(address(governor), PROPOSAL_ID);
        assertFalse(blocked);
        assertEq(wood.balanceOf(BURN_ADDRESS), 0);
        assertEq(swood.totalGuardianStake(), 50_000e18);
    }

    function test_resolveReview_belowQuorum_returnsFalse_noSlash() public {
        // 2 Approves, 1 Block → block weight = 10_000 = 20% of 50_000 < 30%.
        IGuardianRegistry.GuardianVoteType[5] memory sides = [
            IGuardianRegistry.GuardianVoteType.Approve,
            IGuardianRegistry.GuardianVoteType.Approve,
            IGuardianRegistry.GuardianVoteType.Block,
            IGuardianRegistry.GuardianVoteType.None,
            IGuardianRegistry.GuardianVoteType.None
        ];
        _openAndVote(sides);

        vm.warp(reviewEnd);
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ReviewResolved(PROPOSAL_ID, false, 0);
        bool blocked = registry.resolveReview(address(governor), PROPOSAL_ID);

        assertFalse(blocked);
        assertEq(wood.balanceOf(BURN_ADDRESS), 0);
        // Approvers keep their stake (read from sWOOD).
        assertEq(swood.guardianStake(_guardian(0)), 10_000e18);
        assertEq(swood.guardianStake(_guardian(1)), 10_000e18);
        assertEq(swood.totalGuardianStake(), 50_000e18);
    }

    function test_resolveReview_quorumReached_slashesApprovers_burnsWood() public {
        // 2 Approves, 2 Blocks → block weight = 20_000 = 40% of 50_000 >= 30%.
        IGuardianRegistry.GuardianVoteType[5] memory sides = [
            IGuardianRegistry.GuardianVoteType.Approve,
            IGuardianRegistry.GuardianVoteType.Approve,
            IGuardianRegistry.GuardianVoteType.Block,
            IGuardianRegistry.GuardianVoteType.Block,
            IGuardianRegistry.GuardianVoteType.None
        ];
        _openAndVote(sides);

        uint256 totalStakeBefore = swood.totalGuardianStake();
        // Deterministic severity at 40% decisiveness = 1669 bps (see
        // `_openAndVote` derivation). Per approver: 10_000e18 × 1669 / 10_000
        // = 1_669e18 slashed, 8_331e18 residue.
        uint256 perApprover = 1_669e18;
        uint256 slashTotal = 2 * perApprover;

        vm.warp(reviewEnd);
        // Post-split: `ReviewResolved.slashedAmount` is 0 — sWOOD computes and
        // burns the slash; the registry just records the blocked flag.
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ReviewResolved(PROPOSAL_ID, true, 0);
        bool blocked = registry.resolveReview(address(governor), PROPOSAL_ID);

        assertTrue(blocked);
        // WOOD moved to burn address (burn happens inside sWOOD).
        assertEq(wood.balanceOf(BURN_ADDRESS), slashTotal);
        // Each approver retains 10_000e18 − 1_669e18 = 8_331e18.
        assertEq(swood.guardianStake(_guardian(0)), 8_331e18);
        assertEq(swood.guardianStake(_guardian(1)), 8_331e18);
        // Block voters keep their stake.
        assertEq(swood.guardianStake(_guardian(2)), 10_000e18);
        assertEq(swood.guardianStake(_guardian(3)), 10_000e18);
        // Aggregate totals decremented.
        assertEq(swood.totalGuardianStake(), totalStakeBefore - slashTotal);
    }

    function test_resolveReview_cohortTooSmall_returnsFalseEvenWithBlockVotes() public {
        // Drop 2 guardians via sWOOD unstake → cohort down to 30_000e18.
        vm.prank(_guardian(3));
        swood.requestUnstakeGuardian();
        vm.prank(_guardian(4));
        swood.requestUnstakeGuardian();
        assertEq(swood.totalGuardianStake(), 30_000e18);

        // Sherlock #35 / Run-1 #18: `openReview` now reads the denominator
        // from the `t-1` checkpoint to match the numerator's lookup anchor.
        // Same-block state changes are intentionally invisible to that
        // lookup (closes flash-(de)stake on the openReview block) — advance
        // one second so the cohort drop is visible at `block.timestamp - 1`.
        vm.warp(vm.getBlockTimestamp() + 1);

        registry.openReview(address(governor), PROPOSAL_ID);
        // Remaining 3 active guardians all vote Block — would be 100% block
        // weight, but cohort flag short-circuits to false.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(_guardian(i));
            registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
        }

        vm.warp(reviewEnd);
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ReviewResolved(PROPOSAL_ID, false, 0);
        bool blocked = registry.resolveReview(address(governor), PROPOSAL_ID);
        assertFalse(blocked);
        assertEq(wood.balanceOf(BURN_ADDRESS), 0);
    }

    /// @notice Regression for PR #229 fix: the slash targets the approver's
    ///         at-open stake, NOT the live `stakedAmount`. A guardian that
    ///         tops up between voting and resolution should only lose the
    ///         at-open amount. Sized on sWOOD by the raw own-stake checkpoint
    ///         at `r.openedAt` (spec 2026-07-19 §5), which `resolveReview`
    ///         passes to `swood.slashGuardians`.
    function test_resolveReview_slashesOnlyVoteSnapshot_notTopUp() public {
        address approver = _guardian(0);
        registry.openReview(address(governor), PROPOSAL_ID);
        vm.prank(approver);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        // Top up AFTER voting — should not enlarge the slash.
        _stakeGuardian(approver, 10_000e18, 1);
        assertEq(swood.guardianStake(approver), 20_000e18);

        // 2 Block votes hit quorum: 20_000 / 50_000 = 40% >= 30% → the
        // deterministic severity at 40% decisiveness is 1669 bps (see
        // `_openAndVote` derivation).
        vm.prank(_guardian(1));
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(_guardian(2));
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);

        vm.warp(reviewEnd);
        bool blocked = registry.resolveReview(address(governor), PROPOSAL_ID);
        assertTrue(blocked);

        // Slashed at-open snapshot at 1669 bps: 10_000e18 × 1669/10_000 =
        // 1_669e18. The post-open top-up (10_000e18) is untouched. Live post:
        // 20_000e18 - 1_669e18 = 18_331e18.
        assertEq(swood.guardianStake(approver), 18_331e18, "only at-open snapshot slashed at 1669 bps");
        assertEq(wood.balanceOf(BURN_ADDRESS), 1_669e18, "burn equals snapshot * 1669/10_000");
        // Guardian still active (remaining stake > 0).
        assertTrue(swood.isActiveGuardian(approver), "still active with residual stake");
    }

    function test_resolveReview_idempotent() public {
        IGuardianRegistry.GuardianVoteType[5] memory sides = [
            IGuardianRegistry.GuardianVoteType.Approve,
            IGuardianRegistry.GuardianVoteType.Block,
            IGuardianRegistry.GuardianVoteType.Block,
            IGuardianRegistry.GuardianVoteType.None,
            IGuardianRegistry.GuardianVoteType.None
        ];
        _openAndVote(sides);

        vm.warp(reviewEnd);
        bool first = registry.resolveReview(address(governor), PROPOSAL_ID);
        assertTrue(first);
        uint256 burnedBalance = wood.balanceOf(BURN_ADDRESS);

        // Second call returns cached result, no extra slashing, no extra event.
        vm.recordLogs();
        bool second = registry.resolveReview(address(governor), PROPOSAL_ID);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertEq(second, first);
        assertEq(wood.balanceOf(BURN_ADDRESS), burnedBalance);
    }

    /// @notice Regression for Bug B (fuzzer finding): a guardian who voted
    ///         Approve, then requested unstake before `resolveReview`, gets
    ///         slashed when the review resolves blocked. At 40% decisiveness
    ///         the deterministic severity is 1669 bps (see `_openAndVote`
    ///         derivation), so the post-slash residue is non-zero (8_331e18
    ///         from 10_000e18 own stake) and the ghost-cancel path takes the
    ///         `else` branch in `_slashOne` (stake > 0 — `unstakeRequestedAt`
    ///         NOT cleared). The economic deterrent stays intact: cancel
    ///         succeeds but restores only the post-slash residue.
    function test_cancelUnstake_slashedResidue_allowsCancelButKeepsSlash() public {
        registry.openReview(address(governor), PROPOSAL_ID);
        address approver = _guardian(0);
        vm.prank(approver);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);

        vm.prank(_guardian(1));
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);
        vm.prank(_guardian(2));
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Block);

        // Approver requests unstake between vote and resolve.
        vm.prank(approver);
        swood.requestUnstakeGuardian();
        assertFalse(swood.isActiveGuardian(approver));

        vm.warp(reviewEnd);
        bool blocked = registry.resolveReview(address(governor), PROPOSAL_ID);
        assertTrue(blocked);
        // Deterministic 1_669-bps slash on 10_000e18 leaves 8_331e18 residue.
        assertEq(swood.guardianStake(approver), 8_331e18, "8_331e18 residue after 1669-bps slash");
        assertEq(wood.balanceOf(BURN_ADDRESS), 1_669e18, "16.69% burned");

        // The unstake stamp is preserved (residual stake > 0, `else if` skipped).
        // Cancel now SUCCEEDS — but the guardian restored only the post-slash
        // residue; the slash deterrent is intact.
        vm.prank(approver);
        swood.cancelUnstakeGuardian();
        // Approver is "active" again with only the residue.
        assertTrue(swood.isActiveGuardian(approver));
        assertEq(swood.guardianStake(approver), 8_331e18, "only residue restored");
    }
}

contract GuardianRegistryEmergencyTest is RegistryTestHarness {
    MockERC4626Vault vault;
    address creator = address(0xC0FFEE);
    address stranger = address(0xBAD);

    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 1;
    uint256 constant BLOCK_QUORUM_BPS = 3000; // 30%

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, BLOCK_QUORUM_BPS);

        vault = new MockERC4626Vault();
        vault.setOwner(creator);

        // Bind an owner stake for the vault so emergency slashing has a target.
        // Creator mints, prepares, factory binds — all through sWOOD.
        wood.mint(creator, 100_000e18);
        vm.startPrank(creator);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(10_000e18);
        vm.stopPrank();
        vm.prank(regFactory);
        swood.bindOwnerStake(creator, address(vault));

        // Stake 5 guardians × 10_000e18 = 50_000e18 to match
        // MIN_COHORT_STAKE_AT_OPEN.
        for (uint256 i = 0; i < 5; i++) {
            _stakeGuardian(_guardian(i), 10_000e18, 1 + i);
        }

        // Age-weighted voting: mature the cohort to par so emergency block
        // votes carry full stake weight against the raw snapshot denominator.
        skip(30 days);

        // ToB C-1: warp past stake checkpoints so openEmergency can see them.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _guardian(uint256 i) internal pure returns (address) {
        return address(uint160(0xAA00 + i + 1));
    }

    function _emptyCalls() internal pure returns (BatchExecutorLib.Call[] memory) {
        return new BatchExecutorLib.Call[](0);
    }

    function _emptyCallsHash() internal pure returns (bytes32) {
        return keccak256(abi.encode(_emptyCalls()));
    }

    function _openEmergency() internal returns (uint64 reviewEnd_) {
        reviewEnd_ = uint64(vm.getBlockTimestamp() + REVIEW_PERIOD);
        governor.setProposalWithVault(PROPOSAL_ID, vm.getBlockTimestamp(), reviewEnd_, address(vault));
        vm.prank(address(governor));
        registry.openEmergency(PROPOSAL_ID, _emptyCallsHash(), _emptyCalls());
    }

    function test_openEmergency_onlyGovernor() public {
        vm.prank(stranger);
        vm.expectRevert(IGuardianRegistry.UnauthorizedGovernor.selector);
        registry.openEmergency(PROPOSAL_ID, _emptyCallsHash(), _emptyCalls());
    }

    /// @notice P2 guard: `cancelEmergency` is gated on the factory-registered
    ///         governor set (`addGovernor`). A caller outside that set cannot
    ///         cancel a live emergency review.
    function test_cancelEmergency_onlyGovernor() public {
        _openEmergency();
        vm.prank(stranger);
        vm.expectRevert(IGuardianRegistry.UnauthorizedGovernor.selector);
        registry.cancelEmergency(PROPOSAL_ID);
    }

    function test_openEmergency_snapshotsTotalStakeAtOpen() public {
        // Open with totalGuardianStake = 50_000e18 (snapshot). After opening,
        // stake 5 more guardians → live total = 100_000e18. 2 block votes give
        // 20_000e18 block weight.
        //   - Against snapshot (50_000e18): 40% >= 30% → blocked
        //   - Against live total (100_000e18): 20% < 30% → not blocked
        uint64 expectedEnd = uint64(vm.getBlockTimestamp() + REVIEW_PERIOD);
        bytes32 h = _emptyCallsHash();
        governor.setProposalWithVault(PROPOSAL_ID, vm.getBlockTimestamp(), expectedEnd, address(vault));
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.EmergencyReviewOpened(PROPOSAL_ID, h, expectedEnd);
        vm.prank(address(governor));
        registry.openEmergency(PROPOSAL_ID, h, _emptyCalls());

        // Stake 5 additional guardians post-open → live total → 100_000e18.
        for (uint256 i = 5; i < 10; i++) {
            _stakeGuardian(address(uint160(0xBB00 + i)), 10_000e18, 1 + i);
        }
        assertEq(swood.totalGuardianStake(), 100_000e18);

        // 2 block votes from original cohort → 20_000e18 block weight.
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
        vm.prank(_guardian(1));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        vm.warp(expectedEnd);
        vm.prank(address(governor));
        (bool blocked,) = registry.finalizeEmergency(PROPOSAL_ID);
        // Quorum computed against the 50_000e18 snapshot → blocked.
        assertTrue(blocked);
    }

    function test_voteBlockEmergencySettle_updatesTally() public {
        _openEmergency();

        vm.expectEmit(true, true, false, true);
        emit IGuardianRegistry.EmergencyBlockVoteCast(PROPOSAL_ID, _guardian(0), 10_000e18);
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
    }

    function test_voteBlockEmergencySettle_revertsIfDoubleVote() public {
        _openEmergency();
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        vm.prank(_guardian(0));
        vm.expectRevert(IGuardianRegistry.AlreadyVoted.selector);
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
    }

    function test_finalizeEmergency_beforeEnd_reverts() public {
        uint64 reviewEnd_ = _openEmergency();
        vm.warp(reviewEnd_ - 1);
        vm.prank(address(governor));
        vm.expectRevert(IGuardianRegistry.ReviewNotReadyForResolve.selector);
        registry.finalizeEmergency(PROPOSAL_ID);
    }

    function test_finalizeEmergency_belowQuorum_returnsFalse() public {
        uint64 reviewEnd_ = _openEmergency();
        // 1 blocker = 10_000e18 = 20% of 50_000e18 < 30% → false.
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        vm.warp(reviewEnd_);
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.EmergencyReviewResolved(PROPOSAL_ID, false, 0);
        vm.prank(address(governor));
        (bool blocked,) = registry.finalizeEmergency(PROPOSAL_ID);
        assertFalse(blocked);
        // Owner stake intact.
        assertEq(swood.ownerStake(address(vault)), 10_000e18);
        assertEq(wood.balanceOf(BURN_ADDRESS), 0);
    }

    function test_finalizeEmergency_quorumReached_slashesOwner_burnsWood() public {
        uint64 reviewEnd_ = _openEmergency();
        // 2 blockers = 20_000e18 = 40% of 50_000e18 >= 30% → blocked.
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
        vm.prank(_guardian(1));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        assertEq(swood.ownerStake(address(vault)), 10_000e18);

        vm.warp(reviewEnd_);
        // Post-split: `EmergencyReviewResolved.slashedAmount` is 0 — sWOOD
        // computes and burns the owner bond.
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.EmergencyReviewResolved(PROPOSAL_ID, true, 0);
        vm.prank(address(governor));
        (bool blocked,) = registry.finalizeEmergency(PROPOSAL_ID);

        assertTrue(blocked);
        assertEq(swood.ownerStake(address(vault)), 0);
        assertEq(wood.balanceOf(BURN_ADDRESS), 10_000e18);
    }

    function test_finalizeEmergency_cohortTooSmall_returnsFalse() public {
        // Drain all guardian stake to 0 to exercise the cold-start fallback
        // (`totalStakeAtOpen == 0` branch).
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(_guardian(i));
            swood.requestUnstakeGuardian();
        }
        assertEq(swood.totalGuardianStake(), 0);

        uint64 reviewEnd_ = _openEmergency();
        vm.warp(reviewEnd_);
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.EmergencyReviewResolved(PROPOSAL_ID, false, 0);
        vm.prank(address(governor));
        (bool blocked,) = registry.finalizeEmergency(PROPOSAL_ID);
        assertFalse(blocked);
        assertEq(swood.ownerStake(address(vault)), 10_000e18);
        assertEq(wood.balanceOf(BURN_ADDRESS), 0);
    }

    function test_finalizeEmergency_idempotent() public {
        uint64 reviewEnd_ = _openEmergency();
        vm.prank(_guardian(0));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);
        vm.prank(_guardian(1));
        registry.voteBlockEmergencySettle(address(governor), PROPOSAL_ID);

        vm.warp(reviewEnd_);
        vm.prank(address(governor));
        (bool first,) = registry.finalizeEmergency(PROPOSAL_ID);
        assertTrue(first);
        uint256 burnedBalance = wood.balanceOf(BURN_ADDRESS);

        vm.recordLogs();
        vm.prank(address(governor));
        (bool second,) = registry.finalizeEmergency(PROPOSAL_ID);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
        assertEq(second, first);
        assertEq(wood.balanceOf(BURN_ADDRESS), burnedBalance);
    }
}

contract GuardianRegistryAppealTest is RegistryTestHarness {
    address recipient = address(0xBEEF);
    address stranger = address(0xBAD);

    function setUp() public {
        _deployRegistryAndSwood(24 hours, 3000);

        wood.mint(regOwner, 1_000_000e18);
        vm.prank(regOwner);
        wood.approve(address(registry), type(uint256).max);
    }

    function test_fundSlashAppealReserve_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.fundSlashAppealReserve(1_000e18);
    }

    function test_fundSlashAppealReserve_pullsWoodAndIncrements() public {
        uint256 regBalBefore = wood.balanceOf(address(registry));

        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.SlashAppealReserveFunded(regOwner, 10_000e18);
        vm.prank(regOwner);
        registry.fundSlashAppealReserve(10_000e18);

        assertEq(registry.slashAppealReserve(), 10_000e18);
        assertEq(wood.balanceOf(address(registry)), regBalBefore + 10_000e18);
    }

    function test_refundSlash_onlyOwner() public {
        vm.prank(regOwner);
        registry.fundSlashAppealReserve(10_000e18);

        vm.prank(stranger);
        vm.expectRevert();
        registry.refundSlash(recipient, 100e18);
    }

    function test_refundSlash_revertsZeroRecipient() public {
        vm.prank(regOwner);
        registry.fundSlashAppealReserve(10_000e18);

        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.ZeroAddress.selector);
        registry.refundSlash(address(0), 100e18);
    }

    function test_refundSlash_enforcesEpochCap() public {
        vm.prank(regOwner);
        registry.fundSlashAppealReserve(10_000e18);
        // Cap = 20% of 10_000e18 = 2_000e18.

        vm.prank(regOwner);
        registry.refundSlash(recipient, 1_500e18);
        assertEq(
            registry.refundedInEpoch(((block.timestamp - registry.epochGenesis()) / registry.EPOCH_DURATION())),
            1_500e18
        );

        // Second refund 600e18 same epoch → total 2_100e18 > 2_000e18 → revert.
        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.RefundCapExceeded.selector);
        registry.refundSlash(recipient, 600e18);
    }

    function test_refundSlash_capResetsNextEpoch() public {
        vm.prank(regOwner);
        registry.fundSlashAppealReserve(10_000e18);

        vm.prank(regOwner);
        registry.refundSlash(recipient, 1_500e18);
        // Remaining reserve: 8_500e18.

        vm.warp(registry.epochGenesis() + registry.EPOCH_DURATION());
        uint256 nextEp = ((block.timestamp - registry.epochGenesis()) / registry.EPOCH_DURATION());
        assertEq(registry.refundedInEpoch(nextEp), 0);

        // New cap = 20% of 8_500e18 = 1_700e18. Refund 600e18 fits.
        vm.prank(regOwner);
        registry.refundSlash(recipient, 600e18);
        assertEq(registry.refundedInEpoch(nextEp), 600e18);
    }

    function test_refundSlash_movesWood() public {
        vm.prank(regOwner);
        registry.fundSlashAppealReserve(10_000e18);

        uint256 recBalBefore = wood.balanceOf(recipient);

        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.SlashAppealRefunded(
            recipient, 500e18, ((block.timestamp - registry.epochGenesis()) / registry.EPOCH_DURATION())
        );
        vm.prank(regOwner);
        registry.refundSlash(recipient, 500e18);

        assertEq(wood.balanceOf(recipient), recBalBefore + 500e18);
        assertEq(registry.slashAppealReserve(), 9_500e18);
    }
}

contract GuardianRegistryPauseTest is RegistryTestHarness {
    address alice = address(0xA11CE5);
    address stranger = address(0xBAD);

    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant PROPOSAL_ID = 1;

    function setUp() public {
        _deployRegistryAndSwood(REVIEW_PERIOD, 3000);

        for (uint256 i = 0; i < 5; i++) {
            _stakeGuardian(address(uint160(0xAA01 + i)), 10_000e18, 1 + i);
        }
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _openProposal() internal returns (uint256 voteEnd_, uint256 reviewEnd_) {
        voteEnd_ = vm.getBlockTimestamp();
        reviewEnd_ = voteEnd_ + REVIEW_PERIOD;
        governor.setProposal(PROPOSAL_ID, voteEnd_, reviewEnd_);
        registry.openReview(address(governor), PROPOSAL_ID);
    }

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.pause();
    }

    function test_pause_freezesVoteOnProposal() public {
        _openProposal();

        vm.prank(regOwner);
        registry.pause();

        address g = address(uint160(0xAA01));
        vm.prank(g);
        vm.expectRevert(IGuardianRegistry.ProtocolPaused.selector);
        registry.voteOnProposal(address(governor), PROPOSAL_ID, IGuardianRegistry.GuardianVoteType.Approve);
    }

    // Post-split: guardian staking lives in sWOOD which has no pause. The
    // "pause does not freeze stake/claimUnstake" assertions moved to
    // `StakedWood.t.sol`. The registry pause only gates review voting + claims.

    function test_unpause_byOwner_immediate() public {
        vm.prank(regOwner);
        registry.pause();
        assertTrue(registry.paused());

        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.Unpaused(regOwner, false);
        vm.prank(regOwner);
        registry.unpause();
        assertFalse(registry.paused());
        assertEq(registry.pausedAt(), 0);
    }

    function test_unpause_deadman_afterDelay() public {
        vm.prank(regOwner);
        registry.pause();

        vm.warp(vm.getBlockTimestamp() + registry.DEADMAN_UNPAUSE_DELAY() + 1);

        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.Unpaused(stranger, true);
        vm.prank(stranger);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_unpause_deadman_beforeDelay_reverts() public {
        vm.prank(regOwner);
        registry.pause();

        vm.warp(vm.getBlockTimestamp() + registry.DEADMAN_UNPAUSE_DELAY() - 1);

        vm.prank(stranger);
        vm.expectRevert(IGuardianRegistry.NotPausedOrDeadmanNotElapsed.selector);
        registry.unpause();
    }
}

contract GuardianRegistryParamTest is RegistryTestHarness {
    address stranger = address(0xBAD);

    uint256 constant INIT_REVIEW_PERIOD = 24 hours;
    uint256 constant INIT_BLOCK_QUORUM = 3000;

    function setUp() public {
        _deployRegistryAndSwood(INIT_REVIEW_PERIOD, INIT_BLOCK_QUORUM);
    }

    function test_setReviewPeriod_boundsEnforced() public {
        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        registry.setReviewPeriod(5 hours);

        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        registry.setReviewPeriod(8 days);

        vm.startPrank(regOwner);
        registry.setReviewPeriod(6 hours);
        assertEq(registry.reviewPeriod(), 6 hours);
        registry.setReviewPeriod(7 days);
        assertEq(registry.reviewPeriod(), 7 days);
        vm.stopPrank();
    }

    function test_setReviewPeriod_ownerInstant() public {
        vm.expectEmit(true, false, false, true);
        emit IGuardianRegistry.ParameterChangeFinalized(registry.PARAM_REVIEW_PERIOD(), INIT_REVIEW_PERIOD, 12 hours);
        vm.prank(regOwner);
        registry.setReviewPeriod(12 hours);
        assertEq(registry.reviewPeriod(), 12 hours);
    }

    // ── Sherlock #16: coolDownPeriod >= reviewPeriod cross-contract invariant ──

    /// @notice `setReviewPeriod` must reject a review window longer than the
    ///         sWOOD guardian unstake cooldown — otherwise an approver could
    ///         unstake and escape the slash before `resolveReview` runs.
    function test_setReviewPeriod_revertsAboveCooldown() public {
        // Harness wires cooldown = 7 days. A 8d review period is out of the
        // absolute bound; lower the cooldown floor isn't possible (>= 1d), so
        // exercise the invariant within the [6h, 7d] absolute window by
        // first shrinking the cooldown to 1 day.
        vm.prank(regOwner);
        swood.setCooldownPeriod(1 days);

        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.CooldownBelowReviewPeriod.selector);
        registry.setReviewPeriod(2 days);
    }

    /// @notice `setReviewPeriod` succeeds when `v <= coolDownPeriod`.
    function test_setReviewPeriod_succeedsAtOrBelowCooldown() public {
        // cooldown = 7 days from the harness; review period == cooldown is OK.
        vm.startPrank(regOwner);
        registry.setReviewPeriod(7 days);
        assertEq(registry.reviewPeriod(), 7 days);
        registry.setReviewPeriod(3 days);
        assertEq(registry.reviewPeriod(), 3 days);
        vm.stopPrank();
    }

    function test_setBlockQuorumBps_boundsEnforced() public {
        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        registry.setBlockQuorumBps(999);

        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.InvalidParameter.selector);
        registry.setBlockQuorumBps(10_001);

        vm.startPrank(regOwner);
        registry.setBlockQuorumBps(1_000);
        assertEq(registry.blockQuorumBps(), 1_000);
        registry.setBlockQuorumBps(10_000);
        assertEq(registry.blockQuorumBps(), 10_000);
        vm.stopPrank();
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        registry.setReviewPeriod(12 hours);
        vm.expectRevert();
        registry.setBlockQuorumBps(2_000);
        vm.stopPrank();
    }
}

