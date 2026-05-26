// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {BlacklistingERC20Mock} from "./mocks/BlacklistingERC20Mock.sol";
import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";

/// @title GuardianRegistryProposalReward — V1.5 Phase 3 Tasks 3.7/3.8/3.9
/// @notice Covers the registry's on-chain guardian-fee claim flow:
///         fundProposalGuardianPool, claimProposalReward (approver + DPoS
///         commission), W-1 escrow, flushUnclaimedApproverFee, and the
///         cross-proposal drain regression.
///
///         Post-split (Task 7.1): guardian staking, delegation, and commission
///         live in `StakedWood`. This suite migrated onto `RegistryTestHarness`
///         — stake/delegate/commission go through `swood`, the registry still
///         owns the reward-split math (`claimProposalReward`,
///         `claimDelegatorProposalReward`). The DPoS-mechanics-only tests live
///         in `StakedWoodDelegation.t.sol`; what remains here is everything
///         that exercises the registry's reward distribution.
contract GuardianRegistryProposalRewardTest is RegistryTestHarness {
    BlacklistingERC20Mock usdc;

    address approver = makeAddr("approver");
    address approver2 = makeAddr("approver2");
    address blocker = makeAddr("blocker");
    address delegator1 = makeAddr("delegator1");
    address delegator2 = makeAddr("delegator2");

    uint256 constant FEE_AMOUNT = 1_000e6; // 1k USDC guardian fee
    uint256 constant PID = 42;

    function setUp() public {
        _deployRegistryAndSwood(24 hours, 3000);
        _enableDelegation();
        usdc = new BlacklistingERC20Mock("USD Coin", "USDC", 6);

        // Cohort-at-open meets MIN_COHORT_STAKE_AT_OPEN (50k) so openReview
        // records weights rather than short-circuiting.
        _stakeGuardian(approver, 20_000e18, 1);
        _stakeGuardian(approver2, 20_000e18, 2);
        _stakeGuardian(blocker, 20_000e18, 3);

        // Pre-fund the registry with USDC (simulates governor's
        // transferPerformanceFee step).
        usdc.mint(address(registry), 10 * FEE_AMOUNT);
    }

    /// @dev Opens a review, has `approverA` and optionally `approverB` vote
    ///      Approve, and `blk` vote Block. Then warps past reviewEnd and
    ///      resolves.
    function _runReview(address approverA, address approverB, address blk) internal {
        uint256 voteEnd = vm.getBlockTimestamp() + 1;
        uint256 reviewEnd = voteEnd + 24 hours + 1;
        governor.setProposal(PID, voteEnd, reviewEnd);

        vm.warp(voteEnd);
        registry.openReview(PID);

        vm.warp(voteEnd + 1);

        vm.prank(approverA);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);

        if (approverB != address(0)) {
            vm.prank(approverB);
            registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);
        }

        if (blk != address(0)) {
            vm.prank(blk);
            registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Block, 0);
        }

        vm.warp(reviewEnd);
        registry.resolveReview(PID);
    }

    function _fundPool() internal {
        vm.prank(address(governor));
        registry.fundProposalGuardianPool(PID, address(usdc), FEE_AMOUNT);
    }

    // ── Single-approver claim path ──

    /// @notice Solo approver with no delegators receives their FULL gross share
    ///         regardless of commission rate (C-1 fix).
    function test_claim_singleApprover_noCommission_allToApprover() public {
        _runReview(approver, address(0), address(0));
        _fundPool();

        uint256 balBefore = usdc.balanceOf(approver);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        assertEq(usdc.balanceOf(approver) - balBefore, FEE_AMOUNT);
    }

    /// @notice Regression for I-A (PR #242 re-review): solo approver who
    ///         requests unstake mid-review still gets their full gross share.
    ///         The own-stake weight lookup at `r.openedAt` (not `settledAt`)
    ///         means a mid-review unstake — which pushes `_stakeCheckpoints=0`
    ///         at requestUnstake time on sWOOD — does not corrupt the attribution.
    ///         Sherlock run #2 #4 (per ana's PR #350 review): the
    ///         `claimProposalReward` gate uses the same `ownW > 0 at
    ///         openedAt` check as voteOnProposal, so this mid-review
    ///         unstake path is the legitimate case the fix preserves —
    ///         the approver carried slashing risk through `resolveReview`
    ///         (Run-2 #16's `coolDownPeriod >= reviewPeriod` invariant
    ///         prevents pre-resolution exit) and gets paid.
    function test_claim_soloApprover_unstakesMidReview_stillGetsFullShare() public {
        vm.prank(approver);
        swood.setCommission(2000); // would otherwise strand remainder

        uint256 voteEnd = vm.getBlockTimestamp() + 1;
        uint256 reviewEnd = voteEnd + 24 hours + 1;
        governor.setProposal(PID, voteEnd, reviewEnd);
        vm.warp(voteEnd);
        registry.openReview(PID);
        vm.warp(voteEnd + 1);
        vm.prank(approver);
        registry.voteOnProposal(PID, IGuardianRegistry.GuardianVoteType.Approve, 0);

        // Approver requests unstake mid-review (_stakeCheckpoints[approver]
        // gets pushed 0 at this moment on sWOOD).
        vm.prank(approver);
        swood.requestUnstakeGuardian();

        vm.warp(reviewEnd);
        registry.resolveReview(PID);
        _fundPool();

        uint256 balBefore = usdc.balanceOf(approver);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        assertEq(usdc.balanceOf(approver) - balBefore, FEE_AMOUNT);
    }

    function test_claim_soloApprover_withCommission_getsFullShare() public {
        vm.prank(approver);
        swood.setCommission(2000); // 20%
        _runReview(approver, address(0), address(0));
        _fundPool();

        uint256 balBefore = usdc.balanceOf(approver);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        assertEq(usdc.balanceOf(approver) - balBefore, FEE_AMOUNT, "solo approver gets full share");
    }

    function test_claim_twoApprovers_equalWeight_halfEach() public {
        vm.prank(approver);
        swood.setCommission(2000);
        vm.prank(approver2);
        swood.setCommission(2000);
        _runReview(approver, approver2, address(0));
        _fundPool();

        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        vm.prank(approver2);
        registry.claimProposalReward(approver2, PID);
        assertEq(usdc.balanceOf(approver), 500e6);
        assertEq(usdc.balanceOf(approver2), 500e6);
    }

    // ── Approver restriction ──

    function test_claim_blocker_reverts() public {
        _runReview(approver, address(0), blocker);
        _fundPool();
        vm.expectRevert(IGuardianRegistry.NotApprover.selector);
        vm.prank(blocker);
        registry.claimProposalReward(blocker, PID);
    }

    function test_claim_nonVoter_reverts() public {
        _runReview(approver, address(0), address(0));
        _fundPool();
        vm.expectRevert(IGuardianRegistry.NotApprover.selector);
        vm.prank(delegator1);
        registry.claimProposalReward(delegator1, PID);
    }

    function test_claim_noPool_reverts() public {
        _runReview(approver, address(0), address(0));
        vm.expectRevert(IGuardianRegistry.NoPoolFunded.selector);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
    }

    function test_claim_double_reverts() public {
        _runReview(approver, address(0), address(0));
        _fundPool();
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        vm.expectRevert(IGuardianRegistry.AlreadyClaimed.selector);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
    }

    /// @notice Regression for PR #260 zero-payout guard.
    function test_claim_zeroPayout_dust_skipsTransferButFlagsClaimed() public {
        _runReview(approver, approver2, address(0));

        // Fund pool with 1 wei. Each of the two equal-weight approvers
        // computes gross = 1 * 20000e18 / 40000e18 = 0 (integer division).
        vm.prank(address(governor));
        registry.fundProposalGuardianPool(PID, address(usdc), 1);

        uint256 balBefore = usdc.balanceOf(approver);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);

        assertEq(usdc.balanceOf(approver) - balBefore, 0, "no transfer for dust share");

        vm.expectRevert(IGuardianRegistry.AlreadyClaimed.selector);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
    }

    // ── Commission-at-settledAt (INV-V1.5-11) ──

    /// @notice Commission rate applied is the rate at settledAt, not claim time
    ///         (INV-V1.5-11).
    function test_claim_commissionFrozenAtSettledAt() public {
        vm.prank(approver);
        swood.setCommission(1000); // 10%
        _delegate(delegator1, approver, 20_000e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        _runReview(approver, address(0), address(0));
        _fundPool(); // stamps settledAt

        // Raise commission AFTER settlement — should not affect this claim.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(approver);
        swood.setCommission(1500);

        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        // own 20k + delegated 20k = 40k vote weight.
        // gross = 1000, grossFromOwn = 500, grossFromDelegated = 500.
        // 10% rate frozen at settledAt: commission = 50, approverPayout = 550.
        assertEq(usdc.balanceOf(approver), 550e6, "own 500 + 10% of delegated 500 = 550");
    }

    // ── Delegator claim ──

    /// @notice Clean 20k own + 20k delegated (10k + 10k), 20% commission.
    function test_claimDelegator_splitsProRata() public {
        vm.prank(approver);
        swood.setCommission(2000);
        _delegate(delegator1, approver, 10_000e18);
        _delegate(delegator2, approver, 10_000e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        _runReview(approver, address(0), address(0));
        _fundPool();

        uint256 aBefore = usdc.balanceOf(approver);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        // own 20k + delegated 20k = 40k. gross=1000, fromOwn=500, fromDeleg=500,
        // commission=100, payout=600, remainder=400.
        assertEq(usdc.balanceOf(approver) - aBefore, 600e6);

        vm.prank(delegator1);
        registry.claimDelegatorProposalReward(approver, PID);
        assertEq(usdc.balanceOf(delegator1), 200e6, "50% * 400 = 200");

        vm.prank(delegator2);
        registry.claimDelegatorProposalReward(approver, PID);
        assertEq(usdc.balanceOf(delegator2), 200e6, "50% * 400 = 200");
    }

    function test_claimDelegator_beforeApproverClaim_reverts() public {
        _delegate(delegator1, approver, 500e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        _runReview(approver, address(0), address(0));
        _fundPool();

        vm.expectRevert(IGuardianRegistry.DelegatePoolEmpty.selector);
        vm.prank(delegator1);
        registry.claimDelegatorProposalReward(approver, PID);
    }

    /// @notice Sherlock #41 — permissionless seeding via the
    ///         `claimProposalReward(approver, pid)` signature.
    function test_claim41_delegatorTriggersApproverClaim_thenClaims() public {
        vm.prank(approver);
        swood.setCommission(2000);
        _delegate(delegator1, approver, 10_000e18);
        _delegate(delegator2, approver, 10_000e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        _runReview(approver, address(0), address(0));
        _fundPool();

        // Approver does NOT call claimProposalReward themselves.
        uint256 approverBefore = usdc.balanceOf(approver);
        vm.prank(delegator1);
        registry.claimProposalReward(approver, PID);

        // Funds went to the APPROVER (not the caller).
        assertEq(usdc.balanceOf(approver) - approverBefore, 600e6, "approver got their 600");
        assertEq(usdc.balanceOf(delegator1), 0, "third-party caller got nothing from approver claim");

        vm.prank(delegator1);
        registry.claimDelegatorProposalReward(approver, PID);
        assertEq(usdc.balanceOf(delegator1), 200e6, "delegator1: 50% of 400 remainder");

        vm.prank(delegator2);
        registry.claimDelegatorProposalReward(approver, PID);
        assertEq(usdc.balanceOf(delegator2), 200e6, "delegator2: 50% of 400 remainder");

        vm.expectRevert(IGuardianRegistry.AlreadyClaimed.selector);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
    }

    function test_claimDelegator_double_reverts() public {
        vm.prank(approver);
        swood.setCommission(2000);
        _delegate(delegator1, approver, 1_000e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        _runReview(approver, address(0), address(0));
        _fundPool();
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        vm.prank(delegator1);
        registry.claimDelegatorProposalReward(approver, PID);

        vm.expectRevert(IGuardianRegistry.AlreadyClaimed.selector);
        vm.prank(delegator1);
        registry.claimDelegatorProposalReward(approver, PID);
    }

    // ── W-1 escrow ──

    function test_claim_blacklistedApprover_escrows() public {
        vm.prank(approver);
        swood.setCommission(2000);
        _runReview(approver, address(0), address(0));
        _fundPool();
        usdc.setBlacklisted(approver, true);

        vm.expectEmit(true, true, true, true);
        emit IGuardianRegistry.ApproverFeeEscrowed(PID, approver, address(usdc), FEE_AMOUNT);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);

        assertEq(registry.unclaimedApproverFees(keccak256(abi.encode(PID, approver, address(usdc)))), FEE_AMOUNT);
    }

    function test_flushUnclaimedApproverFee_retriesAfterUnblacklist() public {
        vm.prank(approver);
        swood.setCommission(2000);
        _runReview(approver, address(0), address(0));
        _fundPool();
        usdc.setBlacklisted(approver, true);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);

        usdc.setBlacklisted(approver, false);
        uint256 balBefore = usdc.balanceOf(approver);
        registry.flushUnclaimedApproverFee(PID, approver, address(usdc));
        assertEq(usdc.balanceOf(approver) - balBefore, FEE_AMOUNT);
        assertEq(registry.unclaimedApproverFees(keccak256(abi.encode(PID, approver, address(usdc)))), 0);
    }

    function test_flushUnclaimedApproverFee_noEscrow_reverts() public {
        vm.expectRevert(IGuardianRegistry.NoEscrowedAmount.selector);
        registry.flushUnclaimedApproverFee(PID, approver, address(usdc));
    }

    // ── Cross-proposal drain regression (PR #229 review finding class) ──

    function test_flush_cannotDrainUnrelatedProposal() public {
        vm.prank(approver);
        swood.setCommission(2000);
        _runReview(approver, address(0), address(0));
        _fundPool();
        usdc.setBlacklisted(approver, true);
        vm.prank(approver);
        registry.claimProposalReward(approver, PID);
        usdc.setBlacklisted(approver, false);

        // Attempt flush with wrong proposalId → no match in keyed mapping.
        vm.expectRevert(IGuardianRegistry.NoEscrowedAmount.selector);
        registry.flushUnclaimedApproverFee(9999, approver, address(usdc));

        // Original escrow still intact.
        assertEq(registry.unclaimedApproverFees(keccak256(abi.encode(PID, approver, address(usdc)))), FEE_AMOUNT);
    }
}
