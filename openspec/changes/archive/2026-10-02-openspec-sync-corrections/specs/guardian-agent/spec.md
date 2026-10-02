## MODIFIED Requirements

### Requirement: Timing decisions read chain time

Every deadline decision — whether a review is open, whether the late-vote lockout has begun, whether
the window has closed — SHALL be computed from the registry's pause-adjusted clock for that review
(`effectiveNowFor(governor, proposalId)`) against the window recorded on-chain (`reviewWindow`),
never from the agent's local clock and never from the raw block timestamp, which misjudges any review
that spanned a registry pause.

The fork's clock is advanced deliberately in large steps during simulation, so a local clock diverges
from chain time by days within a single run.

#### Scenario: Chain time jumps forward
- **WHEN** the fork's timestamp advances past the review end between two polls
- **THEN** the agent abstains and records the window as closed, rather than submitting a vote that reverts

#### Scenario: Late-vote lockout reached
- **WHEN** chain time enters the final tenth of the review window
- **THEN** the agent does not attempt to vote or change its vote

### Requirement: On-chain review state overrides local state

Before signing any vote the agent SHALL read the review's on-chain state and SHALL NOT vote when the
chain already records a vote from its address for that proposal. The registry exposes no per-guardian
vote view, so the agent SHALL reconstruct its prior vote from the registry's `GuardianVoteCast` /
`GuardianVoteChanged` events (and `getApproverWeights` for an Approve); a same-side re-vote reverts
`NoVoteChange` on-chain in any case.

The adversary here is the agent's own restart: local progress state can be lost, rolled back, or
restored from a stale volume, and a duplicate vote wastes gas at best and misrepresents intent at worst.

#### Scenario: Restart with lost local state
- **WHEN** the agent restarts with an empty state directory and re-observes a review it already voted on
- **THEN** it reads its existing vote from the registry's vote events and does not vote again

#### Scenario: Review already resolved
- **WHEN** a review has been resolved before the agent reaches it
- **THEN** the agent records the outcome and casts no vote

## ADDED Requirements

### Requirement: Reviews are discovered from registry events, which carry the governor

The agent SHALL discover the governor for each proposal from the registry's review events —
`ReviewRegistered(governor, proposalId, voteEnd, reviewEnd)` and `ReviewOpened(governor, proposalId,
totalStakeAtOpen)` both carry the governor address — and SHALL NOT require a governor to be configured.

Governors are minted per vault by the factory, so any single configured governor address is wrong by
construction on a multi-vault deployment.

#### Scenario: Second vault's proposal
- **WHEN** a review opens on a governor the agent has never seen
- **THEN** the agent resolves that governor from the event and evaluates the proposal

## REMOVED Requirements

### Requirement: Reviews are discovered from registry events, not configuration
**Reason**: Its scenario said the review-opened event identifies only the proposal; `ReviewOpened` carries the governor.
**Migration**: Replaced by "Reviews are discovered from registry events, which carry the governor".
