## MODIFIED Requirements

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
