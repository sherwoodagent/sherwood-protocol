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

    /// @dev The ONE resolver. Pure view over proposal storage; no writes, no
    ///      registry mutation.
    /// @return resolved the authoritative current state.
    /// @return reviewConcluded true iff the proposal passed the vote AND its
    ///         guardian-review window elapsed with a determinable outcome — the
    ///         ONLY condition under which `_commitState` fires the registry
    ///         economic commit. FALSE for: a veto-rejection at voteEnd (never
    ///         traversed review), a Draft expiry, an already-Approved -> Expired
    ///         transition (review concluded on a prior commit), an Unresolved
    ///         outcome past reviewEnd (no registered review to commit — see the
    ///         TERMINAL AND CLOSED note on that branch in `_afterVote`), and a paused
    ///         registry (the commit would revert).
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
            // Skip the veto check when pastTotalSupply == 0, otherwise the
            // threshold collapses to 0 and every proposal auto-rejects.
            // Reads the vetoThresholdBps snapshot taken at Draft -> Pending,
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
    ///      determinable (Blocked or Cleared) past reviewEnd AND the registry can
    ///      still accept the commit — it is false for an unregistered window and
    ///      while the registry is paused, so the reported state never promises an
    ///      economic commit the caller cannot make.
    function _afterVote(StrategyProposal storage p) private view returns (ProposalState, bool) {
        if (block.timestamp <= p.reviewEnd) return (ProposalState.GuardianReview, false);
        // Collapsed review window (`reviewPeriod == 0` at propose time): no
        // review was registered — `propose` skips the push on exactly this
        // condition — so the registry holds no record and `outcomeOf` would
        // answer Unresolved forever, stranding the proposal AND the vault that
        // it binds. Treat "no review configured" as cleared.
        // `reviewConcluded` is FALSE: there is no registry
        // review to commit, and calling `resolveReview` here would revert.
        // The `initialize` floor in GuardianRegistry makes this unreachable for
        // a sanctioned deploy; kept as defence in depth for a stub registry
        // wired through `setGuardianRegistry`.
        if (p.reviewEnd <= p.voteEnd) {
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, false);
        }
        IGuardianRegistry reg = IGuardianRegistry(_guardianRegistry);
        IGuardianRegistry.ReviewOutcome o = reg.outcomeOf(address(this), p.id);
        // Unresolved past `reviewEnd` means `outcomeOf` found no window
        // (`r.reviewEnd == 0`), i.e. no review was ever registered.
        // `reviewConcluded` is FALSE: there is no registry review to commit.
        //
        // TERMINAL AND CLOSED — deliberate asymmetry with the collapsed
        // window above. Both mean "no registry record", but here the
        // governor believes a review exists (`reviewEnd > voteEnd`) and the
        // registry disagrees; that disagreement must never produce an
        // executable proposal, so this reports Expired rather than Cleared
        // or GuardianReview — answering Cleared here would approve a
        // proposal no guardian ever reviewed. Expired is terminal:
        // `_commitState` runs `_decOpen()` on it, releasing the vault
        // binding rather than leaving the proposal and vault stuck.
        //
        // This branch is unreachable on any deployment this code can
        // produce: governor and registry deploy in lockstep, both push
        // sites (`propose`, `approveCollaboration`) register the review
        // under the identical `reviewEnd > voteEnd` predicate,
        // `_guardianRegistry` is write-once, and `_authorizedGovernors` has
        // no `remove`. Kept as defence in depth: do NOT restore Approved
        // here on the grounds that the branch is unreachable.
        if (o == IGuardianRegistry.ReviewOutcome.Unresolved) {
            return (ProposalState.Expired, false);
        }
        // A paused registry cannot accept the economic commit: `resolveReview`
        // is `whenNotPaused` while `outcomeOf` is not. Reporting Approved here
        // would hand callers a state every path to act on reverts against
        // (`ProtocolPaused` from a contract they never called), so this
        // reports the honest "still in review" for the duration.
        // `cancelReview` rejects once the review window has closed (bubbling
        // `ReviewNotOpen`), so the proposer cannot race a pending
        // `resolveReview` slash via cancel. A pause outliving `executeBy`
        // still lands on Expired once it lifts. Skipped when the registry
        // already cached the resolution, since the commit is then a no-op.
        if (reg.paused()) {
            (, bool alreadyResolved,,) = reg.getReviewState(address(this), p.id);
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

        // INTERACTION. Fire the registry's economic commit only when this call
        // is what concluded the review AND the registry has not committed it
        // already. Skipping the redundant call matters for more than gas:
        // `resolveReview` is `whenNotPaused` while `outcomeOf` is not, so a
        // review resolved out-of-band before a pause would otherwise make every
        // mutating entrypoint for this proposal revert until unpause — and if
        // `executeBy` elapsed meanwhile, strand it as Expired.
        if (reviewConcluded && stored != resolved) {
            (, bool alreadyResolved,,) = IGuardianRegistry(_guardianRegistry).getReviewState(address(this), p.id);
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

    /// @dev Close a registered guardian review whose proposal died before
    ///      execution. `registerReview` fires at the Draft -> Pending
    ///      transition, so every terminal path out of Pending leaves an entry a
    ///      keeper could otherwise open at `voteEnd`; a review opened on a dead
    ///      proposal still slashes its approvers, and each approve still books
    ///      coverage that pins their budget and their `claimUnstakeGuardian`.
    ///
    ///      BEST EFFORT, deliberately. `cancelReview` reverts once block quorum
    ///      is reached (the anti-dodge guard) and once
    ///      `reviewEnd` has elapsed. Neither may brick a terminal transition,
    ///      and swallowing preserves both guards exactly: a review that refuses
    ///      to cancel is precisely one that SHOULD still resolve and slash.
    ///
    ///      Guarded on the same `reviewEnd > voteEnd` predicate the
    ///      `registerReview` call sites use — a collapsed window was never
    ///      registered, so there is nothing to close.
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
