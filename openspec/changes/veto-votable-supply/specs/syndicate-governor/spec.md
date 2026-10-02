## MODIFIED Requirements

### Requirement: Optimistic passage with veto threshold
The governor SHALL use optimistic governance: no FOR-vote quorum exists. At `voteEnd`, a Pending proposal SHALL be `Rejected` if and only if `votesAgainst >= max(votableSupply * vetoThresholdBps / 10_000, 1)` (the threshold is floored at one vote, so a small electorate's threshold never rounds to zero), where `vetoThresholdBps` is the per-proposal snapshot taken when the proposal entered Pending (a mid-vote parameter change cannot move the bar) and `votableSupply` is the electorate recorded on entering Pending. On BOTH paths the electorate at an instant `t` is `E(t) = getPastTotalSupply(t) - getPastVotes(withdrawalQueue, t)`, clamped at zero, with the queue term skipped when no queue is wired; every holder is self-delegated, so `E(t)` is exactly the weight castable at `t`. Entering Pending SHALL record `votableSupply = E(snapshotTimestamp)`, and every `vote` SHALL lower it to `E(snapshotTimestamp + 1)` when that is smaller — the same two instants the vote weight reads, so the sum of castable weights SHALL NEVER exceed `votableSupply`. The value read before the first vote is therefore provisional; with no vote cast no veto can pass, so the outcome never depends on it. A holder who acquires shares in the propose second is outside both the electorate and the vote; a holder who exits or queues in the propose second leaves both. When `votableSupply == 0`, the veto check SHALL be skipped (otherwise the threshold collapses to zero and every proposal auto-rejects). A proposal not vetoed at voteEnd proceeds into guardian review.

#### Scenario: Veto threshold reached
- **WHEN** voting ends with `votesAgainst` at or above the snapshotted veto threshold of the recorded `votableSupply`
- **THEN** the proposal SHALL resolve to `Rejected` without traversing guardian review, and no registry economic commit SHALL fire for it

#### Scenario: Share flow in the propose second never inflates the veto bar
- **WHEN** a deposit, an instant redeem or a queued redeem lands in the propose second, on either side of `propose`
- **THEN** once a vote is cast `votableSupply` SHALL NOT exceed `E(snapshotTimestamp + 1)`, and no holder's weight exceeds its own votes at either instant, so a redeem ahead of `propose` followed by a re-deposit after it cannot cast more than the electorate holds

#### Scenario: A veto always costs at least one vote
- **WHEN** `votableSupply * vetoThresholdBps < 10_000` and voting ends with no votes against
- **THEN** the proposal SHALL NOT be rejected, because the threshold is floored at one vote

#### Scenario: Silence passes the vote
- **WHEN** voting ends with zero votes cast and a nonzero `votableSupply`
- **THEN** the proposal SHALL proceed to `GuardianReview` (or directly toward Approved if no review window is configured)
