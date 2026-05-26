// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "../BatchExecutorLib.sol";
import {IStakedWood} from "./IStakedWood.sol";

/// @title IGuardianRegistry
/// @notice Interface for the slimmed `GuardianRegistry` — review/emergency
///         lifecycle + multi-asset reward pools only. WOOD custody, guardian
///         staking, DPoS delegation, owner bonds, vote checkpoints, and
///         slashing moved to `StakedWood` (sWOOD); see `IStakedWood`.
/// @dev See `docs/superpowers/specs/2026-05-21-swood-staking-split-design.md`.
interface IGuardianRegistry {
    // ── Enums ──
    enum GuardianVoteType {
        None,
        Approve,
        Block
    }

    // ── Errors ──
    error ZeroAddress();
    error NotActiveGuardian();
    error AlreadyVoted();
    error NoVoteChange();
    error VoteChangeLockedOut();
    error NewSideFull();
    error ReviewNotOpen();
    error ReviewNotReadyForResolve();
    error NotGovernor();
    error PoolAlreadyFunded();
    error EmergencyTooManyCalls();
    error EmergencyHashMismatch();
    /// @notice Sherlock #15 (collapsed into this revert): `openEmergency`
    ///         invoked while the existing review is still open OR within
    ///         `reviewPeriod` of a prior `cancelEmergency` on the same
    ///         proposal. The cooldown branch blocks cancel-and-replay
    ///         grinding of guardian block votes.
    error EmergencyAlreadyOpen();
    error ProtocolPaused();
    error AlreadyPaused();
    error NotPausedOrDeadmanNotElapsed();
    error RefundCapExceeded();
    // Reward claims
    error NoPoolFunded();
    error AlreadyClaimed();
    error NotApprover();
    error NoDelegationAtSettle();
    error DelegatePoolEmpty();
    error NoEscrowedAmount();
    error InvalidParameter();
    /// @notice Sherlock #16: `setReviewPeriod` rejected because the new
    ///         review window exceeds sWOOD's `coolDownPeriod`. A review
    ///         window longer than the guardian unstake cooldown would let an
    ///         approver unstake and escape the slash before `resolveReview`.
    error CooldownBelowReviewPeriod();

