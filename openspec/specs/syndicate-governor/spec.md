# Syndicate Governor Specification

## Purpose

Per-vault governance for agent-managed syndicate vaults: agents propose strategies as pre-committed call batches, shareholders vote optimistically (a proposal passes unless AGAINST votes reach a veto threshold), guardians review, and approved strategies execute and settle through the vault under a risk envelope. Covers the proposal lifecycle state machine, voting and quorum rules, execution safety guards, emergency settlement paths, beacon-based upgrades, factory creation of syndicates, and parameter governance.
## Requirements
### Requirement: Proposal lifecycle state machine
The governor SHALL maintain exactly one authoritative state per proposal, drawn from: `Draft`, `Pending`, `GuardianReview`, `Approved`, `Rejected`, `Expired`, `Executed`, `Settled`, `Cancelled`. State SHALL be written only through a single internal transition point, and SHALL be resolved by a single resolver exposed as the true view `stateOf(proposalId)`: the view reports `Approved` / `Rejected` / `Expired` the instant the outcome is determinable from time and stored votes, never lagging behind a pending state-commit transaction. The legal transitions are:

- `Draft → Pending` (all co-proposers approved), `Draft → Expired` (collaboration deadline passed), `Draft → Cancelled` (lead reject, proposer cancel, or owner emergency cancel)
- `Pending → GuardianReview` (voteEnd passed, veto not met), `Pending → Rejected` (veto threshold reached, or owner veto), `Pending → Cancelled`
- `GuardianReview → Approved` (review concluded not blocked), `GuardianReview → Rejected` (guardians blocked), `GuardianReview → Cancelled` (proposer cancel while the registry review is still cancellable)
- `Approved → Executed` (executeProposal), `Approved → Expired` (executeBy passed), `Approved → Cancelled` (proposer cancel)
- `Executed → Settled` (settle or emergency-settle paths)

`Rejected`, `Expired`, `Settled`, `Cancelled` are terminal.

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

### Requirement: Single open proposal per vault
The governor SHALL bind at most one non-terminal proposal lifecycle to its vault at a time. Both collaborative Drafts and Pending proposals count as binding the vault. The open-proposal count SHALL be incremented when a proposal enters Draft or Pending, and decremented exactly once when it reaches a terminal state (or Settled), with every decrement also stamping the settlement clock so lazily-expired proposals cannot dodge the execute cooldown.

#### Scenario: Second proposal blocked
- **WHEN** an agent calls `propose` while the vault has any non-terminal proposal (Draft, Pending, GuardianReview, Approved, or Executed)
- **THEN** the call SHALL revert with `VaultHasOpenProposal`

#### Scenario: Draft-to-Pending transition re-checks vault binding
- **WHEN** the final co-proposer approval would transition a Draft to Pending while another (non-self) proposal binds the vault
- **THEN** `approveCollaboration` SHALL revert with `VaultHasOpenProposal`

