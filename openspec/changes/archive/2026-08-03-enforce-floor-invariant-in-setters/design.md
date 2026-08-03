# Design — enforce `participationFloorBps < ageFloorBps` in TokenCourt's setters

## Context

See proposal.md — Why. Verified current state (origin/main @ b8b6d0d):

- `setParticipationFloorBps` bounds-checks only `(0, 10_000]` — `src/TokenCourt.sol:204-208`.
- `setStakedWood` checks only non-zero — `src/TokenCourt.sol:177-181`.
- The invariant lives solely in `WireTokenCourt` PRE-FLIGHT 4 — `script/DeployTokenCourt.s.sol:235-243`.
- The precedent pair: `setVoteWindow` checks the window invariant against the wired game, vacuous while unwired (`src/TokenCourt.sol:190-201`); `setChallengeGame` checks it unconditionally against the NEW game, and its natspec names guarding only one of a composing setter pair a "bypass" (`src/TokenCourt.sol:139-149`).
- `finalize` compares aged turnout against a raw-base floor: `turnout == 0 || turnout < floor → Inconclusive` (`src/TokenCourt.sol:525-530`); the floor is `participationFloorBps * base / 10_000` with `base` raw stake minus accused raw (`src/TokenCourt.sol:725-740`). The aged-vs-raw split is deliberate and documented (`src/TokenCourt.sol:377-385`), so the fix is a parameter guard, not an arithmetic change.
- `IStakedWood` does NOT declare `ageFloorBps` (`src/interfaces/IStakedWood.sol`) — deliberately; the deploy script already carries its own one-function local interface for the same read (`script/DeployTokenCourt.s.sol:19-25`).
- `StakedWood.setAgeFloorBps` accepts any `(0, 10_000]` (`src/StakedWood.sol:744-748`). sWOOD does cross-contract checks only against contracts it already points to (e.g. `setCooldownPeriod` vs `registry.reviewPeriod()`, `src/StakedWood.sol:703-711`); it holds no pointer to the court.

Constraint: a sibling branch fixes issue #96 at `src/TokenCourt.sol:738` plus natspec at 569-586 and 360-365. This change touches lines ~14-16 (interface region), 176-208 (the two setters), and `ITokenCourt` — clear of all #96 regions; do not edit `_participationFloor` or the `vote`/floor-base natspec blocks.

## Goals / Non-Goals

**Goals:**
- Make the two TokenCourt levers that can break `participationFloorBps < ageFloorBps` revert instead of succeeding, mirroring the existing window-invariant pattern exactly.
- Keep the deploy pre-flight as the wire-time check for the side the court cannot guard.

**Non-Goals:**
- No guard on `StakedWood.setAgeFloorBps` (accepted decision: TokenCourt may depend on StakedWood, never the reverse — sWOOD is the base-layer custodian read by registry, governor, factory, and court, and giving it a court pointer would invert the layering and add wiring surface to the token-custody contract for a court-local liveness property). Monitoring (option 3) owns that side.
- No change to `finalize`/`_participationFloor` arithmetic, no per-case pinning changes, no changes to `IStakedWood`.

## Decisions

### D1 — Local one-function interface, not an `IStakedWood` addition

Add a file-local interface in `TokenCourt.sol` next to `IChallengeGameLedger` (`src/TokenCourt.sol:14-16`):

- the file already uses exactly this pattern for "the one thing a dependency does not declare";
- `script/DeployTokenCourt.s.sol:19-25` made the same call for the same function, with a comment explaining that widening the shared interface drags surface;
- `IStakedWood`'s omission is load-bearing elsewhere: `_participationFloor`'s natspec (`src/TokenCourt.sol:647-650`) leans on "`IStakedWood` does not expose the parameter anyway" as part of why `FLOOR_LOOKBACK` is hardcoded — adding `ageFloorBps()` to `IStakedWood` would quietly weaken that argument and touch every mock implementing the interface (`MockStakedWood` is `is IStakedWood`, so a new member would force the change on unrelated suites).

