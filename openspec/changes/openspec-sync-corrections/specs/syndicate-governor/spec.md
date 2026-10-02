## MODIFIED Requirements

### Requirement: Factory-only wiring of governor collaborators
`setProtocolConfig`, `setTierRegistry`, `setExposureLedger`, `setBondEscrow`, and `forceSetParams` on the governor SHALL be callable only by the factory. `setProtocolConfig` SHALL reject the zero address (`ZeroAddress`). `setTierRegistry` SHALL reject an address with no code (`TierRegistryNotWired`), as `initialize` does, so a governor always has a tier registry. `setExposureLedger` and `setBondEscrow` SHALL accept `address(0)` as an explicit un-wire (ledger gates skipped; no bond). `setExposureLedger` SHALL revert with `ParamsFrozenDuringProposal` when wiring a non-zero ledger while any proposal is open (a pre-ledger proposal carries no booked coverage and would become permanently unexecutable); un-wiring is exempt. The guardian registry reference SHALL be write-once at `initialize` and required non-zero — there is no re-pointing setter.

#### Scenario: Non-factory caller rejected
- **WHEN** any address other than the factory calls `setTierRegistry`, `setExposureLedger`, `setBondEscrow`, `setProtocolConfig`, or `forceSetParams`
- **THEN** the call SHALL revert with `NotFactory`

#### Scenario: Ledger wiring blocked mid-proposal
- **WHEN** the factory wires a non-zero exposure ledger while the governor has an open proposal
- **THEN** the call SHALL revert with `ParamsFrozenDuringProposal`

#### Scenario: Tier registry cannot be unwired
- **WHEN** the factory calls `setTierRegistry` with `address(0)` or another codeless address
- **THEN** the call SHALL revert with `TierRegistryNotWired`

### Requirement: Proposal lifecycle state machine
The governor SHALL maintain exactly one authoritative state per proposal, drawn from: `Draft`, `Pending`, `GuardianReview`, `Approved`, `Rejected`, `Expired`, `Executed`, `Settled`, `Cancelled`. State SHALL be written only through a single internal transition point, and SHALL be resolved by a single resolver exposed as the true view `stateOf(proposalId)`: the view reports `Approved` / `Rejected` / `Expired` the instant the outcome is determinable from time and stored votes, never lagging behind a pending state-commit transaction. The legal transitions are:

- `Draft → Pending` (all co-proposers approved), `Draft → Expired` (collaboration deadline passed), `Draft → Cancelled` (lead reject, proposer cancel, or owner emergency cancel)
- `Pending → GuardianReview` (voteEnd passed, veto not met, and a review window is configured), `Pending → Approved` (voteEnd passed, veto not met, no review window configured), `Pending → Rejected` (veto threshold reached, or owner veto), `Pending → Expired` (executeBy passed before the state was committed), `Pending → Cancelled`
- `GuardianReview → Approved` (review concluded not blocked), `GuardianReview → Rejected` (guardians blocked), `GuardianReview → Expired` (executeBy passed, or the registry holds no record of the review past `reviewEnd`), `GuardianReview → Cancelled` (proposer cancel while the registry review is still cancellable)
- `Approved → Executed` (executeProposal), `Approved → Expired` (executeBy passed), `Approved → Cancelled` (proposer cancel)
- `Executed → Settled` (settle or emergency-settle paths)

`Rejected`, `Expired`, `Settled`, `Cancelled` are terminal. A proposal whose resolved state is terminal keeps counting as open, and keeps `propose` blocked, until a mutating call commits the transition (`resolveProposalState` is the permissionless one).

#### Scenario: True view resolves time-determined states immediately
- **WHEN** a Pending proposal's `voteEnd` has passed with `votesAgainst` below the veto threshold and its guardian-review window has also elapsed with no block quorum
- **THEN** `stateOf` / `getProposalState` SHALL report `Approved` (or `Expired` if `executeBy` has also passed) without requiring any prior mutating transaction

#### Scenario: Approved proposal expires at executeBy
- **WHEN** a proposal is `Approved` and `block.timestamp` exceeds its `executeBy` deadline
- **THEN** the proposal SHALL resolve to `Expired`, and executing it SHALL revert with `ProposalNotApproved`

