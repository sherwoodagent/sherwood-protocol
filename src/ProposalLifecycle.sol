// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title ProposalLifecycle
/// @notice Abstract base owning the proposal lifecycle (propose -> vote ->
///         guardian review -> execute -> settle). Exactly one authoritative state
///         per proposal, read via `stateOf` (a TRUE view — never lags
///         determinable reality) and written ONLY by `_transition`.
/// @dev Single-writer invariant: `p.state =` appears nowhere but `_transition`.
///      Single-resolver invariant: `_computeState` is the ONE resolver, a pure
///      view over storage. The registry economic commit fires ONLY in
///      `_commitState`, and ONLY on transitions where the guardian review
///      actually concluded.
abstract contract ProposalLifecycle is ISyndicateGovernor {
    /// @dev BPS denominator for the veto-threshold math. Held as a literal here
    ///      (rather than an inherited constant) so the base is self-contained;
    ///      value matches `GovernorParameters.BPS_DENOMINATOR`.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ── Storage ──────────────────────────────────────────────────────────────
    address internal _guardianRegistry;
    mapping(uint256 => StrategyProposal) internal _proposals;
    uint256 internal _openProposalCount;
    uint256 internal _lastSettledAt;
    /// @notice Draft collaboration deadline per proposal.
    /// @dev Public: the getter's bytecode cost is immaterial under Robinhood's
    ///      98,304-byte limit, and `_computeState` reads this for the Draft ->
    ///      Expired edge so an external reader (and the lifecycle harness)
    ///      legitimately wants it.
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

    function _exitedDuringVote(uint256 proposalId) internal view virtual returns (uint256) {
        proposalId; // silence unused-parameter warning in the default
        return 0;
    }

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
            // Skip the veto check when liveSupply == 0, otherwise the
            // threshold collapses to 0 and every proposal auto-rejects.
            // Reads the vetoThresholdBps snapshot taken at Draft -> Pending,
            // not a live param, so mid-vote finalizes don't move the bar.
            uint256 pastTotalSupply = IVotes(p.vault).getPastTotalSupply(p.snapshotTimestamp);
            address queue = ISyndicateVault(p.vault).withdrawalQueue();
            uint256 queueVotes = queue == address(0) ? 0 : IVotes(p.vault).getPastVotes(queue, p.snapshotTimestamp);
            uint256 liveSupply = pastTotalSupply > queueVotes ? pastTotalSupply - queueVotes : 0;
            uint256 exited = _exitedDuringVote(p.id);
            liveSupply = liveSupply > exited ? liveSupply - exited : 0;
            if (liveSupply > 0) {
                uint256 vetoThreshold = (liveSupply * p.vetoThresholdBps) / BPS_DENOMINATOR;
                // FLOOR AT ONE VOTE. Integer division sends the threshold to
                // zero for any electorate small enough that
                // `liveSupply * bps < BPS_DENOMINATOR`, and `votesAgainst >= 0`
                // is vacuously true -- so a proposal nobody voted on would be
                // Rejected. A veto must always cost at least one vote against.
                if (vetoThreshold == 0) vetoThreshold = 1;
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

    function _afterVote(StrategyProposal storage p) private view returns (ProposalState, bool) {
        if (block.timestamp <= p.reviewEnd) return (ProposalState.GuardianReview, false);
        if (p.reviewEnd <= p.voteEnd) {
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, false);
        }
        IGuardianRegistry reg = IGuardianRegistry(_guardianRegistry);
        IGuardianRegistry.ReviewOutcome o = reg.outcomeOf(address(this), p.id);
        if (o == IGuardianRegistry.ReviewOutcome.Unresolved) {
            bool windowRegistered;
            (bool probeOk, bytes memory ret) =
                address(reg).staticcall(abi.encodeCall(IGuardianRegistry.reviewWindow, (address(this), p.id)));
            if (probeOk && ret.length >= 64) {
                (, uint256 registeredReviewEnd) = abi.decode(ret, (uint256, uint256));
                windowRegistered = registeredReviewEnd != 0;
            }
            // (a) no record: terminal immediately, so `_commitState` releases the
            // vault binding rather than stranding it for the execution window.
            if (!windowRegistered) return (ProposalState.Expired, false);
            // (b) registered and merely deferred: still in review, and still
            // subject to the governor's own unmoved deadline.
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.GuardianReview, false);
        }
        if (reg.paused()) {
            (, bool alreadyResolved,) = reg.getReviewState(address(this), p.id);
            if (!alreadyResolved) return (ProposalState.GuardianReview, false);
        }
        if (o == IGuardianRegistry.ReviewOutcome.Blocked) return (ProposalState.Rejected, true);
        return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, true);
    }

    /// @dev The ONLY place `p.state` is assigned.
    function _transition(StrategyProposal storage p, ProposalState to) internal {
        p.state = to;
    }

    /// @dev Persist the resolved state and, when the guardian review concluded on
    ///      THIS transition, fire the registry economic commit. resolveReview
    ///      runs iff the review actually concluded (vote passed + window elapsed
    ///      + determinable outcome), never for a veto-rejection, a Draft expiry,
    ///      or an already-Approved -> Expired transition.
    function _commitState(StrategyProposal storage p) internal returns (ProposalState resolved) {
        ProposalState stored = p.state;
        bool reviewConcluded;
        (resolved, reviewConcluded) = _computeState(p);

        // EFFECTS first. The economic commit below is an external call that
        // reaches sWOOD's slash path, so every local write lands before it.
        // Callers all hold the shared `_reentrancyStatus` lock today, but CEI
        // here makes that safety structural instead of a property every future
        // caller has to remember.
        if (resolved != stored) {
            _transition(p, resolved);
            // Draft binds the vault — both Draft and non-Draft
            // terminal transitions decrement. Draft additionally emits telemetry.
            if (resolved == ProposalState.Rejected || resolved == ProposalState.Expired) {
                _decOpen();
                if (stored == ProposalState.Draft) emit CollaborationDeadlineExpired(p.id);
            }
        }

        if (reviewConcluded && stored != resolved) {
            (, bool alreadyResolved,) = IGuardianRegistry(_guardianRegistry).getReviewState(address(this), p.id);
            if (!alreadyResolved) {
                bool blocked = IGuardianRegistry(_guardianRegistry).resolveReview(address(this), p.id);
                emit GuardianReviewResolved(p.id, blocked);
            }
        } else if (stored != resolved && (resolved == ProposalState.Rejected || resolved == ProposalState.Expired)) {
            // Terminal WITHOUT a concluded review — the LP veto-rejection edge
            // and the Pending/Approved -> Expired edges. The review was
            // registered at the Draft -> Pending transition and nothing else
            // ever closes it, so without this a keeper can still `openReview`
            // it at `voteEnd` and slash guardians for approving a proposal that
            // can never execute.
            _closeReviewIfRegistered(p);
        }
    }

    function _closeReviewIfRegistered(StrategyProposal storage p) internal {
        if (p.reviewEnd <= p.voteEnd) return;
        try IGuardianRegistry(_guardianRegistry).cancelReview(p.id) {} catch {}
    }

    /// @dev Release a vault binding and stamp the settlement clock.
    function _decOpen() internal {
        --_openProposalCount;
        _lastSettledAt = block.timestamp;
    }
}
