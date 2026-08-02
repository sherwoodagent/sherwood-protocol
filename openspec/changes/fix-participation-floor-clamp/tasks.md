## 1. Fix

- [x] 1.1 In `src/TokenCourt.sol` `_participationFloor` (line 738), change `base = base > accusedWeight ? base - accusedWeight : base;` to `base = base > accusedWeight ? base - accusedWeight : 0;`

## 2. Natspec corrections

- [x] 2.1 Rewrite the `_participationFloor` @dev block "THE `>` FALLBACK IS A LIVE BRANCH..." (src/TokenCourt.sol:576-586): the branch is still live (the lookback can make `accusedWeight > base` legitimately), but it now clamps to ZERO. Delete the false claim that the fallback yields "`bps * base` with `base <= accusedWeight`, i.e. a SMALLER floor ... never a larger one"; state instead that the clamp keeps the floor monotone non-increasing in `accusedWeight` (the adversary: an accused approver staking past the base to jump the floor to its maximum and force `Inconclusive`), and that a zero floor is safe because `finalize`'s `turnout == 0` guard still forces `Inconclusive` on an empty vote while any single unaccused voter clearing it is the continuous limit of the subtraction. Update the leading formula line at src/TokenCourt.sol:569-572 ("with a `>` fallback to the unreduced base when the subtrahend would not strictly reduce it") to match.
- [x] 2.2 Update the `vote` @dev address-splitting paragraph (src/TokenCourt.sol:360-365): "every address the accused set DOES name shrinks the floor" now holds unconditionally (down to zero), no longer only in the subtraction branch; keep the open-limitation framing intact.
- [x] 2.3 Sweep the file's remaining `_participationFloor` cross-references (grep `_participationFloor` in src/TokenCourt.sol) for any other description of the old fallback direction and align them.

## 3. Regression tests (test/TokenCourt.t.sol)

- [x] 3.1 Monotonicity across the boundary: with electorate base 1_000e18 and `participationFloorBps = 1_000`, build cases with `accusedWeight` = 999e18, 1_000e18, 1_001e18; assert the emitted `CaseFinalized` floor goes 0.1e18 → 0 → 0 (never up). Reuse the existing mock-swood fixture helpers (`_referredCase` / `_caseWithElectorate` style).
- [x] 3.2 Denial lever closed: `accusedWeight >= base`, one unaccused dust voter (e.g. 1e18 aged weight) votes guilty, window elapses; assert floor == 0 in the event and verdict == `Guilty` (resolves on the merits, not `Inconclusive`).
- [x] 3.3 `turnout == 0` guard interaction: same `accusedWeight >= base` fixture, no votes cast; assert `finalize` yields `Inconclusive` with floor == 0 in the event — the guard, not the floor, carries the empty vote.
- [x] 3.4 Confirm existing floor tests still pass unchanged (`test_finalize_accusedWeightLowersFloor`, the B2 lookback suite, `test_finalize_floorDoesNotUnderflowWhenSnapshotPrecedesLookback`) — none crosses the boundary, so no expected-value edits should be needed; if any needs edits, the fix regressed something and must be revisited.

## 4. Verify

- [x] 4.1 Run `forge build` and the full `forge test` suite in the foreground (serialize behind any running solc: `while pgrep -x solc >/dev/null; do sleep 30; done` first); all green.
- [x] 4.2 Run `forge fmt --check` on src/ and test/ with a CI-matching forge before committing.
- [x] 4.3 Validate this change: `openspec validate fix-participation-floor-clamp --strict`.
