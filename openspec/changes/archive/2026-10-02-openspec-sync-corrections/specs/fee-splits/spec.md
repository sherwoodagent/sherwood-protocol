## MODIFIED Requirements

### Requirement: The performance-fee rate is bounded by a protocol ceiling and a per-vault ceiling

The protocol SHALL define an absolute maximum performance-fee rate that no configuration
can exceed (`FeeConstants.MAX_PERFORMANCE_FEE_BPS`, 2500 bps). Independently, each vault
SHALL be subject to a per-vault maximum (`maxPerformanceFeeBps`) enforced by its
governor. A newly created vault MUST default to a per-vault maximum equal to the
advertised headline rate rather than to the absolute protocol maximum, so charging above
the headline requires the vault owner to raise `maxPerformanceFeeBps` (to at most 2500
bps) through `setMaxPerformanceFeeBps` while no proposal is open. The proposal records
the agent's rate clamped to the per-vault maximum at propose time, and settlement
re-clamps it to the per-vault maximum then in force, so a settlement never charges more
than the lower of the two.

#### Scenario: A rate above the absolute protocol maximum cannot be set

- **WHEN** a vault owner attempts to set a performance-fee rate above the absolute protocol maximum
- **THEN** the call reverts

#### Scenario: A newly created vault starts at the headline ceiling, not the protocol ceiling

- **WHEN** a vault is created through the factory with default parameters
- **THEN** its per-vault maximum performance-fee rate equals the headline rate (2000 bps),
  which is strictly below the absolute protocol maximum (2500 bps)

#### Scenario: A vault that never configures a rate keeps the existing conservative default

- **WHEN** a vault is created and its owner never sets a performance-fee rate
- **THEN** settlement charges `DEFAULT_AGENT_FEE_BPS` (2000 bps), clamped to the per-vault maximum

## ADDED Requirements

### Requirement: An unconfigured fee recipient folds into the agent's share

When the protocol or guardians fee recipient recorded on the proposal is `address(0)`, that party's share of the management fee and of the performance fee SHALL NOT be paid and SHALL fold into the agent's remainder, so no amount is escrowed against the zero address.

#### Scenario: Guardians recipient never configured

- **WHEN** a proposal recorded a zero guardians fee recipient and settles with a fee owed
- **THEN** the guardian share is added to the agent's share and nothing is paid to or escrowed for `address(0)`
