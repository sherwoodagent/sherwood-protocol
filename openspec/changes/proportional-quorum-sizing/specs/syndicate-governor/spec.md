## ADDED Requirements

### Requirement: Coverage-proportional effective capital
The governor SHALL derive, at execute time, an effective capital ceiling from the coverage the approve quorum actually raised, and SHALL use it — not the declared `maxCapital` — as the outflow cap for both the execute and settlement batches. Derivation: when the quorum gate runs, the ledger returns `(coverageRaisedUsd, requiredCoverageUsd)`; `effectiveMaxCapital = maxCapital` when `coverageRaisedUsd >= requiredCoverageUsd`, else `floor(maxCapital × coverageRaisedUsd / requiredCoverageUsd)` — surplus coverage SHALL NOT raise the ceiling above the declared `maxCapital`, and the floor MAY produce zero on dust coverage (a zero effective cap executes with no permitted net outflow — fail-closed). When the gate does not run (no ledger wired, `requiredCoverage == 0`, or tier below the quorum threshold), `effectiveMaxCapital` SHALL equal `maxCapital`. The value SHALL be stored on the proposal in a `uint256 effectiveMaxCapital` field APPENDED as the last member of `StrategyProposal` (append-only storage discipline; `script/syndicate-governor-layout.golden.json` regenerated with an append-only diff), written on EVERY execute path so a stored zero never means "unset" on an executed proposal. It SHALL be immutable once written: settlement reuses the stored value regardless of how live coverage moved after execution — recomputing at settle could cap the unwind below the size legitimately deployed at execution, stranding capital (owner decision 2026-08-03, option A). The governor SHALL emit `EffectiveMaxCapitalSet(proposalId, declaredMaxCapital, effectiveMaxCapital, coverageRaisedUsd, requiredCoverageUsd)` at execute and SHALL expose `getEffectiveMaxCapital(proposalId)` (0 before execution); `getRiskEnvelope` keeps returning the declared envelope. When per-call capital declarations are in force (issue #43), the governor SHALL scale every per-call cap by the same factor (`effectiveCap_i = floor(cap_i × coverageRaisedUsd / requiredCoverageUsd)`), SHALL re-assert `Σ effectiveCaps ≤ effectiveMaxCapital` per batch after floor-rounding (clamping the largest scaled cap by the excess on violation), and SHALL persist the scaled settlement caps at execute so the settlement batch is metered by byte-identical caps however much later it runs.

#### Scenario: Partial coverage executes at proportional size
- **WHEN** a proposal declaring `maxCapital = 1_000_000` reaches execute with 40% of its required coverage raised
- **THEN** execution proceeds with `effectiveMaxCapital = 400_000`, the vault's net-outflow meter reverts any attempt to move more, and `EffectiveMaxCapitalSet` records both the declared and effective figures

#### Scenario: Surplus coverage does not inflate the ceiling
- **WHEN** the raised coverage exceeds `requiredCoverageUsd`
- **THEN** `effectiveMaxCapital` equals the declared `maxCapital` exactly — coverage can only shrink the ceiling, never grow it

#### Scenario: Settlement runs at the execution size
- **WHEN** a proposal executed at 80% size and a covering guardian is later slashed on an unrelated proposal before settlement
- **THEN** `settleProposal` still meters the settlement batch at the STORED `effectiveMaxCapital` from execution — the position can always be unwound at the size it deployed

#### Scenario: Ungated proposals are not resized
- **WHEN** a proposal executes with no exposure ledger wired, or with `requiredCoverage == 0`
- **THEN** `effectiveMaxCapital` is stored equal to `maxCapital` and behavior is unchanged from the pre-change semantics

#### Scenario: Per-call caps scale by the same factor
- **WHEN** per-call capital declarations are in force and a proposal executes at 50% coverage
- **THEN** every execute and settlement call cap is floored to half its declared value, the per-batch sum is re-asserted against `effectiveMaxCapital` after rounding, and the scaled settlement caps are persisted at execute

## MODIFIED Requirements

### Requirement: Execution safety guards
`executeProposal` SHALL be permissionless but SHALL only run when the resolved state is `Approved`, no other proposal is actively executing, and the cooldown has elapsed (`block.timestamp >= lastSettledAt + cooldownPeriod`, skipped when nothing ever settled). Before executing it SHALL: snapshot the vault's asset balance as the capital snapshot; mark the proposal `Executed` and set `executedAt` before any external call (CEI); re-resolve tier and coverage from the stored calls and revert with `TierRegressed` if the live tier exceeds the propose-time `envelopeTier`, or `CoverageRegressed` if the live coverage exceeds the propose-time `requiredCoverage`; and, when an exposure ledger is wired and `requiredCoverage != 0` and the tier is at or above the ledger's quorum tier threshold, measure the bond-encumbered approve coverage via `requireApproveQuorum` — which reverts only on ZERO coverage (fail-closed: no identified, slashable approver means no execution) and otherwise returns `(coverageRaisedUsd, requiredCoverageUsd)`, from which the governor derives and stores the proposal's `effectiveMaxCapital` per the coverage-proportional effective capital requirement. The opening batch SHALL run via the vault's `executeGovernorBatch` under the proposal's `effectiveMaxCapital` net-outflow cap (equal to `maxCapital` whenever coverage was full or the gate did not run). All execute/settle/cancel entrypoints SHALL be protected by a shared reentrancy lock.

#### Scenario: Cooldown between strategies
- **WHEN** `executeProposal` is called before `lastSettledAt + cooldownPeriod` has elapsed
- **THEN** the call SHALL revert with `CooldownNotElapsed`, giving depositors an exit window between strategies

#### Scenario: Stale certification blocks execution
- **WHEN** an adapter used by the proposal's execute calls was demoted or re-certified with a higher extractable bound after propose, so the live tier or coverage exceeds the propose-time snapshot
- **THEN** `executeProposal` SHALL revert (`TierRegressed` / `CoverageRegressed`), and the proposal SHALL remain `Approved` until `executeBy` expires it

#### Scenario: Zero approve coverage blocks execution
- **WHEN** an exposure ledger is wired and a coverage-consuming proposal at or above the quorum tier threshold has no covering approve coverage booked (empty approver set, or every contribution zero)
- **THEN** `executeProposal` SHALL revert, leaving the proposal `Approved` (executable later if covering approvals arrive before `executeBy`)

#### Scenario: Partial approve coverage sizes execution instead of blocking it
- **WHEN** the same proposal reaches execute with a nonzero approve coverage below `requiredCoverageUsd`
- **THEN** execution SHALL proceed at the coverage-proportional `effectiveMaxCapital` instead of reverting — the cliff between 99% coverage and 100% coverage is removed

#### Scenario: Only one live strategy
- **WHEN** `executeProposal` is called while another proposal is in the Executed window
- **THEN** the call SHALL revert with `StrategyAlreadyActive`

### Requirement: Settlement and P&L
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` under the proposal's STORED `effectiveMaxCapital` — the same cap execution ran under, reused rather than recomputed so that post-execution coverage movements can never cap the unwind below the deployed size — then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot minus the vault's interim LP net flow (deposits/withdrawals during the strategy are principal, not performance); state SHALL move to `Settled`, the active-proposal marker cleared, and the open count decremented before external fee transfers; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: Interim LP flow excluded from P&L
- **WHEN** depositors add or remove principal while a strategy is live
- **THEN** the settlement P&L SHALL exclude that interim net flow, so fees are charged only on strategy performance

#### Scenario: Settlement cap matches execution cap
- **WHEN** a proposal that executed at a coverage-scaled `effectiveMaxCapital` is settled at any later time
- **THEN** the settlement batch SHALL be metered by the stored `effectiveMaxCapital`, byte-identical to the figure execution used
