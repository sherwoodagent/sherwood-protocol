## MODIFIED Requirements

### Requirement: Fleet health is reported as blockable capacity

The fleet SHALL report whether the guardians that are currently able to act still carry enough weight
to reach the block quorum, computing each identity's weight exactly as the registry does — its raw
stake at the review's snapshot (`getPastStake(identity, snapshotAt)`) against the block quorum over
`getPastTotalVotes(snapshotAt)` — and counting an identity only when its heartbeat is fresh and its gas
balance is funded.

The adversary is a fleet that appears healthy while being unable to block anything. Per-instance
liveness answers whether a process is running, not whether the layer works. Gas belongs in the signal
because an identity with an empty balance is silently non-voting and is otherwise indistinguishable
from a healthy identity that has seen no reviews.

#### Scenario: Enough identities are down to lose the quorum

- **WHEN** the summed snapshot weight of identities with fresh heartbeats and funded balances falls
  below the block quorum against the snapshot staked total
- **THEN** the fleet reports itself as unable to block, distinctly from any individual instance being
  unhealthy

#### Scenario: An identity has run out of gas

- **WHEN** an identity's balance falls below the level needed to send a vote
- **THEN** it is excluded from blockable capacity and reported, rather than counted as healthy

### Requirement: Fleet composition is decided before stake is placed

The fleet's identity count and per-identity stake allocation SHALL be decided before staking. Stake
cannot be moved between identities in part: the source must request unstake in full, which zeroes its
voting weight at once for every review snapshotted after the request, and its WOOD is released only
after the cooldown and once its open exposure has run down. The destination counts at full raw weight
only for reviews whose snapshot falls after it stakes. Rebalancing therefore removes the source's
whole stake from fleet blocking weight from the request until the destination is staked and new
reviews are snapshotted, and this SHALL be reported rather than discovered during an incident.

#### Scenario: Stake is moved between two identities

- **WHEN** an operator moves stake from one guardian identity to another
- **THEN** the source's whole stake leaves fleet blocking weight at its unstake request, the
  destination counts only for reviews snapshotted after it stakes, and the fleet reports the gap

#### Scenario: Adding an identity after staking

- **WHEN** a new identity is funded with freshly staked WOOD
- **THEN** it contributes blocking weight only to reviews whose snapshot falls after its stake

## ADDED Requirements

### Requirement: A voting identity signs only guardian votes

A guardian identity that holds stake SHALL sign only guardian votes — `voteOnProposal`,
`voteBlockEmergencySettle` and `ChallengeGame.voteOnChallenge` — and its own stake management, and
SHALL NOT call `openReview` or `resolveReview`. The registry opens an unopened review lazily on its
first vote, so a voter's ballot can open a review; that is a side effect of voting, not keeper duty.

The adversary is an operator reasoning about blast radius from an incorrect inventory of what a
staked key can do. Keeping keeper duty on separate keys means the redundantly-run role is provably
unslashable and the staked role has a small, auditable signing surface. It also removes the gas cost of
keeper duty from the identities whose balances gate blockable capacity.

#### Scenario: A voter encounters an unopened review past its voting deadline

- **WHEN** a voting identity observes a registered review whose voting window has elapsed but which
  no keeper has opened
- **THEN** it reports the gap and does not call `openReview`; casting its own vote, if it votes, opens the review on-chain

#### Scenario: A voter encounters an unresolved review past its window

- **WHEN** a voting identity observes an opened review whose review window has elapsed
- **THEN** it reports the gap and does not call `resolveReview`

## REMOVED Requirements

### Requirement: A voting identity signs only votes
**Reason**: Staked identities also cast emergency and challenge ballots, and a first vote opens a review on-chain.
**Migration**: Replaced by "A voting identity signs only guardian votes".