#### Scenario: Permissionless state flush
- **WHEN** any caller invokes `resolveProposalState(proposalId)` for an existing proposal whose lazily-resolved state is terminal (e.g. Rejected via veto, or Expired past executeBy)
- **THEN** the governor SHALL commit the terminal transition, decrement the open-proposal count, and stamp the settlement clock, so the vault is not left soft-locked by a proposal nobody else touches
- **AND** re-calling after the transition has committed SHALL be a no-op

#### Scenario: Terminal states are final
- **WHEN** a proposal has reached `Settled`, `Cancelled`, `Rejected`, or `Expired`
- **THEN** no lifecycle entrypoint SHALL transition it to any other state

### Requirement: Guardian review gate and economic commit
After a passed vote the proposal SHALL sit in `GuardianReview` until `reviewEnd`. The review verdict is owned by the GuardianRegistry: past `reviewEnd`, the governor SHALL resolve `Blocked → Rejected` and `Cleared → Approved` (or `Expired` if `executeBy` already passed) from the registry's `outcomeOf` view. The registry economic commit (`resolveReview`) SHALL fire only from a mutating state-commit, only on the transition where the review actually concluded, and never for a veto-rejection, a Draft expiry, an already-Approved-to-Expired transition, or an already-resolved review. Safety fallbacks: an `Unresolved` outcome past `reviewEnd` when the registry holds no review window for the proposal SHALL resolve to terminal `Expired`, never to an executable `Approved`; an `Unresolved` outcome for a recorded window whose end the registry's pause-adjusted clock has not yet reached keeps the proposal in `GuardianReview` (until `executeBy`); and while the registry is paused and returns an outcome for a review not already resolved, the governor SHALL keep reporting `GuardianReview` rather than a state no caller can act on.

#### Scenario: Guardians block a proposal
- **WHEN** the review window elapses with the registry's block quorum reached
- **THEN** the proposal SHALL resolve to `Rejected`, and the first mutating state-commit SHALL fire `resolveReview` exactly once and emit `GuardianReviewResolved`

#### Scenario: Missing registry record fails closed
- **WHEN** `reviewEnd > voteEnd` (a review should exist) but the registry has no review window recorded for the proposal and answers `Unresolved` past `reviewEnd`
- **THEN** the proposal SHALL resolve to `Expired` — terminal and vault-releasing — and SHALL NOT become executable

#### Scenario: Dead proposal's review is closed
- **WHEN** a proposal with a registered review reaches a terminal state without its review concluding (veto-rejection, a Pending-state or emergency cancel, expiry)
- **THEN** the governor SHALL best-effort cancel the registry review so approvers of a proposal that can never execute cannot later be slashed; a review that refuses to cancel (block quorum reached or window elapsed) SHALL NOT brick the terminal transition. A proposer cancel in `GuardianReview` is the exception: it calls the registry's `cancelReview` directly and fails if the registry refuses

### Requirement: Collaborative proposals
A proposal submitted with co-proposers SHALL enter `Draft` and require every co-proposer to `approveCollaboration` before the collaboration deadline (`propose time + collaborationWindow`); the deadline passing expires the Draft. Co-proposer validation at propose SHALL require: at most `maxCoProposers` entries, each a registered agent, no duplicates, none equal to the lead, each split at least 100 bps (1%), and the total co-split at most 9_000 bps so the lead keeps at least 10%. The Draft SHALL snapshot `votingPeriod` and `executionWindow` at propose time and use those snapshots at the Draft-to-Pending transition; the vault owner's setters are frozen while the Draft is open, and the snapshot also holds against a factory `forceSetParams` override. `vetoThresholdBps` is read at the Draft-to-Pending transition. Each co-proposer approval SHALL be one-shot; the transition to Pending fires when the approval count equals the co-proposer count. `rejectCollaboration` SHALL be lead-proposer-only (a dissenting co-proposer simply withholds approval); the lead SHALL NOT cancel a multi-co-proposer Draft once all but one co-proposer has approved (front-run guard `CancelNotAllowedNearQuorum`).

#### Scenario: Collaboration window lapses
- **WHEN** the collaboration deadline passes with approvals outstanding
- **THEN** the Draft SHALL resolve to `Expired`, `approveCollaboration` SHALL revert with `CollaborationExpired` (or `NotDraftState` once the expiry has been committed), and the vault binding SHALL be released on commit

