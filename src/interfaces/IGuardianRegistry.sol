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
    error InvalidParameter();
    /// @notice Sherlock #16: `setReviewPeriod` rejected because the new
    ///         review window exceeds sWOOD's `coolDownPeriod`. A review
    ///         window longer than the guardian unstake cooldown would let an
    ///         approver unstake and escape the slash before `resolveReview`.
    error CooldownBelowReviewPeriod();
    error UnauthorizedGovernor();

    // ── Events ──
    event GovernorAdded(address indexed governor);
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
        address indexed governor, uint256 indexed proposalId, uint256 epochId, address indexed blocker, uint256 weight
    );
    event Paused(address indexed by);
    event Unpaused(address indexed by, bool deadman);
    event SlashAppealReserveFunded(address indexed by, uint256 amount);
    event SlashAppealRefunded(address indexed recipient, uint256 amount, uint256 epochId);
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);

    // ── Guardian fns ──
    /// @notice Cast or change a guardian review vote on a proposal. Vote weight
    ///         is read from sWOOD's `getPastVotes` at the review's `openedAt`.
    ///         Block votes carry no proposed severity — the slash severity is
    ///         a deterministic function of block-side decisiveness, computed
    ///         at `resolveReview` (spec 2026-07-19 Part D).
    function voteOnProposal(address governor, uint256 proposalId, GuardianVoteType support) external;

    // ── Multi-governor management ──
    function addGovernor(address governor) external;

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
    function isEmergencyOpen(address governor, uint256 proposalId) external view returns (bool);

    // ── Permissionless ──
    function openReview(address governor, uint256 proposalId) external;
    function resolveReview(address governor, uint256 proposalId) external returns (bool blocked);
    function resolveEmergencyReview(address governor, uint256 proposalId) external;
    function voteBlockEmergencySettle(address governor, uint256 proposalId) external;

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
    /// @notice Returns the cached review state for a proposal.
    /// @return opened Whether `openReview` was called
    /// @return resolved Whether `resolveReview` has finalized the review
    /// @return blocked Whether guardians reached the block quorum (requires resolved)
    /// @return cohortTooSmall Whether the cohort at open was below MIN_COHORT_STAKE_AT_OPEN
    function getReviewState(address governor, uint256 proposalId)
        external
        view
        returns (bool opened, bool resolved, bool blocked, bool cohortTooSmall);

    /// @notice Per-proposal approver set + their snapshot vote weights + the
    ///         summed approve-weight denominator. Read by the off-chain Merkl bot.
    function getApproverWeights(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 totalApproveWeight);

    function reviewPeriod() external view returns (uint256);
    function factory() external view returns (address);
    function swood() external view returns (IStakedWood);

    /// @notice A vault's bound owner stake. Passthrough to sWOOD —
    ///         `GovernorEmergency` reads it through the registry handle.
    function ownerStake(address vault) external view returns (uint256);

    /// @notice The minimum WOOD a vault owner must bond. Passthrough to sWOOD.
    function minOwnerStake() external view returns (uint256);
    function requiredOwnerBond(address vault) external view returns (uint256);
}
