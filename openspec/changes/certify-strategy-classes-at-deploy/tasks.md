## 1. The two-phase script

- [x] 1.1 Add `script/CertifyStrategyClasses.s.sol` with `propose()` and `finalize()`, reading template addresses from `chains/{chainId}.json` the way `DeployTemplates.s.sol` does
- [x] 1.2 State `tier` and `extractableBoundBps` per template in a named constant block with the rationale for each, overridable by env
- [x] 1.3 Exclude `MORPHO_SUPPLY_TEMPLATE` from the class set, citing the eligibility rule it fails
- [x] 1.4 Pin `expectedTemplateCodehash` at propose time; on drift, print the recovery runbook and fail with a named reason rather than a bare `TemplateCodehashChanged`
- [x] 1.5 Refuse to announce when `submitterBondWood() != 0` — `certifyClass` is submitter-only with a bond and this script funds no such flow
- [x] 1.6 Mirror `Deploy._seedTierRegistry`'s ownership guard: log a RUNBOOK line and skip, never revert
- [x] 1.7 Make `finalize()` re-runnable — an already-allowed class is skipped, not re-written; a certified-but-unallowed class resumes at `setClassAllowed`
- [x] 1.8 Bound CL at `9_999` bps: its levered path leaves `marketParams.oracle/irm/lltv` unbound, so the reachable loss is the whole collateral. Flag the residual — tier < 2 drops the per-call `Tier2CallCapExceedsCeiling` — for ratification
- [x] 1.9 Require BOTH selectors certified before `setClassAllowed`; recognise a completed grant by `classTierOf`, never by `readyAt == 0`
- [x] 1.10 Refuse both phases for a class that was certified and then demoted, detected by the anchor surviving `_demoteClass`
- [x] 1.11 Surface `MAX_CERTIFY_WINDOW`: print the deadline in phase A, give phase B an expiry branch with the cancel-and-re-propose recovery
- [x] 1.12 Check the drift guard on both selectors, not just `execute()`
- [x] 1.13 Add `CERTIFY_STRICT=true`, turning every skip path into a revert
- [x] 1.14 Detect demotion through ANY selector, not just the two the script walks: `_demoteClass` leaves `_classCalleeAllowed` set, so callee-open with the class disallowed is the discriminator, read via a throwaway clone
- [x] 1.15 Compare the class anchor's `templateCodehash` against the live template, and assert on a probe clone after `setClassAllowed` that both axes actually opened — a drift with no pending record left otherwise reports success and grants nothing

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
- [x] 3.8 A phase A that announced only `execute()` makes `finalize()` refuse to allowlist the class
- [x] 3.9 A class demoted by `demoteClassByChallenge` is refused by both phases, not re-granted
- [x] 3.10 An expired grant produces the expiry branch, not a bare `CertificationExpired()`
- [x] 3.11 One selector already certified plus a drifted template fires the guard on the other selector
- [x] 3.12 `CERTIFY_STRICT=true` reverts where the default skips — one test per reachable path: ownership moved, submitter bond, template missing from the book, template address codeless
- [x] 3.13 A conviction on a third selector, with `execute()`/`settle()` still certified, is refused by both phases
- [x] 3.14 Drift after both grants executed halts `finalize()` under the drift reason, not the post-condition's
