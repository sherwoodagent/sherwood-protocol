## ADDED Requirements

### Requirement: The StrategyFactory phase wires the registry before handoff
`DeployStrategyFactory` SHALL require `TIER_REGISTRY` in the address book and `TierRegistry.owner() == deployer`, SHALL call `setStrategyFactory(<minted factory>)` inside its broadcast, and SHALL assert `strategyFactory()` reads back the minted factory. There SHALL be no deferred or escape-hatch path: an unwired registry makes every `propose` revert `StrategyNotRegistered` and every non-asset batch target refused, so the phase runs BEFORE the multisig accepts TierRegistry ownership. A TierRegistry redeploy runbook SHALL list `setStrategyFactory(STRATEGY_FACTORY)` alongside the certification set.

#### Scenario: The ceremony leaves the registry wired
- **WHEN** `DeployStrategyFactory` completes against a registry the deployer still owns
- **THEN** `tierRegistry.strategyFactory()` equals the minted factory and a `propose` naming a strategy registered on it succeeds

#### Scenario: The ceremony refuses a handed-off registry
- **WHEN** the multisig has already accepted TierRegistry ownership
- **THEN** the phase reverts naming the wiring, deploying nothing

## MODIFIED Requirements

### Requirement: The Robinhood ceremony seats every owner-gated write before handoff
`DeployRobinhoodMainnet` reimplements `run()` rather than extending the canonical `DeploySherwood.run()`, so every write the canonical run makes between `deployCore` and the multisig handoff SHALL be restated in it. Those writes SHALL be collected in ONE internal method (`_seatOwnerWrites`) rather than scattered inline, so the set can be asserted as a set: each is an `onlyOwner` call on a contract the handoff then transfers, so each has exactly one window in which it is cheap and an eternity afterwards in which it is a multisig chore.

The set is: `setProtocolFeeRecipient`, `setGuardiansFeeRecipient`, and **the TierRegistry launch set** (`_seedTierRegistry`). `deployCore` mints the TierRegistry empty and wires it into the factory; the attestations are separate `onlyOwner` writes. `isCounterpartyAllowed` GATES CLONE-INIT for every shipped template, so an empty registry makes every clone revert at init and makes `DeployConcentratedLiquidityStrategy` refuse to run at all.

The launch set is ONE axis: every venue a template binds — the Uniswap v3 factory and position manager, the Morpho Blue singleton, each Chainlink aggregator — is seeded with `setCounterpartyAllowed(x, true)`, and each aggregator is additionally paired to its token with `setPriceSourceForToken`. No deploy script SHALL call any adapter or callee allowlist setter; none exists. The addresses this deploy MINTS (the swap adapter) are attested as counterparties by their own phase (`DeployPortfolioStrategy._attestAdapter`) inside the two-step ownership window, and degrade to a `setCounterpartyAllowed` RUNBOOK line once the multisig has accepted.

#### Scenario: Launch set lands before the handoff
- **WHEN** the Robinhood ceremony completes
- **THEN** the TierRegistry answers `isCounterpartyAllowed == true` for `UNISWAP_V3_FACTORY`, `UNISWAP_V3_POSITION_MANAGER`, `MORPHO_BLUE` and every seeded Chainlink feed, and `isPriceSourceForToken(token, feed)` for every feed whose token is on the chain

#### Scenario: Seeding moved below the handoff
- **GIVEN** a refactor that moves the seed call after the Safe has accepted ownership
- **THEN** the seeding SKIPS rather than reverting — it is best-effort by design — and the ceremony ships an empty registry while looking clean, which `test/deploy/DeployRobinhoodMainnetHandoff.t.sol` pins

The ceremony SHALL seat BOTH `protocolFeeRecipient` AND `guardiansFeeRecipient` on `ProtocolConfig` inside the broadcast, and validation SHALL assert both. `ProtocolConfig`'s constructor seeds only the splits, and a zero recipient does NOT strand its leg — the governor zeroes that slice and hands it to the agent as remainder, in both `_chargeManagementFee` and `_chargePerformanceFee`. An unseated recipient is therefore a SILENT RE-ROUTING to the proposer, not a missing payment. The guardian leg is the load-bearing one: `MANAGEMENT_FEE_BPS = 200` is sized so 20% of management and 25% of performance fund the guardian pool, so leaving it unset charges depositors at a rate justified by a pool that receives nothing.

Both are seeded to the DEPLOYER as a placeholder, never as the destination. The runbook SHALL direct the multisig to call `setProtocolFeeRecipient` and `setGuardiansFeeRecipient` after `acceptOwnership()`; until it does, both fee legs accrue to a single EOA.

#### Scenario: Unseated guardian fee recipient refused
- **WHEN** the core ceremony completes with `guardiansFeeRecipient` still zero
- **THEN** validation FAILS naming that leg, because the guardian budget would otherwise pay the proposer with nothing on-chain to notice

#### Scenario: Post-deploy validation reads
- **WHEN** the five scripts complete
- **THEN** the operator verifies `factory.beacon/protocolConfig`, `swood.wood == WOOD`, `swood.registry == registry`, `registry.reviewPeriod == 86400`, `registry.blockQuorumBps == 3000`, `strategyFactory.approvedTemplate(PORTFOLIO) == true`, and `governorImpl.MIN_VOTING_PERIOD() == 86400`

#### Scenario: Mainnet ceremony with EOA multisig refused
- **WHEN** `OWNER_MULTISIG` is an EOA and handoff is not skipped
- **THEN** the deploy reverts "OWNER_MULTISIG must be a contract (Safe), not an EOA"