### Requirement: Proposal creation validation
`propose` SHALL only be callable by a registered agent of the governor's vault, and SHALL validate: the `vault` argument equals the governor's bound vault; `strategyDuration` is within `[minStrategyDuration, maxStrategyDuration]`; `executeCalls` and `settlementCalls` are both non-empty and each at most 64 calls; `metadataURI` is at most 512 bytes; `envelope.maxCapital` is nonzero and at most `totalAssets() * maxCapitalBps / 10_000` at propose time; and `envelope.maxDrawdownBps` is at most 10_000. The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`), the protocol and guardian fee bps and recipients from ProtocolConfig, the strategy's `selfManagesFees` flag, and the risk envelope — all immutable for the proposal's lifetime.

#### Scenario: Non-agent proposer rejected
- **WHEN** an address that is not a registered agent of the vault calls `propose`
- **THEN** the call SHALL revert with `NotRegisteredAgent`

#### Scenario: maxCapital ceiling enforced
- **WHEN** a proposer declares `envelope.maxCapital` greater than `totalAssets() * maxCapitalBps / 10_000`
- **THEN** the call SHALL revert with `MaxCapitalExceedsCeiling`

#### Scenario: Batch size and metadata caps
- **WHEN** `executeCalls.length` or `settlementCalls.length` exceeds 64, or `metadataURI` exceeds 512 bytes
- **THEN** the call SHALL revert with `TooManyCalls` or `MetadataURITooLong` respectively

#### Scenario: Fee configuration snapshotted at propose
- **WHEN** the protocol multisig changes `protocolFeeBps` or `guardianFeeBps` after a proposal is created
- **THEN** that proposal's settlement SHALL use the rates and recipients snapshotted at propose time, not the changed values

### Requirement: Voting timeline and vote snapshot
A non-collaborative proposal SHALL enter `Pending` immediately at propose; a collaborative proposal enters `Pending` on the final co-proposer approval. On entering Pending the governor SHALL set: `snapshotTimestamp = block.timestamp - 1` (closing the same-block flash-delegate window), `voteEnd = now + votingPeriod`, `reviewEnd = voteEnd + reviewPeriod` (read from the guardian registry), and `executeBy = reviewEnd + executionWindow`. When `reviewEnd > voteEnd` the governor SHALL push the review window to the guardian registry via `registerReview` under exactly that predicate; a collapsed window (`reviewPeriod == 0`) is treated as no review configured.

#### Scenario: Vote weight from checkpointed shares
- **WHEN** a shareholder votes on a Pending proposal
- **THEN** their vote weight SHALL be `getPastVotes(voter, snapshotTimestamp)` from the vault's ERC20Votes checkpoints, and a zero weight SHALL revert with `NoVotingPower`

#### Scenario: One vote per address
- **WHEN** an address that has already voted on a proposal votes again
- **THEN** the call SHALL revert with `AlreadyVoted`

#### Scenario: Voting only while Pending
- **WHEN** `vote` is called on a proposal whose resolved state is not `Pending` (voting ended, Draft, or terminal)
- **THEN** the call SHALL revert with `NotWithinVotingPeriod`

### Requirement: Optimistic passage with veto threshold
The governor SHALL use optimistic governance: no FOR-vote quorum exists. At `voteEnd`, a Pending proposal SHALL be `Rejected` if and only if `votesAgainst >= pastTotalSupply * vetoThresholdBps / 10_000`, where `vetoThresholdBps` is the per-proposal snapshot taken when the proposal entered Pending (a mid-vote parameter change cannot move the bar) and `pastTotalSupply` is the vault supply at `snapshotTimestamp`. When `pastTotalSupply == 0`, the veto check SHALL be skipped (otherwise the threshold collapses to zero and every proposal auto-rejects). A proposal not vetoed at voteEnd proceeds into guardian review.

#### Scenario: Veto threshold reached
- **WHEN** voting ends with `votesAgainst` at or above the snapshotted veto threshold of past total supply
- **THEN** the proposal SHALL resolve to `Rejected` without traversing guardian review, and no registry economic commit SHALL fire for it

#### Scenario: Silence passes the vote
- **WHEN** voting ends with zero votes cast and a nonzero past total supply
- **THEN** the proposal SHALL proceed to `GuardianReview` (or directly toward Approved if no review window is configured)

### Requirement: Guardian review gate and economic commit
After a passed vote the proposal SHALL sit in `GuardianReview` until `reviewEnd`. The review verdict is owned by the GuardianRegistry: past `reviewEnd`, the governor SHALL resolve `Blocked → Rejected` and `Cleared → Approved` (or `Expired` if `executeBy` already passed) from the registry's `outcomeOf` view. The registry economic commit (`resolveReview`) SHALL fire only from a mutating state-commit, only on the transition where the review actually concluded, and never for a veto-rejection, a Draft expiry, an already-Approved-to-Expired transition, or an already-resolved review. Safety fallbacks: an `Unresolved` outcome past `reviewEnd` (registry holds no record for a window the governor believes exists) SHALL resolve to terminal `Expired`, never to an executable `Approved`; while the registry is paused and the review is not already resolved, the governor SHALL keep reporting `GuardianReview` rather than a state no caller can act on.

#### Scenario: Guardians block a proposal
- **WHEN** the review window elapses with the registry's block quorum reached
- **THEN** the proposal SHALL resolve to `Rejected`, and the first mutating state-commit SHALL fire `resolveReview` exactly once and emit `GuardianReviewResolved`

#### Scenario: Missing registry record fails closed
- **WHEN** `reviewEnd > voteEnd` (a review should exist) but the registry answers `Unresolved` past `reviewEnd`
- **THEN** the proposal SHALL resolve to `Expired` — terminal and vault-releasing — and SHALL NOT become executable

#### Scenario: Dead proposal's review is closed
- **WHEN** a proposal with a registered review reaches a terminal state without its review concluding (veto-rejection, cancellation, expiry)
- **THEN** the governor SHALL best-effort cancel the registry review so approvers of a proposal that can never execute cannot later be slashed; a review that refuses to cancel (block quorum reached or window elapsed) SHALL NOT brick the terminal transition

### Requirement: Execution safety guards
`executeProposal` SHALL be permissionless but SHALL only run when the resolved state is `Approved`, no other proposal is actively executing, and the cooldown has elapsed (`block.timestamp >= lastSettledAt + cooldownPeriod`, skipped when nothing ever settled). Before executing it SHALL: snapshot the vault's asset balance as the capital snapshot; mark the proposal `Executed` and set `executedAt` before any external call (CEI); re-resolve tier and coverage from the stored calls and revert with `TierRegressed` if the live tier exceeds the propose-time `envelopeTier`, or `CoverageRegressed` if the live coverage exceeds the propose-time `requiredCoverage`; and, when an exposure ledger is wired and `requiredCoverage != 0` and the tier is at or above the ledger's quorum tier threshold, require a bond-encumbered approve quorum via `requireApproveQuorum` (fail-closed: silence does not execute a coverage-consuming proposal). The opening batch SHALL run via the vault's `executeGovernorBatch` under the proposal's `maxCapital` net-outflow cap. All execute/settle/cancel entrypoints SHALL be protected by a shared reentrancy lock.

#### Scenario: Cooldown between strategies
- **WHEN** `executeProposal` is called before `lastSettledAt + cooldownPeriod` has elapsed
- **THEN** the call SHALL revert with `CooldownNotElapsed`, giving depositors an exit window between strategies

#### Scenario: Stale certification blocks execution
- **WHEN** an adapter used by the proposal's execute calls was demoted or re-certified with a higher extractable bound after propose, so the live tier or coverage exceeds the propose-time snapshot
- **THEN** `executeProposal` SHALL revert (`TierRegressed` / `CoverageRegressed`), and the proposal SHALL remain `Approved` until `executeBy` expires it

#### Scenario: Missing approve quorum blocks execution
- **WHEN** an exposure ledger is wired and a coverage-consuming proposal at or above the quorum tier threshold has no covering approve quorum booked
- **THEN** `executeProposal` SHALL revert, leaving the proposal `Approved` (executable later if covering approvals arrive before `executeBy`)

#### Scenario: Only one live strategy
- **WHEN** `executeProposal` is called while another proposal is in the Executed window
- **THEN** the call SHALL revert with `StrategyAlreadyActive`

### Requirement: Settlement and P&L
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` under the same `maxCapital` cap as execution, then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot minus the vault's interim LP net flow (deposits/withdrawals during the strategy are principal, not performance); state SHALL move to `Settled`, the active-proposal marker cleared, and the open count decremented before external fee transfers; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: Interim LP flow excluded from P&L
- **WHEN** depositors add or remove principal while a strategy is live
- **THEN** the settlement P&L SHALL exclude that interim net flow, so fees are charged only on strategy performance

