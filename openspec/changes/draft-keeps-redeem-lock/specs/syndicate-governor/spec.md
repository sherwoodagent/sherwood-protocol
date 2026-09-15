## Purpose

The collaborative stamp reads the veto electorate at the snapshot instant, and the
status seam says which selector answers which LP-flow question.

## MODIFIED Requirements

### Requirement: Optimistic passage with veto threshold
The governor SHALL use optimistic governance: no FOR-vote quorum exists. At `voteEnd`, a Pending proposal SHALL be `Rejected` if and only if `votesAgainst >= votableSupply * vetoThresholdBps / 10_000`, where `vetoThresholdBps` is the per-proposal snapshot taken when the proposal entered Pending (a mid-vote parameter change cannot move the bar) and `votableSupply` is the vault's total supply MINUS the withdrawal queue's share balance, recorded at that same Draft → Pending transition. On the direct path both terms SHALL be read live at `propose`: instant redeem is open until that call, so a read at `snapshotTimestamp` would count shares that already left. On the collaborative path both terms SHALL be read at `snapshotTimestamp` (`getPastTotalSupply` and the queue's `getPastVotes`): the redeem lane is open for the whole Draft and the final `approveCollaboration`'s readiness is public, so a live queue term could be shrunk by a same-block `requestRedeem` whose owner keeps snapshot weight. The governor SHALL NOT reconstruct the votable set at resolve. When `votableSupply == 0`, the veto check SHALL be skipped. A proposal not vetoed at voteEnd proceeds into guardian review.

#### Scenario: A same-block queued redeem before the final approve does not shrink the bar
- **WHEN** a holder moves all shares into the withdrawal queue in the block of the final `approveCollaboration`, ahead of it, and then votes Against with snapshot weight
- **THEN** the recorded votable supply SHALL include the queued shares, so the Against weight is measured against the same set the weight came from and a holder below the threshold cannot veto; the shares stay locked for the cycle whether or not the request is cancelled

#### Scenario: Parked queue shares are outside the collaborative electorate
- **WHEN** shares sit in the withdrawal queue from an earlier proposal when a collaborative Draft is stamped
- **THEN** the recorded votable supply SHALL exclude them, read through the queue's checkpointed custody at `snapshotTimestamp`

### Requirement: Status surface for the vault and observers
The governor SHALL expose the narrow `IProposalStatus` seam the vault consumes — `getActiveProposal()` (id of the executing proposal, 0 if none; nonzero gates instant deposits), `openProposalCount()` (count of proposals binding the vault, Drafts included; nonzero gates instant redemption and the owner's rescue paths), and `strategyOf(proposalId)` (scalar strategy adapter, address(0) = none) — plus full read views (`getProposal` with the authoritative resolved state overlaid, `getProposalState`, execute/settlement calls, vote weight and hasVoted, risk envelope, tier, required coverage, cooldown end, capital snapshot, and co-proposers). `getVoteWeight` on a Draft whose snapshot is unset SHALL revert with `ProposalInDraft` rather than silently returning zero.

#### Scenario: getProposal reports resolved state
- **WHEN** `getProposal` is read for a proposal whose stored state lags its time-determined state
- **THEN** the returned struct's `state` field SHALL carry the authoritative resolved value from the single resolver

#### Scenario: The two gates answer different questions
- **WHEN** a collaborative Draft is the only open proposal
- **THEN** `openProposalCount()` is 1 and `getActiveProposal()` is 0: instant redeem is locked, instant deposit is open
