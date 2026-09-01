## ADDED Requirements

### Requirement: Affirmative-approval passage mode
Each per-vault governor SHALL carry an `approvalMode` parameter with exactly two values — `Optimistic` (0, the default and the only behavior available before this change) and `Affirmative` (1) — and an `approvalQuorumBps` parameter that is read ONLY in `Affirmative` mode. In `Affirmative` mode a Pending proposal SHALL be `Rejected` at `voteEnd` unless `votesFor >= liveSupply * approvalQuorumBps / 10_000`, where `liveSupply` is computed by exactly the same expression the optimistic veto path uses today (`getPastTotalSupply(snapshotTimestamp)` minus the withdrawal queue's checkpointed votes at that timestamp, floored at zero). Absence of votes SHALL therefore be a rejection, not a passage: a proposal that nobody votes on SHALL resolve to `Rejected` at `voteEnd` and SHALL NOT enter guardian review. The veto arithmetic SHALL NOT run in `Affirmative` mode — a proposal that clears the FOR quorum passes regardless of `votesAgainst`, because a mode with an affirmative bar has no need of a second, weaker rejection test and running both would create two thresholds an owner must reason about jointly. `liveSupply == 0` SHALL resolve `Rejected` in `Affirmative` mode (there is no supply that could ever reach the bar), which is the opposite of the optimistic path's skip-the-check behavior and is the fail-closed direction for each mode respectively.

Everything downstream of the vote SHALL be unchanged: a proposal that passes the affirmative bar enters `GuardianReview` on the identical predicate, the guardian review gate and its economic commit are untouched, and a guardian block still overrides an approved vote. The single resolver (`_computeState`) SHALL remain the one place passage is decided, and `_transition` SHALL remain the only writer of `p.state`; a rejection produced by a missed affirmative quorum SHALL report `reviewConcluded == false`, exactly as a veto rejection does, so no registry economic commit fires for it and the registered review is best-effort cancelled by the existing dead-proposal path.

`approvalMode` and `approvalQuorumBps` SHALL be snapshotted onto the proposal when it enters `Pending`, alongside the existing `vetoThresholdBps` snapshot, so a mid-vote parameter change cannot move the bar a voter was told about. Both snapshot fields SHALL be APPENDED as trailing members of `StrategyProposal` (append-only storage discipline for beacon-upgraded governors; `script/syndicate-governor-layout.golden.json` regenerated with an append-only diff).

#### Scenario: Silence rejects in affirmative mode
- **WHEN** a vault's governor is in `Affirmative` mode and voting ends with zero votes cast and a nonzero live supply
- **THEN** the proposal SHALL resolve to `Rejected` without traversing guardian review, and no registry economic commit SHALL fire for it

#### Scenario: FOR quorum reached
- **WHEN** voting ends in `Affirmative` mode with `votesFor` at or above the snapshotted `approvalQuorumBps` of live supply
- **THEN** the proposal SHALL proceed to `GuardianReview` on the same predicate as the optimistic path, and the guardian verdict SHALL still be able to block it

#### Scenario: Against votes are irrelevant once the bar is cleared
- **WHEN** a proposal in `Affirmative` mode ends voting with `votesFor` above the approval quorum and `votesAgainst` above the veto threshold
- **THEN** the proposal SHALL pass the vote — only the affirmative test runs in this mode

#### Scenario: Queue-escrowed shares do not raise the bar
- **WHEN** a holder escrows a large redeem into the withdrawal queue before `voteEnd` in `Affirmative` mode
- **THEN** the queue's checkpointed voting weight SHALL be netted out of `liveSupply` before the quorum is computed, exactly as it is for the veto threshold, so escrowed shares cannot make the quorum arithmetically unreachable

#### Scenario: Empty live supply fails closed
- **WHEN** `liveSupply` resolves to zero in `Affirmative` mode
- **THEN** the proposal SHALL resolve to `Rejected` (in `Optimistic` mode the veto check is skipped instead and the proposal proceeds — the fail-closed direction differs by mode and is deliberate)

#### Scenario: Mid-vote mode change cannot move the bar
- **WHEN** the vault owner changes `approvalMode` or `approvalQuorumBps` after a proposal entered Pending
- **THEN** the setter SHALL revert `ParamsFrozenDuringProposal`, and in the rescue path (`forceSetParams`) the in-flight proposal SHALL still resolve against its own snapshotted mode and quorum

### Requirement: Club vault creation preset
The factory SHALL accept, in its syndicate creation config, the parameters that constitute a club vault — closed deposits (`openDeposits == false`), a beneficial-owner cap (`maxHolders`), and the governor's `approvalMode` / `approvalQuorumBps` — and SHALL seat them atomically in the same transaction that creates the vault and its governor. There SHALL be NO separate "template" contract, "preset" enum, or template registry in `src/`: the club configuration is a documented BUNDLE of the parameters this change already adds, applied at creation, and the only protocol surface it needs is that those parameters be settable at creation rather than only afterwards. The named bundle — closed deposits, `maxHolders = 99`, `Affirmative` mode, a default `approvalQuorumBps`, and `agentFeeBps = 0` (management fee only, using the vault's existing owner-settable performance-fee surface) — SHALL live in tooling (CLI/docs), not in contract code.

