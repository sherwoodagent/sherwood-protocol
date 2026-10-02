# Syndicate Governor Specification

## Purpose

Per-vault governance for agent-managed syndicate vaults: agents propose strategies as pre-committed call batches, shareholders vote optimistically (a proposal passes unless AGAINST votes reach a veto threshold), guardians review, and approved strategies execute and settle through the vault under a risk envelope. Covers the proposal lifecycle state machine, voting and quorum rules, execution safety guards, emergency settlement paths, beacon-based upgrades, factory creation of syndicates, and parameter governance.
## Requirements
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

### Requirement: Single open proposal per vault
The governor SHALL bind at most one non-terminal proposal lifecycle to its vault at a time. Both collaborative Drafts and Pending proposals count as binding the vault. The open-proposal count SHALL be incremented when a proposal enters Draft or Pending, and decremented exactly once when it reaches a terminal state (or Settled), with every decrement also stamping the settlement clock so lazily-expired proposals cannot dodge the propose cooldown.

#### Scenario: Second proposal blocked
- **WHEN** an agent calls `propose` while the vault has any non-terminal proposal (Draft, Pending, GuardianReview, Approved, or Executed)
- **THEN** the call SHALL revert with `VaultHasOpenProposal`

#### Scenario: Draft-to-Pending transition re-checks vault binding
- **WHEN** the final co-proposer approval would transition a Draft to Pending while another (non-self) proposal binds the vault
- **THEN** `approveCollaboration` SHALL revert with `VaultHasOpenProposal`

### Requirement: Proposal creation validation
`propose` SHALL only be callable by a registered agent of the governor's vault and, while the factory's `ownerOnlyProposals` is true, only by the vault owner and only without co-proposers; the flag SHALL be read live at propose time, so it binds agents registered before it was set. `propose` SHALL check, in this order: the `vault` argument equals the governor's bound vault (`VaultNotRegistered`); the caller is a registered agent (`NotRegisteredAgent`); the owner-only rule (`ProposerNotOwner`, `CollaborationDisabled`); the vault's owner bond is live (`OwnerBondNotLive`); no proposal is open on the vault (`VaultHasOpenProposal`); the settle cooldown has elapsed (`CooldownNotElapsed`); `strategy` is a strategy the protocol's `StrategyFactory` (resolved through the governor's tier registry) holds as registered with unchanged code (`StrategyNotRegistered(strategy)` — `address(0)`, an EOA and an unregistered contract are all refused); `strategyDuration` is at most both the vault's `maxStrategyDuration` and the protocol ceiling (`StrategyDurationTooLong`) and at least `minStrategyDuration` (`StrategyDurationTooShort`); `executeCalls` and `settlementCalls` are both non-empty (`EmptyExecuteCalls`, `EmptySettlementCalls`) and each at most 64 calls (`TooManyCalls`); every call in either batch obeys the vault's structural batch rules — a call whose target is not the vault's `asset()` names a registered strategy (`NotARegisteredStrategy(target)`, the vault's own error), and a call on the asset passes the same asset-call predicate the vault applies; `metadataURI` is at most 512 bytes (`MetadataURITooLong`); `envelope.maxCapital` is nonzero (`ZeroMaxCapital`); `envelope.maxDrawdownBps` is at most 10_000 (`InvalidDrawdown`); and the co-proposer rules. It SHALL then require one cap per call in each batch (`CallCapsLengthMismatch`), each batch's caps to sum to at most `maxCapital` (`CallCapsExceedMaxCapital`; zero caps are legal), `maxCapital` to be at most `totalAssets() * maxCapitalBps / 10_000` (`MaxCapitalExceedsCeiling`), and every call resolving to tier 2 to declare a cap at most `totalAssets() * tier2CallCapBps / 10_000` (`Tier2CallCapExceedsCeiling(index)`, the index within its own batch; checked at propose only). The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`, emitting `FeeClamped` when the clamp fires), the protocol and guardians fee recipients and the management and performance fee splits from ProtocolConfig, the risk envelope, the per-call caps, and the tier and required coverage priced per call through `tierOf` — all immutable for the proposal's lifetime. Beyond registration the `strategy` field names the proposal's strategy for observers and the vault's `strategyOf`, and settlement refuses to finish while it still answers `executed() == true`; the governor SHALL NOT probe the strategy's `proposer()` or `vault()` and SHALL NOT consult any registry allowlist for a call's target or recipient. The factory read SHALL be fail-closed: an unwired factory or one that does not answer registers nothing.

#### Scenario: Non-agent proposer rejected
- **WHEN** an address that is not a registered agent of the vault calls `propose`
- **THEN** the call SHALL revert with `NotRegisteredAgent`

#### Scenario: Owner-only proposals
- **WHEN** the factory's `ownerOnlyProposals` is true and a registered agent other than the vault owner calls `propose`
- **THEN** the call SHALL revert with `ProposerNotOwner`
- **AND** the vault owner, registered as an agent, SHALL propose as usual, while a proposal with co-proposers SHALL revert with `CollaborationDisabled`
- **AND** `setOwnerOnlyProposals(false)` SHALL restore proposing by every registered agent

