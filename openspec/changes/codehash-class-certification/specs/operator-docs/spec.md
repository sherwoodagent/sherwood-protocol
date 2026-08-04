## ADDED Requirements

### Requirement: The onboarding checklist covers class certification

`docs/adapter-onboarding-checklist.md` SHALL carry a class-certification section covering, in order: why address-keyed consent does not survive per-proposal clones; the eligibility bar a template must clear before it may be class-certified; the three writes (`proposeClassCertification`, `certifyClass`, `setClassAllowed`) and which one replaces the per-proposal `setAdapterAllowed(clone, true)`; verification reads for class membership; the rollback path and its guarantee that demotion is never worse than the status quo; and the token↔price-source attestation, including that the packed max-age must be stripped before attesting.

The eligibility bar SHALL state all four disqualifying conditions: an unbound init-supplied external address, a price source not bound to the token it prices, a clone mechanism that writes per-instance bytecode, and a template that is itself a proxy.

#### Scenario: Operator certifies a class
- **WHEN** an operator follows the class-certification section
- **THEN** they perform the eligibility check before any write, and end with a certified class whose clones need no per-proposal owner action

#### Scenario: Operator reads the silent-failure warning
- **WHEN** an operator considers a clone mechanism that embeds per-instance data
- **THEN** the checklist states that the class dissolves with no revert anywhere — proposals keep executing, having quietly fallen back to the tier-2 default

### Requirement: The checklist states that clone-init deploy order is load-bearing

`docs/adapter-onboarding-checklist.md` SHALL state that the tier registry must be wired and reachable through `vault() → governor() → tierRegistry()` before any `PortfolioStrategy` clone is initialized, that a clone deploy otherwise reverts `TierRegistryUnresolved`, and that this fail-closed posture applies to initialization only — rebalance and settle continue to degrade open because blocking them would strand vault capital.

#### Scenario: Operator deploys a clone before wiring the registry
- **WHEN** an operator initializes a clone while the registry is unreachable
- **THEN** the deploy reverts, and the checklist has already told them the ordering requirement and the error to expect
