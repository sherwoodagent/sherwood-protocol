# test-fixtures (delta)

## ADDED Requirement: Multi-approver fixtures genuinely exercise every approver

#### Scenario: fixture built via the shared helper

- **WHEN** a test constructs a multi-approver set through the shared helper
- **THEN** each approver's bookable budget is strictly smaller than the
  proposal's requirement, every approver books a non-zero share, and the
  helper asserts `approversOf` returns exactly the intended count — so a
  broken second-approver accounting path cannot pass unnoticed.

#### Scenario: reader encounters the hazard

- **WHEN** a test author reads `ExposureLedger.t.sol`
- **THEN** a comment block names both early exits
  (`requireApproveQuorum` quorum-reached; `recordApproval` no-free-budget),
  explains how each silently shrinks a fixture's effective set, states the
  sizing rule, and points at the helper.

#### Scenario: intentional early-exit fixture

- **WHEN** a test deliberately relies on an early exit
- **THEN** it carries an explicit `// EARLY-EXIT INTENDED:` comment stating
  which exit and why.