Creation-time validation SHALL apply the same bounds as the individual setters, so a creation config can never seat a value a setter would reject. Seating `agentFeeBps = 0` at creation SHALL remain distinguishable from "never set" (the vault stores the fee offset-by-one for exactly this reason), so a club vault's explicit 0% agent fee SHALL NOT read back as the 20% default.

#### Scenario: Club creation seats every parameter atomically
- **WHEN** a creator calls `createSyndicate` with a club configuration
- **THEN** the vault SHALL be created with `openDeposits == false` and the configured `maxHolders`, its governor SHALL initialize in `Affirmative` mode with the configured quorum, and no post-creation transaction SHALL be required to reach the club posture

#### Scenario: Out-of-bounds creation config rejected
- **WHEN** a creation config carries an `approvalQuorumBps` outside the governor's hardcoded bounds, or a `maxHolders` the vault's own setter would reject
- **THEN** `createSyndicate` SHALL revert with the same error the corresponding setter raises, before any side effects

#### Scenario: Default creation is unchanged
- **WHEN** a creator omits the club parameters (zero/false defaults)
- **THEN** the syndicate SHALL be created exactly as it is today: open or whitelisted deposits per the existing flag, uncapped holders, and `Optimistic` passage

## MODIFIED Requirements

### Requirement: Optimistic passage with veto threshold
The governor SHALL support two passage modes, selected per vault by `approvalMode` and snapshotted onto each proposal at Pending. In `Optimistic` mode — the default, and the behavior of every vault that does not opt out — no FOR-vote quorum exists: at `voteEnd`, a Pending proposal SHALL be `Rejected` if and only if `votesAgainst >= liveSupply * vetoThresholdBps / 10_000`, where `vetoThresholdBps` is the per-proposal snapshot taken when the proposal entered Pending (a mid-vote parameter change cannot move the bar) and `liveSupply` is the vault supply at `snapshotTimestamp` less the withdrawal queue's checkpointed votes at that timestamp. When `liveSupply == 0`, the veto check SHALL be skipped (otherwise the threshold collapses to zero and every proposal auto-rejects). A proposal not vetoed at voteEnd proceeds into guardian review. In `Affirmative` mode the veto test SHALL NOT run and passage is governed instead by the affirmative-approval passage requirement.

#### Scenario: Veto threshold reached
- **WHEN** voting ends in `Optimistic` mode with `votesAgainst` at or above the snapshotted veto threshold of live supply
- **THEN** the proposal SHALL resolve to `Rejected` without traversing guardian review, and no registry economic commit SHALL fire for it

#### Scenario: Silence passes the vote
- **WHEN** voting ends in `Optimistic` mode with zero votes cast and a nonzero live supply
- **THEN** the proposal SHALL proceed to `GuardianReview` (or directly toward Approved if no review window is configured)

#### Scenario: Mode selects which test runs
- **WHEN** a proposal's snapshotted `approvalMode` is `Affirmative`
- **THEN** the veto arithmetic SHALL be skipped entirely and passage SHALL be decided by the FOR-vote quorum instead

### Requirement: Governance parameter management
Governance parameters (`votingPeriod`, `executionWindow`, `vetoThresholdBps`, `maxPerformanceFeeBps`, `cooldownPeriod`, `collaborationWindow`, `maxCoProposers`, `minStrategyDuration`, `maxStrategyDuration`, `maxCapitalBps`, `approvalMode`, `approvalQuorumBps`) SHALL be settable only by the vault owner (a multisig expected to enforce its own external delay), applied instantly, and frozen while any proposal binds the vault (`ParamsFrozenDuringProposal`). Every setter SHALL validate hardcoded bounds: votingPeriod within [per-deployment floor (mainnet 24h), 3d]; executionWindow [1h, 7d]; vetoThresholdBps [2_000, 8_000]; maxPerformanceFeeBps ≤ 3_000 (`FeeConstants.MAX_PERFORMANCE_FEE_BPS`, the hard ceiling — distinct from the 2_000 headline the factory ships); cooldownPeriod within [per-deployment floor (mainnet 1h), 30d]; strategyDuration bounds within [1h, 30d] with min ≤ max and max additionally capped by the protocol-wide `maxStrategyDuration` ceiling from ProtocolConfig (unset = no ceiling); collaborationWindow [1h, 7d]; maxCoProposers [1, 10]; maxCapitalBps [1, 10_000] with 0 stored meaning unset and reading as 10_000; `approvalMode` ∈ {`Optimistic`, `Affirmative`}; `approvalQuorumBps` within [2_000, 6_700]. `approvalQuorumBps` SHALL be validated on every write regardless of the mode in force, so a mode flip can never expose a value that was never bounds-checked. Every change SHALL emit the uniform `ParameterChangeFinalized(paramKey, old, new)` event, including for the two new keys (`PARAM_APPROVAL_MODE`, `PARAM_APPROVAL_QUORUM_BPS`). The per-deployment timing floors SHALL be implementation-constructor immutables bounded below by 1 minute.

