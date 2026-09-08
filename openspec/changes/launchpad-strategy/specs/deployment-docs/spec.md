## ADDED Requirements

### Requirement: Tokenize-fund deploy script and registry runbook

The deploy ceremony SHALL gain `script/robinhood-mainnet/DeployLaunchpadStrategy.s.sol`, runnable after the core stack, deploying the `LaunchpadStrategy` template, the `SushiLaunchAdapter` singleton, and the `StonkLaunchAdapter` implementation, then approving the template on `StrategyFactory`.

Identity, not presence: this chain's known hazard is unrelated bytecode squatting on canonical addresses, so the script SHALL assert venue identity before deploying anything wired to it — the Sushi launchpad answers `v3Factory()`/`positionManager()`/`WETH()` consistently with the recorded Sushi V3 addresses, and each Smart Launch pad answers `quote()` with its lane's token and `launchCount() > 0` (or is explicitly annotated as fresh). A `code.length != 0` check alone SHALL NOT be treated as sufficient.

The Stonk lane set SHALL be checked against the address book's V3 pads, and the reason is that the obvious guard does not cover it. The script derives each lane's quote from the pad itself, so the adapter constructor's pairing check compares a value to itself and cannot fire; what actually catches a mis-filed pad is the constructor's duplicate-quote rejection, and that only bites on a COLLISION. A V3 (external-token) pad reports the same quote as its V2 sibling, so filing one under a V2 key collides with nothing and would ship a lane pointed at a bring-your-own-token pad this always-minting template can never use. Codehashes cannot separate the families — every pad's differs, since its lane is an immutable — so the script SHALL reject any chosen pad that the book files as a V3 pad, comparing against every V3 lane rather than only the matching one.

The Sushi identity assertion's FIRST hop SHALL be a length-checked staticcall. A codeful-but-unrelated address — this chain's recorded hazard — has no `WETH()`, and a typed call there aborts on an ABI-decode panic with no reason string, telling an operator nothing. Later hops may be typed, since by then the target has answered one launchpad-shaped question correctly.

The post-deploy validation reads SHALL gain: `strategyFactory.approvedTemplate(LAUNCHPAD_TEMPLATE) == true`, `tierRegistry.isAdapterAllowed(SUSHI_LAUNCH_ADAPTER) == true`, `tierRegistry.isAdapterAllowed(STONK_LAUNCH_ADAPTER_IMPL) == true`, Counterparty standing is NOT required for these venues — each adapter pins its venue in immutables that the codehash gate already covers, unlike a template that takes venue addresses from proposer input — so the runbook SHALL NOT instruct the owner to set allowances that no code reads. The runbook SHALL note that the launch venues exist only on mainnet 4663 — the testnet (46630) ceremony skips this script, and fork rehearsal happens on a 4663 fork.

`chains/4663.json` SHALL gain `SUSHI_LAUNCHPAD_V1`, `SUSHI_V3_FACTORY`, `SUSHI_V3_POSITION_MANAGER`, `WOOD_WETH_SUSHI_V3_POOL`, `SAFE_LAUNCH_LENS_V2`, and the Smart Launch pad set keyed by lane; `addresses/4663.json` SHALL record each with its identity-verification evidence, following the existing `external` block convention.

#### Scenario: Venue identity check fails
- **WHEN** the script runs against an address whose reads do not match the recorded venue identity
- **THEN** it reverts before deploying or approving anything wired to that venue

#### Scenario: Testnet ceremony
- **WHEN** the ceremony targets chain 46630
- **THEN** the launchpad-strategy script is skipped and no template approval for it is written
