## MODIFIED Requirements

### Requirement: Multi-approver fixtures genuinely exercise every approver
`ExposureLedger.t.sol` SHALL provide a fixture helper, `_wireUnderCoveredApprovers`, that sizes each approver's bookable budget strictly above zero and strictly below the proposal's requirement (so every approver books a non-zero lock and no single lock meets the quorum) and asserts `approversOf` returns exactly the intended count, plus `_assertApproverSet` for the count check alone. A test in that file that relies on every approver of a multi-approver set being read SHALL build the set with the helper or end on `_assertApproverSet`. The early exit that can silently shrink a fixture's effective set is `requireApproveQuorum`'s quorum-reached return, which stops reading approvers once the sum meets the requirement; `recordApproval` with no free budget reverts `ApproveLockBelowFloor` rather than seating nobody silently. A test that deliberately relies on the quorum-reached exit SHALL say so in a comment.

#### Scenario: Fixture built via the shared helper
- **WHEN** a test constructs a multi-approver set through the shared helper
- **THEN** each approver's bookable budget is strictly smaller than the proposal's requirement, every approver books a non-zero lock, and the helper asserts `approversOf` returns exactly the intended count — so a broken second-approver accounting path cannot pass unnoticed

#### Scenario: Reader encounters the hazard
- **WHEN** a test author reads the fixture section of `ExposureLedger.t.sol`
- **THEN** a comment block explains the quorum-reached early exit, states the sizing rule, and points at the helper

#### Scenario: Intentional early-exit fixture
- **WHEN** a test deliberately relies on the quorum-reached exit
- **THEN** it carries a comment stating that it does and why
