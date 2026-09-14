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
7. `script/CertifyStrategyClasses.s.sol --sig 'finalize()'`, no earlier than `certifyDelay` (default 3 days, floor `MIN_CERTIFY_DELAY` = 1 day) after step 6 and no later than `MAX_CERTIFY_WINDOW` (14 days) past that — executes the grants and calls `setClassAllowed(template, true)`, the write that opens both the callee and the funds axis. Step 7 is therefore legal only on days 3–17 of the ceremony; past the window `certifyClass` reverts `CertificationExpired` and every grant must be cancelled with `cancelClassCertification` and re-announced from step 6. Phase A SHALL print the absolute unix deadline, and phase B SHALL name the lapsed window with that recovery rather than surfacing a bare `CertificationExpired()`.

Steps 6 and 7 are NOT optional and SHALL NOT be deferred to a post-launch runbook. `SyndicateVault._guardBatchCalls` gates every governor batch on `isCallableTarget(target)` and `isAdapterAllowed(recipient)`; a strategy clone satisfies neither until its class is both certified and allowed, so a ceremony that stops at step 5 yields a protocol whose first strategy proposal reverts `DisallowedBatchCallee` at execution — naming a clone address rather than the missing step. Per-clone `setAdapterAllowed` is not the alternative: a clone's address is not known until an agent creates it.

Both phases SHALL run while the deployer still owns the `TierRegistry` (`proposeClassCertification` and `setClassAllowed` are `onlyOwner`), and SHALL log a RUNBOOK line and skip rather than revert once ownership has moved. `CERTIFY_STRICT=true` SHALL turn every such skip — ownership moved, submitter bond configured, template missing from the address book, template address codeless — into a revert, so a run that IS step 6 or 7 of this ceremony cannot exit 0 having done nothing. Those four are the whole list: the class set is a fixed two entries, so "no template found at all" is reached only by every entry hitting one of the two address-book skips, each of which already reverts under strict with a message naming the failing key. The default stays skip, because the same script also runs behind a deploy that has already broadcast.

`finalize()` SHALL be re-runnable: an already-allowed class is skipped rather than re-written, and a class whose two selectors are both certified but not yet allowed resumes at `setClassAllowed`.

`setClassAllowed` SHALL NOT be called unless BOTH `IStrategy.execute()` and `IStrategy.settle()` carry a live class certification. It opens both axes for every selector at once, so allowlisting a class whose `settle()` is still tier 2 ships the "half-certified looks done" state this step exists to prevent. A `readyAt == 0` pending record is not evidence of a completed grant — it is equally "never announced" or "cancelled" — so the completed case SHALL be recognised by `classTierOf != TIER_ARBITRARY`, and every other case SHALL halt the phase.

Neither phase SHALL restore a class that was certified and then demoted, and the refusal SHALL NOT depend on which selector was demoted. Two independent reads establish it:

- **the per-selector sweep** — `_demoteClass` erases the tier config and the allowlist flag but leaves the class ANCHOR standing, so `classAnchorOf(cloneCodehashOf(template)).template != address(0)` alongside an uncertified, unannounced `execute()` or `settle()` is exactly "certified, then revoked";
- **the allowlist discriminator** — `_demoteClass` clears `_classAllowed` for the WHOLE class from ANY selector while deliberately leaving `_classCalleeAllowed` set. A class that is callee-open and not `isClassAllowed` has therefore been allowlisted and then demoted; a class certified but never allowlisted reads false on both. The sweep alone is escapable: a conviction on any third selector de-allowlists the class while `execute()` and `settle()` stay certified, and the phases would proceed. `_classCalleeAllowed` has no getter and class membership is only decidable from a member, so both phases SHALL read this through a throwaway `Clones.clone(template)`.

Both phases SHALL refuse on either read, with a RUNBOOK line demanding an explicit owner `setClassAllowed`, since `setClassAllowed`'s own contract is that restoring allowlist standing is never a side effect of re-certification. The refusal covers the window in which THIS SCRIPT would otherwise be the party re-announcing; once the owner has re-certified AND re-allowlisted a demoted class by hand, the class reads allowed and the phases skip it, and that owner transaction is itself the explicit decision.

