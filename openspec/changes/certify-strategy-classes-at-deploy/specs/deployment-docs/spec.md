## MODIFIED Requirements

### Requirement: Deploy ceremony order and skip rules
The fork ceremony SHALL run five scripts in order, each broadcast with the flags above:
1. `script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet` with `WOOD_TOKEN=<live WOOD>`, `SKIP_MULTISIG_HANDOFF=true`, `ROBINHOOD_FORK_CHAIN_ID=9994663` — core only; no ENS/ERC-8004 (both registrar addresses are `address(0)` on Robinhood).
2. `script/robinhood-mainnet/DeployPortfolioStrategy.s.sol` — UniswapSwapAdapter (v3+v4) + PortfolioStrategy template.
3. `script/robinhood-mainnet/DeployMorphoStrategy.s.sol` — MorphoSupplyStrategy template. Separate from step 2 because that script reads four Uniswap addresses to build its adapter and this template needs none of them.
4. `script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol` — ConcentratedLiquidityStrategy template. It reads `UNISWAP_V3_POSITION_MANAGER`, `UNISWAP_V3_FACTORY` and `MORPHO_BLUE` from the address book and asserts the position manager's identity, not merely its code presence; the first and third keys SHALL be seeded before this step runs.
5. `script/DeployStrategyFactory.s.sol` with `SKIP_MULTISIG_HANDOFF=true` — keyless-clone StrategyFactory + template approvals.

The ceremony SHALL then certify and allowlist the CODE CLASS of each eligible strategy template, in two broadcasts separated by `certifyDelay`:

6. `script/CertifyStrategyClasses.s.sol --sig 'propose()'` — announces a class certification for each template in the class set against both `IStrategy.execute()` and `IStrategy.settle()`, pinning each template's live codehash.
7. `script/CertifyStrategyClasses.s.sol --sig 'finalize()'`, no earlier than `certifyDelay` (default 3 days, floor `MIN_CERTIFY_DELAY` = 1 day) after step 6 — executes the grants and calls `setClassAllowed(template, true)`, the write that opens both the callee and the funds axis.

Steps 6 and 7 are NOT optional and SHALL NOT be deferred to a post-launch runbook. `SyndicateVault._guardBatchCalls` gates every governor batch on `isCallableTarget(target)` and `isAdapterAllowed(recipient)`; a strategy clone satisfies neither until its class is both certified and allowed, so a ceremony that stops at step 5 yields a protocol whose first strategy proposal reverts `DisallowedBatchCallee` at execution — naming a clone address rather than the missing step. Per-clone `setAdapterAllowed` is not the alternative: a clone's address is not known until an agent creates it.

Both phases SHALL run while the deployer still owns the `TierRegistry` (`proposeClassCertification` and `setClassAllowed` are `onlyOwner`), and SHALL log a RUNBOOK line and skip rather than revert once ownership has moved. `finalize()` SHALL be re-runnable: an already-allowed class is skipped rather than re-written, and a class certified but not yet allowed resumes at `setClassAllowed`.

The class set SHALL exclude any template that does not satisfy the class-eligibility rules in `docs/adapter-onboarding-checklist.md` §4b. `MorphoSupplyStrategy` is excluded: it receives its Morpho singleton in init data and then interrogates that address as its own validator, so a class bound cannot be asserted over every initialization. It remains address-certifiable.

`DeployWood` SHALL be skipped — WOOD is already live on the fork. CREATE3 makes the core addresses order-independent. With handoff skipped, the deployer retains ownership of beacon / factory / registry / sWOOD / ProtocolConfig (needed for fork admin); on the real mainnet ceremony `SKIP_MULTISIG_HANDOFF` SHALL NOT be used and `OWNER_MULTISIG` MUST be a contract (Safe), not an EOA.

The ceremony SHALL persist `TIER_REGISTRY` into `chains/{chainId}.json`. `DeployPlanD` and `WireTokenCourt` both read that key as an env address, so omitting it leaves the later phases with nothing to read and forces the operator to recover the address from broadcast logs.

`DeployPlanB` SHALL likewise persist `EXPOSURE_LEDGER` and `PROPOSER_BOND_ESCROW`, `DeployPlanD` SHALL persist `CHALLENGE_GAME`, and `DeployTokenCourt` SHALL persist `TOKEN_COURT` — each is read as an env address by a later phase, and the reasoning is identical to `TIER_REGISTRY`'s. These writes SHALL happen in `run()`, never in the `deploy(AddressBook)` entry point the Plan B / Plan D pre-flight suites drive. They SHALL further go through `ScriptBase._patchAddressIfBook`, which no-ops when the chain has no address book: `DeployTokenCourt.run()` IS driven by its pre-flight suite under `vm.setEnv`, so an unguarded patch creates a junk `chains/31337.json` in the repo every time the tests run.

#### Scenario: TierRegistry reaches the address book
- **WHEN** the core ceremony completes
- **THEN** `chains/{chainId}.json` carries `TIER_REGISTRY`, and it equals `factory.tierRegistry()`

#### Scenario: Guardian-econ phases hand each other their addresses
- **WHEN** Plan B, Plan D and the court phases complete
- **THEN** `chains/{chainId}.json` carries `EXPOSURE_LEDGER`, `PROPOSER_BOND_ESCROW`, `CHALLENGE_GAME` and `TOKEN_COURT`, and the operator can run each phase straight out of the address book rather than off the previous phase's broadcast log

#### Scenario: Ceremony stops after the strategy factory
- **WHEN** steps 1-5 complete and the class ceremony is skipped
- **THEN** a governor batch naming a strategy clone reverts `DisallowedBatchCallee` at execution, and the clone reads `false` on both `isCallableTarget` and `isAdapterAllowed`

#### Scenario: Class ceremony completes
- **WHEN** step 7 completes for a template
- **THEN** a clone of that template that nobody has ever named reads `true` on both `isCallableTarget` and `isAdapterAllowed`, and a clone of a template outside the class set still reads `false` on both

#### Scenario: Finalize run before the delay
- **WHEN** step 7 runs before `certifyDelay` has elapsed since step 6
- **THEN** it reverts `CertifyDelayNotElapsed` — the announcement window is not skippable by the ceremony

#### Scenario: Ownership already handed to the multisig
- **WHEN** either phase runs after the `Ownable2Step` handoff has completed
- **THEN** it logs a RUNBOOK line naming the owner-run step and returns without reverting, leaving the registry untouched