#### Scenario: maxCapital ceiling enforced
- **WHEN** a proposer declares `envelope.maxCapital` greater than `totalAssets() * maxCapitalBps / 10_000`
- **THEN** the call SHALL revert with `MaxCapitalExceedsCeiling`

#### Scenario: Batch size and metadata caps
- **WHEN** `executeCalls.length` or `settlementCalls.length` exceeds 64, or `metadataURI` exceeds 512 bytes
- **THEN** the call SHALL revert with `TooManyCalls` or `MetadataURITooLong` respectively

#### Scenario: Caps must cover every call and fit the envelope
- **WHEN** a batch's caps array is shorter or longer than its calls array, or its caps sum to more than `maxCapital`
- **THEN** the call SHALL revert with `CallCapsLengthMismatch` or `CallCapsExceedMaxCapital` respectively

#### Scenario: Fee configuration snapshotted at propose
- **WHEN** the protocol multisig changes the fee splits or recipients in ProtocolConfig after a proposal is created
- **THEN** that proposal's settlement SHALL use the splits and recipients snapshotted at propose time, not the changed values

#### Scenario: Two legs priced at their own tiers
- **WHEN** a proposal's execute batch calls a certified class-member clone (tier 1, bound `b1`) and an uncertified custom contract (tier 2, bound 10_000), with per-call caps `c1` and `c2`
- **THEN** `requiredCoverage == c1 * b1 / 10_000 + c2` and `envelopeTier == 2`

#### Scenario: Uncertified registered strategy is admitted at full coverage
- **WHEN** a proposal's execute batch calls a registered strategy no certification names
- **THEN** `propose` succeeds and the proposal prices at tier 2 with full-notional coverage

#### Scenario: The strategy field must be registered
- **WHEN** `strategy` is `address(0)`, an EOA, or a contract nobody registered
- **THEN** `propose` reverts `StrategyNotRegistered(strategy)`; once the contract is registered the same call succeeds and `getProposal(pid).strategy` is the address verbatim

#### Scenario: Unregistered batch target refused at propose
- **WHEN** any call in `executeCalls` or `settlementCalls` names the vault, the queue, the governor or any unregistered contract
- **THEN** `propose` reverts `NotARegisteredStrategy(target)` and nothing is stored

### Requirement: Voting timeline and vote snapshot
A non-collaborative proposal SHALL enter `Pending` immediately at propose; a collaborative proposal enters `Pending` on the final co-proposer approval. On entering Pending the governor SHALL set: `snapshotTimestamp = block.timestamp - 1` (closing the same-block acquisition window), `votableSupply` (below), `voteEnd = now + votingPeriod`, `reviewEnd = voteEnd + reviewPeriod` (read from the guardian registry), and `executeBy = reviewEnd + executionWindow`. When `reviewEnd > voteEnd` the governor SHALL push the review window to the guardian registry via `registerReview` under exactly that predicate; a collapsed window (`reviewPeriod == 0`) is treated as no review configured.

#### Scenario: Vote weight from checkpointed shares
- **WHEN** a shareholder votes on a Pending proposal
- **THEN** their vote weight SHALL be the lesser of `getPastVotes(voter, snapshotTimestamp)` and `getPastVotes(voter, snapshotTimestamp + 1)` (the end of the propose second), so shares redeemed ahead of `propose` in its second carry no weight; a vote inside the propose second SHALL revert with `NotWithinVotingPeriod`, and a zero weight SHALL revert with `NoVotingPower`

#### Scenario: One vote per address
- **WHEN** an address that has already voted on a proposal votes again
- **THEN** the call SHALL revert with `AlreadyVoted`

#### Scenario: Voting only while Pending
- **WHEN** `vote` is called on a proposal whose resolved state is not `Pending` (voting ended, Draft, or terminal)
- **THEN** the call SHALL revert with `NotWithinVotingPeriod`

