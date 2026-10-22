## ADDED Requirements

### Requirement: No proposal is exempt from either fee

Every settlement SHALL charge the management fee and compute the performance fee the same way, whatever the proposal's strategy reports about itself. No strategy can opt out of either leg.

#### Scenario: Every proposal pays management

- **WHEN** any proposal settles
- **THEN** the management fee is charged and distributed by the recorded management split, and the performance fee is computed from the high-water mark and the realized profit

## REMOVED Requirements

### Requirement: Strategies that self-manage their fees still pay the management fee
**Reason**: The self-managed-fees exemption does not exist; no strategy can skip the performance leg either.
**Migration**: Replaced by "No proposal is exempt from either fee".