### Requirement: Fee distribution waterfall
On a positive P&L, unless the proposal's snapshotted `selfManagesFees` flag is true (which skips the entire governor fee waterfall), the governor SHALL distribute, in order: (1) protocol fee = gross profit × snapshotted `protocolFeeBps` to the snapshotted protocol recipient; (2) guardian fee = gross profit × snapshotted `guardianFeeBps` to the snapshotted guardians recipient, emitting `GuardianFeeAccrued` only when the transfer actually delivers; (3) agent performance fee = net profit × the propose-time performance fee, re-clamped at settle to the live `maxPerformanceFeeBps` (emitting `FeeClamped` when the clamp fires), split across active co-proposers by their `splitBps` with the remainder to the lead proposer; (4) management fee = remaining net × the vault's live `managementFeeBps` to the vault owner. Any individual fee transfer that reverts (e.g. a blacklisted recipient) SHALL be escrowed against `(vault, recipient, token)` instead of reverting settlement, emitting `FeeTransferFailed`; recipients pull escrowed amounts later via `claimUnclaimedFees`, which SHALL zero the escrow slot before transferring and only pay from the vault that owes it.

#### Scenario: Settlement never bricks on a bad recipient
- **WHEN** a fee recipient's transfer reverts during settlement
- **THEN** the amount SHALL be recorded in the unclaimed-fees escrow, the rest of the waterfall SHALL continue, and the proposal SHALL still reach `Settled`

