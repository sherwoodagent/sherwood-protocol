## MODIFIED Requirements

### Requirement: Deploy ceremony order and skip rules
SUPERSEDED. This change's four-script, environment-driven ceremony (`Deploy.s.sol` →
`DeployPortfolioStrategy` → `DeployConcentratedLiquidityStrategy` → `DeployStrategyFactory`,
each configured through `SKIP_MULTISIG_HANDOFF` / `ROBINHOOD_FORK_CHAIN_ID`) no longer exists.
The ceremony SHALL be the single env-free entry point `script/robinhood-mainnet/DeployAll.s.sol`,
whose order, postures and checks are normative in `openspec/specs/deployment-docs/spec.md`.

#### Scenario: Reader follows this delta
- **WHEN** an operator or reviewer reaches this file
- **THEN** they read `openspec/specs/deployment-docs/spec.md` instead, which carries the current
  phase order, the two-run Mainnet checkpoint and the post-deploy validation reads
