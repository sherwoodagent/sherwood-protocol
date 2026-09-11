## Purpose

Fix the veto denominator: record the votable set at propose instead of
reconstructing it at resolve from a snapshot read and a live read that cannot
both be right.

## MODIFIED Requirements

### Requirement: Optimistic passage with veto threshold
The governor SHALL use optimistic governance: no FOR-vote quorum exists. At `voteEnd`, a Pending proposal SHALL be `Rejected` if and only if `votesAgainst >= votableSupply * vetoThresholdBps / 10_000`, where `vetoThresholdBps` is the per-proposal snapshot taken when the proposal entered Pending (a mid-vote parameter change cannot move the bar) and `votableSupply` is the vault's total supply MINUS the withdrawal queue's share balance, both read live at that same Draft → Pending transition. The governor SHALL NOT reconstruct the votable set at resolve: `totalSupply()` cannot distinguish a voter's redemption from a claimed queued redemption, so any combination of a snapshot read and a live read is exact for one shape and wrong for the other. When `votableSupply == 0`, the veto check SHALL be skipped (otherwise the threshold collapses to zero and every proposal auto-rejects). A proposal not vetoed at voteEnd proceeds into guardian review.

#### Scenario: Veto threshold reached
- **WHEN** voting ends with `votesAgainst` at or above the snapshotted veto threshold of the recorded votable supply
- **THEN** the proposal SHALL resolve to `Rejected` without traversing guardian review, and no registry economic commit SHALL fire for it

#### Scenario: Silence passes the vote
- **WHEN** voting ends with zero votes cast and a nonzero votable supply
- **THEN** the proposal SHALL proceed to `GuardianReview` (or directly toward Approved if no review window is configured)

#### Scenario: Redeem ordered ahead of propose in the same block
- **WHEN** a holder redeems ahead of `propose` in its block, while other shares sit parked in the withdrawal queue
- **THEN** the recorded votable supply SHALL exclude both the redeemed and the parked shares, so the veto bar is a fraction of the shares that can actually vote and not of a set inflated by either

#### Scenario: Shares queued between the snapshot and propose
- **WHEN** a holder calls `requestRedeem` after `snapshotTimestamp` but before `propose` in the same block
- **THEN** those shares SHALL be outside the recorded votable supply, because they sit in the queue at the instant the electorate is fixed
