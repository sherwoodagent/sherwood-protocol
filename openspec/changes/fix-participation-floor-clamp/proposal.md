# Fix TokenCourt participation-floor clamp (issue #96)

## Why

`TokenCourt._participationFloor` (src/TokenCourt.sol:738) skips the accused-weight subtraction entirely when `accusedWeight >= base`, falling back to the FULL unreduced base instead of clamping to zero. The floor is therefore non-monotone in `accusedWeight`: as the accused cohort's stake approaches the base the floor shrinks toward zero, then at `accusedWeight >= base` it jumps to the maximum (`participationFloorBps × base`). Because the accused control `accusedWeight` (by staking more before the drain, inside `FLOOR_LOOKBACK`), they can deliberately land in the fallback branch, push the floor beyond any achievable turnout, and force `Inconclusive` — no slash, no `_convicted` mark, no adapter demotion, counter-bond returned whole. This is strictly cheaper than the non-approving-address denial attack the B2 lookback minimum was added to close, and it lands in the exact branch the B2 natspec declares safe. The function's own natspec (src/TokenCourt.sol:583-586) claims the fallback yields "a SMALLER floor than the subtraction would have produced — never a larger one"; the truth is the opposite (a clamped subtraction would yield 0, the fallback yields the maximum).

## What Changes

- One-line fix in `_participationFloor`: `base = base > accusedWeight ? base - accusedWeight : 0;` — clamp to zero instead of falling back to the unreduced base, making the floor monotone non-increasing in `accusedWeight`.
- Correct the `_participationFloor` natspec: the `>` fallback block (the "LIVE BRANCH, NOT DEFENCE-IN-DEPTH" / "SMALLER floor ... never a larger one" paragraph) must describe the clamp-to-zero behavior and why zero is safe there — `finalize`'s `turnout == 0` guard (src/TokenCourt.sol:529) still forces `Inconclusive` on an empty vote, so a zero floor never lets a zero-turnout case resolve on the merits; any single unaccused voter clears a zero floor, which is the correct continuous limit of the subtraction.
- Also reconcile the `vote` natspec's address-splitting paragraph (src/TokenCourt.sol:360-365, "every address the accused set DOES name shrinks the floor") which is only true of the subtraction branch today.
- Regression tests in `test/TokenCourt.t.sol`:
  - Monotonicity across the `accusedWeight >= base` boundary (`accusedWeight = base - ε` vs `base` vs `base + ε`: floor goes ε-scaled → 0 → 0, never jumps up).
  - `accusedWeight >= base` with a single unaccused dust voter → floor 0, turnout ≥ floor, case resolves on the merits (Guilty on an unopposed guilty vote), closing the denial lever.
  - `accusedWeight >= base` with zero turnout → still `Inconclusive` via the `turnout == 0` guard (the guard, not the floor, carries the empty-vote case).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `token-court`: the "Participation floor" requirement changes — the floor base becomes `max(0, min-lookback-base - accusedWeight)` (clamp to zero) instead of falling back to the unreduced base when the subtraction would not strictly reduce it. The requirement's stated rationale ("`accusedWeight <= total` by construction") is false once the B2 lookback min is in play and is corrected alongside.

## Impact

- `src/TokenCourt.sol` — `_participationFloor` (one expression at line 738) and the natspec blocks at lines 576-586 (fallback rationale) and 360-365 (`vote` address-splitting paragraph).
- `test/TokenCourt.t.sol` — new regression tests; existing floor tests (`test_finalize_accusedWeightLowersFloor`, B2 lookback suite) are unaffected because none crosses the `accusedWeight >= base` boundary.
- `openspec/specs/token-court/spec.md` — "Participation floor" requirement text (via this change's delta spec).
- No interface, storage, event, or deployment changes. Behavior changes only in the previously-untested `accusedWeight >= base` region, where the old behavior was the bug.