Alternative rejected: extend `IStakedWood` — larger blast radius (interface + all implementers + natspec that argues from the omission) for zero behavioral gain. Name the local interface distinctly (e.g. `IStakedWoodAgeFloor`, matching the script's) to avoid any future import collision.

### D2 — Direction and strictness: `newBps < ageFloorBps`, equality REJECTED

From the arithmetic, not the issue text: `finalize` passes iff `turnout >= floor` (`src/TokenCourt.sol:529` inverts `turnout < floor`; exact equality clears). Turnout sums aged weight — per account `ageFactor ∈ [ageFloorBps, 10_000]` bps of raw stake (`src/StakedWood.sol:589-599`) — while `floor = participationFloorBps/10_000 × base` with `base` raw (`src/TokenCourt.sol:739`). For an all-young electorate the achievable turnout ceiling is `ageFloorBps/10_000 × (raw un-accused stake)`, so the raw-turnout fraction needed to clear is `participationFloorBps / ageFloorBps`:

- `participationFloorBps < ageFloorBps`: needed fraction < 100% — clearable.
- `== ageFloorBps`: needed fraction = 100%, achievable only if every un-accused staked wei votes at exactly age zero — `turnout == floor` passes `finalize`'s `>=` in principle, but 100% turnout is not a liveness guarantee anyone can stand on. Equality is what PRE-FLIGHT 4 already rejects (`floorBps < ageFloorBps`, `script/DeployTokenCourt.s.sol:238-239`), and the guard must agree with the pre-flight or the two would certify different states.
- `> ageFloorBps`: needed fraction > 100% — arithmetically unclearable for the all-young case.

So the guard is: revert iff `newBps >= swood.ageFloorBps()`. (Caveat kept honest in natspec: with mature stake the ceiling rises toward par, so the hazard is the launch-window/young-electorate regime, not every case.)

### D3 — Vacuous branch mirrors `setVoteWindow`; fail-open when unwired, fail-closed on a broken read

`setVoteWindow`'s shape (`src/TokenCourt.sol:192-198`): cache the pointer, skip the check when zero, otherwise do plain high-level view calls whose reverts bubble.

- **Unwired (`stakedWood == address(0)`): fail-open (skip).** Right because there is nothing to protect yet — no electorate means no case can be referred (`refer` needs sWOOD reads), and the compose-bypass this opens is closed at the other end by D4's unconditional check in `setStakedWood`, exactly as `setChallengeGame` closes `setVoteWindow`'s vacuous branch.
- **Wired but the read reverts / target has no code: fail-closed (revert).** A high-level Solidity call to a codeless address reverts on the extcodesize check; a wrong-ABI target reverts on decode. Right here because a floor change against an electorate whose age floor cannot be read is exactly the blind write the guard exists to prevent, and the owner's remedy (fix the wiring first) is always available. This matches `setVoteWindow`, which also bricks against a game whose `autoSlashDelay()`/`disputeTimeout()` revert — the established posture.

### D4 — Guard `setStakedWood` too (unconditional), per the documented compose-bypass

`setChallengeGame`'s natspec (`src/TokenCourt.sol:139-149`) states the rule this codebase already committed to: when two setters compose into an invariant, guarding only one is a bypass ("raise while unwired, then wire"). The floor invariant composes identically: `setParticipationFloorBps(3_000)` while unwired (vacuous) followed by `setStakedWood(sWOOD with ageFloorBps 2_500)` reaches the broken state without any guard firing — unless `setStakedWood` checks `participationFloorBps < newStakedWood.ageFloorBps()` on every call. Like `setChallengeGame`, `setStakedWood` already requires non-zero, so there is no vacuous branch: every call validates.

Cost accepted: `setStakedWood` now refuses a target without `ageFloorBps()`. Any real electorate must expose the full `IStakedWood` read surface anyway (the court calls `getPastTotalVotes`/`getPastStake`/`getVotes` on it), so a target failing this read was never a functional electorate; and the game-side `ChallengeGame.setStakedWood` already grew an analogous read-back (`authorizedSlasher()`, review PR #56 M2) with the same "no bare addresses" consequence, absorbed in tests by using `MockStakedWood`.

Alternative rejected: guard only `setParticipationFloorBps` — recreates the exact pattern `src/TokenCourt.sol:139-149` names a bypass, and reviewers of that natspec would flag it immediately.

### D5 — The honest limitation (option 1+3's seam), stated plainly

The invariant has three levers; this change guards two:

1. Raising `participationFloorBps` — **guarded** (D2/D3).
2. Re-pointing `stakedWood` at a lower-age-floor electorate — **guarded** (D4).
3. **Lowering `ageFloorBps` on StakedWood — NOT guarded and not guardable from the court.** (Direction check: RAISING `ageFloorBps` only widens the margin and cannot break the invariant; lowering it is the breaking move.) `StakedWood.setAgeFloorBps` (`src/StakedWood.sol:744-748`) validates only `(0, 10_000]`, sWOOD holds no court pointer, and adding one is rejected (Non-Goals). The sWOOD owner lowering `ageFloorBps` to `<= participationFloorBps` silently re-creates the issue-#84 state.

Coverage for lever 3 is: (a) off-chain monitoring of `ParameterChangeFinalized(PARAM_AGE_FLOOR_BPS, ...)` against the court's live floor — option 3, an operational commitment, not code in this repo; (b) PRE-FLIGHT 4 at wire time (D6). The spec delta records this residual as its own scenario so it is a documented acceptance, not an omission. Note both floor-side reads are LIVE by design (`src/TokenCourt.sol:679-724`), so a broken invariant is also repaired live: restoring either parameter immediately restores clearability for any case finalizing afterward — the damage mode is liveness (forced `Inconclusive`s, each burning a slice of an honest challenger's bond via the escalating unwind), not a wedge.

### D6 — PRE-FLIGHT 4: keep, with a corrected comment

Not redundant after the setter guard, for three reasons:

1. The deploy default `participationFloorBps = 1_000` is set at declaration (`src/TokenCourt.sol:104`), never through the setter — the constructor path has no guard. `setStakedWood` (D4) covers the deploy sequence (`script/DeployTokenCourt.s.sol:74`), but only against sWOOD's value at that instant.
2. Lever 3 (D5): `setAgeFloorBps` can lower the age floor between `DeployTokenCourt` and `WireTokenCourt` — the pre-flight is the last check that sees the PAIR's live values before the court gains ruling authority, and after this change it is the ONLY check that can catch a sWOOD-side move.
3. It is a free script assert; removing it buys nothing.

Update its comment the way PRE-FLIGHT 3's was updated when the setters grew the window checks (`script/DeployTokenCourt.s.sol:122-137`): state that both court-side levers now enforce this on-chain, and that what the pre-flight still uniquely covers is the sWOOD-side lever and the first-wiring state. `test/deploy/DeployTokenCourtPreflight.t.sol`'s PRE-FLIGHT 4 test must correspondingly reach the violating state via `swood.setAgeFloorBps(...)` (legal on its own setter) instead of `court.setParticipationFloorBps(AGE_FLOOR_BPS)` (now reverts) — which conveniently turns the test into living documentation of D5's residual.

### D7 — Error and event surface

New `error FloorInvariantViolated()` in `ITokenCourt` beside `WindowInvariantViolated` (`src/interfaces/ITokenCourt.sol:179`), same naming grammar. No new event: both setters already emit (`ParticipationFloorBpsSet`, `StakedWoodSet`), and the window precedent added no event either. Reuse of `InvalidParameter` was rejected: the existing bounds scenario ("Bounded parameters") is pinned to `InvalidParameter` for `(0, 10_000]`, and a distinct selector tells an operator *which* contract's state to fix (the court's bound vs the cross-contract relation), exactly as `WindowInvariantViolated` vs `InvalidParameter` already distinguishes for `setVoteWindow`.

