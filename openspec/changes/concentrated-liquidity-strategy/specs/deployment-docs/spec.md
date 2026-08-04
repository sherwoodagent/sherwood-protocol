## MODIFIED Requirements

### Requirement: Deploy ceremony order and skip rules
The fork ceremony SHALL run four scripts in order, each broadcast with the flags above:
1. `script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet` with `WOOD_TOKEN=<live WOOD>`, `SKIP_MULTISIG_HANDOFF=true`, `ROBINHOOD_FORK_CHAIN_ID=9994663` — core + zero-adapter PriceRouter; no ENS/ERC-8004 (both registrar addresses are `address(0)` on Robinhood).
2. `script/robinhood-mainnet/DeployPortfolioStrategy.s.sol` — UniswapSwapAdapter (v3+v4) + PortfolioStrategy template.
3. `script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol` — ConcentratedLiquidityStrategy template, wired to the position manager and the Morpho singleton. The script SHALL assert both external addresses hold code before deploying the template, and SHALL refuse to run when either is an EOA or unset. Adversary: approving a template wired to a position manager that does not exist on this chain, so every clone of it reverts mid-batch after the vault has already approved the pull.
4. `script/DeployStrategyFactory.s.sol` with `SKIP_MULTISIG_HANDOFF=true` — keyless-clone StrategyFactory + template approvals for both strategy templates.

`DeployWood` SHALL be skipped — WOOD is already live on the fork. CREATE3 makes the core addresses order-independent. With handoff skipped, the deployer retains ownership of beacon / factory / registry / sWOOD / ProtocolConfig / PriceRouter (needed for fork admin); on the real mainnet ceremony `SKIP_MULTISIG_HANDOFF` SHALL NOT be used and `OWNER_MULTISIG` MUST be a contract (Safe), not an EOA.

#### Scenario: Post-deploy validation reads
- **WHEN** the four scripts complete
- **THEN** the operator verifies `factory.beacon/priceRouter/protocolConfig`, `swood.wood == WOOD`, `swood.registry == registry`, `registry.reviewPeriod == 86400`, `registry.blockQuorumBps == 3000`, `strategyFactory.approvedTemplate(PORTFOLIO) == true`, `strategyFactory.approvedTemplate(CL_LP) == true`, and `governorImpl.MIN_VOTING_PERIOD() == 86400`

#### Scenario: Mainnet ceremony with EOA multisig refused
- **WHEN** `OWNER_MULTISIG` is an EOA and handoff is not skipped
- **THEN** the deploy reverts "OWNER_MULTISIG must be a contract (Safe), not an EOA"

#### Scenario: Position manager address holds no code
- **WHEN** the CL-LP deploy script runs with a position-manager address that holds no code on the target chain
- **THEN** the script reverts before deploying or approving the template
