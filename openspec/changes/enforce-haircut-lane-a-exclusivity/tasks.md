# Tasks — enforce-haircut-lane-a-exclusivity

Branch `fix/issue-59-haircut-lane-invariant`, based on `feat/lane-a-enablement` (PR #104 head). Do NOT rebase onto main; PR #104 must merge first (proposal.md — Merge order). All forge commands run in the FOREGROUND, serialized behind the shared build lockfile (`while pgrep -x solc >/dev/null; do sleep 30; done` before each).

## 1. Contract guards (src/pricing/PriceRouter.sol)

- [ ] 1.1 Add `error HaircutLaneAConflict();` beside the existing errors (after `HaircutCannotDecrease`, ~line 70).
- [ ] 1.2 In `setHaircutBps`, after the `HaircutTooHigh` and `HaircutCannotDecrease` checks, add `if (bps != 0 && laneAEnabled[kind]) revert HaircutLaneAConflict();` (design D5 ordering — existing selectors keep firing first).
- [ ] 1.3 In `setLaneAEnabled`, before the assignment, add `if (enabled && haircutBps[kind] != 0) revert HaircutLaneAConflict();` — disabling must not be blocked.
- [ ] 1.4 Rewrite the `setHaircutBps` natspec tail (currently `src/pricing/PriceRouter.sol:184-189`): keep the one-sided-asymmetry analysis and the two-sided-quote follow-up pointer; DELETE the "Currently dormant" paragraph (falsified by PR #104: `Erc20SpotAdapter`/`MorphoSupplyAdapter` exist in-tree and `script/DeployLaneA.s.sol` registers them and can enable Lane A); replace the "Until then, keep the haircut at 0…" advisory with the enforced guarantee: both setters revert `HaircutLaneAConflict` rather than reach `haircutBps[kind] != 0 && laneAEnabled[kind]`. State the adversary (Lane A depositor minting against understated NAV) per house style.
- [ ] 1.5 Extend the `setLaneAEnabled` natspec: enabling requires `haircutBps[kind] == 0` (`HaircutLaneAConflict`); disabling is never blocked (de-escalation path).

## 2. Deploy script comment (script/DeployLaneA.s.sol)

- [ ] 2.1 Update the PRE-FLIGHT G2 comment block (`:79-87`) and `checkHaircutsZero` natspec (`:503-510`): both setters now enforce the exclusion on-chain (`HaircutLaneAConflict`); G2 still uniquely covers routers running a pre-guard implementation and fails BEFORE the broadcast deploys anything (design D3). Do NOT change `checkHaircutsZero`'s behavior or its `"PRE-FLIGHT G2"` revert strings — `test/integration/LaneAWiring.t.sol:493-517` pins them.

## 3. Tests (test/pricing/PriceRouter.t.sol)

- [ ] 3.1 `test_setHaircut_revertsOnLaneAEnabledKind` — enable KIND (haircut 0), then `vm.expectRevert(PriceRouter.HaircutLaneAConflict.selector)` on `setHaircutBps(KIND, 1)`; assert `haircutBps(KIND) == 0` after.
- [ ] 3.2 `test_setLaneAEnabled_revertsOnHaircutKind` — set haircut 100 (KIND disabled), then expectRevert `HaircutLaneAConflict` on `setLaneAEnabled(KIND, true)`; assert `laneAEnabled(KIND) == false` after.
- [ ] 3.3 `test_haircutLaneA_unreachableFromEitherOrder` — both sequences on two fresh kinds: (a) enable → haircut reverts; (b) haircut → enable reverts. The unsafe pair is unreachable regardless of order.
- [ ] 3.4 `test_setLaneAEnabled_disableNeverBlocked` — two cases: an enabled zero-haircut kind can be disabled, and `setLaneAEnabled(kind, false)` on a nonzero-haircut (never-enabled) kind also succeeds as a no-op disable; assert `LaneAEnabledSet(kind, false)` emitted in both.
- [ ] 3.5 Honest-path regressions: `test_setLaneAEnabled_zeroHaircut_stillWorks` (haircut 0 + enable succeeds; `setHaircutBps(KIND, 0)` while enabled also succeeds) and `test_setHaircut_onDisabledKind_stillWorks` (nonzero haircut on a Lane-A-disabled kind succeeds and emits `HaircutSet`).
- [ ] 3.6 `test_haircutIsOneWayDoor_kindPermanentlyLaneB` — pin the permanence: haircut 100 on a disabled kind, then `setHaircutBps(kind, 0)` reverts `HaircutCannotDecrease` AND `setLaneAEnabled(kind, true)` reverts `HaircutLaneAConflict` (spec scenario "A nonzero haircut permanently closes the kind's instant lane"; living documentation of design D2).
- [ ] 3.7 Guardrail check: hoist any call-in-argument-position out of `vm.prank`/`vm.expectRevert` windows (repo gotcha — a pending one-shot cheatcode is consumed by argument evaluation).

## 4. Verification

- [ ] 4.1 `forge build` then `forge test --match-path "test/pricing/PriceRouter.t.sol"` — new tests green, existing suite untouched (design's sweep predicts zero existing-test updates; if any fails, STOP and re-check the sweep before editing tests).
- [ ] 4.2 `forge test --match-path "test/integration/LaneA*"` — ladders (esp. g/g2 poisoned-router and wiring-order tests) still green.
- [ ] 4.3 Full `forge test` + `forge fmt --check` (fmt with a forge matching CI).
- [ ] 4.4 `openspec validate --change enforce-haircut-lane-a-exclusivity` passes.

## 5. PR

- [ ] 5.1 Open PR with base `feat/lane-a-enablement` (NOT main). PR body: link issue #59, state explicitly that #59 STAYS OPEN (this is the runtime-invariant mitigation; the two-sided quote is the fix), and repeat the merge-order + empty-CI-check-list warning from proposal.md.
- [ ] 5.2 After PR #104 merges: retarget to `main`, confirm CI actually RUNS (an empty check list is not passing), and re-verify.
