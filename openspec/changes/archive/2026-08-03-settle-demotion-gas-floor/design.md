## Context

See proposal.md — Why. All references verified on `origin/main` at `b8b6d0d` (branch `fix/issue-51-demotion-gas-floor`).

Anatomy of `_settle`'s conviction branch, in execution order:

1. `src/ChallengeGame.sol:1064-1066` — the gas floor: `if (gasleft() < approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE) revert InsufficientSlashGas();`. Constants at `:176` (`SLASH_GAS_PER_APPROVER = 180_000`) and `:177` (`SLASH_GAS_BASE = 2_000_000`). The check is deliberately placed "as late as possible" (`:1061-1063`) and sits inside the `!_verdictAlreadyCollected` branch only.
2. `:1094` — `swood.slashVerdict(...)`, the call the floor budgets for.
3. `:1124-1131` — `forfeitBond` on the proposer-bond escrow, its own bare `try/catch` (`ProposerBondForfeitureFailed` on miss).
4. `:1157-1162` — the demotion: `try tierRegistry.demoteByChallenge(c.adapterTarget, c.adapterSelector) {} catch { emit AdapterDemotionFailed(...); }` — a BARE catch, after the slash, guarded only by `c.adapterTarget != address(0)`.
5. `:1174-1189` — the tail: burn transfer to `0x…dEaD` + `ChallengerBondBurned` (or the escalated single transfer), the challenger refund transfer, `_bookRefund`'s SSTORE, and `ChallengeSettled`.

`TierRegistry.demoteByChallenge` (`src/TierRegistry.sol:256-259`) role-checks `authorizedDemoter` then runs `_demote` (`:270-280`): `delete _configs[k]` (a 2-slot struct), conditionally start the bond-release timelock (one SSTORE 0→nonzero plus `SubmitterBondReleaseStarted`), and emit `TierDemoted`. Estimated worst-case frame cost ≈ 45k gas; issue #77's spec (branch `fix/issue-77-demote-clears-allowlist`, commit `4d27c11`) adds `delete _adapterAllowed[target]` inside `_demote`, ≈ +5k → ≈ 50k.

