## MODIFIED Requirements

### Requirement: Status surface for the vault and observers
The governor SHALL expose the narrow `IProposalStatus` seam the vault consumes — `getActiveProposal()` (id of the executing proposal, 0 if none), `openProposalCount()` (count of proposals binding the vault, Drafts included; nonzero gates instant deposit, instant redemption and the owner's rescue paths), and `strategyOf(proposalId)` (scalar strategy adapter, address(0) = none) — plus full read views (`getProposal` with the authoritative resolved state overlaid, `getProposalState`, execute/settlement calls, vote weight and hasVoted, risk envelope, tier, required coverage, cooldown end, capital snapshot, and co-proposers). `getVoteWeight` on a Draft whose snapshot is unset SHALL revert with `ProposalInDraft` rather than silently returning zero; otherwise it SHALL return the weight `vote` would record — the same end-of-propose-second cap — and zero while `block.timestamp <= snapshotTimestamp + 1`, when no vote can be cast yet.

#### Scenario: getProposal reports resolved state
- **WHEN** `getProposal` is read for a proposal whose stored state lags its time-determined state
- **THEN** the returned struct's `state` field SHALL carry the authoritative resolved value from the single resolver

#### Scenario: Draft vote weight query rejected
- **WHEN** `getVoteWeight` is called for a proposal still in Draft
- **THEN** the call SHALL revert with `ProposalInDraft`

#### Scenario: Vote weight view agrees with vote
- **WHEN** `getVoteWeight` is read for a holder who redeemed ahead of `propose` in its second, after that second has ended
- **THEN** it SHALL return zero, matching `vote` reverting with `NoVotingPower`; for any other holder it SHALL equal the weight `vote` records

#### Scenario: A Draft locks both LP flows
- **WHEN** a collaborative Draft is the only open proposal
- **THEN** `openProposalCount()` is 1 and `getActiveProposal()` is 0: instant deposit and instant redeem are both locked