`finalize()` SHALL further prove the grant it just made rather than assuming it. After `setClassAllowed(template, true)` a throwaway clone SHALL read `true` on both `isCallableTarget` and `isAdapterAllowed`, else the phase halts under its own reason. The state this catches is reachable today: with both grants already executed no pending record survives to carry a codehash drift, and a stale anchor makes `_classOf` return zero, so `setClassAllowed` succeeds and grants nothing. `finalize()` SHALL therefore also compare `classAnchorOf(cloneCodehashOf(template)).templateCodehash` against the live `template.codehash` before certifying, which is the guard that names that case; the clone probe is the post-condition behind it.

The class set SHALL exclude any template that does not satisfy the class-eligibility rules in `docs/adapter-onboarding-checklist.md` §4b. `MorphoSupplyStrategy` is excluded because its `marketParams.oracle`, `.irm` and `.lltv` are proposer-chosen and bound to nothing — the only market check is `market(id).lastUpdate != 0`, which is permissionlessly true of any params tuple on Morpho Blue — so no class bound holds over every initialization. (It does bind its Morpho singleton to the registry at `MorphoSupplyStrategy.sol:190`; the earlier "it validates its Morpho address by asking that address" justification is stale and SHALL NOT be relied on.) It remains address-certifiable only in the formal sense: a clone's address does not exist until the proposal that creates it, so the address path costs two owner transactions and a full `certifyDelay` PER PROPOSAL, which is not an operational alternative. Until this template's market parameters are bound, proposals against it are gated on that per-proposal ceremony.

`ConcentratedLiquidityStrategy` shares that unbound market surface on its levered path and is nevertheless in the class set, because leaving it out leaves its clones failing `isCallableTarget` — the defect this change exists to fix. It is therefore certified at `extractableBoundBps = 9_999`, the maximum `proposeClassCertification` accepts below `FULL_NOTIONAL_BPS`, so the guardian coverage the governor demands approximates the uncertified tier-2 demand instead of the 5x discount `2_000` would buy on a surface that can lose the whole collateral.

Certifying ANY class below tier 2 SHALL be ratified by a human before a mainnet run, because it removes a control no `extractableBoundBps` restores. `SyndicateGovernor._scanCalls` applies the per-call `Tier2CallCapExceedsCeiling` ceiling only when a call resolves to tier 2, so a tier-1 class certification — which is what steps 6 and 7 perform for both templates — drops that ceiling for every clone of the template, permanently and for every future proposal. The bound is a coverage multiplier, not a cap; raising it to `9_999` narrows the coverage discount and does not reinstate the ceiling. This is the trade steps 6 and 7 buy callability with, and accepting it is a deployment decision, not a script default.

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

#### Scenario: Strict mode on a skip path
- **WHEN** a phase runs with `CERTIFY_STRICT=true` and hits any skip condition
- **THEN** it reverts naming the condition, instead of exiting 0 having written nothing

#### Scenario: Only one selector was announced
- **WHEN** step 7 runs against a template whose `settle()` was never announced or was cancelled
- **THEN** the phase halts and `setClassAllowed` is not called, so the clone stays off both axes rather than becoming callable with `settle()` still at tier 2

#### Scenario: Finalize after the window lapsed
- **WHEN** step 7 runs more than `MAX_CERTIFY_WINDOW` after `readyAt`
- **THEN** it names the lapsed window and the cancel-and-re-propose recovery, and halts — not a bare `CertificationExpired()`

#### Scenario: Template redeployed after one selector was already certified
- **WHEN** a third party executes the `execute()` grant, the template is then redeployed, and step 7 runs
- **THEN** the drift guard fires on the `settle()` record and prints the recovery, rather than reverting `TemplateCodehashChanged` from inside `certifyClass`

#### Scenario: Re-run after a challenge conviction demoted the class
- **WHEN** the class is demoted by `demoteClassByChallenge` and either phase is re-run
- **THEN** it refuses, printing a RUNBOOK line demanding an explicit owner `setClassAllowed`, and does not re-announce or re-allowlist the class

#### Scenario: Conviction lands on a selector the script never walks
- **WHEN** the owner has also certified a third selector on a template, a conviction demotes that third selector, and either phase is re-run while `execute()` and `settle()` are still certified
- **THEN** it refuses on the allowlist discriminator — a clone reads callable while `isClassAllowed` reads false — and does not re-allowlist the class

#### Scenario: Template redeployed after BOTH grants were already executed
- **WHEN** both selectors are certified out of band, the template is then redeployed, and step 7 runs
- **THEN** the anchor-codehash comparison halts the phase, rather than calling `setClassAllowed` on a class whose every clone reads `false` on both axes
