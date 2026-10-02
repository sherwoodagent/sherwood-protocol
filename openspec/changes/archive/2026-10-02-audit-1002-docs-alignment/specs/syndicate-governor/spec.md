## MODIFIED Requirements

### Requirement: Governance parameter management
Governance parameters (`votingPeriod`, `executionWindow`, `vetoThresholdBps`, `maxPerformanceFeeBps`, `cooldownPeriod`, `collaborationWindow`, `maxCoProposers`, `minStrategyDuration`, `maxStrategyDuration`, `maxCapitalBps`, `tier2CallCapBps`) SHALL be settable only by the vault owner, applied instantly in the same transaction, and frozen while any proposal binds the vault (`ParamsFrozenDuringProposal`). No on-chain delay or notice applies: the owner can change a parameter and propose in the same block. An open proposal keeps the `voteEnd` and veto threshold it recorded on entering Pending (at `propose`, or for a collaborative proposal at the Draft→Pending transition). Every setter SHALL validate hardcoded bounds: votingPeriod within [`MIN_VOTING_PERIOD`, 3 days]; executionWindow [1h, 7d]; vetoThresholdBps [2_000, 8_000]; maxPerformanceFeeBps ≤ 2_500 (`FeeConstants.MAX_PERFORMANCE_FEE_BPS`, the hard ceiling — distinct from the 2_000 headline the factory ships); cooldownPeriod within [`MIN_COOLDOWN_PERIOD`, 30d]; strategyDuration bounds within [1h, 30d] with min ≤ max and max additionally capped by the protocol-wide `maxStrategyDuration` ceiling from ProtocolConfig (unset = no ceiling); collaborationWindow [1h, 7d]; maxCoProposers [1, 10]; maxCapitalBps [1, 10_000] with 0 stored meaning unset and reading as 10_000; tier2CallCapBps [1, 10_000] with 0 stored meaning unset and reading as 10_000. Every setter SHALL emit the uniform `ParameterChangeFinalized(paramKey, old, new)` event. `MIN_VOTING_PERIOD` and `MIN_COOLDOWN_PERIOD` SHALL be implementation-constructor immutables bounded below by 1 minute and above by their parameter's maximum (3 days and 30 days). The Robinhood mainnet implementation sets both to 1 hour (`RobinhoodParams`), so the vault owner may run a 1-hour LP vote at an 80% veto threshold; the factory's per-vault default is a 24-hour vote at 20%.

#### Scenario: Parameters frozen mid-proposal
- **WHEN** the vault owner calls any parameter setter while `openProposalCount > 0`
- **THEN** the call SHALL revert with `ParamsFrozenDuringProposal`

#### Scenario: Out-of-bounds value rejected
- **WHEN** the vault owner sets `vetoThresholdBps` below 2_000 or above 8_000
- **THEN** the call SHALL revert with `InvalidVetoThresholdBps`

#### Scenario: Shortest legal veto window on mainnet
- **WHEN** the owner of a vault on the Robinhood mainnet implementation sets `votingPeriod` to 1 hour and `vetoThresholdBps` to 8_000 and proposes in the same block
- **THEN** the proposal's `voteEnd` is one hour after propose, and it is rejected only if votes against reach 80% of its votable supply

#### Scenario: Factory rescue bypasses the freeze but not the bounds
- **WHEN** the factory calls `forceSetParams` (reachable by the factory owner via `setParamsOverride`) during an active proposal
- **THEN** the `GovernorParams` set (every parameter above except `maxCapitalBps` and `tier2CallCapBps`) SHALL be applied without the `whenNoActiveProposal` freeze, but SHALL still pass the same bounds validation, and a single `ParameterChangeFinalized("forceSetParams", 0, 0)` SHALL be emitted

#### Scenario: Unset tier-2 ceiling is inert
- **WHEN** `tier2CallCapBps` has never been set
- **THEN** it SHALL read as 10_000 and the per-call tier-2 ceiling SHALL admit any cap the other propose-time validations admit
