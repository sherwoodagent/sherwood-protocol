# Fee Splits Specification

## Purpose

Defines how the two depositor-facing fee numbers are divided among the parties that
earn them — agent, protocol, guardian network, and fund owner — and guarantees that a
settlement pays the split and rate ceilings that were in force when the proposal was
made, not whatever governance has since changed them to.

## Requirements

### Requirement: Management split is a three-way division summing to full basis points

The protocol configuration SHALL hold a management split with exactly three shares —
agent, protocol, and guardian network — expressed in basis points. The three shares
MUST sum to 10 000. Any attempt to set a split that does not sum to 10 000 MUST be
rejected.

#### Scenario: A valid management split is accepted

- **WHEN** governance sets a management split of 7000 agent / 2000 protocol / 1000 guardian
- **THEN** the configuration stores it and emits an event carrying all three shares

#### Scenario: A management split that does not sum to full basis points is rejected

- **WHEN** governance sets a management split of 7000 agent / 2000 protocol / 500 guardian
- **THEN** the call reverts and the previously stored split is unchanged

#### Scenario: A management split may allocate zero to a party

- **WHEN** governance sets a management split of 10000 agent / 0 protocol / 0 guardian
- **THEN** the configuration accepts it, because the sum is 10 000

### Requirement: Performance split is a four-way division summing to full basis points

The protocol configuration SHALL hold a performance split with exactly four shares —
agent, protocol, guardian network, and fund owner — expressed in basis points. The four
shares MUST sum to 10 000. Any attempt to set a split that does not sum to 10 000 MUST
be rejected.

#### Scenario: A valid performance split is accepted

- **WHEN** governance sets a performance split of 6000 agent / 1500 protocol / 1500 guardian / 1000 owner
- **THEN** the configuration stores it and emits an event carrying all four shares

#### Scenario: A performance split that overshoots full basis points is rejected

- **WHEN** governance sets a performance split summing to 10 001
- **THEN** the call reverts and the previously stored split is unchanged

### Requirement: Only authorized governance may change a split

Split configuration SHALL be modifiable only by the protocol configuration's authorized
owner. An unauthorized caller MUST NOT be able to change either split.

#### Scenario: An unauthorized caller cannot change a split

- **WHEN** an address that is not the configuration owner attempts to set either split
- **THEN** the call reverts and both stored splits are unchanged

### Requirement: Both splits are snapshotted onto the proposal at propose time

When a strategy proposal is created, the management split and the performance split then
in force SHALL be recorded on that proposal. Settlement of that proposal MUST use the
recorded splits, so that a governance change made after propose time cannot alter what
an in-flight proposal pays.

#### Scenario: A split change after propose does not affect the in-flight proposal

- **WHEN** a proposal is created under a 7000/2000/1000 management split, governance then
  changes the split to 5000/3000/2000, and the proposal later settles
- **THEN** the settlement distributes the management fee as 7000/2000/1000

#### Scenario: A split change before propose does affect the next proposal

- **WHEN** governance changes the management split and a new proposal is created afterwards
- **THEN** that proposal records the new split and settles against it

### Requirement: The performance-fee rate is bounded by a protocol ceiling and a per-vault ceiling

The protocol SHALL define an absolute maximum performance-fee rate that no configuration
can exceed. Independently, each vault SHALL be subject to a per-vault maximum enforced by
its governor. A newly created vault MUST default to a per-vault maximum equal to the
advertised headline rate rather than to the absolute protocol maximum, so that charging
above the headline requires an explicit, separately authorized governance action.

#### Scenario: A rate above the absolute protocol maximum cannot be set

- **WHEN** a vault owner attempts to set a performance-fee rate above the absolute protocol maximum
- **THEN** the call reverts

#### Scenario: A newly created vault starts at the headline ceiling, not the protocol ceiling

- **WHEN** a vault is created through the factory with default parameters
- **THEN** its per-vault maximum performance-fee rate equals the headline rate (2000 bps),
  which is strictly below the absolute protocol maximum (2500 bps)

#### Scenario: A vault that never configures a rate keeps the existing conservative default

- **WHEN** a vault is created and its owner never sets a performance-fee rate
- **THEN** settlement charges the pre-existing default agent-fee rate, unchanged by this change
