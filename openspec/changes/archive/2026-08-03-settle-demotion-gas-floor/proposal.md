## Why

Issue #51: `ChallengeGame._settle`'s `InsufficientSlashGas` floor (`src/ChallengeGame.sol:1064`) is sized for the slash alone (`approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE`, constants at `:176-177`), while the best-effort adapter demotion (`:1158`, a bare `try/catch` around `tierRegistry.demoteByChallenge`) runs after the slash with no gas term of its own. The issue posits a caller-selected 63/64 starvation: pass the floor, let the slash spend the budget, and the starved demotion child reverts into the catch — conviction lands, adapter keeps its certification, only `AdapterDemotionFailed` records it.

Verification for this change (see design.md §"Is the silent miss reachable?") shows the silent miss is **not currently reachable**: an OOG'd demotion child consumes its whole 63/64 stipend, leaving 1/64 of the frame — which cannot pay for `_settle`'s own tail (the burn/refund WOOD transfers and events at `:1174-1189`), so the whole settle reverts instead of completing with a miss. The demotion's gas safety today rests on two incidental facts — the floor constants' measured slack and the tail costing more than 1/63 of the demotion — neither of which is stated anywhere or defended by a test. The spec (`openspec/specs/challenge-game/spec.md:154`) already asserts the floor "protects the best-effort `demoteByChallenge`"; the code only delivers that by accident. This change makes the guarantee structural: a settle that cannot afford the demotion is refused up front, before any state moves.

F11's rationale (test/ChallengeGame.t.sol:1119-1134, IChallengeGame.sol:371-377) is preserved untouched: a genuinely revoked `authorizedDemoter` role — a condition nobody selects at call time — still lands the verdict and surfaces `AdapterDemotionFailed`, because the catch stays. Only the caller-tunable failure axis (gas) moves from the catch to the floor.

## What Changes

- Add a `DEMOTION_GAS = 200_000` constant to `ChallengeGame`, natspec-documented in the house style (adversary, sizing evidence, 63/64 arithmetic, headroom for issue #77's planned `_adapterAllowed` delete inside `TierRegistry._demote`).
- Extend the `_settle` gas floor: when the challenge names an adapter (`c.adapterTarget != address(0)`), the `InsufficientSlashGas` check requires `gasleft() >= approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE + DEMOTION_GAS`. Filings that accuse no adapter keep the current floor — they demote nothing and owe nothing for it.
- Keep the bare `try/catch` around `demoteByChallenge` exactly as is (F11). **Selector-filtering the catch is explicitly rejected** — see design.md §"Why not selector-filter".
- Update the floor's and the demotion's natspec so the mechanism description matches the verified behaviour (the current comment implies the silent miss is live; it is not — the floor extension is hardening, not a live-bug fix).
- Update the two floor-arithmetic tests and add gas-starvation boundary tests (below).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `challenge-game`: the "Slash gas floor" requirement gains the adapter-demotion term (`+ DEMOTION_GAS` when an adapter is named) and its rationale is corrected — the floor now guarantees, rather than incidentally permits, that a settle which passes the check can complete the demotion; the "Adapter demotion is best-effort" requirement is narrowed to state that the catch exists for registry-side refusals (revoked role), not for caller-chosen gas budgets, which the floor now refuses up front.

## Impact

- `src/ChallengeGame.sol`: one new constant near `:176-177`, one modified conditional at `:1064`, natspec updates at `:1061-1063` and `:1134-1156`. No interface change, no storage change, no event change.
- `test/ChallengeGame.t.sol`: `test_resolve_enforcesTheSlashGasFloor` (`:1232`) derives its starved budget from the live constants — must include the new term; `test_resolve_settlesEvenWhenTheDemoterRoleWasRevoked` (`:1135`, the F11 regression) must keep passing unchanged.
- `test/SlashGasCeiling.t.sol`: the CI gate `test_slashGasFloorFitsRobinhoodMaxTxGas` (`:456`) and `test_theFloorExceedsWhatAFullCapConvictionSpends` (`:647`) compute the floor by hand — both gain the term. Worst-case floor becomes `100 * 180_000 + 2_000_000 + 200_000 = 20,200,000` against the gate's `32M * (63/64)^3 = 30,523,315` ceiling — 1.51x headroom (was 1.53x).
- `openspec/specs/challenge-game/spec.md`: requirement deltas per above.
- No overlap with open PRs #104 (`feat/lane-a-enablement`) or #88 (`spec/wood-twap-ceiling`) — neither touches `ChallengeGame.sol` or `TierRegistry.sol`. No collision with issue #95's future `_refundAll` work (`:1345+`); this change ends at `:1189`. Issue #77's spec (branch `fix/issue-77-demote-clears-allowlist`) adds a `delete` inside `TierRegistry._demote`; `DEMOTION_GAS` is sized with headroom for it.