## Affected callers and tests (full sweep)

Callers of `setParticipationFloorBps` / `setStakedWood` (court-side) and floor-adjacent fixtures, from `grep -rn` over `test/` and `script/`:

| Site | Today | After the guard | Action |
|---|---|---|---|
| `test/TokenCourt.t.sol:162,164` (`test_setters_boundsAndValues`) | expects `InvalidParameter` for 0 / 10_001 | unchanged — bounds check still fires first | none |
| `test/TokenCourt.t.sol:263-272` (emit test: `setStakedWood(makeAddr("newSwood"))` then `setParticipationFloorBps(2_000)`) | passes with an EOA sWOOD | **breaks twice**: EOA re-point now reverts (D4 fail-closed), and the floor set would read the EOA | legitimate update: re-point to a fresh `MockStakedWood` (with `ageFloorBps` defaulted > 2_000); mirrors how `DeployTokenCourtPreflight.t.sol:159-166` already retired a bare-address sWOOD for the game's setter |
| `test/TokenCourt.t.sol:1170` (`test_finalize_floorStillInflatableByAMonthOldStake_knownResidual`, sets 100) | passes | passes once `MockStakedWood.ageFloorBps` defaults above 100 (default 2_500 chosen to match every real fixture) | none beyond the mock gaining the member |
| `test/TokenCourt.t.sol:135-146` (`setUp` wires `MockStakedWood`) | passes | passes — default floor 1_000 < mock default 2_500 | none |
| `test/deploy/DeployTokenCourtPreflight.t.sol:235-246` (PRE-FLIGHT 4 bite test, sets floor = `AGE_FLOOR_BPS` 2_500) | reaches the violating state via the court's setter | **breaks** — that call now reverts `FloorInvariantViolated`; this test was pinning the unguarded behaviour (its own comment: "allows any value in `(0, 10_000]`") | legitimate update: violate from the sWOOD side via `swood.setAgeFloorBps(1_000)` (D6); add a companion test that the old route now reverts |
| `test/SlashGasCeiling.t.sol:269`, `test/TokenCourtEndToEnd.t.sol:236` (`court.setStakedWood(real swood)`) | pass | pass — real `StakedWood` proxies with `ageFloorBps: 2500` fixtures (`SlashGasCeiling.t.sol:208`, `TokenCourtEndToEnd.t.sol:178`) vs default floor 1_000 | none |
| `script/DeployTokenCourt.s.sol:74` (`court.setStakedWood(stakedWood)`) | passes | passes iff the target sWOOD's `ageFloorBps > 1_000` — true for the shipped config (2_500); a mis-provisioned sWOOD now fails the DEPLOY step instead of the wire step (strictly earlier, strictly better) | none; regression test proves it |
| `test/StakedWood.t.sol:461-509` (`setAgeFloorBps` tests) | pass | unchanged — `StakedWood` is untouched | none |
| `test/ChallengeGame.t.sol` `setStakedWood` sites (455, 1929, 2053-2063, 3584, 3845-3854) | pass | unchanged — those are `ChallengeGame.setStakedWood`, a different contract's setter | none |

