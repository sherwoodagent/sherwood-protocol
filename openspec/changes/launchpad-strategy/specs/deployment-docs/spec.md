## ADDED Requirements

### Requirement: Tokenize-fund deploy script and registry runbook

The deploy ceremony SHALL gain `script/robinhood-mainnet/DeployLaunchpadStrategy.s.sol`, runnable after the core stack, deploying the `LaunchpadStrategy` template, the `SushiLaunchAdapter` singleton, and the `StonkLaunchAdapter` implementation, then approving the template on `StrategyFactory`.

Identity, not presence: this chain's known hazard is unrelated bytecode squatting on canonical addresses, so the script SHALL assert venue identity before deploying anything wired to it — the Sushi launchpad answers `v3Factory()`/`positionManager()`/`WETH()` consistently with the recorded Sushi V3 addresses, and each Smart Launch pad answers `quote()` with its lane's token and `launchCount() > 0` (or is explicitly annotated as fresh). A `code.length != 0` check alone SHALL NOT be treated as sufficient.

The post-deploy validation reads SHALL gain: `strategyFactory.approvedTemplate(LAUNCHPAD_TEMPLATE) == true`, `tierRegistry.isAdapterAllowed(SUSHI_LAUNCH_ADAPTER) == true`, `tierRegistry.isAdapterAllowed(STONK_LAUNCH_ADAPTER_IMPL) == true`, and counterparty standing for the Sushi launchpad and every configured pad. The runbook SHALL note that the launch venues exist only on mainnet 4663 — the testnet (46630) ceremony skips this script, and fork rehearsal happens on a 4663 fork.

`chains/4663.json` SHALL gain `SUSHI_LAUNCHPAD_V1`, `SUSHI_V3_FACTORY`, `SUSHI_V3_POSITION_MANAGER`, `WOOD_WETH_SUSHI_V3_POOL`, `SAFE_LAUNCH_LENS_V2`, and the Smart Launch pad set keyed by lane; `addresses/4663.json` SHALL record each with its identity-verification evidence, following the existing `external` block convention.

#### Scenario: Venue identity check fails
- **WHEN** the script runs against an address whose reads do not match the recorded venue identity
- **THEN** it reverts before deploying or approving anything wired to that venue

#### Scenario: Testnet ceremony
- **WHEN** the ceremony targets chain 46630
- **THEN** the launchpad-strategy script is skipped and no template approval for it is written
