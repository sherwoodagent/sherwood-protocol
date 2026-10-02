## MODIFIED Requirements

### Requirement: A block that cannot reach quorum is reported, not cast

When the agent determines a proposal should be blocked, it SHALL compute whether the achievable
block weight can reach the snapshotted block quorum, and when it cannot, SHALL record that the
quorum is unreachable rather than reporting a successful defence.

Both sides are measured at the proposal's propose-time snapshot (`snapshotAt = propose − 1 s`): the
denominator is `getPastTotalVotes(snapshotAt)` and each ballot is the voter's raw
`getPastStake(voter, snapshotAt)`, with no age discount. Stake held at `propose` that does not vote
still counts in the denominator, so a cohort outweighed by non-voting stake cannot block regardless
of participation. Silently casting a doomed vote would present an undefended protocol as a defended
one.

#### Scenario: Non-voting stake makes the quorum unreachable
- **WHEN** the agent decides to block and the raw snapshot stake of every guardian expected to vote Block is below `blockQuorumBps` of the snapshot total
- **THEN** it records the quorum as unreachable, and its report distinguishes this from a cleared review
