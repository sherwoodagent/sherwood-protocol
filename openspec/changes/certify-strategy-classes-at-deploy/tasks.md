## 1. The two-phase script

- [x] 1.1 Add `script/CertifyStrategyClasses.s.sol` with `propose()` and `finalize()`, resolving template addresses from `chains/{chainId}.json`
- [x] 1.2 State `tier` and `extractableBoundBps` in a named constant block with the rationale, overridable by env
- [x] 1.3 Certify `PORTFOLIO_TEMPLATE` only; leave `CONCENTRATED_LIQUIDITY_TEMPLATE` and `MORPHO_SUPPLY_TEMPLATE` at the uncertified default, citing the unbound market parameters each leaves open
- [x] 1.4 Pin `expectedTemplateCodehash` at propose time; on drift, print the recovery runbook and fail with a named reason rather than a bare `TemplateCodehashChanged`
- [x] 1.5 Refuse to announce when `submitterBondWood() != 0` — `certifyClass` is submitter-only with a bond and this script funds no such flow
- [x] 1.6 Guard phase A on registry ownership (`proposeClassCertification` is `onlyOwner`): log a RUNBOOK line and skip, never revert
- [x] 1.7 Leave phase B unguarded on ownership — `certifyClass` is permissionless without a bond, so a handoff inside the three-day gap must not strand the ceremony
- [x] 1.8 Make both phases re-runnable — an already-certified selector is skipped, not re-announced or re-executed
- [x] 1.9 Require BOTH selectors certified before reporting success; recognise a completed grant by `classTierOf`, never by `readyAt == 0`
- [x] 1.10 Refuse both phases for a class that was certified and then demoted, detected by the anchor surviving `_demoteClass` while a selector is neither certified nor pending
- [x] 1.11 Surface `MAX_CERTIFY_WINDOW`: print the deadline in phase A, give phase B an expiry branch with the cancel-and-re-propose recovery
- [x] 1.12 Check the drift guard on both pending records AND on the class anchor, so drift after both grants executed is still caught
- [x] 1.13 Add `CERTIFY_STRICT=true`, turning every skip path into a revert, reached through an overridable seam rather than a direct `vm.envOr` read

## 2. Discoverability

- [x] 2.1 Add the RUNBOOK line to `Deploy.s.sol` naming the step and the delay

## 3. Tests

- [x] 3.1 Pin the bug: before the ceremony every strategy clone resolves to `(TIER_ARBITRARY, FULL_NOTIONAL_BPS)` on both selectors
- [x] 3.2 Phase A announces the eligible template on both selectors with the codehash and risk parameters pinned, and announces nothing for the excluded ones
- [x] 3.3 `finalize()` before the delay surfaces `CertifyDelayNotElapsed`; after it, both selectors certify
- [x] 3.4 The property: after the ceremony a factory-minted clone reads `(1, 2_000)` on both selectors, and a clone of an excluded template still reads full notional
- [x] 3.5 Phase A skips without reverting once ownership has moved; a merely pending handoff does not block it; phase B completes after a completed handoff
- [x] 3.6 Both phases are re-runnable, including from a half-finished ceremony, and a re-run emits no redundant `ClassCertified`
- [x] 3.7 Every test fails under a stated mutation of the code it pins
- [x] 3.8 A phase A that announced only `execute()` makes `finalize()` halt
- [x] 3.9 A class demoted by `demoteClassByChallenge` is refused by both phases
- [x] 3.10 An expired grant produces the expiry branch, not a bare `CertificationExpired()`
- [x] 3.11 Drift carried only by the pending records is caught before any anchor exists
- [x] 3.12 Drift after both grants executed halts `finalize()` on the anchor comparison
- [x] 3.13 `CERTIFY_STRICT=true` reverts where the default skips — one test per reachable path: ownership moved, submitter bond, template missing from the book, template address codeless
- [x] 3.14 A conviction on a selector the script never walks leaves `execute()`/`settle()` certified and both phases as clean no-ops
