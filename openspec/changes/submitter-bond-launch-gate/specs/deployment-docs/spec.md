# deployment-docs (delta)

## ADDED Requirements

### Requirement: Submitter bond launch-gate is asserted at deploy time and documented in source

`TierRegistry.submitterBondWood` SHALL remain `0` at deploy until the three-part launch-gate condition holds: a guard-bypass slash path exists and can reach `_bonds`, a seated court can enforce a *disputed* slash (issue #25), and third-party submission volume exists. `script/Deploy.s.sol` SHALL assert `TierRegistry(d.tierRegistry).submitterBondWood() == 0` immediately after deploying `TierRegistry`, so a future accidental non-zero `setSubmitterBondWood` call inserted into the deploy flow reverts the deployment rather than shipping an unenforceable, unrecoverable cost on adapter submitters. The launch-gate condition SHALL also be stated in NatSpec directly on the `submitterBondWood` declaration.

#### Scenario: deploy script runs with the bond left at its default

- **WHEN** `script/Deploy.s.sol` deploys `TierRegistry` and no code path sets a non-zero `submitterBondWood`
- **THEN** the post-deploy assertion passes and the deployment proceeds

#### Scenario: a future change accidentally enables the bond before the gate condition holds

- **WHEN** a deploy script is modified to call `setSubmitterBondWood` with a non-zero value without the guard-bypass slash path and disputed-slash court existing
- **THEN** the deploy script's assertion reverts, failing the deployment rather than silently imposing an unenforceable submitter cost
