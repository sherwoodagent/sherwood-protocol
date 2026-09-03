# deployment-docs (delta)

## ADDED Requirements

### Requirement: Owner-bond gate upgrade ordering
The SHE-215 upgrade SHALL be applied in the order **sWOOD → GuardianRegistry → governor beacon**. `SyndicateGovernor` reaches the predicate by a TYPED call to `IGuardianRegistry.ownerBondLive`, so a beacon upgraded ahead of the registry would call a selector the live registry does not implement and every `propose` and `executeProposal` would revert bare, with no named error to diagnose. The ordering SHALL be recorded as a ceremony note rather than left to the operator to derive.

#### Scenario: Ceremony applied in order
- **WHEN** the operator upgrades sWOOD, then GuardianRegistry, then the governor beacon
- **THEN** the proposal lane stays reachable throughout, because every governor that can call `ownerBondLive` faces a registry that implements it

#### Scenario: Beacon upgraded first
- **WHEN** the governor beacon is upgraded before the registry
- **THEN** `propose` and `executeProposal` SHALL revert with empty returndata for every vault until the registry upgrade lands
