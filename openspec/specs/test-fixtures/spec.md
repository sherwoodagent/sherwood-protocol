# Test Fixtures Specification

## Purpose

Requirements on multi-approver test fixtures for `ExposureLedger`, so a fixture's early exits (quorum reached, no free budget) cannot silently shrink the exercised approver set and mask a broken accounting path.

## Requirements

### Requirement: Multi-approver fixtures genuinely exercise every approver
A test constructing a multi-approver set SHALL use the shared fixture helper, which SHALL size each approver's bookable budget strictly smaller than the proposal's requirement (so every approver books a non-zero share) and SHALL assert `approversOf` returns exactly the intended count. `ExposureLedger.t.sol` SHALL carry a comment block naming both early exits (`requireApproveQuorum`'s quorum-reached exit and `recordApproval`'s no-free-budget exit), explaining how each silently shrinks a fixture's effective set, stating the sizing rule, and pointing at the helper. A test that deliberately relies on an early exit SHALL carry an explicit `// EARLY-EXIT INTENDED:` comment stating which exit and why.

#### Scenario: Fixture built via the shared helper
- **WHEN** a test constructs a multi-approver set through the shared helper
- **THEN** each approver's bookable budget is strictly smaller than the proposal's requirement, every approver books a non-zero share, and the helper asserts `approversOf` returns exactly the intended count — so a broken second-approver accounting path cannot pass unnoticed

#### Scenario: Reader encounters the hazard
- **WHEN** a test author reads `ExposureLedger.t.sol`
- **THEN** a comment block names both early exits (`requireApproveQuorum` quorum-reached; `recordApproval` no-free-budget), explains how each silently shrinks a fixture's effective set, states the sizing rule, and points at the helper

#### Scenario: Intentional early-exit fixture
- **WHEN** a test deliberately relies on an early exit
- **THEN** it carries an explicit `// EARLY-EXIT INTENDED:` comment stating which exit and why
