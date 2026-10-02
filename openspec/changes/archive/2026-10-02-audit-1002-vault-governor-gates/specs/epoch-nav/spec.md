## MODIFIED Requirements

### Requirement: Bounded duration substitutes for per-epoch NAV checkpointing in v1

The protocol SHALL NOT record per-epoch NAV checkpoints on-chain in v1. Instead, `ProtocolConfig.maxStrategyDuration` SHALL impose a protocol-wide ceiling on `strategyDuration` (clamping every vault's own maximum), so a single guardian commitment spans the whole risk window and the drawdown predicate (predicate 5, `DrawdownBreach`) is enforceable at settlement without renewal, NAV checkpointing or claims-made attribution. The clamp SHALL hold at `propose`: a proposal whose `strategyDuration` exceeds the smaller of the vault's stored `maxStrategyDuration` and the live ceiling of the governor's `protocolConfig` SHALL revert `StrategyDurationTooLong`, whatever maximum the vault stored before the ceiling dropped. The setter SHALL be owner-only and SHALL reject a non-zero value below 1 day; zero means "no protocol ceiling" (preserving pre-parameter deployments) and changes never rebind in-flight proposals, which snapshot parameters at propose time. In the challenge game the drawdown predicate is a label carried in the filing event — no contract derives it from on-chain NAV records.

#### Scenario: Degenerate ceiling rejected

- **WHEN** the owner sets `maxStrategyDuration` to a non-zero value below 1 day
- **THEN** the call reverts `InvalidMaxStrategyDuration`

#### Scenario: In-flight proposals keep their snapshot

- **WHEN** the ceiling changes while a proposal is live
- **THEN** only proposals created afterwards see the new ceiling

#### Scenario: Lowered ceiling binds existing and new vaults at propose

- **WHEN** the owner lowers the ceiling below a vault's stored `maxStrategyDuration`, on a vault created before or after the change
- **THEN** a proposal longer than the ceiling reverts `StrategyDurationTooLong`, and one within both bounds proposes
