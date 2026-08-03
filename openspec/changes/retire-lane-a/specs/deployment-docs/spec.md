# deployment-docs (delta)

Two requirements modified (issue #54): the PriceRouter is deleted with Lane A, so
the deploy ceremony no longer deploys/wires/validates one and the Robinhood
chain-specific requirement loses its zero-adapter-router clause. Everything else in
this capability — fork identity, size gate, vnet lifecycle, funding cheats, Plan
B/D/TokenCourt pre-flights, the WOOD price-cap/haircut/rate-limit runbook — is
untouched (none of it references the PriceRouter).

## MODIFIED Requirements

### Requirement: Deploy ceremony order and skip rules

The fork ceremony SHALL run three scripts in order, each broadcast with the flags above:
1. `script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet` with `WOOD_TOKEN=<live WOOD>`, `SKIP_MULTISIG_HANDOFF=true`, `ROBINHOOD_FORK_CHAIN_ID=9994663` — core only; no ENS/ERC-8004 (both registrar addresses are `address(0)` on Robinhood).
2. `script/robinhood-mainnet/DeployPortfolioStrategy.s.sol` — UniswapSwapAdapter (v3+v4) + PortfolioStrategy template.
3. `script/DeployStrategyFactory.s.sol` with `SKIP_MULTISIG_HANDOFF=true` — keyless-clone StrategyFactory + template approvals.

`DeployWood` SHALL be skipped — WOOD is already live on the fork. CREATE3 makes the core addresses order-independent. With handoff skipped, the deployer retains ownership of beacon / factory / registry / sWOOD / ProtocolConfig (needed for fork admin); on the real mainnet ceremony `SKIP_MULTISIG_HANDOFF` SHALL NOT be used and `OWNER_MULTISIG` MUST be a contract (Safe), not an EOA.

#### Scenario: Post-deploy validation reads
- **WHEN** the three scripts complete
- **THEN** the operator verifies `factory.beacon/protocolConfig`, `swood.wood == WOOD`, `swood.registry == registry`, `registry.reviewPeriod == 86400`, `registry.blockQuorumBps == 3000`, `strategyFactory.approvedTemplate(PORTFOLIO) == true`, and `governorImpl.MIN_VOTING_PERIOD() == 86400`

#### Scenario: Mainnet ceremony with EOA multisig refused
- **WHEN** `OWNER_MULTISIG` is an EOA and handoff is not skipped
- **THEN** the deploy reverts "OWNER_MULTISIG must be a contract (Safe), not an EOA"

### Requirement: Chain-specific factory identity configuration

On Robinhood Chain (no ENS/Durin registrar, no ERC-8004 identity registry) the factory SHALL be deployed with `address(0)` for both `ensRegistrar` and `agentRegistry` (identity + subname registration disabled), and validation SHALL assert both read back as zero.

#### Scenario: Identity disabled on Robinhood
- **WHEN** post-deploy validation runs on 4663 or its fork
- **THEN** `factory.ensRegistrar() == address(0)` and `factory.agentRegistry() == address(0)`