#### Scenario: Parameters frozen mid-proposal
- **WHEN** the vault owner calls any parameter setter while `openProposalCount > 0`
- **THEN** the call SHALL revert with `ParamsFrozenDuringProposal`

#### Scenario: Out-of-bounds value rejected
- **WHEN** the vault owner sets `vetoThresholdBps` below 2_000 or above 8_000, or `approvalQuorumBps` below 2_000 or above 6_700
- **THEN** the call SHALL revert with `InvalidVetoThresholdBps` / `InvalidApprovalQuorumBps` respectively

#### Scenario: Quorum bounds hold even while optimistic
- **WHEN** the vault owner writes `approvalQuorumBps` while `approvalMode` is `Optimistic` (so the value is inert)
- **THEN** the bounds SHALL still be enforced, so a later flip to `Affirmative` can only ever activate a validated value

#### Scenario: Factory rescue bypasses the freeze but not the bounds
- **WHEN** the factory calls `forceSetParams` (reachable by the factory owner via `setParamsOverride`) during an active proposal
- **THEN** the full parameter set SHALL be applied without the `whenNoActiveProposal` freeze, but SHALL still pass the same bounds validation, `approvalMode` and `approvalQuorumBps` included

### Requirement: Factory creation of syndicates
`SyndicateFactory.createSyndicate(creatorAgentId, config)` SHALL, in one transaction: validate the config (non-zero asset, non-empty name/symbol/metadataURI, subdomain of at least 3 characters not already taken); require the creator to have a prepared owner stake in sWOOD (`canCreateVault`); collect the creation fee if configured; verify the creator owns the ERC-8004 agent identity when an agent registry is configured; deploy the vault as an immutable `ERC1967Proxy` plus its withdrawal queue; deploy the per-vault governor as a `BeaconProxy` initialized with the vault, guardian registry, protocol config, factory address, and the factory's default governor parameters OVERLAID with any club parameters carried in the creation config (`approvalMode`, `approvalQuorumBps`); record the vault-to-governor mapping (the sole vault↔governor wiring); authorize the governor on the guardian registry via `addGovernor`; push the factory's current tier registry, exposure ledger, and bond escrow into the fresh governor, skipping unset slots rather than writing zero; and bind the creator's prepared owner stake to the vault atomically. The vault SHALL be initialized with the config's `openDeposits` flag and its `maxHolders` cap in the same call. ENS subname registration SHALL be best-effort: any registrar failure (including a reverting `available()` view) SHALL emit `EnsRegistrationFailed` and never revert the creation; the subdomain-to-syndicate mapping is written unconditionally as the logical name reservation.

#### Scenario: Creation without prepared stake rejected
- **WHEN** a caller without a prepared owner stake calls `createSyndicate`
- **THEN** the call SHALL revert with `PreparedStakeNotFound` before any side effects

#### Scenario: Governor deployed with default parameters
- **WHEN** a syndicate is created without club parameters
- **THEN** its governor SHALL initialize with the factory defaults (votingPeriod 24h, executionWindow 24h, vetoThresholdBps 2_000, maxPerformanceFeeBps 2_000 (`FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS`), cooldownPeriod 1h, collaborationWindow 24h, maxCoProposers 10, strategyDuration bounds [1h, 30d], `approvalMode` `Optimistic`), all within the governor's own bounds validation

#### Scenario: ENS failure does not brick creation
- **WHEN** the ENS registrar is paused, faults, or the label was front-run
- **THEN** the syndicate SHALL still be created fully operational and `EnsRegistrationFailed` SHALL be emitted for out-of-band retry

#### Scenario: Duplicate subdomain rejected
- **WHEN** `config.subdomain` already maps to an existing syndicate
- **THEN** the call SHALL revert with `SubdomainTaken`
