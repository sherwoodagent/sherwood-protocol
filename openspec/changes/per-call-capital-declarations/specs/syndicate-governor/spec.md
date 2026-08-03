# syndicate-governor (delta)

## MODIFIED Requirements

### Requirement: Proposal creation validation
`propose` SHALL take, alongside `executeCalls` and `settlementCalls`, two parallel per-call capital cap arrays (`executeCallCaps`, `settlementCallCaps`, one `uint256` per call, denominated in the vault asset) — an accepted breaking change to `propose`'s ABI. `propose` SHALL only be callable by a registered agent of the governor's vault, and SHALL validate: the `vault` argument equals the governor's bound vault; `strategyDuration` is within `[minStrategyDuration, maxStrategyDuration]`; `executeCalls` and `settlementCalls` are both non-empty and each at most 64 calls; each cap array's length equals its call array's length (`CallCapsLengthMismatch` otherwise); `Σ executeCallCaps ≤ envelope.maxCapital` AND `Σ settlementCallCaps ≤ envelope.maxCapital`, evaluated per batch and not combined (`CallCapsExceedMaxCapital` otherwise) — the two batches execute in separate transactions, each independently bounded by the vault's `maxCapital` net-outflow meter, and an honest settlement legitimately re-moves the capital the execute batch deployed; `metadataURI` is at most 512 bytes; `envelope.maxCapital` is nonzero and at most `totalAssets() * maxCapitalBps / 10_000` at propose time; and `envelope.maxDrawdownBps` is at most 10_000. Individual caps of zero SHALL be legal at every tier — a zero cap declares that the call moves no vault asset, and the per-call meter enforces exactly that declaration. The proposal SHALL snapshot at propose time: the agent performance fee (clamped to `maxPerformanceFeeBps`), the protocol and guardian fee bps and recipients from ProtocolConfig, the strategy's `selfManagesFees` flag, the risk envelope, and both cap arrays — all immutable for the proposal's lifetime, with the caps stored per-proposal and readable via `getCallCaps(proposalId)`.

`propose` SHALL additionally reject any entry of `executeCalls` or `settlementCalls` whose `target` the vault's privileged-batch-target predicate flags (the vault itself or its bound withdrawal queue), reverting `DisallowedBatchTarget(target)` — the same error the vault's execution-time guard raises for the same violation. The check SHALL consume the vault's own predicate view rather than restating the address set in the governor, covers ONLY the unconditional privileged-target denylist (never the registry-gated selector half, which depends on mutable state), and SHALL degrade open when the vault does not expose the predicate view — the execution-time guard in `executeGovernorBatch` remains the authoritative enforcement regardless. The per-call cap validation SHALL be independent of this target check: it SHALL run in full even when the target check degrades open, and SHALL never consult the vault.

When a tier registry is wired, `propose` SHALL additionally enforce the per-call tier-2 ceiling: every call in EITHER array whose (target, selector) resolves to tier 2 (uncertified included) SHALL declare a cap at most `totalAssets() * tier2CallCapBps / 10_000` at propose time, reverting `Tier2CallCapExceedsCeiling` otherwise. The ceiling SHALL be evaluated inside the same registry sweep that prices coverage (one scan, not two) and SHALL NOT be re-evaluated at execute — post-propose tier drift is the regression guards' concern.

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

#### Scenario: Cap array length mismatch rejected
- **WHEN** a proposer supplies `executeCallCaps` whose length differs from `executeCalls`, or `settlementCallCaps` whose length differs from `settlementCalls`
- **THEN** the call SHALL revert with `CallCapsLengthMismatch`

#### Scenario: Caps summing over the envelope rejected per batch
- **WHEN** `Σ executeCallCaps` or `Σ settlementCallCaps` exceeds `envelope.maxCapital`
- **THEN** the call SHALL revert with `CallCapsExceedMaxCapital`
- **AND** a proposal whose execute caps and settlement caps EACH sum within `maxCapital` SHALL pass this check even when the two sums combined exceed `maxCapital` (the batches are separately metered)

#### Scenario: Tier-2 call cap above the per-call ceiling rejected at propose
- **GIVEN** a wired tier registry and `tier2CallCapBps` set to 200
- **WHEN** a proposer declares a cap greater than 2% of `totalAssets()` on a call whose (target, selector) resolves to tier 2 — in either the execute or the settlement array
- **THEN** the call SHALL revert with `Tier2CallCapExceedsCeiling`, while the same cap on a certified tier-0/1 call SHALL be accepted