#### Scenario: Guardian fee attribution only on delivery
- **WHEN** the guardian-fee transfer escrows instead of delivering
- **THEN** `GuardianFeeAccrued` SHALL NOT be emitted (preventing the off-chain airdrop bot from double-paying)

#### Scenario: Inactive co-proposer skipped
- **WHEN** a co-proposer is no longer a registered agent at settlement
- **THEN** their share SHALL be skipped, and the co-proposer distribution SHALL never pay out more than the total agent fee

#### Scenario: Self-managed fees opt out
- **WHEN** the proposal's strategy declared `selfManagesFees() == true` at propose time
- **THEN** settlement SHALL skip the entire fee waterfall, reading the propose-time snapshot rather than a live strategy call

### Requirement: Collaborative proposals
A proposal submitted with co-proposers SHALL enter `Draft` and require every co-proposer to `approveCollaboration` before the collaboration deadline (`propose time + collaborationWindow`); the deadline passing expires the Draft. Co-proposer validation at propose SHALL require: at most `maxCoProposers` entries, each a registered agent, no duplicates, none equal to the lead, each split at least 100 bps (1%), and the total co-split at most 9_000 bps so the lead keeps at least 10%. The Draft SHALL snapshot `votingPeriod` and `executionWindow` at propose time and use those snapshots at the Draft-to-Pending transition, so a mid-Draft parameter change cannot move the timeline co-proposers already approved. Each co-proposer approval SHALL be one-shot; the transition to Pending fires when the approval count equals the co-proposer count. `rejectCollaboration` SHALL be lead-proposer-only (a dissenting co-proposer simply withholds approval); the lead SHALL NOT cancel a multi-co-proposer Draft once all but one co-proposer has approved (front-run guard `CancelNotAllowedNearQuorum`).

#### Scenario: Collaboration window lapses
- **WHEN** the collaboration deadline passes with approvals outstanding
- **THEN** the Draft SHALL resolve to `Expired`, `approveCollaboration` SHALL revert with `CollaborationExpired`, and the vault binding SHALL be released on commit

#### Scenario: Draft timing immune to param changes
- **WHEN** the vault owner changes `votingPeriod` while a collaborative Draft awaits approvals
- **THEN** the Draft's eventual Pending timeline SHALL use the values snapshotted at propose time

#### Scenario: Near-quorum cancel blocked
- **WHEN** the lead calls `cancelProposal` on a Draft with more than one co-proposer where all but one have approved
- **THEN** the call SHALL revert with `CancelNotAllowedNearQuorum`