No other repo caller of either court setter exists (`grep -rn "setParticipationFloorBps\|setStakedWood" src/ test/ script/`).

## Risks / Trade-offs

- [Rescue-path friction: re-pointing to an emergency sWOOD whose `ageFloorBps <= participationFloorBps` now reverts] → not a wedge: lower `setParticipationFloorBps` first (checked against the OLD sWOOD, which by the invariant already admits any lower value), then re-point. Two transactions instead of one, in the owner's control.
- [Fail-closed read bricks floor changes if the wired sWOOD is broken/selfdestructed] → same posture `setVoteWindow` already has toward a broken game; the fix is `setStakedWood` to a working electorate, which every other court function needs anyway.
- [Sibling #96 branch merge conflict on `src/TokenCourt.sol`] → regions are disjoint (#96: 738, 569-586, 360-365; this: 14-16, 176-208 + `ITokenCourt`); whichever lands second rebases trivially.
- [PR #88 touches `test/TokenCourtEndToEnd.t.sol`] → this change does not modify that file; no conflict.
- [Monitoring (option 3) is an operational commitment outside this repo] → recorded in the spec delta's residual scenario and in the wire script's MANUAL NEXT block so it cannot be silently forgotten.

## Migration Plan

Contracts are non-upgradeable but the change is additive-revert-only: existing deployments keep their behaviour until the next TokenCourt deployment. Deploy scripts unchanged in sequence; PRE-FLIGHT 4 keeps guarding the wire step. No storage layout impact (no new state variables). Rollback = redeploy without the guard (none expected).
