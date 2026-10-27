## ADDED Requirements

### Requirement: A block that cannot reach the snapshot quorum is reported, not cast

When the agent determines a proposal should be blocked, it SHALL compute whether the achievable
block weight can reach the snapshotted block quorum, and when it cannot, SHALL record that the
quorum is unreachable rather than reporting a successful defence.

Both sides are measured at the proposal's snapshot `snapshotAt`, one second before the block in which
it entered Pending: the
denominator is `getPastTotalVotes(snapshotAt)` and each ballot is the voter's raw
`getPastStake(voter, snapshotAt)`, with no age discount. Stake counted at `snapshotAt` that does not vote
still counts in the denominator, so a cohort outweighed by non-voting stake cannot block regardless
of participation. Silently casting a doomed vote would present an undefended protocol as a defended
one.

#### Scenario: Non-voting stake makes the quorum unreachable
- **WHEN** the agent decides to block and the raw snapshot stake of every guardian expected to vote Block is below `blockQuorumBps` of the snapshot total
- **THEN** it records the quorum as unreachable, and its report distinguishes this from a cleared review

## REMOVED Requirements

### Requirement: A block that cannot reach quorum is reported, not cast
**Reason**: It assumed age-weighted ballots against a raw denominator. Ballots are raw `getPastStake` at the proposal's snapshot.
**Migration**: Replaced by "A block that cannot reach the snapshot quorum is reported, not cast".
