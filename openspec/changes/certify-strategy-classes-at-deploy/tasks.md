## 1. The two-phase script

- [x] 1.1 Add `script/CertifyStrategyClasses.s.sol` with `propose()` and `finalize()`, reading template addresses from `chains/{chainId}.json` the way `DeployTemplates.s.sol` does
- [x] 1.2 State `tier` and `extractableBoundBps` per template in a named constant block with the rationale for each, overridable by env
- [x] 1.3 Exclude `MORPHO_SUPPLY_TEMPLATE` from the class set, citing the eligibility rule it fails
- [x] 1.4 Pin `expectedTemplateCodehash` at propose time; on drift, print the recovery runbook and fail with a named reason rather than a bare `TemplateCodehashChanged`
- [x] 1.5 Refuse to announce when `submitterBondWood() != 0` — `certifyClass` is submitter-only with a bond and this script funds no such flow
- [x] 1.6 Mirror `Deploy._seedTierRegistry`'s ownership guard: log a RUNBOOK line and skip, never revert
- [x] 1.7 Make `finalize()` re-runnable — an already-allowed class is skipped, not re-written; a certified-but-unallowed class resumes at `setClassAllowed`

## 2. Discoverability

- [x] 2.1 Add the RUNBOOK line to `Deploy.s.sol` naming the step and the delay

## 3. Tests

- [x] 3.1 Pin the bug: before the ceremony a real ERC-1167 clone fails both axes and a real vault batch naming it reverts `DisallowedBatchCallee` / `DisallowedTransferTarget`
- [x] 3.2 Phase A announces every eligible template on both selectors, with the codehash and risk parameters pinned
- [x] 3.3 `finalize()` before the delay surfaces `CertifyDelayNotElapsed`; after it, both selectors certify
- [x] 3.4 The property: after the ceremony the vault accepts a batch that calls and pays a clone, and a clone of the excluded template still does not
- [x] 3.5 Owner-not-deployer skips without reverting; a merely pending Ownable2Step handoff does not block the ceremony
- [x] 3.6 Both phases are re-runnable, including from a half-finished ceremony, and a re-run emits no redundant `ClassAllowedSet`
- [x] 3.7 Every test fails under a stated mutation of the code it pins
