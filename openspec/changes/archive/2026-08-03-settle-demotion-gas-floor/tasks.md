## 1. Contract change (src/ChallengeGame.sol)

- [x] 1.1 Add `uint256 public constant DEMOTION_GAS = 200_000;` beside `SLASH_GAS_PER_APPROVER`/`SLASH_GAS_BASE` (`:176-177`), with house-style natspec: the adversary (a permissionless `resolve`/`finalize` caller dialling gas so the conviction lands but the demotion child starves), the sizing evidence (estimated ≈45k worst-case `demoteByChallenge` frame, ≈50k with issue #77's `_adapterAllowed` delete; 63/64 forwarding leaves ≥ ~197k — ~4x), and the pointer to the measurement test added in 2.4.
- [x] 1.2 Extend the floor at `:1064`: require `+ DEMOTION_GAS` when `c.adapterTarget != address(0)`; keep the slash-only floor for zero-adapter filings. Keep the check's position (after `_convicted[key] = true`, before `slashVerdict`) and the `InsufficientSlashGas` revert unchanged.
- [x] 1.3 Update the constants' natspec block above `:176` (floor arithmetic walk: full-cap total becomes `20,200,000` for adapter-naming settles, headroom 1.511x) and the floor-placement comment at `:1061-1063`.
- [x] 1.4 Rewrite the demotion comment at `:1134-1156` to the corrected account: the catch exists for registry-side refusals (F11's revoked role); the caller-chosen gas axis is refused up front by the floor's `DEMOTION_GAS` term; state why the catch stays BARE (design.md Decision 2 — selector-filtering re-opens F11's wedge and classifies nothing an OOG child can produce). Do NOT change the try/catch itself.

## 2. Tests

- [x] 2.1 `test/ChallengeGame.t.sol:1232` `test_resolve_enforcesTheSlashGasFloor`: derive the starved budget from the live constants INCLUDING `game.DEMOTION_GAS()` (the fixture names an adapter), so the test keeps refusing at the floor rather than passing on slack.
- [x] 2.2 Add the gas-starvation boundary test (the issue-#51 reproduction, honest form): call `resolve` on an adapter-naming challenge with gas that clears the OLD floor (`approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE + margin`) but sits below the extended floor; assert the call reverts with exactly `InsufficientSlashGas` (not OOG — check the returned selector, per the `:1244-1246` pattern), that `swood.callCount() == 0`, and that a retry with honest gas settles AND demotes (`tiers.demoteCount() == 1`, no `AdapterDemotionFailed`). This is the test that proves a budget which could previously reach the slash on an adapter-naming settle is now refused before any state moves.
- [x] 2.3 Add the no-adapter floor test: a zero-adapter filing settles with gas between the slash-only floor and the extended floor — the `DEMOTION_GAS` term is not charged where no demotion is owed.
- [x] 2.4 Add a demotion-cost bracketing test in `test/SlashGasCeiling.t.sol` (real `TierRegistry`, per its existing fixture): measure the gas a successful `demoteByChallenge` consumes at settle time and assert it `< DEMOTION_GAS * 63 / 64` with headroom logged, so the constant is anchored to a measurement and issue #77's future `delete` has a visible budget.
- [x] 2.5 Update `test/SlashGasCeiling.t.sol:456` `test_slashGasFloorFitsRobinhoodMaxTxGas` and `:647` `test_theFloorExceedsWhatAFullCapConvictionSpends` to compute the floor with `+ DEMOTION_GAS` (worst case: adapter named). Confirm the gate still passes: `20,200,000 < 30,523,315`.
- [x] 2.6 Re-run unchanged and confirm green: `test_resolve_settlesEvenWhenTheDemoterRoleWasRevoked` (`:1135`, the F11 regression — must pass with zero edits), `test_fullCapConviction_fitsInAMinableTransaction` (`:553`, the 32M execution proof), `test_resolve_withoutAnAdapterDemotesNothing` (`:1200`), and the `TokenCourt` finalize-filter suite (`test/TokenCourt.t.sol:870-892`).

## 3. Spec sync and verification

- [x] 3.1 `openspec validate settle-demotion-gas-floor --strict` passes.
- [x] 3.2 Full `forge test` green; run `forge fmt` with a CI-matching forge before committing (repo guardrail).
- [x] 3.3 Cross-check no conflict materialised: `git diff origin/main -- src/ChallengeGame.sol` touches only the constants block, `:1061-1066`, and `:1134-1162`; nothing in `_refundAll` (`:1345+`, issue #95) or `TierRegistry.sol` (issue #77).
