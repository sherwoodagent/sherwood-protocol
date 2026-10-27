# guardian-fleet Specification

## Purpose
Defines how several guardian identities are operated as one production service: which role opens and
resolves reviews, how those instances tolerate racing each other, how identities are isolated from
one another, how a single simulation is shared across differing policies, and what signal tells the
operator whether the layer could still block a proposal right now. The capability exists because a
single guardian daemon cannot keep the review path live, and because the reasons to run several are
narrower than they appear.
## Requirements
### Requirement: Reviews are opened and resolved by a stakeless keeper role

The fleet SHALL run a keeper role that discovers registered reviews, calls `openReview` once the
voting window has elapsed, and calls `resolveReview` once the review window has elapsed. The keeper
SHALL hold no stake and SHALL sign no vote.

The adversary is the protocol's own default. A review that nobody opens is never observed by a
guardian, and the governor's mutating state resolution treats an unopened review as not blocked and
proceeds to execute. The guardian layer is therefore inert unless something actively opens reviews,
and a voter that watches only for opened reviews cannot be that something.

The keeper SHALL be stakeless so that its failures cost liveness and never stake, which is what makes
it safe to run redundantly.

#### Scenario: A registered review reaches its voting deadline

- **WHEN** a registered review's voting window elapses
- **THEN** the keeper calls `openReview` for that governor and proposal

#### Scenario: An opened review reaches its review deadline

- **WHEN** an opened review's review window elapses
- **THEN** the keeper calls `resolveReview`, so that any approver slash lands

#### Scenario: The keeper is asked to vote

- **WHEN** the keeper encounters a review within its voting window
- **THEN** it casts no vote, because voting requires stake it does not hold

### Requirement: Keeper instances are redundant and tolerate racing

The fleet SHALL run more than one keeper instance, each applying randomized delay before sending, and
SHALL treat a losing race as an acceptable cost rather than coordinating to prevent it.

Both entrypoints are permissionless and return early rather than reverting once the work is done, so
a racing instance pays gas for a successful no-op and the resolution and any slash occur exactly
once. The adversary is a single keeper failing silently: one missed review opening removes the entire
cohort's ability to block that proposal, which is a far larger loss than the gas a duplicate
transaction wastes.

#### Scenario: Two keepers act on the same review

- **WHEN** two keeper instances send `openReview` for the same review
- **THEN** the review opens once, the second transaction is a successful no-op, and no state is
  corrupted

#### Scenario: One keeper is down

- **WHEN** any single keeper instance is unavailable at the moment a review becomes openable
- **THEN** another instance opens it within its jitter window

#### Scenario: Work is discovered independently of local state

- **WHEN** a keeper starts with no persisted state
- **THEN** it discovers outstanding reviews from registry registration events and bounds its search
  at the registry's deployment block rather than scanning from genesis

### Requirement: Each guardian identity is an isolated service with its own key

Every voting identity SHALL run as its own service with its own signing key and its own persistent
state, and SHALL NOT share a signing key with any other instance.

Two adversaries. The first is nonce contention: processes sharing one key build transactions at the
same nonce, so one is dropped or replaced, and avoiding that requires leader election the fleet
otherwise does not need. Distinct identities on distinct accounts share no mutable on-chain state and
are independent without coordination. The second is key compromise: one leaked key must cost one
bond rather than the whole position.

#### Scenario: One identity is compromised

- **WHEN** a single guardian's signing key is disclosed
- **THEN** only that identity's bond is at risk, and the remaining identities continue voting

#### Scenario: Two instances would sign as the same identity

- **WHEN** configuration would run two instances with the same signing key
- **THEN** the fleet refuses to start the duplicate rather than contending for nonces

### Requirement: One simulation is shared and each guardian applies its own policy

A proposal SHALL be simulated once per review, its evidence SHALL be recorded, and each guardian
SHALL reach its own verdict by applying its own policy to that shared evidence. The simulating
component SHALL hold no signing key.

Running identical analysis once per guardian is replication rather than diversification: the same
inputs and the same analyser yield the same verdict, so the additional runs decorrelate only
transient infrastructure failures. Because a single operator owns every bond, a correlated slash
costs exactly what slashing one guardian holding the whole position would cost, so there is no
economic exposure being hedged.

Policy divergence between guardians SHALL remain available, because it is genuine position sizing:
only the guardians that approved a blocked proposal are slashed.

#### Scenario: Guardians differ on the same evidence

- **WHEN** two guardians with different policy thresholds evaluate the same evidence record
- **THEN** each casts its own verdict, and only those that approved are exposed to a later slash

#### Scenario: The simulating component is asked to sign

- **WHEN** the simulating component reaches a verdict
- **THEN** it publishes evidence and signs nothing, because it holds no key

#### Scenario: Evidence is unavailable

- **WHEN** the shared simulation fails to produce an evidence record for a review
- **THEN** every guardian abstains for that review rather than voting on absent evidence

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

### Requirement: A voting identity signs only guardian votes

In a fleet deployment, a guardian identity that holds stake SHALL sign only guardian votes — `voteOnProposal`,
`voteBlockEmergencySettle` and `ChallengeGame.voteOnChallenge` — and its own stake management, and
SHALL NOT call `openReview` or `resolveReview`. This is how a guardian agent runs inside a fleet; the guardian-agent `defend` mode signs those two calls only when the agent runs alone. Both calls are permissionless on-chain. The registry opens an unopened review lazily on its
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