### Requirement: Optimistic passage with veto threshold
The governor SHALL use optimistic governance: no FOR-vote quorum exists. At `voteEnd`, a Pending proposal SHALL be `Rejected` if and only if `votesAgainst >= max(votableSupply * vetoThresholdBps / 10_000, 1)` (the threshold is floored at one vote, so a small electorate's threshold never rounds to zero), where `vetoThresholdBps` is the per-proposal snapshot taken when the proposal entered Pending (a mid-vote parameter change cannot move the bar) and `votableSupply` is the electorate recorded on entering Pending. On BOTH paths the electorate at an instant `t` is `E(t) = getPastTotalSupply(t) - getPastVotes(withdrawalQueue, t)`, clamped at zero, with the queue term skipped when no queue is wired; every holder is self-delegated, so `E(t)` is exactly the weight castable at `t`. Entering Pending SHALL record `votableSupply = E(snapshotTimestamp)`, and every `vote` SHALL lower it to `E(snapshotTimestamp + 1)` when that is smaller — the same two instants the vote weight reads, so the sum of castable weights SHALL NEVER exceed `votableSupply`. The value read before the first vote is therefore provisional; with no vote cast no veto can pass, so the outcome never depends on it. A holder who acquires shares in the propose second is outside both the electorate and the vote; a holder who exits or queues in the propose second leaves both. When `votableSupply == 0`, the veto check SHALL be skipped (otherwise the threshold collapses to zero and every proposal auto-rejects). A proposal not vetoed at voteEnd proceeds into guardian review.

#### Scenario: Veto threshold reached
- **WHEN** voting ends with `votesAgainst` at or above the snapshotted veto threshold of the recorded `votableSupply`
- **THEN** the proposal SHALL resolve to `Rejected` without traversing guardian review, and no registry economic commit SHALL fire for it

#### Scenario: Share flow in the propose second never inflates the veto bar
- **WHEN** a deposit, an instant redeem or a queued redeem lands in the propose second, on either side of `propose`
- **THEN** once a vote is cast `votableSupply` SHALL NOT exceed `E(snapshotTimestamp + 1)`, and no holder's weight exceeds its own votes at either instant, so a redeem ahead of `propose` followed by a re-deposit after it cannot cast more than the electorate holds

#### Scenario: A veto always costs at least one vote
- **WHEN** `votableSupply * vetoThresholdBps < 10_000` and voting ends with no votes against
- **THEN** the proposal SHALL NOT be rejected, because the threshold is floored at one vote

#### Scenario: Silence passes the vote
- **WHEN** voting ends with zero votes cast and a nonzero `votableSupply`
- **THEN** the proposal SHALL proceed to `GuardianReview` (or directly toward Approved if no review window is configured)

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

### Requirement: Execution safety guards
`executeProposal` SHALL be permissionless but SHALL only run when the resolved state is `Approved` (`ProposalNotApproved`), no other proposal is actively executing (`StrategyAlreadyActive`), and the vault's owner bond is still live (`OwnerBondNotLive`). The settle cooldown is enforced at `propose`, and since `cooldownPeriod` is frozen while a proposal is open it cannot be the first gate to fail at execute. Before executing it SHALL: snapshot the vault's asset balance as the capital snapshot and its price per share as the settle-price anchor; mark the proposal `Executed` and set `executedAt` before the execute batch (the owner-bond, asset-balance and price-per-share reads come first); start the vault's management-fee accrual; re-resolve tier and coverage from the stored calls of both legs and revert with `TierRegressed` if the live tier exceeds the propose-time `envelopeTier`, or `CoverageRegressed` if the live coverage exceeds the propose-time `requiredCoverage`; revert `MaxCapitalCeilingRegressed` if `maxCapital` now exceeds `totalAssets() * maxCapitalBps / 10_000`; and, when an exposure ledger is wired and `requiredCoverage != 0`, at every tier, measure the bond-encumbered approve coverage via `requireApproveQuorum` — which reverts on no covering approver (fail-closed: no identified, slashable approver means no execution) and otherwise returns `(coverageRaisedUsd, requiredCoverageUsd)`, from which the governor derives and stores the proposal's `effectiveMaxCapital` per the coverage-proportional effective capital requirement. The opening batch SHALL run via the vault's `executeGovernorBatch` with the (scaled) execute caps under the proposal's `effectiveMaxCapital` net-outflow cap (equal to `maxCapital` whenever coverage was full or the gate did not run). All execute/settle/cancel entrypoints SHALL be protected by a shared reentrancy lock.

#### Scenario: Cooldown between strategies
- **WHEN** `propose` is called before the cooldown deadline stamped at the last terminal event (`terminalAt + cooldownPeriod` as of that event; nothing ever settled: no cooldown)
- **THEN** the call SHALL revert with `CooldownNotElapsed`, giving depositors an exit window between strategies

#### Scenario: Stale certification blocks execution
- **WHEN** an adapter used by the proposal's calls was demoted or re-certified with a higher extractable bound after propose, so the live tier or coverage exceeds the propose-time snapshot
- **THEN** `executeProposal` SHALL revert (`TierRegressed` / `CoverageRegressed`), and the proposal SHALL remain `Approved` until `executeBy` expires it

#### Scenario: Missing approve quorum blocks execution
- **WHEN** an exposure ledger is wired and a coverage-consuming proposal has no covering approve coverage booked (empty approver set, or every contribution zero)
- **THEN** `executeProposal` SHALL revert `InsufficientApproveCoverage`, leaving the proposal `Approved` until `executeBy` expires it; no approval can be added after `reviewEnd`

#### Scenario: Partial approve coverage sizes execution instead of blocking it
- **WHEN** the same proposal reaches execute with a nonzero approve coverage below `requiredCoverageUsd`
- **THEN** execution SHALL proceed at the coverage-proportional `effectiveMaxCapital` instead of reverting

#### Scenario: Only one live strategy
- **WHEN** `executeProposal` is called while another proposal is in the Executed window
- **THEN** the call SHALL revert with `StrategyAlreadyActive`

### Requirement: Settlement and P&L
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` carrying the effective (coverage-scaled) settlement caps stored at execute and a net-outflow budget of ZERO: the settle batch may bring assets home (net inflow or zero) and SHALL revert `MaxNetOutflowExceeded(netOutflow, 0)` on any net asset egress, so the proposal's `effectiveMaxCapital` bounds the whole lifecycle's egress rather than each leg. Per-call settlement caps still meter the gross a settlement call may move. Settlement SHALL then revert `StrategyNotSettled(strategy)` while the proposal's strategy still answers `executed() == true`, and `SettlePriceBelowFloor(ppsNow, ppsFloor)` when the vault's price per share sits below the execute-time price less the proposal's declared `maxDrawdownBps` (capped at `MAX_STAMP_DRAWDOWN_BPS`, 9_000). Then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot taken at execute; the management fee and then the performance fee SHALL be charged; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV; then the active-proposal marker SHALL be cleared, the state moved to `Settled`, and the open count decremented.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: Interim LP flow excluded from P&L
- **WHEN** depositors try to add or remove principal while a strategy is live
- **THEN** instant deposits and redemptions are locked and queued requests sit in the withdrawal queue until the settle stamp, so the asset-balance delta settlement measures carries no interim LP flow and fees are charged only on strategy performance

#### Scenario: Settlement leg that does not unwind the strategy
- **WHEN** the settlement calls leave the proposal's strategy answering `executed() == true`
- **THEN** `settleProposal` and `unstick` SHALL revert with `StrategyNotSettled`; only the guardian-reviewed, owner-bonded `finalizeEmergencySettle` MAY close the proposal with the strategy still executed

#### Scenario: A settle batch cannot move assets out
- **WHEN** the settlement calls approve a registered strategy and it pulls one unit of the asset from the vault, within that call's cap
- **THEN** `settleProposal` reverts `MaxNetOutflowExceeded(1, 0)` and the proposal stays `Executed`

#### Scenario: A settle batch that brings assets home succeeds
- **WHEN** the settlement calls make the strategy return what the execute batch deployed and settle it, and the price per share is above the floor
- **THEN** `settleProposal` succeeds and the vault's balance is back to its pre-execute level

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
For a proposal stuck in `Executed` past `executedAt + strategyDuration`, the vault owner SHALL have two escape hatches. (1) `unstick`: run the governance-approved pre-committed settlement calls (no guardian review required, no owner stake required — the calls were already voted on) with the effective settlement caps and the same zero net-outflow budget as `settleProposal`, revert `StrategyNotSettled` while the strategy still answers `executed() == true`, apply the settle-price floor at `MAX_STAMP_DRAWDOWN_BPS` (9_000), then finalize settlement. (2) Owner-supplied calls: `emergencySettleWithCalls` SHALL open a guardian review on the registry keyed by the hash of the supplied calls (so a blocked earlier round resolves and slashes first) and SHALL then revert `OwnerBondInsufficient` unless the owner's bonded stake in the guardian registry is non-zero and meets the required owner bond; `cancelEmergencySettle` withdraws an open review (`EmergencyNotProposed` when none is open); `finalizeEmergencySettle` SHALL, after the registry review resolves, revert with `EmergencySettleBlocked` if guardians blocked it, revert `OwnerBondInsufficient` if the owner's stake is zero, otherwise execute the registry-stored calls with empty per-call caps and a net-outflow budget of ZERO, and finalize settlement, with no unwind check and no price floor. Every emergency call SHALL still pass the vault's structural batch rules. Net outflow is measured across the whole batch: vault float MAY leave inside the batch only if at least as much returns before the batch ends (a solvent repay the vault fronts and the redeemed collateral returns passes), and asset the strategy returns MAY be passed on; an insolvent unwind needs funds delivered to the strategy from outside the vault. All emergency entrypoints SHALL require the caller to be the vault owner, the proposal to be in `Executed` state, and SHALL share the governor's reentrancy lock.

#### Scenario: Unstick before duration elapses is rejected
- **WHEN** the vault owner calls `unstick` or `emergencySettleWithCalls` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Guardians block owner-supplied emergency calls
- **WHEN** the guardian review of an emergency settle reaches block quorum
- **THEN** `finalizeEmergencySettle` SHALL revert with `EmergencySettleBlocked` and the owner-supplied calls SHALL never execute

#### Scenario: Under-bonded owner cannot propose custom calls
- **WHEN** the vault owner's registry stake is below the required owner bond
- **THEN** `emergencySettleWithCalls` SHALL revert with `OwnerBondInsufficient`

#### Scenario: Emergency batch cannot move vault float
- **WHEN** an unblocked emergency batch on a proposal that deployed nothing calls `asset.transfer(recipient, n)` for any `n > 0`
- **THEN** `finalizeEmergencySettle` SHALL revert `MaxNetOutflowExceeded(n, 0)` and the vault balance SHALL be unchanged

#### Scenario: Vault-fronted repay returned within the batch
- **WHEN** an unblocked emergency batch sends `R` of the asset to the strategy, and the strategy repays its lender and returns at least `R` of the asset to the vault before the batch ends
- **THEN** `finalizeEmergencySettle` SHALL succeed under the zero budget; if the batch returns less than `R` (an insolvent position) it SHALL revert `MaxNetOutflowExceeded`

#### Scenario: Capital returned in the batch may be redirected
- **WHEN** an unblocked emergency batch makes the strategy return `C` of the asset and then transfers `C` to another address
- **THEN** the batch SHALL succeed (net outflow zero), and transferring `C + 1` SHALL revert `MaxNetOutflowExceeded(1, 0)`; the guardian review is the control on this residual

### Requirement: Risk tiering and proposer bond at propose
At propose time the governor SHALL resolve the proposal's tier and required coverage through the tier registry: tier = MAX tier across execute AND settlement calls (the aggregate the execute-time regression guard compares against); coverage = the per-call sum `Σ cap_i × boundBps_i / 10_000` across BOTH execute and settlement calls, where each call's contribution is its OWN declared cap times its certified bound (tier-0/1) or times 10_000 (tier-2/uncertified). Coverage SHALL be linear in the cap vector (scaling every cap by a factor scales coverage by the same factor, modulo floor rounding downward) — the property the execute-time proportional sizing consumes. A tier registry is always wired: the governor's `initialize` and `setTierRegistry` refuse a codeless registry (`TierRegistryNotWired`). `requiredCoverage == 0` is reachable when every declared cap is zero; such a proposal consumes no coverage and passes the execute-time quorum gate on its existing `requiredCoverage != 0` key, because it declares zero asset-extractable value and the per-call meter enforces exactly that declaration. When an exposure ledger is wired, propose SHALL additionally enforce the ledger's covered-TVL cap and coverage-horizon gates against the per-call-sum coverage (fail-closed, failing on the proposer; the collaborative path uses the worst-case deadline `now + collaborationWindow + votingPeriod + reviewPeriod + executionWindow`), and when a bond escrow is also wired and the ledger-priced risk-scaled WOOD proposer bond (priced from the per-call-sum coverage) is non-zero SHALL require the escrow to point at the same ledger (`LedgerEscrowMismatch`) and lock the bond in the escrow, recording the amount, the escrow address, AND the exposure-ledger address on the proposal before the external lock call. The recorded ledger is the one the reclaim gates read for the life of the bond — re-pointing the governor's live ledger slot afterwards MUST NOT change which ledger gates an already-locked bond.

#### Scenario: Coverage is the per-call sum, not full notional per call
- **GIVEN** a wired registry, `maxCapital` of 10,000,000, and a batch of a tier-0 call (100 bps bound) capped at 8,000,000, a tier-1 call (500 bps) capped at 1,900,000, and a tier-2 call capped at 100,000
- **WHEN** the proposal is created
- **THEN** `requiredCoverage` SHALL be 80,000 + 95,000 + 100,000 = 275,000 — not the 10,000,000+ the proposal-wide formula would have priced — and the risk-scaled proposer bond SHALL be priced from that per-call sum

#### Scenario: Unwired registries keep the safe default
- **WHEN** no exposure ledger is wired (a tier registry cannot be unwired)
- **THEN** the covered-TVL, coverage-horizon and bond gates SHALL be skipped, and tier and coverage are still priced through the tier registry

#### Scenario: All-zero caps price zero coverage
- **GIVEN** a wired registry and a proposal whose every cap is zero
- **WHEN** the proposal is created and later executed
- **THEN** `requiredCoverage` SHALL be 0, the approve-quorum gate SHALL be skipped on its `requiredCoverage != 0` key, and the per-call meter SHALL revert any call that moves any vault asset out of custody

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
Governance parameters (`votingPeriod`, `executionWindow`, `vetoThresholdBps`, `maxPerformanceFeeBps`, `cooldownPeriod`, `collaborationWindow`, `maxCoProposers`, `minStrategyDuration`, `maxStrategyDuration`, `maxCapitalBps`, `tier2CallCapBps`) SHALL be settable only by the vault owner, applied instantly in the same transaction, and frozen while any proposal binds the vault (`ParamsFrozenDuringProposal`). No on-chain delay or notice applies: the owner can change a parameter and propose in the same block. An open proposal keeps the `voteEnd` and veto threshold it recorded on entering Pending (at `propose`, or for a collaborative proposal at the Draft→Pending transition). Every setter SHALL validate hardcoded bounds: votingPeriod within [`MIN_VOTING_PERIOD`, 3 days]; executionWindow [1h, 7d]; vetoThresholdBps [2_000, 8_000]; maxPerformanceFeeBps ≤ 2_500 (`FeeConstants.MAX_PERFORMANCE_FEE_BPS`, the hard ceiling — distinct from the 2_000 headline the factory ships); cooldownPeriod within [`MIN_COOLDOWN_PERIOD`, 30d]; strategyDuration bounds within [1h, 30d] with min ≤ max and max additionally capped by the protocol-wide `maxStrategyDuration` ceiling from ProtocolConfig (unset = no ceiling); collaborationWindow [1h, 7d]; maxCoProposers [1, 10]; maxCapitalBps [1, 10_000] with 0 stored meaning unset and reading as 10_000; tier2CallCapBps [1, 10_000] with 0 stored meaning unset and reading as 10_000. Every setter SHALL emit the uniform `ParameterChangeFinalized(paramKey, old, new)` event. `MIN_VOTING_PERIOD` and `MIN_COOLDOWN_PERIOD` SHALL be implementation-constructor immutables bounded below by 1 minute and above by their parameter's maximum (3 days and 30 days). The Robinhood mainnet implementation sets both to 1 hour (`RobinhoodParams`), so the vault owner may run a 1-hour LP vote at an 80% veto threshold; the factory's per-vault default is a 24-hour vote at 20%.

#### Scenario: Parameters frozen mid-proposal
- **WHEN** the vault owner calls any parameter setter while `openProposalCount > 0`
- **THEN** the call SHALL revert with `ParamsFrozenDuringProposal`

#### Scenario: Out-of-bounds value rejected
- **WHEN** the vault owner sets `vetoThresholdBps` below 2_000 or above 8_000
- **THEN** the call SHALL revert with `InvalidVetoThresholdBps`

#### Scenario: Shortest legal veto window on mainnet
- **WHEN** the owner of a vault on the Robinhood mainnet implementation sets `votingPeriod` to 1 hour and `vetoThresholdBps` to 8_000 and proposes in the same block
- **THEN** the proposal's `voteEnd` is one hour after propose, and it is rejected only if votes against reach 80% of its votable supply

#### Scenario: Factory rescue bypasses the freeze but not the bounds
- **WHEN** the factory calls `forceSetParams` (reachable by the factory owner via `setParamsOverride`) during an active proposal
- **THEN** the `GovernorParams` set (every parameter above except `maxCapitalBps` and `tier2CallCapBps`) SHALL be applied without the `whenNoActiveProposal` freeze, but SHALL still pass the same bounds validation, and a single `ParameterChangeFinalized("forceSetParams", 0, 0)` SHALL be emitted

#### Scenario: Unset tier-2 ceiling is inert
- **WHEN** `tier2CallCapBps` has never been set
- **THEN** it SHALL read as 10_000 and the per-call tier-2 ceiling SHALL admit any cap the other propose-time validations admit

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

### Requirement: Beacon upgrade rules
Every per-vault governor SHALL be deployed as a `BeaconProxy` reading its implementation from the shared `GovernorBeacon` (an OpenZeppelin `UpgradeableBeacon`). `GovernorBeacon.upgradeTo(newImpl)` SHALL be restricted to the beacon owner (the factory-owner multisig behind a delay module) and SHALL atomically re-point every live vault governor to the new implementation. Governor implementations SHALL disable their own initializers at construction, and per-deployment timing floors bake into implementation bytecode so a floor change is an implementation swap via the beacon, not a storage migration.

#### Scenario: Mass upgrade in one transaction
- **WHEN** the beacon owner calls `upgradeTo(newImpl)`
- **THEN** every governor proxy deployed against that beacon SHALL execute the new implementation on its next call, with per-governor storage unchanged

#### Scenario: Non-owner upgrade rejected
- **WHEN** any address other than the beacon owner calls `upgradeTo`
- **THEN** the call SHALL revert

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

### Requirement: Factory lifecycle-gated administration
The factory SHALL gate structural changes on the governor's lifecycle state. `rotateOwner(vault, newOwner)` SHALL require the caller to be the current vault owner or the vault's creator record (which every rotation overwrites with the new owner), the old owner stake to be fully withdrawn (`VaultStillStaked`), and the incoming owner's prior vault-specific consent to the stake binding (recorded on sWOOD by `newOwner` via `approveOwnerStakeBinding(vault)` — adversary: a current owner of an empty-slot vault must not be able to spend a third party's escrowed prepared stake by rotating the vault onto them); when `newOwner` differs from the current owner it SHALL additionally require both `getActiveProposal() == 0` and `openProposalCount() == 0`. A rotation to the current owner is a re-bond (for example after a blocked emergency round burned the bond) and SHALL be allowed while a proposal is open; it spends only the owner's own prepared stake with the owner's own consent. `rotateOwner` SHALL transfer vault ownership, rebind the owner-stake slot on sWOOD (consuming the consent), and update the creator record. The signature and single-call semantics of `rotateOwner` SHALL be unchanged — consent is enforced at the sWOOD spend site, not by a new factory entrypoint. `upgradeVault(vault, expectedImpl)` SHALL require upgrades enabled, the caller to be the creator, `vaultImpl == expectedImpl` (so a factory-owner impl swap cannot land an implementation the creator did not opt into), and both lifecycle gates. `pushWiring(governor)` SHALL be factory-owner-only, SHALL verify the target is a governor this factory deployed (via the unforgeable `governor.vault()` → `governorOf` round-trip), and SHALL push only the factory's currently-set tier registry / exposure ledger / bond escrow — never writing zero, so wiring can be added but never silently removed. The factory's guardian registry is set once at `initialize`; there is no setter.

The factory SHALL additionally own the batch-executor migration primitives: `setExecutorImpl(newImpl)` SHALL be factory-owner-only, reject the zero address (`InvalidExecutorImpl`), and change which executor library NEW syndicates are wired to at creation (existing vaults are untouched by it). `pushExecutor(vault)` SHALL be factory-owner-only, SHALL verify the vault is one this factory deployed (`VaultNotDeployed`), SHALL require the vault's governor lifecycle quiet (`getActiveProposal() == 0` and `openProposalCount() == 0` — a re-point under a live proposal would swap the meter out from under stored, coverage-priced calls), and SHALL push the factory's current executor into the vault via the vault's factory-only re-point, which updates the executor address AND re-stamps the expected executor codehash atomically. A vault whose executor was not migrated after a library ABI change SHALL fail closed on its next governor batch (unknown selector, no fallback on the library) — strategies unavailable, funds and LP exits unaffected — until `pushExecutor` runs.

#### Scenario: Rotation blocked mid-lifecycle
- **WHEN** `rotateOwner` to an address other than the current owner, or `upgradeVault`, is called while the vault's governor has an executing proposal or any open proposal
- **THEN** the call SHALL revert (`ProposalActive` / `StrategyActive` or `ProposalsOpen`)

#### Scenario: Same-owner re-bond mid-lifecycle
- **WHEN** the vault's bond slot is empty, the current owner has prepared a stake and approved `vault` for binding, and calls `rotateOwner(vault, owner)` while a proposal is open
- **THEN** the call SHALL succeed and the owner-stake slot SHALL hold the prepared stake, so a new emergency round can open

#### Scenario: Rotation without the incoming owner's consent
- **WHEN** `rotateOwner(vault, newOwner)` passes the caller and lifecycle gates but `newOwner` has not approved `vault` for stake binding on sWOOD
- **THEN** the call SHALL revert with `BindingNotApproved`, and no vault ownership, owner-stake, or creator-record state SHALL change

#### Scenario: pushWiring rejects foreign governors
- **WHEN** `pushWiring` targets an address that is not a governor deployed by this factory
- **THEN** the call SHALL revert with `NotFactoryGovernor`

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

### Requirement: Owner bond gates the normal proposal lane
`propose` and `executeProposal` SHALL both refuse with `OwnerBondNotLive` when `IGuardianRegistry.ownerBondLive(vault)` is false, read through the registry handle the governor already holds — the same route `GovernorEmergency` uses for `ownerStake`. The gate SHALL be re-asserted at execute and not only at admission: the bond that matters is the one live WHEN CAPITAL MOVES, and the vote plus the review period sit between the two points. The reachable route between them is `slashOwnerBond`, which carries no open-proposal gate; the owner's own exit is not that route, because `requestUnstakeOwner` refuses while a proposal is open and `propose` refuses once a request is in. The gate SHALL be a state check and not a latch, so re-funding the slot reopens the lane. Registered-agent status (`isAgent`) is independent of the owner's stake and SHALL NOT be treated as a substitute for this check.

#### Scenario: Propose refused without a live owner bond
- **WHEN** a registered agent calls `propose` on a vault whose owner-stake slot is exiting, claimed or slashed
- **THEN** the call SHALL revert with `OwnerBondNotLive`

#### Scenario: Bonded vault proposes as before
- **WHEN** the owner-stake slot is bound and not exiting
- **THEN** `propose` SHALL behave exactly as it did before this change

#### Scenario: Execute refused when the bond leaves after approval
- **GIVEN** an `Approved` proposal whose vault's owner bond was slashed after propose
- **WHEN** `executeProposal` is called
- **THEN** it SHALL revert with `OwnerBondNotLive` before any batch runs

#### Scenario: An approved proposal is not bricked
- **WHEN** the owner-stake slot is re-funded inside the execution window after an `OwnerBondNotLive` refusal
- **THEN** `executeProposal` SHALL succeed for the same proposal

### Requirement: Fee distribution charges every proposal
Every settlement path (`settleProposal`, `unstick`, `finalizeEmergencySettle`) SHALL charge both fee legs, in order; no strategy self-report can exempt a proposal from either. (1) Management fee = `assetSeconds × managementFeeBps / (10_000 × 365 days)`, where `assetSeconds` is the vault's accrual from execute to settle (consumed and reset at settlement) and `managementFeeBps` is the vault's rate, fixed at vault initialization; it is split by the snapshotted management split into protocol, guardian and agent shares, the agent taking the remainder. (2) Performance fee = `base × performanceFeeBps / 10_000`, where `base = min(aboveHighWaterMark(), max(pnl, 0))`, read after the management fee has left the vault, and the propose-time `performanceFeeBps` is re-clamped to the live `maxPerformanceFeeBps` (emitting `FeeClamped` when the clamp fires); it is split by the snapshotted performance split into protocol, guardian, vault-owner and agent shares, the agent taking the remainder. The high-water mark SHALL be ratcheted after every settlement whether or not a fee was charged. If a snapshotted split did not sum to 10_000, the management fee would be zero (after the accrual is consumed) and the performance fee zero with the mark still ratcheted; `ProtocolConfig`'s constructor and setters (`InvalidMgmtSplit`, `InvalidPerfSplit`) make such a split unreachable. A protocol or guardian share whose snapshotted recipient is `address(0)` SHALL fold into the agent's share. The agent's share of either leg SHALL be split across co-proposers by their `splitBps` with the remainder to the lead proposer; a co-proposer who is no longer a registered agent at settlement forfeits its share, which stays in the vault and is not paid to the lead. `GuardianFeeAccrued` SHALL be emitted for a guardian share only when its transfer delivers. Any individual fee transfer that reverts (e.g. a blacklisted recipient) SHALL be escrowed against `(vault, recipient, token)` instead of reverting settlement, emitting `FeeTransferFailed`, with the escrowed amount capped at the vault's `spendableFee` (`FeeEscrowCapped` when the cap binds). Recipients pull escrowed amounts later via `claimUnclaimedFees`, which SHALL be `nonReentrant`, SHALL revert `VaultProposalActive` while the claimed vault has an executing proposal, SHALL zero the escrow slot before transferring, and SHALL only pay from the vault that owes it.

#### Scenario: Settlement never bricks on a bad recipient
- **WHEN** a fee recipient's transfer reverts during settlement
- **THEN** the amount SHALL be recorded in the unclaimed-fees escrow, the rest of the waterfall SHALL continue, and the proposal SHALL still reach `Settled`

#### Scenario: Guardian fee attribution only on delivery
- **WHEN** the guardian-fee transfer escrows instead of delivering
- **THEN** `GuardianFeeAccrued` SHALL NOT be emitted (preventing the off-chain airdrop bot from double-paying)

#### Scenario: Inactive co-proposer forfeits
- **WHEN** a co-proposer is no longer a registered agent at settlement
- **THEN** their share SHALL stay in the vault, the lead SHALL receive only its own share, and the co-proposer distribution SHALL never pay out more than the agent fee

#### Scenario: No self-report skips a fee leg
- **WHEN** a proposal settles, whatever its strategy reports about itself
- **THEN** the management fee is charged, the performance fee is computed from the high-water mark and the realized P&L, and the mark is ratcheted

#### Scenario: Ordinary escrow claim unaffected
- **WHEN** an escrowed recipient calls `claimUnclaimedFees` directly while the vault has no executing proposal
- **THEN** the call succeeds, zeroes the escrow slot, and transfers the amount

### Requirement: Coverage-proportional effective capital
The governor SHALL derive, at execute time, an effective capital ceiling from the coverage the approve quorum actually raised, and SHALL use it — not the declared `maxCapital` — as the net-outflow cap for the execute batch. Derivation: when the quorum gate runs, the ledger returns `(coverageRaisedUsd, requiredCoverageUsd)`; `effectiveMaxCapital = maxCapital` when `coverageRaisedUsd >= requiredCoverageUsd`, else `floor(maxCapital × coverageRaisedUsd / requiredCoverageUsd)` — surplus coverage SHALL NOT raise the ceiling above the declared `maxCapital`, and the floor MAY produce zero on dust coverage (a zero effective cap executes with no permitted net outflow — fail-closed). When the gate does not run (no ledger wired, or `requiredCoverage == 0`), `effectiveMaxCapital` SHALL equal `maxCapital`. The value SHALL be stored in the proposal's `effectiveMaxCapital` field, written on EVERY execute path so a stored zero never means "unset" on an executed proposal, and SHALL be immutable once written. Settlement does not read it: the settle batch runs with a zero net-outflow budget and the settlement caps stored at execute, so later moves in live coverage never re-size the unwind. The governor SHALL emit `EffectiveMaxCapitalSet(proposalId, declaredMaxCapital, effectiveMaxCapital, coverageRaisedUsd, requiredCoverageUsd)` at execute and SHALL expose `getEffectiveMaxCapital(proposalId)` (0 before execution); `getRiskEnvelope` keeps returning the declared envelope. When coverage falls short, the governor SHALL scale every per-call cap by the same factor (`effectiveCap_i = floor(cap_i × coverageRaisedUsd / requiredCoverageUsd)`), SHALL re-assert `Σ effectiveCaps ≤ effectiveMaxCapital` per batch after floor-rounding (clamping the largest scaled cap by the excess on violation), and SHALL persist the settlement caps (scaled, or an identity copy when no scaling applied) at execute so the settlement batch is metered by byte-identical caps however much later it runs.

#### Scenario: Partial coverage executes at proportional size
- **WHEN** a proposal declaring `maxCapital = 1_000_000` reaches execute with 40% of its required coverage raised
- **THEN** execution proceeds with `effectiveMaxCapital = 400_000`, the vault's net-outflow meter reverts any attempt to move more, and `EffectiveMaxCapitalSet` records both the declared and effective figures

#### Scenario: Surplus coverage does not inflate the ceiling
- **WHEN** the raised coverage exceeds `requiredCoverageUsd`
- **THEN** `effectiveMaxCapital` equals the declared `maxCapital` exactly — coverage can only shrink the ceiling, never grow it

#### Scenario: Settlement is metered by the caps stored at execute
- **WHEN** a proposal executed at 80% size and a covering guardian is later slashed on an unrelated proposal before settlement
- **THEN** `settleProposal` meters the settlement batch with the scaled settlement caps persisted at execute and a zero net-outflow budget — the later slash does not re-size the unwind

#### Scenario: Ungated proposals are not resized
- **WHEN** a proposal executes with no exposure ledger wired, or with `requiredCoverage == 0`
- **THEN** `effectiveMaxCapital` is stored equal to `maxCapital` and the caps are unscaled

#### Scenario: Per-call caps scale by the same factor
- **WHEN** a proposal executes at 50% coverage
- **THEN** every execute and settlement call cap is floored to half its declared value, the per-batch sum is re-asserted against `effectiveMaxCapital` after rounding, and the scaled settlement caps are persisted at execute