#### Scenario: Zero caps legal, mixed batch accepted
- **WHEN** a proposer declares a batch mixing a tier-0 call capped at 80% of `maxCapital`, a tier-1 call capped at 19%, a tier-2 call capped at 1% (within the tier-2 ceiling), and a zero-capped tier-2 harvest call
- **THEN** `propose` SHALL accept it, storing the caps immutably and pricing coverage from them per-call

#### Scenario: Settlement call naming the withdrawal queue rejected at propose
- **WHEN** a registered agent calls `propose` with a `settlementCalls` entry whose `target` is the vault's bound withdrawal queue
- **THEN** the call SHALL revert with `DisallowedBatchTarget(queue)` at propose

#### Scenario: Cap validation independent of the target-check degrade path
- **GIVEN** a vault that does not expose the privileged-batch-target predicate view (the target check degrades open)
- **WHEN** a registered agent proposes with caps violating the per-batch sum rule
- **THEN** the call SHALL still revert with `CallCapsExceedMaxCapital` — cap validation never degrades and never consults the vault

### Requirement: Risk tiering and proposer bond at propose
At propose time the governor SHALL resolve the proposal's tier and required coverage through the tier registry: tier = MAX tier across execute calls (batch-wide, unchanged — the fail-closed aggregate for the quorum-tier gate and the regression guard); coverage = the per-call sum `Σ cap_i × boundBps_i / 10_000` across BOTH execute and settlement calls, where each call's contribution is its OWN declared cap times its certified bound (tier-0/1) or times 10_000 (tier-2/uncertified). Coverage SHALL be linear in the cap vector (scaling every cap by a factor scales coverage by the same factor, modulo floor rounding downward) — the property issue #27's proportional sizing consumes. With no tier registry wired, every proposal SHALL resolve to tier 2 with `requiredCoverage == maxCapital` (the pre-registry safe default is NOT made cheaper by per-call caps). `requiredCoverage == 0` is reachable when every declared cap is zero; such a proposal consumes no coverage and passes the execute-time quorum gate on its existing `requiredCoverage != 0` key, because it declares zero asset-extractable value and the per-call meter enforces exactly that declaration. When an exposure ledger is wired, propose SHALL additionally enforce the ledger's covered-TVL cap and coverage-horizon gates against the per-call-sum coverage (fail-closed, failing on the proposer; the collaborative path uses the worst-case deadline `now + collaborationWindow + votingPeriod + reviewPeriod + executionWindow`), and when a bond escrow is also wired SHALL lock the ledger-priced risk-scaled WOOD proposer bond — now priced from the per-call-sum coverage — in the escrow, recording the amount, the escrow address, AND the exposure-ledger address on the proposal before the external lock call. The recorded ledger is the one the reclaim gates read for the life of the bond — re-pointing the governor's live ledger slot afterwards MUST NOT change which ledger gates an already-locked bond.

#### Scenario: Coverage is the per-call sum, not full notional per call
- **GIVEN** a wired registry, `maxCapital` of 10,000,000, and a batch of a tier-0 call (100 bps bound) capped at 8,000,000, a tier-1 call (500 bps) capped at 1,900,000, and a tier-2 call capped at 100,000
- **WHEN** the proposal is created
- **THEN** `requiredCoverage` SHALL be 80,000 + 95,000 + 100,000 = 275,000 — not the 10,000,000+ the proposal-wide formula would have priced — and the risk-scaled proposer bond SHALL be priced from that per-call sum

#### Scenario: Unwired registries keep the safe default
- **WHEN** no tier registry is wired
- **THEN** every proposal SHALL be tier 2 with `requiredCoverage == maxCapital` regardless of the declared caps, and with no exposure ledger wired the covered-TVL and bond gates SHALL be skipped

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

