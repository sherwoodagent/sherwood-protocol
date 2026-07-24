// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title ProposalLifecycle
/// @notice Abstract base owning the proposal lifecycle (propose -> vote ->
///         guardian review -> execute -> settle). Exactly one authoritative
///         state per proposal, read via `stateOf` (a TRUE view — never lags
///         determinable reality) and written ONLY by `_transition`.
/// @dev Single-writer invariant: `p.state =` appears nowhere but `_transition`.
///      Single-resolver invariant: `_computeState` is the ONE resolver (no view
///      twin), a pure view over storage. The registry economic commit
///      (`resolveReview`) fires ONLY in `_commitState`, and ONLY on the
///      transitions where the guardian review actually concluded — see the
///      `reviewConcluded` discipline documented on `_computeState`.
abstract contract ProposalLifecycle is ISyndicateGovernor {
    /// @dev BPS denominator for the veto-threshold math. Held as a literal here
    ///      (rather than an inherited constant) so the base is self-contained;
    ///      value matches `GovernorParameters.BPS_DENOMINATOR`.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ── Storage ──────────────────────────────────────────────────────────────
    // Moved here in the later fold task; declared now so the base compiles
    // standalone. Nothing inherits this base yet, so these names do NOT collide
    // with the identical declarations still living in SyndicateGovernor.
    address internal _guardianRegistry;
    mapping(uint256 => StrategyProposal) internal _proposals;
    uint256 internal _openProposalCount;
    uint256 internal _lastSettledAt;
    mapping(uint256 => uint256) public collaborationDeadline;
    uint256[10] private __lifecycleGap;

    /// @notice Reverts parameter mutations while any proposal binds a vault.
    modifier whenNoActiveProposal() {
        if (_openProposalCount > 0) revert ParamsFrozenDuringProposal();
        _;
    }

    /// @notice The authoritative current state of `proposalId`. A TRUE view:
    ///         reports Approved/Rejected/Expired the instant it is determinable,
    ///         never lagging behind a pending `_commitState`.
    function stateOf(uint256 proposalId) public view returns (ProposalState) {
        (ProposalState s,) = _computeState(_proposals[proposalId]);
        return s;
    }

    /// @notice Number of proposals currently binding a vault.
    function openProposalCount() public view virtual returns (uint256) {
        return _openProposalCount;
    }

    /// @dev The ONE resolver. Pure view over proposal storage; no writes, no
    ///      registry mutation.
    /// @return resolved the authoritative current state.
    /// @return reviewConcluded true iff the proposal passed the vote AND its
    ///         guardian-review window elapsed with a determinable outcome — the
    ///         ONLY condition under which `_commitState` fires the registry
    ///         economic commit. FALSE for: a veto-rejection at voteEnd (never
    ///         traversed review), a Draft expiry, an already-Approved -> Expired
    ///         transition (review concluded on a prior commit), and an
    ///         Unresolved outcome past reviewEnd (fail-closed, stays in review).
    ///         This reproduces exactly the set of transitions on which the
    ///         pre-refactor `_resolveState` called `resolveReview`.
    function _computeState(StrategyProposal storage p)
        internal
        view
        returns (ProposalState resolved, bool reviewConcluded)
    {
        ProposalState stored = p.state;

        if (stored == ProposalState.Draft) {
            return (block.timestamp > collaborationDeadline[p.id] ? ProposalState.Expired : ProposalState.Draft, false);
        }

        if (stored == ProposalState.Pending) {
            if (block.timestamp <= p.voteEnd) return (ProposalState.Pending, false);

            // Voting ended — optimistic: approved unless AGAINST votes reach the
            // veto threshold.
            // G-H4: skip the veto check when pastTotalSupply == 0, otherwise the
            // threshold collapses to 0 and every proposal auto-rejects.
            // G-H6: read the vetoThresholdBps snapshot taken at Draft -> Pending,
            // not a live param, so mid-vote finalizes don't move the bar.
            uint256 pastTotalSupply = IVotes(p.vault).getPastTotalSupply(p.snapshotTimestamp);
            if (pastTotalSupply > 0) {
                uint256 vetoThreshold = (pastTotalSupply * p.vetoThresholdBps) / BPS_DENOMINATOR;
                if (p.votesAgainst >= vetoThreshold) {
                    // Veto rejection never traversed guardian review.
                    return (ProposalState.Rejected, false);
                }
            }

            // Voting passed — fall through to guardian-review handling.
            return _afterVote(p);
        }

        if (stored == ProposalState.GuardianReview) {
            return _afterVote(p);
        }

        if (stored == ProposalState.Approved) {
            // The review already concluded on a prior commit; re-committing must
            // NOT re-run resolveReview, so reviewConcluded stays false.
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, false);
        }

        // Executed / Settled / Cancelled / Expired / Rejected: terminal or
        // externally driven — no further passive resolution.
        return (stored, false);
    }

    /// @dev Maps a vote-passed proposal to GuardianReview / Approved / Rejected /
    ///      Expired using the review window and the registry's determinable
    ///      outcome (`outcomeOf`, a pure view sharing one predicate with
    ///      `resolveReview`). reviewConcluded is true exactly when the outcome is
    ///      determinable (Blocked or Cleared) past reviewEnd.
    function _afterVote(StrategyProposal storage p) private view returns (ProposalState, bool) {
        if (block.timestamp <= p.reviewEnd) return (ProposalState.GuardianReview, false);
        IGuardianRegistry.ReviewOutcome o = IGuardianRegistry(_guardianRegistry).outcomeOf(address(this), p.id);
        if (o == IGuardianRegistry.ReviewOutcome.Blocked) return (ProposalState.Rejected, true);
        if (o == IGuardianRegistry.ReviewOutcome.Cleared) {
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, true);
        }
        // Unresolved past reviewEnd: fail-closed, stay in review (no economic commit).
        return (ProposalState.GuardianReview, false);
    }

    /// @dev The ONLY place `p.state` is assigned.
    function _transition(StrategyProposal storage p, ProposalState to) internal {
        p.state = to;
    }

    /// @dev Persist the resolved state and, when the guardian review concluded on
    ///      THIS transition, fire the registry economic commit. Mirrors the
    ///      pre-refactor `_resolveState`: resolveReview runs iff the review
    ///      actually concluded (vote passed + window elapsed + determinable
    ///      outcome), never for a veto-rejection, a Draft expiry, or an
    ///      already-Approved -> Expired transition.
    function _commitState(StrategyProposal storage p) internal returns (ProposalState resolved) {
        ProposalState stored = p.state;
        bool reviewConcluded;
        (resolved, reviewConcluded) = _computeState(p);

        if (reviewConcluded && stored != resolved) {
            bool blocked = IGuardianRegistry(_guardianRegistry).resolveReview(address(this), p.id);
            emit GuardianReviewResolved(p.id, blocked);
        }

        if (resolved != stored) {
            _transition(p, resolved);
            // Sherlock #8: Draft binds the vault — both Draft and non-Draft
            // terminal transitions decrement. Draft additionally emits telemetry.
            if (resolved == ProposalState.Rejected || resolved == ProposalState.Expired) {
                _decOpen();
                if (stored == ProposalState.Draft) emit CollaborationDeadlineExpired(p.id);
            }
        }
    }

    /// @dev Release a vault binding and stamp the settlement clock.
    function _decOpen() internal {
        --_openProposalCount;
        _lastSettledAt = block.timestamp;
    }
}
