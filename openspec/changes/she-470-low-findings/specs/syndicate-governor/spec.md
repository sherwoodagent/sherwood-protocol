# syndicate-governor (delta)

## ADDED Requirements

### Requirement: A registry pause cannot hold a proposal past executeBy
While the guardian registry is paused and a proposal's review outcome is determinable but not yet resolved, the resolver SHALL report `GuardianReview` only until `executeBy`; once `block.timestamp > executeBy` it SHALL report `Expired`, as the sibling review branches do. A committed `Expired` releases the vault binding; approver slashes remain collectable through the registry's permissionless `resolveReview` after unpause.

#### Scenario: Paused past reviewEnd, the proposal expires at executeBy
- **WHEN** a proposal is `Approved` after `reviewEnd`, the registry owner pauses the registry, and the clock passes `executeBy`
- **THEN** `getProposalState` reports `Expired`, and `resolveProposalState` commits `Expired` and frees the vault