### Requirement: Execution safety guards
`executeProposal` SHALL be permissionless but SHALL only run when the resolved state is `Approved`, no other proposal is actively executing, and the cooldown has elapsed (`block.timestamp >= lastSettledAt + cooldownPeriod`, skipped when nothing ever settled). Before executing it SHALL: snapshot the vault's asset balance as the capital snapshot; mark the proposal `Executed` and set `executedAt` before any external call (CEI); re-resolve tier and coverage from the stored calls AND the stored per-call caps (the same immutable inputs priced at propose) and revert with `TierRegressed` if the live tier exceeds the propose-time `envelopeTier`, or `CoverageRegressed` if the live per-call-sum coverage exceeds the propose-time `requiredCoverage`; and, when an exposure ledger is wired and `requiredCoverage != 0` and the tier is at or above the ledger's quorum tier threshold, require a bond-encumbered approve quorum via `requireApproveQuorum` (fail-closed: silence does not execute a coverage-consuming proposal). The opening batch SHALL run via the vault's `executeGovernorBatch` carrying the stored `executeCallCaps` (per-call gross-outflow enforcement) under the proposal's `maxCapital` net-outflow cap (batch-level enforcement) — two distinct accounting layers, both mandatory on this path. All execute/settle/cancel entrypoints SHALL be protected by a shared reentrancy lock.

#### Scenario: Cooldown between strategies
- **WHEN** `executeProposal` is called before `lastSettledAt + cooldownPeriod` has elapsed
- **THEN** the call SHALL revert with `CooldownNotElapsed`, giving depositors an exit window between strategies

#### Scenario: Stale certification blocks execution
- **WHEN** an adapter used by the proposal's calls was demoted or re-certified with a higher extractable bound after propose, so the live tier or the live per-call-sum coverage exceeds the propose-time snapshot
- **THEN** `executeProposal` SHALL revert (`TierRegressed` / `CoverageRegressed`), and the proposal SHALL remain `Approved` until `executeBy` expires it

#### Scenario: Missing approve quorum blocks execution
- **WHEN** an exposure ledger is wired and a coverage-consuming proposal at or above the quorum tier threshold has no covering approve quorum booked
- **THEN** `executeProposal` SHALL revert, leaving the proposal `Approved` (executable later if covering approvals arrive before `executeBy`)

#### Scenario: Only one live strategy
- **WHEN** `executeProposal` is called while another proposal is in the Executed window
- **THEN** the call SHALL revert with `StrategyAlreadyActive`

#### Scenario: Call exceeding its own cap reverts even under the batch total
- **GIVEN** an executed batch whose call 2 is capped at 100,000 while `maxCapital` is 10,000,000
- **WHEN** call 2's gross outflow of the vault asset reaches 100,001, with the whole batch's net outflow far below `maxCapital`
- **THEN** the batch SHALL revert with `CallCapExceeded(1, 100001, 100000)` and the proposal SHALL remain `Approved` (expiring at `executeBy` if never re-executed within bounds)