### Requirement: Cancellation and owner veto
`cancelProposal` SHALL be proposer-only and permitted in Draft (subject to the near-quorum guard), Pending (only until `voteEnd`), GuardianReview (only while the registry review is still cancellable — the registry's refusal past `reviewEnd` bubbles up and closes the window), and Approved. Every cancel branch SHALL decrement the open count (rate-limiting propose-cancel-propose via the settle cooldown) and close any registered review. `emergencyCancel` SHALL be vault-owner-only and narrowed to Draft and Pending states. `vetoProposal` SHALL be vault-owner-only, narrowed to Pending, and SHALL set the proposal to `Rejected` — once a proposal reaches GuardianReview, the guardian cohort and execution window drive the outcome and the owner loses unilateral authority.

#### Scenario: Proposer cancels during voting
- **WHEN** the proposer cancels a Pending proposal before `voteEnd`
- **THEN** the proposal SHALL become `Cancelled`, its registered review SHALL be closed so guardians cannot be slashed for it, and the vault binding SHALL be released

#### Scenario: Owner cannot cancel past Pending
- **WHEN** the vault owner calls `emergencyCancel` or `vetoProposal` on a proposal in GuardianReview, Approved, or Executed
- **THEN** the call SHALL revert with `ProposalNotCancellable`

#### Scenario: Cancel in GuardianReview closes the review or fails
- **WHEN** the proposer cancels during GuardianReview and the registry review's window has already elapsed
- **THEN** the registry's `cancelReview` revert SHALL bubble up and the cancel SHALL fail — the proposer must commit to the review outcome at that point

### Requirement: Emergency settlement paths
For a proposal stuck in `Executed` past `executedAt + strategyDuration`, the vault owner SHALL have two escape hatches. (1) `unstick`: run the governance-approved pre-committed settlement calls (no guardian review required, no owner stake required — the calls were already voted on) under the proposal's `maxCapital` cap, then finalize settlement. (2) Owner-supplied calls: `emergencySettleWithCalls` SHALL require the owner's bonded stake in the guardian registry to meet the required owner bond, and SHALL open a guardian review on the registry keyed by the hash of the supplied calls; `cancelEmergencySettle` withdraws an open review; `finalizeEmergencySettle` SHALL, after the registry review resolves, revert with `EmergencySettleBlocked` if guardians blocked it, otherwise execute the registry-stored calls under the `maxCapital` cap and finalize settlement. All emergency entrypoints SHALL require the caller to be the vault owner, the proposal to be in `Executed` state, and SHALL share the governor's reentrancy lock.

#### Scenario: Unstick before duration elapses is rejected
- **WHEN** the vault owner calls `unstick` or `emergencySettleWithCalls` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Guardians block owner-supplied emergency calls
- **WHEN** the guardian review of an emergency settle reaches block quorum
- **THEN** `finalizeEmergencySettle` SHALL revert with `EmergencySettleBlocked` and the owner-supplied calls SHALL never execute

#### Scenario: Under-bonded owner cannot propose custom calls
- **WHEN** the vault owner's registry stake is below the required owner bond
- **THEN** `emergencySettleWithCalls` SHALL revert with `OwnerBondInsufficient`

### Requirement: Risk tiering and proposer bond at propose
At propose time the governor SHALL resolve the proposal's tier and required coverage through the tier registry: tier = MAX tier across execute calls; coverage = `maxCapital × Σ boundBps / 10_000` summed per-call across BOTH execute and settlement calls, where a certified tier-0/1 call contributes its certified bound and a tier-2/uncertified call contributes 10_000 (full notional). With no tier registry wired, every proposal SHALL resolve to tier 2 / full-notional coverage (the safe default). When an exposure ledger is wired, propose SHALL additionally enforce the ledger's covered-TVL cap and coverage-horizon gates (fail-closed, failing on the proposer; the collaborative path uses the worst-case deadline `now + collaborationWindow + votingPeriod + reviewPeriod + executionWindow`), and when a bond escrow is also wired SHALL lock the ledger-priced risk-scaled WOOD proposer bond in the escrow, recording the amount, the escrow address, AND the exposure-ledger address on the proposal before the external lock call. The recorded ledger is the one the reclaim gates read for the life of the bond — re-pointing the governor's live ledger slot afterwards MUST NOT change which ledger gates an already-locked bond (adversary: a vault owner colluding with the proposer re-points at a permissive ledger after settlement, when the open-proposal guard no longer holds, to detach the reclaim gates from a live challenge).

#### Scenario: Unwired registries keep the safe default
- **WHEN** no tier registry is wired
- **THEN** every proposal SHALL be tier 2 with `requiredCoverage == maxCapital`, and with no exposure ledger wired the covered-TVL and bond gates SHALL be skipped

#### Scenario: Bond reclaim is terminal-only and permissionless
- **WHEN** any caller invokes `reclaimProposerBond` on a proposal in a terminal state (Rejected, Expired, Cancelled, or Settled) with a nonzero recorded bond
- **THEN** the governor SHALL zero the recorded bond and release it from the escrow recorded on the proposal at lock time (never the live escrow slot), paying the proposer, with the executed-proposal challenge gates evaluated against the ledger recorded on the proposal at lock time (never the live ledger slot); a second call SHALL revert with `NoBondToReclaim`
- **AND** a call while the proposal is non-terminal SHALL revert with `ProposalNotTerminal`

#### Scenario: Forfeited bond reclaim is an acknowledged no-op
- **WHEN** any caller invokes `reclaimProposerBond` on a terminal proposal whose recorded bond is nonzero but whose recorded escrow no longer holds a bond for it (a conviction forfeited it)
- **THEN** the governor SHALL zero the recorded bond, emit `ProposerBondForfeitureAcknowledged(proposalId, amount)`, and return without transferring — never reverting indefinitely and never leaving the recorded amount stale; a second call SHALL revert with `NoBondToReclaim`

#### Scenario: Forfeiture is never a lifecycle outcome
- **WHEN** a proposal is rejected by veto, blocked by guardians, expired, or cancelled
- **THEN** the proposer bond SHALL be returnable in full — forfeiture is exclusively a passed-challenge outcome outside this capability

### Requirement: Governance parameter management
Governance parameters (`votingPeriod`, `executionWindow`, `vetoThresholdBps`, `maxPerformanceFeeBps`, `cooldownPeriod`, `collaborationWindow`, `maxCoProposers`, `minStrategyDuration`, `maxStrategyDuration`, `maxCapitalBps`) SHALL be settable only by the vault owner (a multisig expected to enforce its own external delay), applied instantly, and frozen while any proposal binds the vault (`ParamsFrozenDuringProposal`). Every setter SHALL validate hardcoded bounds: votingPeriod within [per-deployment floor (mainnet 24h), 30d]; executionWindow [1h, 7d]; vetoThresholdBps [2_000, 5_000]; maxPerformanceFeeBps ≤ 3_000 (`FeeConstants.MAX_PERFORMANCE_FEE_BPS`, the hard ceiling — distinct from the 2_000 headline the factory ships); cooldownPeriod within [per-deployment floor (mainnet 1h), 30d]; strategyDuration bounds within [1h, 3650d] with min ≤ max and max additionally capped by the protocol-wide `maxStrategyDuration` ceiling from ProtocolConfig (unset = no ceiling); collaborationWindow [1h, 7d]; maxCoProposers [1, 10]; maxCapitalBps [1, 10_000] with 0 stored meaning unset and reading as 10_000. Every change SHALL emit the uniform `ParameterChangeFinalized(paramKey, old, new)` event. The per-deployment timing floors SHALL be implementation-constructor immutables bounded below by 1 minute.

#### Scenario: Parameters frozen mid-proposal
- **WHEN** the vault owner calls any parameter setter while `openProposalCount > 0`
- **THEN** the call SHALL revert with `ParamsFrozenDuringProposal`

#### Scenario: Out-of-bounds value rejected
- **WHEN** the vault owner sets `vetoThresholdBps` below 2_000 or above 5_000
- **THEN** the call SHALL revert with `InvalidVetoThresholdBps`

#### Scenario: Factory rescue bypasses the freeze but not the bounds
- **WHEN** the factory calls `forceSetParams` (reachable by the factory owner via `setParamsOverride`) during an active proposal
- **THEN** the full parameter set SHALL be applied without the `whenNoActiveProposal` freeze, but SHALL still pass the same bounds validation

### Requirement: Factory-only wiring of governor collaborators
`setProtocolConfig`, `setTierRegistry`, `setExposureLedger`, `setBondEscrow`, and `forceSetParams` on the governor SHALL be callable only by the factory. `setProtocolConfig` SHALL reject the zero address; the other three SHALL accept `address(0)` as an explicit un-wire back to the safe default (tier-2 full notional; gates skipped; no bond). `setExposureLedger` SHALL revert with `ParamsFrozenDuringProposal` when wiring a non-zero ledger while any proposal is open (a pre-ledger proposal carries no booked coverage and would become permanently unexecutable); un-wiring is exempt. The guardian registry reference SHALL be write-once at `initialize` and required non-zero — there is no re-pointing setter.

#### Scenario: Non-factory caller rejected
- **WHEN** any address other than the factory calls `setTierRegistry`, `setExposureLedger`, `setBondEscrow`, `setProtocolConfig`, or `forceSetParams`
- **THEN** the call SHALL revert with `NotFactory`

#### Scenario: Ledger wiring blocked mid-proposal
- **WHEN** the factory wires a non-zero exposure ledger while the governor has an open proposal
- **THEN** the call SHALL revert with `ParamsFrozenDuringProposal`

### Requirement: Beacon upgrade rules
Every per-vault governor SHALL be deployed as a `BeaconProxy` reading its implementation from the shared `GovernorBeacon` (an OpenZeppelin `UpgradeableBeacon`). `GovernorBeacon.upgradeTo(newImpl)` SHALL be restricted to the beacon owner (the factory-owner multisig behind a delay module) and SHALL atomically re-point every live vault governor to the new implementation. Governor implementations SHALL disable their own initializers at construction, and per-deployment timing floors bake into implementation bytecode so a floor change is an implementation swap via the beacon, not a storage migration.

#### Scenario: Mass upgrade in one transaction
- **WHEN** the beacon owner calls `upgradeTo(newImpl)`
- **THEN** every governor proxy deployed against that beacon SHALL execute the new implementation on its next call, with per-governor storage unchanged

#### Scenario: Non-owner upgrade rejected
- **WHEN** any address other than the beacon owner calls `upgradeTo`
- **THEN** the call SHALL revert

### Requirement: Factory creation of syndicates
`SyndicateFactory.createSyndicate(creatorAgentId, config)` SHALL, in one transaction: validate the config (non-zero asset, non-empty name/symbol/metadataURI, subdomain of at least 3 characters not already taken); require the creator to have a prepared owner stake in sWOOD (`canCreateVault`); collect the creation fee if configured; verify the creator owns the ERC-8004 agent identity when an agent registry is configured; deploy the vault as an immutable `ERC1967Proxy` plus its withdrawal queue; deploy the per-vault governor as a `BeaconProxy` initialized with the vault, guardian registry, protocol config, factory address, and the factory's default governor parameters; record the vault-to-governor mapping (the sole vault↔governor wiring); authorize the governor on the guardian registry via `addGovernor`; push the factory's current tier registry, exposure ledger, and bond escrow into the fresh governor, skipping unset slots rather than writing zero; and bind the creator's prepared owner stake to the vault atomically. ENS subname registration SHALL be best-effort: any registrar failure (including a reverting `available()` view) SHALL emit `EnsRegistrationFailed` and never revert the creation; the subdomain-to-syndicate mapping is written unconditionally as the logical name reservation.

#### Scenario: Creation without prepared stake rejected
- **WHEN** a caller without a prepared owner stake calls `createSyndicate`
- **THEN** the call SHALL revert with `PreparedStakeNotFound` before any side effects

#### Scenario: Governor deployed with default parameters
- **WHEN** a syndicate is created
- **THEN** its governor SHALL initialize with the factory defaults (votingPeriod 24h, executionWindow 24h, vetoThresholdBps 2_000, maxPerformanceFeeBps 2_000 (`FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS`), cooldownPeriod 1h, collaborationWindow 24h, maxCoProposers 10, strategyDuration bounds [1h, 30d]), all within the governor's own bounds validation

#### Scenario: ENS failure does not brick creation
- **WHEN** the ENS registrar is paused, faults, or the label was front-run
- **THEN** the syndicate SHALL still be created fully operational and `EnsRegistrationFailed` SHALL be emitted for out-of-band retry

#### Scenario: Duplicate subdomain rejected
- **WHEN** `config.subdomain` already maps to an existing syndicate
- **THEN** the call SHALL revert with `SubdomainTaken`

### Requirement: Factory lifecycle-gated administration
The factory SHALL gate structural changes on the governor's lifecycle state. `rotateOwner(vault, newOwner)` SHALL require the caller to be the current vault owner or the original creator, the old owner stake to be fully withdrawn, both `getActiveProposal() == 0` and `openProposalCount() == 0`, and the incoming owner's prior vault-specific consent to the stake binding (recorded on sWOOD by `newOwner` via `approveOwnerStakeBinding(vault)` — adversary: a current owner of an empty-slot vault must not be able to spend a third party's escrowed prepared stake by rotating the vault onto them); it SHALL transfer vault ownership, rebind the owner-stake slot on sWOOD (consuming the consent), and update the creator record. The signature and single-call semantics of `rotateOwner` SHALL be unchanged — consent is enforced at the sWOOD spend site, not by a new factory entrypoint. `upgradeVault(vault, expectedImpl)` SHALL require upgrades enabled, the caller to be the creator, `vaultImpl == expectedImpl` (so a factory-owner impl swap cannot land an implementation the creator did not opt into), and the same two lifecycle gates. `pushWiring(governor)` SHALL be factory-owner-only, SHALL verify the target is a governor this factory deployed (via the unforgeable `governor.vault()` → `governorOf` round-trip), and SHALL push only the factory's currently-set tier registry / exposure ledger / bond escrow — never writing zero, so wiring can be added but never silently removed. `setGuardianRegistry` SHALL fail-closed unless the new registry advertises this factory (or address(0) for a stateless stub).

#### Scenario: Rotation blocked mid-lifecycle
- **WHEN** `rotateOwner` or `upgradeVault` is called while the vault's governor has an executing proposal or any open proposal
- **THEN** the call SHALL revert (`ProposalActive` / `StrategyActive` or `ProposalsOpen`)

#### Scenario: Rotation without the incoming owner's consent
- **WHEN** `rotateOwner(vault, newOwner)` passes the caller and lifecycle gates but `newOwner` has not approved `vault` for stake binding on sWOOD
- **THEN** the call SHALL revert with `BindingNotApproved`, and no vault ownership, owner-stake, or creator-record state SHALL change

#### Scenario: pushWiring rejects foreign governors
- **WHEN** `pushWiring` targets an address that is not a governor deployed by this factory
- **THEN** the call SHALL revert with `NotFactoryGovernor`

### Requirement: Status surface for the vault and observers
The governor SHALL expose the narrow `IProposalStatus` seam the vault consumes — `getActiveProposal()` (id of the executing proposal, 0 if none), `openProposalCount()` (count of proposals binding the vault; nonzero gates instant deposits), and `strategyOf(proposalId)` (scalar strategy adapter, address(0) = none) — plus full read views (`getProposal` with the authoritative resolved state overlaid, `getProposalState`, execute/settlement calls, vote weight and hasVoted, risk envelope, tier, required coverage, cooldown end, capital snapshot, and co-proposers). `getVoteWeight` on a Draft whose snapshot is unset SHALL revert with `ProposalInDraft` rather than silently returning zero.

#### Scenario: getProposal reports resolved state
- **WHEN** `getProposal` is read for a proposal whose stored state lags its time-determined state
- **THEN** the returned struct's `state` field SHALL carry the authoritative resolved value from the single resolver

#### Scenario: Draft vote weight query rejected
- **WHEN** `getVoteWeight` is called for a proposal still in Draft
- **THEN** the call SHALL revert with `ProposalInDraft`

