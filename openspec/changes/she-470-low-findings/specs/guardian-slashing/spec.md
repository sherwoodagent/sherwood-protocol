# guardian-slashing (delta)

## ADDED Requirements

### Requirement: An emergency block vote lands only while the governor reports Executed
`voteBlockEmergencySettle` SHALL revert `ReviewNotOpen` unless the governor reports the proposal `Executed`, read through the same staticcall probe as the review-vote gate; a failed or short read keeps the window-only check. A round made moot by a settle therefore takes no new block weight, while block votes cast before the settle still count when the round is resolved.

#### Scenario: A block vote after a third-party settle is refused
- **WHEN** an emergency round is open, a keeper settles the proposal through `settleProposal`, and a guardian then calls `voteBlockEmergencySettle`
- **THEN** the call reverts `ReviewNotOpen`, and resolving the round after `reviewEnd` leaves the owner bond intact

#### Scenario: A block cast before the settle still burns
- **WHEN** a guardian with block quorum votes while the proposal is `Executed`, and the proposal is settled afterwards
- **THEN** `resolveEmergencyReview` burns the owner bond
