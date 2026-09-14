## MODIFIED Requirements

### Requirement: Deploy ceremony order and skip rules
The fork ceremony SHALL run five scripts in order, each broadcast with the flags above:
1. `script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet` with `WOOD_TOKEN=<live WOOD>`, `SKIP_MULTISIG_HANDOFF=true`, `ROBINHOOD_FORK_CHAIN_ID=9994663` — core only; no ENS/ERC-8004 (both registrar addresses are `address(0)` on Robinhood).
2. `script/robinhood-mainnet/DeployPortfolioStrategy.s.sol` — UniswapSwapAdapter (v3+v4) + PortfolioStrategy template.
3. `script/robinhood-mainnet/DeployMorphoStrategy.s.sol` — MorphoSupplyStrategy template. Separate from step 2 because that script reads four Uniswap addresses to build its adapter and this template needs none of them.
4. `script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol` — ConcentratedLiquidityStrategy template. It reads `UNISWAP_V3_POSITION_MANAGER`, `UNISWAP_V3_FACTORY` and `MORPHO_BLUE` from the address book and asserts the position manager's identity, not merely its code presence; the first and third keys SHALL be seeded before this step runs.
5. `script/DeployStrategyFactory.s.sol` with `SKIP_MULTISIG_HANDOFF=true` — keyless-clone StrategyFactory + template approvals.

The ceremony SHALL then certify the CODE CLASS of each eligible strategy template, in two broadcasts separated by `certifyDelay`:

6. `script/CertifyStrategyClasses.s.sol --sig 'propose()'` — announces a class certification for each template in the class set against both `IStrategy.execute()` and `IStrategy.settle()`, pinning each template's live codehash.
7. `script/CertifyStrategyClasses.s.sol --sig 'finalize()'`, no earlier than `certifyDelay` (default 3 days, floor `MIN_CERTIFY_DELAY` = 1 day) after step 6 and no later than `MAX_CERTIFY_WINDOW` (14 days) past that — executes the grants. Step 7 is therefore legal only on days 3–17 of the ceremony; past the window `certifyClass` reverts `CertificationExpired` and every grant must be cancelled with `cancelClassCertification` and re-announced from step 6. Phase A SHALL print the absolute unix deadline, and phase B SHALL name the lapsed window with that recovery rather than surfacing a bare `CertificationExpired()`.

Steps 6 and 7 are an ECONOMICS step, not a liveness one, and SHALL be described as such. `StrategyFactory.cloneAndInit` records `cloneTemplate[clone]` and `SyndicateVault._guardBatchCalls` admits any target the factory registers, so a clone of an uncertified template is callable and fundable. What it is not is cheap: `SyndicateGovernor._scanCalls` resolves every call through `tierOf(target, selector)`, an uncertified class answers `(TIER_ARBITRARY, FULL_NOTIONAL_BPS)`, and the required guardian coverage is then the full declared cap of every leg. A ceremony that stops at step 5 therefore yields a working protocol whose every strategy proposal is priced at full notional. Per-clone address certification is not the alternative: a clone's address does not exist until the proposal that creates it, so that path costs two owner transactions and a full `certifyDelay` PER PROPOSAL.

Phase A SHALL run while the deployer still owns the `TierRegistry` (`proposeClassCertification` is `onlyOwner`), and SHALL log a RUNBOOK line and skip rather than revert once ownership has moved. Phase B SHALL NOT carry that guard: `certifyClass` is permissionless when no submitter bond is configured, and an `Ownable2Step` handoff landing inside the three-day gap would otherwise strand a ceremony already announced. `CERTIFY_STRICT=true` SHALL turn every skip — ownership moved, submitter bond configured, template missing from the address book, template address codeless — into a revert, so a run that IS step 6 or 7 cannot exit 0 having done nothing. The default stays skip, because the same script also runs behind a deploy that has already broadcast.

Both phases SHALL be re-runnable: a selector already certified is skipped rather than re-announced or re-executed, and a ceremony interrupted between `certifyClass` calls resumes rather than re-executing a pending record that no longer exists. A completed grant SHALL be recognised by `classTierOf != TIER_ARBITRARY`, never by `readyAt == 0`, which is equally "never announced" and "cancelled".

Success SHALL require BOTH `IStrategy.execute()` and `IStrategy.settle()` to carry a live class certification. A governor batch names both, and `_scanCalls` prices each separately, so a class with only `execute()` certified still books full notional on the settlement leg while reporting a completed ceremony.

Neither phase SHALL restore a class that was certified and then demoted. `_demoteClass` erases the tier config for the selector it is given and leaves the class ANCHOR standing, so `classAnchorOf(cloneCodehashOf(template)).template != address(0)` alongside a selector that is neither certified nor pending is exactly "certified, then taken away" — or a class only ever half-granted, which needs the same owner decision. Both phases SHALL refuse on that read with a RUNBOOK line demanding an explicit owner `proposeClassCertification`, so restored standing is never a side effect of re-running this script. The pending-record allowance is load-bearing: an owner who has re-announced a demoted class after re-review HAS made that decision, and treating any standing anchor as a refusal would also block every ordinary re-run.

A conviction on a selector the script does not walk SHALL be a no-op for it. `_demoteClass` erases only the selector it is given and nothing class-wide survives it, so `execute()` and `settle()` keep their grants and both phases correctly do nothing.

`finalize()` SHALL compare the template's live codehash against BOTH the pending records and `classAnchorOf(cloneCodehashOf(template)).templateCodehash`. The pending records carry drift before any grant executes; once both have executed no pending record survives, and a stale anchor makes `_classAnchorOf` resolve nothing, so every clone silently falls back to the uncertified default while the script would otherwise report success.

