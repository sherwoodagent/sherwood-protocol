## MODIFIED Requirements

### Requirement: Casting a ballot
`voteOnChallenge(challengeId, convict)` SHALL be callable only on a `Filed` challenge (otherwise `WrongStatus`) and strictly before `filedAt + voteWindowAtFiling` (otherwise `WindowClosed`). It SHALL refuse the challenge's own challenger (`ChallengerCannotVote`), the challenged proposal's pinned proposer AND each of its recorded co-proposers (`ProposerCannotVote`), an accused approver of that challenge (`AccusedCannotVote`) and a second ballot from the same address (`AlreadyVoted`). Co-proposers are named on-chain and take a share of the proposal's performance fee, so they are the same interested-party class as the lead. All three identity bars are checks a second, unlinked address defeats, so they are floors rather than ceilings; what BOUNDS a self-dealing voter is that a ballot counts only stake held since before the proposal executed, so a sybil must have staked before the call it accuses and still hold the quorum of the TOTAL staked WOOD and outweigh the acquit side. Without the bars a filer convicts its own accusation and collects the prosecutor fee for it, and a proposer or co-proposer votes on the challenge that would confiscate the proposer bond. The ballot's weight SHALL be `min(getPastStake(voter, filedAt - 1), getPastStake(voter, executedAt - 1))`, reading the `executedAt` pinned on the challenge at filing: stake added after the proposal executed never stood behind it and carries no vote, and stake removed before the filing is not counted either. The voter MUST be an active guardian (`isActiveGuardian`) with a non-zero weight, otherwise `NoVotableStake`. The weight SHALL be credited to exactly one of `convictWeight` / `acquitWeight`, and `ChallengeVoteCast(challengeId, voter, convict, weight)` SHALL be emitted. The clamp applies to ballots only: `totalStakeAtFiling`, `votableAtFiling`, the quorum and the early-settle bar keep reading `filedAt - 1`, so post-execution stake still enlarges both denominators and can only make a conviction harder. There SHALL be no vote change and no un-vote: the ballot latch is one-shot, which is what lets `resolve` settle a decided tally without waiting for the window. Consequently `convictWeight + acquitWeight <= votableAtFiling <= totalStakeAtFiling` always holds.

#### Scenario: Challenger refused on its own filing
- **WHEN** the address that filed the challenge calls `voteOnChallenge`, holding a guardian seat of its own
- **THEN** the call reverts `ChallengerCannotVote` and neither tally moves

#### Scenario: Proposer refused
- **WHEN** the proposer of the challenged proposal calls `voteOnChallenge`, holding a guardian seat of its own
- **THEN** the call reverts `ProposerCannotVote` and neither tally moves

#### Scenario: Co-proposer refused
- **WHEN** a co-proposer of a collaborative proposal calls `voteOnChallenge`, holding a guardian seat of its own
- **THEN** the call reverts `ProposerCannotVote` and neither tally moves

#### Scenario: Accused approver refused
- **WHEN** an approver whose lock backs the challenged proposal calls `voteOnChallenge`
- **THEN** the call reverts `AccusedCannotVote`, while that approver's stake stays in the denominator

#### Scenario: One ballot per guardian
- **WHEN** a guardian that already voted calls `voteOnChallenge` again, with either value
- **THEN** the call reverts `AlreadyVoted` and neither tally moves

#### Scenario: Ballot after the pinned window refused
- **WHEN** `block.timestamp >= filedAt + voteWindowAtFiling`
- **THEN** `voteOnChallenge` reverts `WindowClosed`, whatever the owner has since done to the live `voteWindow`

#### Scenario: Stake added after execution carries no ballot
- **WHEN** an address with no stake at execution stakes more than the honest non-accused stake one second before a filing and votes convict
- **THEN** the call reverts `NoVotableStake`, that stake still counts in `totalStakeAtFiling` and `votableAtFiling`, and the false challenge fails

#### Scenario: A top-up after execution does not add weight
- **WHEN** a guardian staked before execution tops up after it and then votes
- **THEN** its ballot weighs its stake at `executedAt - 1`

#### Scenario: A stake reduced after execution votes at the lower amount
- **WHEN** a guardian's stake falls between execution and the filing
- **THEN** its ballot weighs its stake at `filedAt - 1`
