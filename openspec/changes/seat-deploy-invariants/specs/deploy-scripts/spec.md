# deploy-scripts (delta)

## ADDED Requirement: DeployPlanB seats the duration ceiling

#### Scenario: default run

- **WHEN** DeployPlanB runs without `MAX_STRATEGY_DURATION` set
- **THEN** `ProtocolConfig.maxStrategyDuration` is seated to the documented
  default inside the broadcast, and the post-broadcast assert confirms it is
  non-zero.

#### Scenario: operator override

- **WHEN** `MAX_STRATEGY_DURATION` is set in the environment
- **THEN** that value is seated instead; zero is REJECTED before broadcast
  (an explicit "no ceiling" must not be expressible through this script).

## ADDED Requirement: DeployPlanB asserts delegation is off

#### Scenario: delegation accidentally on

- **GIVEN** `delegationEnabled` reads true on the target chain
- **WHEN** the post-broadcast pre-flights run
- **THEN** the run FAILS with a message naming the delegator-walkout hole
  (delegated stake credited to a ~35-day coverage window while
  `requestUnstakeDelegation` checks only the delegator and the unbonding
  pool is slashable for only `coolDownPeriod`).

#### Scenario: preflight tests cover both

- **THEN** `test/deploy/DeployPlanBPreflight.t.sol` gains cases: default
  seating lands; zero override rejected; delegation-on fails the named
  assert; delegation-off passes.
