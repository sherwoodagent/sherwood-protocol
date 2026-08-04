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

    /// @dev The ONE resolver. Pure view over proposal storage; no writes, no
    ///      registry mutation.
    /// @return resolved the authoritative current state.
    /// @return reviewConcluded true iff the proposal passed the vote AND its
    ///         guardian-review window elapsed with a determinable outcome — the
    ///         ONLY condition under which `_commitState` fires the registry
    ///         economic commit. FALSE for a veto-rejection at `voteEnd`, a Draft
    ///         expiry, an already-Approved-to-Expired transition, an Unresolved
    ///         outcome past `reviewEnd`, and a paused registry.
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
            // Escrowed redeem-queue shares are checkpointed into
            // `getPastTotalSupply` (the queue burns them at CLAIM, not at the
            // settle stamp) but the queue auto-delegates to itself and never
            // votes, and every escrowed share already has its settle price
            // stamped and its assets reserved. Left in the denominator they
            // inflate the veto threshold against LPs who hold 100% of the live
            // economics — a whale who queues and stamps a large enough redeem
            // without claiming can make veto arithmetically impossible. Net them
            // out via the queue's own checkpointed voting weight, which equals
            // its escrowed custody balance exactly because it never votes.
            address queue = ISyndicateVault(p.vault).withdrawalQueue();
            uint256 queueVotes = queue == address(0) ? 0 : IVotes(p.vault).getPastVotes(queue, p.snapshotTimestamp);
            uint256 liveSupply = pastTotalSupply > queueVotes ? pastTotalSupply - queueVotes : 0;
            if (liveSupply > 0) {
                uint256 vetoThreshold = (liveSupply * p.vetoThresholdBps) / BPS_DENOMINATOR;
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
    ///      `resolveReview`). `reviewConcluded` is true exactly when the outcome
    ///      is determinable past `reviewEnd` AND the registry can still accept the
    ///      commit, so the reported state never promises an economic commit the
    ///      caller cannot make.
    function _afterVote(StrategyProposal storage p) private view returns (ProposalState, bool) {
        if (block.timestamp <= p.reviewEnd) return (ProposalState.GuardianReview, false);
        // Collapsed review window (`reviewPeriod == 0` at propose time): no review
        // was registered — `propose` skips the push on exactly this condition — so
        // the registry holds no record and `outcomeOf` would answer Unresolved
        // forever, stranding the proposal AND the vault it binds. Treat
        // no-review-configured as cleared, with `reviewConcluded` FALSE since
        // calling `resolveReview` here would revert. Unreachable for a sanctioned
        // deploy; kept as defence in depth for a stub registry.
        if (p.reviewEnd <= p.voteEnd) {
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, false);
        }
        IGuardianRegistry reg = IGuardianRegistry(_guardianRegistry);
        IGuardianRegistry.ReviewOutcome o = reg.outcomeOf(address(this), p.id);
        // Unresolved past `reviewEnd` means `outcomeOf` found no window, i.e. no
        // review was ever registered. `reviewConcluded` is FALSE.
        //
        // TERMINAL AND CLOSED — deliberate asymmetry with the collapsed window
        // above. Both mean no registry record, but here the governor believes a
        // review exists and the registry disagrees; that disagreement must never
        // produce an executable proposal, so this reports Expired rather than
        // Cleared — answering Cleared would approve a proposal no guardian ever
        // reviewed. Expired is terminal, so `_commitState` releases the vault
        // binding rather than leaving both stuck.
        //
        // Unreachable on any deployment this code can produce: governor and
        // registry deploy in lockstep, both push sites register under the
        // identical predicate, `_guardianRegistry` is write-once, and there is no
        // governor-removal path. Kept as defence in depth: do NOT restore Approved
        // here on the grounds that the branch is unreachable.
        if (o == IGuardianRegistry.ReviewOutcome.Unresolved) {
            return (ProposalState.Expired, false);
        }
        // A paused registry cannot accept the economic commit: `resolveReview` is
        // `whenNotPaused` while `outcomeOf` is not. Reporting Approved would hand
        // callers a state every path to act on reverts against, so this reports
        // the honest still-in-review for the duration. `cancelReview` rejects once
        // the review window has closed, so the proposer cannot race a pending
        // `resolveReview` slash via cancel, and a pause outliving `executeBy`
        // still lands on Expired once it lifts.
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
    ///      execution. `registerReview` fires at the Draft -> Pending transition,
    ///      so every terminal path out of Pending leaves an entry a keeper could
    ///      otherwise open at `voteEnd` — and a review opened on a dead proposal
    ///      still slashes its approvers and pins their budget.
    ///
    ///      BEST EFFORT, deliberately. `cancelReview` reverts once block quorum is
    ///      reached and once `reviewEnd` has elapsed; neither may brick a terminal
    ///      transition, and swallowing preserves both guards exactly — a review
    ///      that refuses to cancel is precisely one that SHOULD still resolve and
    ///      slash. Guarded on the same predicate the `registerReview` call sites
    ///      use, since a collapsed window was never registered.
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