#### Scenario: Draft timing immune to param changes
- **WHEN** the factory owner changes `votingPeriod` through `setParamsOverride` while a collaborative Draft awaits approvals
- **THEN** the Draft's eventual Pending timeline SHALL use the values snapshotted at propose time

#### Scenario: Collaboration refused under owner-only proposals
- **WHEN** the factory's `ownerOnlyProposals` is true and a co-proposer calls `approveCollaboration` on a Draft created before it was set
- **THEN** the call SHALL revert with `CollaborationDisabled`, leaving the Draft to be rejected, cancelled, or to expire

#### Scenario: Near-quorum cancel blocked
- **WHEN** the lead calls `cancelProposal` on a Draft with more than one co-proposer where all but one have approved
- **THEN** the call SHALL revert with `CancelNotAllowedNearQuorum`

### Requirement: Factory creation of syndicates
`SyndicateFactory.createSyndicate(creatorAgentId, config)` SHALL, in one transaction: validate the config (non-zero asset, non-empty name/symbol/subdomain/metadataURI); require the creator to have a prepared owner stake in sWOOD (`canCreateVault`); collect the creation fee if configured, unless the factory owner has sponsored the caller (`setCreationSponsored`), in which case the single-use credit is consumed and no fee is transferred; verify the creator owns the ERC-8004 agent identity when an agent registry is configured; require a subdomain of at least 3 characters not already taken; deploy the vault as a UUPS `ERC1967Proxy` (upgradeable only through the factory's creator-gated `upgradeVault` while `upgradesEnabled`) plus its withdrawal queue; deploy the per-vault governor as a `BeaconProxy` initialized with the vault, guardian registry, protocol config, factory address, the factory's tier registry, and the factory's default governor parameters; record the vault-to-governor mapping (the sole vault↔governor wiring); authorize the governor on the guardian registry via `addGovernor`; push the factory's current exposure ledger and bond escrow into the fresh governor, skipping unset slots rather than writing zero; and bind the creator's prepared owner stake to the vault atomically. The factory SHALL NOT register ENS subnames; the subdomain-to-syndicate mapping is the syndicate's logical name reservation.

#### Scenario: Creation without prepared stake rejected
- **WHEN** a caller without a prepared owner stake calls `createSyndicate`
- **THEN** the call SHALL revert with `PreparedStakeNotFound` before any side effects

#### Scenario: Governor deployed with default parameters
- **WHEN** a syndicate is created
- **THEN** its governor SHALL initialize with the factory defaults (votingPeriod 24h, executionWindow 24h, vetoThresholdBps 2_000, maxPerformanceFeeBps 2_000 (`FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS`), cooldownPeriod 1h, collaborationWindow 24h, maxCoProposers 10, strategyDuration bounds [1h, 30d]), all within the governor's own bounds validation

#### Scenario: Duplicate subdomain rejected
- **WHEN** `config.subdomain` already maps to an existing syndicate
- **THEN** the call SHALL revert with `SubdomainTaken`

#### Scenario: Agent registry re-pointed or disabled
- **WHEN** the factory owner calls `setAgentRegistry(newRegistry)`
- **THEN** `AgentRegistryUpdated(old, new)` SHALL be emitted and both `createSyndicate` and every factory vault's `registerAgent` SHALL check identity against `newRegistry` from then on, skipping the check when it is zero; any other caller SHALL revert

#### Scenario: Factory launch flags
- **WHEN** the factory owner calls `setDepositsRestricted(bool)` or `setOwnerOnlyProposals(bool)`
- **THEN** the flag SHALL be stored and `DepositsRestrictedUpdated` / `OwnerOnlyProposalsUpdated` emitted, both flags SHALL apply to every syndicate the factory created, and any other caller SHALL revert

#### Scenario: Sponsored creation waives one fee
- **WHEN** the factory owner has called `setCreationSponsored(creator, true)` and a creation fee is configured
- **THEN** `creator`'s next `createSyndicate` SHALL transfer no fee and clear the credit, and any later creation by `creator` SHALL pay the fee; a credit SHALL waive nothing for any other caller
