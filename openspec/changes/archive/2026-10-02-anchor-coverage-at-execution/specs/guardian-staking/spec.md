## ADDED Requirements

### Requirement: Anchored slashable-stake view
The staking contract SHALL expose `slashableStakeAt(guardian, anchor)`, a guardian's slashable stake as of a past anchor timestamp: the greater of the liability checkpoint and the votable-stake checkpoint looked up at `anchor - 1`, clamped to the guardian's current live stake — `min(max(liability@(anchor-1), votableStake@(anchor-1)), liveStake)`. The lookup sits one second before the anchor so a top-up landing in the anchor's own block is excluded. The view SHALL revert `VerdictNotPast` for an anchor in the future, and `anchor == 0` SHALL read the zero instant. This is the sizing basis the verdict slash applies per approver, and the view and the slash SHALL derive it from one shared implementation so the number a coverage reader books and the number a conviction recovers cannot drift. The view SHALL be read-only and add no storage.

#### Scenario: View agrees with the verdict slash

- **WHEN** a verdict slash at 100% severity executes against an approver, anchored at a proposal's execution timestamp
- **THEN** the WOOD recovered equals what the anchored view returned for that approver and anchor immediately before the slash

#### Scenario: Post-anchor top-up excluded

- **WHEN** a guardian tops up its stake at or after the anchor timestamp and the view is queried at that anchor
- **THEN** the returned value reflects only the stake checkpointed before the anchor (clamped to live), excluding the top-up

#### Scenario: Unstake request does not zero the basis

- **WHEN** a guardian requested unstake after the anchor (which zeroes its votable checkpoint but not its liability trace) and the view is queried at that anchor
- **THEN** the returned value still reflects the at-anchor stake, because the liability trace survives the request

#### Scenario: Future anchor refused

- **WHEN** the view is queried with an anchor later than the current block timestamp
- **THEN** it reverts `VerdictNotPast`
