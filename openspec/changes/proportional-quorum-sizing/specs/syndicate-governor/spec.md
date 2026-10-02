## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Execution safety guards
`executeProposal` SHALL be permissionless but SHALL only run when the resolved state is `Approved` (`ProposalNotApproved`), no other proposal is actively executing (`StrategyAlreadyActive`), and the vault's owner bond is still live (`OwnerBondNotLive`). The settle cooldown is enforced at `propose`, and since `cooldownPeriod` is frozen while a proposal is open it cannot be the first gate to fail at execute. Before executing it SHALL: snapshot the vault's asset balance as the capital snapshot and its price per share as the settle-price anchor; mark the proposal `Executed` and set `executedAt` before any external call (CEI); start the vault's management-fee accrual; re-resolve tier and coverage from the stored calls of both legs and revert with `TierRegressed` if the live tier exceeds the propose-time `envelopeTier`, or `CoverageRegressed` if the live coverage exceeds the propose-time `requiredCoverage`; revert `MaxCapitalCeilingRegressed` if `maxCapital` now exceeds `totalAssets() * maxCapitalBps / 10_000`; and, when an exposure ledger is wired and `requiredCoverage != 0`, at every tier, measure the bond-encumbered approve coverage via `requireApproveQuorum` — which reverts on no covering approver (fail-closed: no identified, slashable approver means no execution) and otherwise returns `(coverageRaisedUsd, requiredCoverageUsd)`, from which the governor derives and stores the proposal's `effectiveMaxCapital` per the coverage-proportional effective capital requirement. The opening batch SHALL run via the vault's `executeGovernorBatch` with the (scaled) execute caps under the proposal's `effectiveMaxCapital` net-outflow cap (equal to `maxCapital` whenever coverage was full or the gate did not run). All execute/settle/cancel entrypoints SHALL be protected by a shared reentrancy lock.

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