F11 (PR #25 review) is the finding that made the demotion best-effort: `test/ChallengeGame.t.sol:1119-1134` records that `setAuthorizedDemoter(0)` — documented as an unwire switch — used while a challenge was live left `_settle` reverting inside the demotion forever: bonds stranded, coverage frozen, accused barred from `claimUnstakeGuardian`, "one governance transaction, permanent". F11's failure mode is a **revoked role**: registry-side, not chosen by the settle caller. Issue #51's whole argument is that gas starvation is different in kind — caller-selected, repeatable, free — and F11 never contemplated it.

The precedent: the same shape in `TokenCourt.finalize` was Critical and was fixed by selector-filtering the catch — `src/TokenCourt.sol:545-566` swallows only `IChallengeGame.WrongStatus.selector` and re-raises everything else byte-for-byte (assembly revert at `:561-563`), with the natspec at `:474-496` naming `InsufficientSlashGas` as the caller-forcible revert a bare catch would have converted into a permanently burned verdict.

## Is the silent miss reachable? (Verification of the 63/64 mechanism)

The issue's mechanism — floor passes, slash eats the budget, demotion child starves, settle completes with only `AdapterDemotionFailed` — was checked quantitatively rather than assumed. It is **refuted** on current main, twice over:

**(1) The tail contradiction.** Gas starvation of the demotion child means the child runs out of gas, and an OOG child consumes its ENTIRE forwarded stipend (63/64 of the parent's gas `G` at the call). The parent resumes in the catch with exactly `G/64`. For the settle to complete silently, `G/64` must then pay for the `AdapterDemotionFailed` emit (~2k: LOG3, three indexed topics) plus the tail at `:1174-1189` — at minimum one warm WOOD `safeTransfer` (~15-25k), usually two, plus events (call it `T ≥ 20k`, and `≥ 2k` even on the most contrived reading). Feasibility requires simultaneously:

- `63G/64 < D` (child starves), with `D` ≈ 50k the demotion's worst-case cost → `G < ~51k`;
- `G/64 ≥ T` (tail completes) → `G ≥ 64·T ≥ 1.28M` (or `≥ 128k` even at `T = 2k`).

These contradict by 1-2 orders of magnitude. The general condition for a silent best-effort miss via gas dialling is `T < D/63`; here `D/63 ≈ 800` gas and `T ≥ 20,000`. Any budget tight enough to starve the child OOGs the whole transaction instead — which reverts everything, harmlessly and retryably. Compare `TokenCourt.finalize`, where the starved child (`rule`, i.e. the whole multi-million-gas settle) gave `D/63` in the tens of thousands against a post-catch tail of ~2k: there the attack WAS feasible, which is exactly why that instance was Critical and this one is low.

**(2) The slack floor.** Independently, the floor's constants are deliberately oversized against measurement (`test/SlashGasCeiling.t.sol:618-629`: ~130k marginal per approver vs the 180k constant; ~368k fixed base vs the 2M constant; full-cap conviction measured at 11.18M vs a 20M floor). At any cohort size the caller cannot dial the gas remaining at the demotion call below roughly the constants' slack minus the escrow call — hundreds of times the demotion's cost.

Consequence for this change's framing: the fix is **hardening, not a live-bug fix**. Both protections are incidental — nothing states them, nothing tests them, and each is one innocent refactor away from disappearing (retuning the constants toward the measured actuals erodes (2); slimming or reordering the tail — e.g. a future pull-payment refactor of the challenger refund, exactly the shape issue #95 discusses for `_refundAll` — erodes (1)). The spec delta records the invariant explicitly; the floor term enforces it structurally. The natspec updates MUST also correct the places that currently describe the silent miss as live.

## Goals / Non-Goals

**Goals:**

- Make "a settle that passes the floor can afford its demotion" an explicit, tested invariant rather than an emergent one.
- Preserve F11's guarantee bit-for-bit: a revoked demoter role still settles, still emits `AdapterDemotionFailed`, still leaves the owner's `demote` as the remedy.
- Keep the full-cap floor comfortably inside Robinhood's 32M per-transaction budget.

**Non-Goals:**

- No selector filter on the demotion catch (Decision 2).
- No change to the `forfeitBond` catch at `:1124-1131` (Decision 4).
- No change to `TierRegistry`, no interface changes, no storage changes, no new events.
- Not touching `_refundAll` (`:1345+`, issue #95's region) or the adapter allowlist (issue #77's region, TierRegistry side).

## Decisions

### Decision 1: Extend the floor (option a), sized `DEMOTION_GAS = 200_000`, applied only when an adapter is named

The check at `:1064` becomes, in effect:

- no adapter named → `gasleft() >= approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE` (unchanged);
- adapter named → the same `+ DEMOTION_GAS`.

Why conditional: a zero-adapter filing (predicates that indict a price or an envelope — `test_resolve_withoutAnAdapterDemotesNothing`, `test/ChallengeGame.t.sol:1200`) demotes nothing; charging it a demotion stipend would make the floor lie in the other direction. The branch costs one `!= address(0)` on a field already loaded for the demotion itself.

Sizing: worst-case `demoteByChallenge` frame ≈ 45k (cold account 2.6k + role check + 2-slot config delete + bond-slot read + one 0→nonzero SSTORE ≈ 22.1k + two events + overhead), ≈ 50k with issue #77's extra `delete _adapterAllowed[target]`. The child receives 63/64 of what remains; `DEMOTION_GAS = 200_000` guarantees ≥ ~197k forwarded even if everything before the demotion consumed exactly its budgeted share — ~4x the estimated worst case including #77. The 4x follows the file's house convention of fat, measured-against margins (per-approver constant is 1.4x of a measured number; the base is >5x). The implementation MUST add a measurement/bracketing test in `SlashGasCeiling.t.sol` style so the 4x is anchored to a real number, not this estimate: assert real-`TierRegistry` demotion gas `< DEMOTION_GAS * 63/64` with room stated for #77.

32M fit (the hard constraint): `MAX_APPROVERS_PER_PROPOSAL = 100` (`src/GuardianRegistry.sol:34`). Worst-case floor = `100 * 180_000 + 2_000_000 + 200_000 = 20,200,000`. The CI gate's ceiling (`test/SlashGasCeiling.t.sol:456-472`) is `32,000,000 * (63/64)^3 = 30,523,315`. Headroom 30,523,315 / 20,200,000 = **1.511x** (was 1.526x — the term costs 1% of the headroom). Fits comfortably; option (a) survives the constraint.

Alternative considered — unconditional `+ DEMOTION_GAS`: simpler by one branch, and 200k is noise against a 2M base. Rejected because the floor's natspec derives every term from work the settle will actually do; an unconditional term would be the first one that sometimes budgets for nothing, and the no-adapter scenario in the spec would become false.

### Decision 2: Keep the catch bare — no selector filter (option b rejected)

The TokenCourt precedent does not transfer, because the two catches protect against opposite harms:

- In `TokenCourt.finalize` (`src/TokenCourt.sol:474-496`), swallowing a transient revert DESTROYED the verdict permanently (state already `Resolved`, `refer` reverts `AlreadyReferred` — no retry path). Bubbling was safe: it left the case in `Voting` for anyone to retry. So the filter (swallow only the genuinely-terminal `WrongStatus`, bubble `InsufficientSlashGas`/`NotCourt`/everything else) was strictly right there.
- In `_settle`, it is exactly inverted: swallowing loses only the demotion (recoverable — the owner's `demote`, per F11), while bubbling a registry-side revert re-creates F11's permanent wedge: the challenge can NEVER settle, bonds stranded, coverage frozen forever, accused barred from unstaking. Here bubbling is the catastrophic direction.

With the floor extension in place, the failure axes separate cleanly: gas (caller-chosen) is refused before the slash; everything that still reaches the catch is registry-side (revoked role being the only reachable one on the real `TierRegistry` — `_demote` at `src/TierRegistry.sol:270-280` has no revert paths of its own). A filter that swallowed only `NotAuthorizedDemoter` and bubbled the rest would add no security (there is no "rest" to bubble on the real registry, and an OOG child produces empty revert data a filter cannot classify) while betting the protocol's liveness on every future registry revert being one the filter anticipated. Doing BOTH (a) and (b) is over-engineering with negative expected value: (b)'s only effect after (a) is re-opening F11.

### Decision 3: Natspec corrections ride along

Three places currently describe the starvation as live and must be updated to the verified account (floor slack + tail contradiction, now superseded by the explicit term): the floor-placement comment at `:1061-1063`, the demotion comment at `:1134-1156`, and the constants' natspec block above `:176-177` (which walks the floor arithmetic and must gain the `DEMOTION_GAS` term and the new 20.2M total). The spec's "Slash gas floor" requirement text is corrected by the delta in this change.

### Decision 4: `forfeitBond`'s catch (`:1124-1131`) is out of scope, with the reasoning recorded

The proposer-bond forfeiture at `:1124` shares the shape (bare catch between the floor and the demotion). The same tail contradiction applies — a starved escrow child OOGs 63/64 of the frame and the remaining 1/64 cannot fund the demotion attempt plus the tail, so there is no silent-miss budget for it either — and `SLASH_GAS_BASE`'s measured slack (~1.6M over the base's actual work) covers its real cost (~60-100k) many times over. Extending the floor for it too would be defensible symmetry, but its failure economics differ (a missed forfeiture is money the PROPOSER keeps, and `ProposerBondForfeitureFailed` has legitimate non-gas causes: bond already reclaimed, zero-bond proposals — `:1108-1115`), and PR #106 just landed that path; widening this change into it would grow the blast radius for no demonstrated gap. If a future measurement shows the base's slack eroding, add a term for it then — the spec text this change writes ("the caller-selectable failure axis — the gas budget — is refused up front") states the invariant that would force it.

## Risks / Trade-offs

- [DEMOTION_GAS is estimated, not measured] → the implementation adds a `SlashGasCeiling`-style test that measures a real-`TierRegistry` demotion and asserts it fits inside `DEMOTION_GAS * 63/64` with explicit #77 headroom; the constant only ever errs upward (a too-big term costs callers 200k of budget, never correctness).
- [Issue #77 lands after this and grows `_demote`] → +~5k against ~150k of margin; the measurement test's headroom assertion is the tripwire if #77 grows beyond its spec.
- [Honest callers of adapter-naming settles must now supply 200k more gas] → they already supply 2.36M+ (two-approver floor); wallets estimate gas, and the failure mode is a clean `InsufficientSlashGas` retry, tested.
- [Raising the floor cuts the 32M headroom] → by 1%: 20.2M vs a 30.52M ceiling, gate-tested in CI (`test_slashGasFloorFitsRobinhoodMaxTxGas`).
- [The refutation in §"Is the silent miss reachable?" could be wrong somewhere] → the fix does not depend on it; it is strictly belt-and-suspenders. The refutation only changes the framing (hardening vs live bug) and the honest shape of the reproduction test (the "silent miss" cannot be reproduced against the real contracts, so the tests prove the floor's guarantee from both sides instead — see tasks.md).

## Migration Plan

Constants-and-natspec change to a not-yet-deployed contract; no storage, interface, or deploy-wiring impact. Redeploy of `ChallengeGame` picks it up; no migration.

## Open Questions

None.
