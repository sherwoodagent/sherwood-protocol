## MODIFIED Requirements

### Requirement: Execute-time approve quorum
`requireApproveQuorum(governor, proposalId, asset, requiredCoverage)` SHALL MEASURE coverage instead of gating all-or-nothing: it SHALL return `(coverageRaisedUsd, requiredCoverageUsd)` where `requiredCoverageUsd = coverageUsd(asset, requiredCoverage)` and `coverageRaisedUsd` is the covering approvers' aggregate `Σ min(reservation_i, live slashableBondUsd_i)`, both USD-18 from the same price read. The approver set SHALL come from the ledger's own list, never the registry's; each per-approver term SHALL keep the LIVE (unanchored) slashable-bond basis. The function MAY stop summing once the aggregate reaches `requiredCoverageUsd` (the reported surplus may be clamped — the consumer's scale factor clamps at 1, so surplus precision is not load-bearing). It SHALL revert `InsufficientApproveCoverage` ONLY when the approver set is empty or the aggregate is zero — an identified, slashable approver with nonzero coverage is still mandatory, but a partial shortfall SHALL no longer revert. The governor SHALL invoke this check at execute for every proposal with a wired ledger, non-zero `requiredCoverage`, and `envelopeTier >= quorumTierThreshold`; zero-`requiredCoverage` proposals keep optimistic passage. Unpriceable WOOD (`NoWoodPrice`) SHALL continue to propagate — a coverage figure that cannot be priced must halt execution, not size it.

#### Scenario: Aggregate coverage across a cohort
- **WHEN** two guardians each hold a live bond worth $600k and both reserved on a $1M-coverage proposal
- **THEN** the returned `coverageRaisedUsd` is at least `requiredCoverageUsd` — no single approver must cover the proposal alone, and the consumer's scale factor is 1

#### Scenario: Partial coverage is reported, not rejected
- **WHEN** the covering approvers' aggregate is 80% of `requiredCoverageUsd`
- **THEN** the call returns `(0.8 × requiredCoverageUsd, requiredCoverageUsd)` instead of reverting, so the governor can size execution to the coverage actually raised

#### Scenario: Bond shrank since the vote
- **WHEN** an approver's live bond (unstake, or a WOOD price fall) is now worth less than its reservation
- **THEN** it contributes the shrunken live value to `coverageRaisedUsd`, so the executed size still reflects coverage in dollars at execution

#### Scenario: No covering approver
- **WHEN** a coverage-consuming proposal at or above the tier threshold reaches execute with no listed approver, or with every listed approver's contribution at zero (reservations released, or bonds worthless)
- **THEN** the call reverts `InsufficientApproveCoverage` and the proposal expires at `executeBy` unless covering approvals arrive — zero coverage is an error, not a size