    // ── Events ──
    event ReviewOpened(uint256 indexed proposalId, uint128 totalStakeAtOpen);
    event CohortTooSmallToReview(uint256 indexed proposalId, uint256 totalStakeAtOpen);
    event GuardianVoteCast(
        uint256 indexed proposalId, address indexed guardian, GuardianVoteType support, uint128 weight
    );
    event GuardianVoteChanged(
        uint256 indexed proposalId, address indexed guardian, GuardianVoteType from, GuardianVoteType to
    );
    event ApproverCapReached(uint256 indexed proposalId);
    /// @notice Emitted when a Block vote is rejected because the blocker
    ///         array has hit `MAX_BLOCKERS_PER_PROPOSAL`. Parallels
    ///         `ApproverCapReached`.
    event BlockerCapReached(uint256 indexed proposalId);
    event ReviewResolved(uint256 indexed proposalId, bool blocked, uint256 slashedAmount);
    event EmergencyReviewOpened(uint256 indexed proposalId, bytes32 callsHash, uint64 reviewEnd);
    event EmergencyReviewCancelled(uint256 indexed proposalId);
    event EmergencyBlockVoteCast(uint256 indexed proposalId, address indexed guardian, uint128 weight);
    event EmergencyReviewResolved(uint256 indexed proposalId, bool blocked, uint256 slashedAmount);
    // Emitted per blocker when a review resolves blocked = true. Merkl's
    // off-chain bot reads this to build the epoch WOOD campaign's Merkle roots.
    event BlockerAttributed(
        uint256 indexed proposalId, uint256 indexed epochId, address indexed blocker, uint256 weight
    );
    event Paused(address indexed by);
    event Unpaused(address indexed by, bool deadman);
    event SlashAppealReserveFunded(address indexed by, uint256 amount);
    event SlashAppealRefunded(address indexed recipient, uint256 amount, uint256 epochId);
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);

    // ── Guardian fns ──
    /// @notice Cast or change a guardian review vote on a proposal. Vote weight
    ///         is read from sWOOD's `getPastVotes` at the review's `openedAt`.
    function voteOnProposal(uint256 proposalId, GuardianVoteType support, uint256 slashBps) external;

    // ── Governor-only (emergency) ──
    function openEmergency(uint256 proposalId, bytes32 callsHash, BatchExecutorLib.Call[] calldata calls) external;
    function cancelEmergency(uint256 proposalId) external;
    function finalizeEmergency(uint256 proposalId) external returns (bool blocked, BatchExecutorLib.Call[] memory calls);

    /// @notice Governor-only: invalidate an open guardian review when the
    ///         proposer cancels the underlying proposal during
    ///         GuardianReview. Marks the review resolved as not-blocked so a
    ///         subsequent permissionless `resolveReview` cannot still slash
    ///         approvers. Mirrors `cancelEmergency` for the standard review
    ///         path. Idempotent on already-resolved reviews. Reverts after
    ///         `reviewEnd` to prevent cancel-after-block-quorum bypass.
    function cancelReview(uint256 proposalId) external;

    // ── Views (emergency) ──
    function isEmergencyOpen(uint256 proposalId) external view returns (bool);

    // ── Permissionless ──
    function openReview(uint256 proposalId) external;
    function resolveReview(uint256 proposalId) external returns (bool blocked);
    function resolveEmergencyReview(uint256 proposalId) external;
    function voteBlockEmergencySettle(uint256 proposalId) external;

    // ── Slash appeal ──
    function fundSlashAppealReserve(uint256 amount) external;
    function refundSlash(address recipient, uint256 amount) external;

    // ── Pause ──
    function pause() external;
    function unpause() external;

    // ── Parameter setters (owner-instant; owner is a multisig with external delay) ──
    function setReviewPeriod(uint256) external;
    function setBlockQuorumBps(uint256) external;

    // ── Views ──
    /// @notice Returns the cached review state for a proposal (Task 25).
    /// @return opened Whether `openReview` was called
    /// @return resolved Whether `resolveReview` has finalized the review
    /// @return blocked Whether guardians reached the block quorum (requires resolved)
    /// @return cohortTooSmall Whether the cohort at open was below MIN_COHORT_STAKE_AT_OPEN
    function getReviewState(uint256 proposalId)
        external
        view
        returns (bool opened, bool resolved, bool blocked, bool cohortTooSmall);

    function reviewPeriod() external view returns (uint256);
    function governor() external view returns (address);
    function factory() external view returns (address);
    function swood() external view returns (IStakedWood);

    /// @notice A vault's bound owner stake. Passthrough to sWOOD —
    ///         `GovernorEmergency` reads it through the registry handle.
    function ownerStake(address vault) external view returns (uint256);

    /// @notice The minimum WOOD a vault owner must bond. Passthrough to sWOOD.
    function minOwnerStake() external view returns (uint256);

    // ── On-chain guardian-fee pool (vault assets) ──
    /// @notice Called by governor in `_distributeFees` after transferring the
    ///         guardian-fee slice to the registry. Stamps the pool with
    ///         `(asset, amount, settledAt)` so approvers + delegators can
    ///         claim pro-rata. See spec §4.8.
    function fundProposalGuardianPool(uint256 proposalId, address asset, uint256 amount) external;

    /// @notice Sherlock #41 — permissionless approver claim. Funds always go to
    ///         `approver`; any third party can call to seed the delegator pool
    ///         even if `approver` never claims themselves. DPoS commission is
    ///         kept by the approver, remainder is stored for delegator claim.
    function claimProposalReward(address approver, uint256 proposalId) external;

    /// @notice Delegator pulls their share from delegate's remainder pool.
    ///         Pool is seeded by the first call to `claimProposalReward` (any
    ///         caller, including third-party — Sherlock #41), so delegators
    ///         are never stranded by an absent approver.
    function claimDelegatorProposalReward(address delegate, uint256 proposalId) external;

    /// @notice Pull previously-escrowed guardian-fee reward after the transfer-
    ///         failure condition has been lifted. Keyed by (proposalId, recipient,
    ///         asset) so cross-proposal drain is impossible.
    function flushUnclaimedApproverFee(uint256 proposalId, address recipient, address asset) external;

    event ProposalGuardianPoolFunded(uint256 indexed proposalId, address indexed asset, uint256 amount);
    event ApproverRewardClaimed(
        uint256 indexed proposalId, address indexed approver, uint256 gross, uint256 commission, uint256 remainder
    );
    event DelegatorProposalRewardClaimed(
        address indexed delegator, address indexed delegate, uint256 indexed proposalId, uint256 share
    );
    event ApproverFeeEscrowed(
        uint256 indexed proposalId, address indexed recipient, address indexed asset, uint256 amount
    );
}
