## Purpose

The status seam says a Draft counts toward the LP-flow locks. The veto electorate is
specified in the main governor spec (snapshot-only, `veto-votable-supply`).

## MODIFIED Requirements

### Requirement: Status surface for the vault and observers
The governor SHALL expose the narrow `IProposalStatus` seam the vault consumes — `getActiveProposal()` (id of the executing proposal, 0 if none), `openProposalCount()` (count of proposals binding the vault, Drafts included; nonzero gates instant deposit, instant redemption and the owner's rescue paths), and `strategyOf(proposalId)` (scalar strategy adapter, address(0) = none) — plus full read views (`getProposal` with the authoritative resolved state overlaid, `getProposalState`, execute/settlement calls, vote weight and hasVoted, risk envelope, tier, required coverage, cooldown end, capital snapshot, and co-proposers). `getVoteWeight` on a Draft whose snapshot is unset SHALL revert with `ProposalInDraft` rather than silently returning zero.

#### Scenario: getProposal reports resolved state
- **WHEN** `getProposal` is read for a proposal whose stored state lags its time-determined state
- **THEN** the returned struct's `state` field SHALL carry the authoritative resolved value from the single resolver

#### Scenario: A Draft locks both LP flows
- **WHEN** a collaborative Draft is the only open proposal
- **THEN** `openProposalCount()` is 1 and `getActiveProposal()` is 0: instant deposit and instant redeem are both locked