The class set SHALL exclude any template whose `_initialize` does not bound the loss surface the certified bound claims to price, and exclusion SHALL be treated as costless: an uncertified template's clones remain callable, they merely keep paying full notional.

- `MorphoSupplyStrategy` is excluded because it decodes `MarketParams` straight out of init data and binds none of `mp.oracle`, `.irm` or `.lltv` — the only market check is `market(id).lastUpdate != 0`, which is permissionlessly satisfiable on Morpho Blue — so no class bound holds over every initialization. It DOES bind its Morpho singleton through the registry (`MorphoSupplyStrategy.sol:82`); the "it validates its Morpho address by asking that address" justification in `docs/adapter-onboarding-checklist.md` §4b is stale and SHALL NOT be relied on.
- `ConcentratedLiquidityStrategy` is excluded on the same ground. Its levered path binds `swapAdapter`, `positionManager`, `uniswapFactory`, `morpho` and `marketParams.collateralToken` to the registry but leaves `marketParams.oracle`, `.irm` and `.lltv` proposer-chosen, and the LTV buffer test prices collateral off the strategy's own feed rather than the market oracle, so a levered clone can be pointed at a market with an attacker-authored oracle and lose the whole collateral. Tier and bound are per-CLASS, so the unlevered mode — which names no Morpho surface at all — does not change the price the class must carry.
- `PortfolioStrategy` is in the set at `tier = 1`, `extractableBoundBps = 2_000`. Its `_initialize` binds the swap adapter, every price feed and each token↔feed pairing through the registry, and no single in-batch call can exceed `MAX_SLIPPAGE_CEILING_BPS` = 1_000 bps, so `2_000` is that ceiling with 2x headroom. The bound prices the in-batch surface only: `rebalanceDelta()` is `onlyProposer` and called on the clone rather than through a governor batch, and carries no lifetime decay budget, so its repeats are unbounded by any class parameter.

Certifying ANY class below tier 2 SHALL be ratified by a human before a mainnet run, because it removes a control no `extractableBoundBps` restores. `SyndicateGovernor._scanCalls` applies the per-call `Tier2CallCapExceedsCeiling` ceiling only when a call resolves to tier 2, so a tier-1 class certification drops that ceiling for every clone of the template, permanently and for every future proposal. The bound is a coverage multiplier, not a cap; raising it narrows the coverage discount and does not reinstate the ceiling. Accepting that trade is a deployment decision, not a script default.

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
- **THEN** every strategy clone reads `(TIER_ARBITRARY, FULL_NOTIONAL_BPS)` from `tierOf` on both `execute()` and `settle()`, so the governor books the full declared cap of every leg as required guardian coverage

#### Scenario: Class ceremony completes
- **WHEN** step 7 completes for `PortfolioStrategy`
- **THEN** a factory-minted clone that nobody has ever named reads `(1, 2_000)` from `tierOf` on both selectors, and a clone of a template outside the class set still reads `(TIER_ARBITRARY, FULL_NOTIONAL_BPS)`

#### Scenario: Finalize run before the delay
- **WHEN** step 7 runs before `certifyDelay` has elapsed since step 6
- **THEN** it reverts `CertifyDelayNotElapsed` — the announcement window is not skippable by the ceremony

#### Scenario: Ownership already handed to the multisig
- **WHEN** step 6 runs after the `Ownable2Step` handoff has completed
- **THEN** it logs a RUNBOOK line naming the owner-run step and returns without reverting, leaving the registry untouched

#### Scenario: Handoff completes between the two phases
- **WHEN** step 6 ran while the deployer owned the registry, ownership then moves to the multisig, and step 7 runs
- **THEN** it certifies both selectors anyway, because `certifyClass` is permissionless without a submitter bond

#### Scenario: Strict mode on a skip path
- **WHEN** a phase runs with `CERTIFY_STRICT=true` and hits any skip condition
- **THEN** it reverts naming the condition, instead of exiting 0 having written nothing

#### Scenario: Only one selector was announced
- **WHEN** step 7 runs against a template whose `settle()` was never announced or was cancelled
- **THEN** the phase halts, and the clone keeps reading full notional on both selectors rather than reporting a completed ceremony over a half-priced class

#### Scenario: Finalize after the window lapsed
- **WHEN** step 7 runs more than `MAX_CERTIFY_WINDOW` after `readyAt`
- **THEN** it names the lapsed window and the cancel-and-re-propose recovery, and halts — not a bare `CertificationExpired()`

#### Scenario: Template redeployed before either grant executed
- **WHEN** both selectors are announced, the template is then redeployed, and step 7 runs
- **THEN** the pending records carry the drift, and the phase halts with the recovery printed rather than reverting `TemplateCodehashChanged` from inside `certifyClass`

#### Scenario: Template redeployed after BOTH grants were already executed
- **WHEN** both selectors are certified out of band, the template is then redeployed, and step 7 runs
- **THEN** the anchor-codehash comparison halts the phase, rather than reporting success over a class whose every clone has fallen back to full notional

#### Scenario: Re-run after a challenge conviction demoted the class
- **WHEN** the class is demoted by `demoteClassByChallenge` and either phase is re-run
- **THEN** it refuses, printing a RUNBOOK line demanding an explicit owner re-announcement, and does not re-announce or re-certify the class

#### Scenario: Conviction lands on a selector the script never walks
- **WHEN** the owner has also certified a third selector on a template, a conviction demotes that third selector, and either phase is re-run
- **THEN** both phases are no-ops and the clone keeps reading `(1, 2_000)` on `execute()` and `settle()`, because `_demoteClass` erases only the selector it is given