### Requirement: Settlement and P&L
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` carrying the stored `settlementCallCaps` under the same `maxCapital` cap as execution — the per-call caps bind the settlement leg for the same reason coverage prices it: settlement calls are arbitrary pre-committed calldata, and a malicious proposer parking extraction there to self-settle after 1 hour is the attack the cap bounds. Then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot minus the vault's interim LP net flow (deposits/withdrawals during the strategy are principal, not performance); state SHALL move to `Settled`, the active-proposal marker cleared, and the open count decremented before external fee transfers; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: Interim LP flow excluded from P&L
- **WHEN** depositors add or remove principal while a strategy is live
- **THEN** the settlement P&L SHALL exclude that interim net flow, so fees are charged only on strategy performance

#### Scenario: Settlement leg is per-call metered
- **WHEN** a settlement call's gross outflow of the vault asset exceeds its stored cap
- **THEN** the settlement batch SHALL revert with `CallCapExceeded`, leaving the proposal `Executed` for the emergency paths — extraction parked in `settlementCalls` is bounded per call, not only by `maxCapital`

### Requirement: Emergency settlement paths
For a proposal stuck in `Executed` past `executedAt + strategyDuration`, the vault owner SHALL have two escape hatches. (1) `unstick`: run the governance-approved pre-committed settlement calls (no guardian review required, no owner stake required — the calls were already voted on) carrying the stored `settlementCallCaps` under the proposal's `maxCapital` cap — the same caps the voted batch was priced with, since `unstick` replays exactly those calls — then finalize settlement. (2) Owner-supplied calls: `emergencySettleWithCalls` SHALL require the owner's bonded stake in the guardian registry to meet the required owner bond, and SHALL open a guardian review on the registry keyed by the hash of the supplied calls; `cancelEmergencySettle` withdraws an open review; `finalizeEmergencySettle` SHALL, after the registry review resolves, revert with `EmergencySettleBlocked` if guardians blocked it, otherwise execute the registry-stored calls with EMPTY per-call caps (skipping per-call metering) under the `maxCapital` cap and finalize settlement — owner-supplied rescue calls have no propose-time declaration to enforce, are guardian-reviewed and owner-bonded, and MUST NOT be able to brick on the very declaration that stranded the proposal (a settlement-leg `CallCapExceeded` is a legitimate reason to need this path). All emergency entrypoints SHALL require the caller to be the vault owner, the proposal to be in `Executed` state, and SHALL share the governor's reentrancy lock.

#### Scenario: Unstick before duration elapses is rejected
- **WHEN** the vault owner calls `unstick` or `emergencySettleWithCalls` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Guardians block owner-supplied emergency calls
- **WHEN** the guardian review of an emergency settle reaches block quorum
- **THEN** `finalizeEmergencySettle` SHALL revert with `EmergencySettleBlocked` and the owner-supplied calls SHALL never execute

#### Scenario: Under-bonded owner cannot propose custom calls
- **WHEN** the vault owner's registry stake is below the required owner bond
- **THEN** `emergencySettleWithCalls` SHALL revert with `OwnerBondInsufficient`

#### Scenario: Unstick replays under the voted caps
- **WHEN** the vault owner calls `unstick` on a proposal whose settlement calls would exceed their stored per-call caps
- **THEN** the batch SHALL revert with `CallCapExceeded` — `unstick` re-runs the voted declaration, it does not relax it; the owner's relief is the guardian-reviewed `emergencySettleWithCalls` path

#### Scenario: Rescue path is not per-call metered
- **WHEN** `finalizeEmergencySettle` executes guardian-approved owner-supplied calls
- **THEN** per-call metering SHALL be skipped (empty caps) and the batch SHALL remain bounded by the `maxCapital` net-outflow cap, the queue reserve, and the buffer checks

### Requirement: Governance parameter management
Governance parameters (`votingPeriod`, `executionWindow`, `vetoThresholdBps`, `maxPerformanceFeeBps`, `cooldownPeriod`, `collaborationWindow`, `maxCoProposers`, `minStrategyDuration`, `maxStrategyDuration`, `maxCapitalBps`, `tier2CallCapBps`) SHALL be settable only by the vault owner (a multisig expected to enforce its own external delay), applied instantly, and frozen while any proposal binds the vault (`ParamsFrozenDuringProposal`). Every setter SHALL validate hardcoded bounds: votingPeriod within [per-deployment floor (mainnet 24h), 30d]; executionWindow [1h, 7d]; vetoThresholdBps [2_000, 5_000]; maxPerformanceFeeBps ≤ 1_500; cooldownPeriod within [per-deployment floor (mainnet 1h), 30d]; strategyDuration bounds within [1h, 3650d] with min ≤ max and max additionally capped by the protocol-wide `maxStrategyDuration` ceiling from ProtocolConfig (unset = no ceiling); collaborationWindow [1h, 7d]; maxCoProposers [1, 10]; maxCapitalBps [1, 10_000] with 0 stored meaning unset and reading as 10_000; tier2CallCapBps [1, 10_000] with 0 stored meaning unset and reading as 10_000 (the inert default — the ceiling mechanism ships with the contract, the policy value is a deployment or governance act). Every change SHALL emit the uniform `ParameterChangeFinalized(paramKey, old, new)` event. The per-deployment timing floors SHALL be implementation-constructor immutables bounded below by 1 minute.

#### Scenario: Parameters frozen mid-proposal
- **WHEN** the vault owner calls any parameter setter while `openProposalCount > 0`
- **THEN** the call SHALL revert with `ParamsFrozenDuringProposal`

#### Scenario: Out-of-bounds value rejected
- **WHEN** the vault owner sets `vetoThresholdBps` below 2_000 or above 5_000, or `tier2CallCapBps` to 0 or above 10_000
- **THEN** the call SHALL revert with the parameter's invalid-value error (`InvalidVetoThresholdBps` / `InvalidTier2CallCapBps`)

#### Scenario: Factory rescue bypasses the freeze but not the bounds
- **WHEN** the factory calls `forceSetParams` (reachable by the factory owner via `setParamsOverride`) during an active proposal
- **THEN** the full parameter set SHALL be applied without the `whenNoActiveProposal` freeze, but SHALL still pass the same bounds validation

#### Scenario: Unset tier-2 ceiling is inert
- **WHEN** `tier2CallCapBps` has never been set
- **THEN** it SHALL read as 10_000 and the per-call tier-2 ceiling SHALL admit any cap the other propose-time validations admit

### Requirement: Factory lifecycle-gated administration
The factory SHALL gate structural changes on the governor's lifecycle state. `rotateOwner(vault, newOwner)` SHALL require the caller to be the current vault owner or the original creator, the old owner stake to be fully withdrawn, both `getActiveProposal() == 0` and `openProposalCount() == 0`, and the incoming owner's prior vault-specific consent to the stake binding (recorded on sWOOD by `newOwner` via `approveOwnerStakeBinding(vault)` — adversary: a current owner of an empty-slot vault must not be able to spend a third party's escrowed prepared stake by rotating the vault onto them); it SHALL transfer vault ownership, rebind the owner-stake slot on sWOOD (consuming the consent), and update the creator record. The signature and single-call semantics of `rotateOwner` SHALL be unchanged — consent is enforced at the sWOOD spend site, not by a new factory entrypoint. `upgradeVault(vault, expectedImpl)` SHALL require upgrades enabled, the caller to be the creator, `vaultImpl == expectedImpl` (so a factory-owner impl swap cannot land an implementation the creator did not opt into), and the same two lifecycle gates. `pushWiring(governor)` SHALL be factory-owner-only, SHALL verify the target is a governor this factory deployed (via the unforgeable `governor.vault()` → `governorOf` round-trip), and SHALL push only the factory's currently-set tier registry / exposure ledger / bond escrow — never writing zero, so wiring can be added but never silently removed. `setGuardianRegistry` SHALL fail-closed unless the new registry advertises this factory (or address(0) for a stateless stub).

The factory SHALL additionally own the batch-executor migration primitives: `setExecutorImpl(newImpl)` SHALL be factory-owner-only, reject the zero address, and change which executor library NEW syndicates are wired to at creation (existing vaults are untouched by it). `pushExecutor(vault)` SHALL be factory-owner-only, SHALL verify the vault is one this factory deployed, SHALL require the vault's governor lifecycle quiet (`getActiveProposal() == 0` and `openProposalCount() == 0` — a re-point under a live proposal would swap the meter out from under stored, coverage-priced calls), and SHALL push the factory's current executor into the vault via the vault's factory-only re-point, which updates the executor address AND re-stamps the expected executor codehash atomically. A vault whose executor was not migrated after a library ABI change SHALL fail closed on its next governor batch (unknown selector, no fallback on the library) — strategies unavailable, funds and LP exits unaffected — until `pushExecutor` runs.

#### Scenario: Rotation blocked mid-lifecycle
- **WHEN** `rotateOwner` or `upgradeVault` is called while the vault's governor has an executing proposal or any open proposal
- **THEN** the call SHALL revert (`ProposalActive` / `StrategyActive` or `ProposalsOpen`)

#### Scenario: Rotation without the incoming owner's consent
- **WHEN** `rotateOwner(vault, newOwner)` passes the caller and lifecycle gates but `newOwner` has not approved `vault` for stake binding on sWOOD
- **THEN** the call SHALL revert with `BindingNotApproved`, and no vault ownership, owner-stake, or creator-record state SHALL change

#### Scenario: pushWiring rejects foreign governors
- **WHEN** `pushWiring` targets an address that is not a governor deployed by this factory
- **THEN** the call SHALL revert with `NotFactoryGovernor`

#### Scenario: Executor re-point is lifecycle-gated and atomic
- **WHEN** the factory owner calls `pushExecutor(vault)` while the vault's governor has an open or executing proposal
- **THEN** the call SHALL revert; and when it succeeds on a quiet vault, the vault's executor address and expected codehash SHALL both reflect the factory's current executor in the same transaction

#### Scenario: Unmigrated vault fails closed, not silently unmetered
- **GIVEN** a vault upgraded to the new implementation but still pointing at the old executor library
- **WHEN** its governor drives any batch (execute, settle, or emergency)
- **THEN** the batch SHALL revert (the old library lacks the metered selector) — the vault never executes an unmetered batch as a fallback
