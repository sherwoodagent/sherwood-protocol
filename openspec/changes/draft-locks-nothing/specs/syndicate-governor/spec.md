## Purpose

The governor's status seam gains the count the vault's redeem lock now reads:
proposals past Draft, rather than proposals open.

## MODIFIED Requirements

### Requirement: Single open proposal per vault
The governor SHALL bind at most one non-terminal proposal lifecycle to its vault at a time. Both collaborative Drafts and Pending proposals count as binding the vault. The open-proposal count SHALL be incremented when a proposal enters Draft or Pending, and decremented exactly once when it reaches a terminal state (or Settled), with every decrement also stamping the settlement clock so lazily-expired proposals cannot dodge the propose cooldown. The governor SHALL separately track how many of those open proposals are still in Draft, so that `openProposalCount() - draftCount` — the proposals past Draft — is exactly the set that locks the vault's instant redemption. Binding the vault SHALL NOT by itself lock any LP flow: a Draft stamps neither the vote snapshot nor the veto electorate, so nothing that happens during it can move either.

#### Scenario: Draft binds without locking
- **WHEN** a collaborative Draft is open and no other proposal is
- **THEN** `openProposalCount()` is 1 and `lockedProposalCount()` is 0, a second propose reverts `VaultHasOpenProposal`, and instant deposit and instant redeem both remain open on the vault

#### Scenario: The lock arrives with the stamp
- **WHEN** the final co-proposer approves and the proposal enters Pending
- **THEN** `lockedProposalCount()` becomes 1 in the same transaction that records `snapshotTimestamp` and `votableSupply`, so no share can move into the withdrawal queue before the electorate is fixed

### Requirement: Status surface for the vault and observers
The governor SHALL expose the narrow `IProposalStatus` seam the vault consumes — `getActiveProposal()` (id of the executing proposal, 0 if none; nonzero gates instant deposits), `openProposalCount()` (count of proposals binding the vault, Drafts included; gates the owner's rescue paths), `lockedProposalCount()` (those past Draft; nonzero gates instant redemption), and `strategyOf(proposalId)` (scalar strategy adapter, address(0) = none) — plus full read views (`getProposal` with the authoritative resolved state overlaid, `getProposalState`, execute/settlement calls, vote weight and hasVoted, risk envelope, tier, required coverage, cooldown end, capital snapshot, and co-proposers). `getVoteWeight` on a Draft whose snapshot is unset SHALL revert with `ProposalInDraft` rather than silently returning zero.

#### Scenario: getProposal reports resolved state
- **WHEN** `getProposal` is read for a proposal whose stored state lags its time-determined state
- **THEN** the returned struct's `state` field SHALL carry the authoritative resolved value from the single resolver

#### Scenario: The two counts diverge only for a Draft
- **WHEN** the open proposal is Pending, in GuardianReview, Approved or Executed
- **THEN** `lockedProposalCount()` equals `openProposalCount()`; they differ only while a Draft is open
