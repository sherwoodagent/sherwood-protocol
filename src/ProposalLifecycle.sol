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
    /// @notice Draft collaboration deadline per proposal.
    /// @dev Deliberately `public` here, where the pre-fold governor kept it
    ///      `internal` with a "no auto-getter — bytecode lever" note. That
    ///      rationale was an EIP-170 concession; this stack targets Robinhood's
    ///      98,304-byte limit, where the getter's cost is immaterial, and
    ///      `_computeState` reads this for the Draft -> Expired edge so an
    ///      external reader (and the lifecycle harness) legitimately wants it.
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
    ///         SECURITY INVARIANT on that branch in `_afterVote`), and a paused
    ///         registry (the commit would revert).
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
        // it binds. Treat "no review configured" as cleared, matching the
        // pre-refactor path where the registry resolved a never-opened review
        // to not-blocked. `reviewConcluded` is FALSE: there is no registry
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
        // (`r.reviewEnd == 0`), i.e. no review was ever registered. Treated as
        // "no review configured => cleared", the same answer the collapsed
        // window above gets, instead of fail-closing into a state with no exit
        // (`resolveReview` reverts ReviewNotReadyForResolve, `_openProposalCount`
        // stays pinned, and `emergencyCancel` is Draft/Pending-only).
        // `reviewConcluded` is FALSE: there is no registry review to commit.
        //
        // SECURITY INVARIANT — read before changing how this contract is
        // deployed. This is NOT the same condition as the collapsed window: a
        // collapsed window means the governor KNOWS there is no review; here
        // the governor believes there IS one (`reviewEnd > voteEnd`) and the
        // registry disagrees. Answering Cleared is therefore fail-OPEN — a
        // proposal reaching this branch is Approved and executable with no
        // guardian review at all — where the collapsed-window branch is merely
        // permissive by construction. It is safe only because governor and
        // registry are deployed in lockstep, which makes the branch
        // unreachable:
        //   - both push sites (`propose`, `approveCollaboration`) call
        //     `registerReview` under the identical `reviewEnd > voteEnd`
        //     predicate this function tests, so a registered window exists
        //     whenever we get past the collapsed-window check above;
        //   - `p.reviewEnd` is written only immediately before those pushes,
        //     so the registry's `reviewEnd` can never trail the governor's;
        //   - `_reviews` entries are never deleted and `registerReview` is
        //     `onlyGovernor` (an unauthorised governor reverts at propose time,
        //     it does not silently skip the push);
        //   - `_guardianRegistry` is write-once at `initialize` — the factory's
        //     `setGuardianRegistry` only affects future deployments;
        //   - `_authorizedGovernors` has no `remove`, so a governor cannot be
        //     de-authorised mid-flight.
        // The one state that breaks all of this is a governor whose proposals
        // PREDATE `registerReview`: those hold `reviewEnd > voteEnd` with no
        // registry record, and they would land here and auto-approve. The
        // storage relinearisation in this refactor already forces a fresh
        // deployment (see the beacon constraint pinned in
        // `test/governor/GovernorLayoutPins.t.sol`), which is what keeps them
        // out of reach. Anyone proposing a beacon-migration path for the
        // governor is re-arming a security gate here, not fixing a liveness
        // bug, and must close this branch first.
        if (o == IGuardianRegistry.ReviewOutcome.Unresolved) {
            return (block.timestamp > p.executeBy ? ProposalState.Expired : ProposalState.Approved, false);
        }
        // A paused registry cannot accept the economic commit: `resolveReview`
        // is `whenNotPaused` while `outcomeOf` is not. Reporting Approved here
        // would hand callers a state every path to act on reverts against
        // (`ProtocolPaused` from a contract they never called). Report the
        // honest "still in review" for the duration. This is a view-honesty
        // fix, NOT a liveness one: the hold does not make `cancelProposal`
        // usable again. `cancelReview` is indeed not pause-gated, but this
        // branch is only reachable past `p.reviewEnd`, and `cancelReview`
        // rejects at exactly that point (it refuses once the window has
        // closed, so the proposer cannot race a pending `resolveReview`
        // slash) — the cancel bubbles `ReviewNotOpen` rather than
        // `ProtocolPaused`. A pause outliving `executeBy` still lands on
        // Expired the moment it lifts. Skipped when the registry already
        // cached the resolution: the commit is then a no-op, so the pause
        // cannot strand it.
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
    ///      THIS transition, fire the registry economic commit. Mirrors the
    ///      pre-refactor `_resolveState`: resolveReview runs iff the review
    ///      actually concluded (vote passed + window elapsed + determinable
    ///      outcome), never for a veto-rejection, a Draft expiry, or an
    ///      already-Approved -> Expired transition.
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
            // Sherlock #8: Draft binds the vault — both Draft and non-Draft
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
        // `executeBy` elapsed meanwhile, strand it as Expired. Skipping also
        // restores exact parity with the pre-refactor path, which emitted no
        // governor-side event when the registry resolved the review first.
        if (reviewConcluded && stored != resolved) {
            (, bool alreadyResolved,,) = IGuardianRegistry(_guardianRegistry).getReviewState(address(this), p.id);
            if (!alreadyResolved) {
                bool blocked = IGuardianRegistry(_guardianRegistry).resolveReview(address(this), p.id);
                emit GuardianReviewResolved(p.id, blocked);
            }
        }
    }

    /// @dev Release a vault binding and stamp the settlement clock.
    function _decOpen() internal {
        --_openProposalCount;
        _lastSettledAt = block.timestamp;
    }
}
