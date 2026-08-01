# Guardian Economic Security — Plan E: Two-Layer Court (v1c)

> Migrated from docs/superpowers/plans/2026-07-25-guardian-econ-security-E-court.md (superpowers workflow) on 2026-08-01.

> **SUPERSEDED:** the two-layer court this change built (`Court` — bonded panel + token-vote appeal + bad-faith track) was replaced by the single-layer token court in the 2026-07-28 token-court change — see `openspec/changes/archive/2026-07-28-token-court/`. The current adjudication capability is specced in `openspec/specs/token-court/spec.md`. The `ChallengeGame.rule` court-only entrypoint introduced here survived and is what the successor court drives.

## Why

Plan D knowingly opened a hole: a disputed challenge times out in favour of the accused, so a genuinely guilty approver could dispute and run out the clock. Spec §3.5's adjudication layer closes it — and §3.5 is explicit that neither half is safe alone: a token vote alone is incompetent for forensic questions (single-digit turnout, narrative over trace) and capturable at ~$15M mcap; a standalone panel is bribable (5 humans, bribe 3) with no check above it. The layers cover each other's failure mode, so the plan shipped panel + appeal + bad-faith track together, never wired half-built.

## What Changes

- `ChallengeGame` gains a court-only ruling entrypoint: owner-set `court` address, `rule(challengeId, guilty)` callable only by the court and only on a `Disputed` challenge; a guilty ruling routes into the same `_settle` an undisputed challenge takes (slash at `maxSlashBps`, no severity ramp), not-guilty into the same `_fail`; a ruling beats the timeout. With `court == address(0)`, Plan D's timeout behaviour is unchanged — the court is additive, not breaking.
- New contract `Court` (Ownable2Step, not upgradeable): owner-set panel roster with per-member slashable WOOD bonds; `refer` opens a case for a disputed challenge and computes the voting snapshot ONCE (`executedAt - 1`, stored); layer 1 — bonded panelists rule within `panelWindow` (silence/tie → `NotGuilty`, fail-safe); layer 2 — bonded token-vote appeal weighted by `StakedWood.getPastVotes` at the stored snapshot, with a participation floor (`participationFloorBps` of `getPastTotalVotes`) below which the panel ruling stands; a SEPARATE bad-faith token vote (never the merits appeal) slashes a panelist's bond, with slashed bonds sent to the protocol backstop.
- End-to-end suite: guilty-unappealed (Plan D's hole closed — the guilty approver cannot escape by disputing), acquitted-on-appeal (panelist bond untouched), below-floor appeal (panel ruling stands — the anti-capture arc).
- Deploy script `script/DeployPlanE.s.sol` with load-bearing pre-flights (court not already wired, panel seated AND bonded, `participationFloorBps != 0`, `badFaithWindow != 0`, Plan D wiring intact) — a half-wired court is worse than none.

## Capabilities

- challenge-game
- token-court

## Impact

- Created: `src/Court.sol` (later replaced by the token court), `src/interfaces/ICourt.sol`, `test/Court.t.sol`, `test/CourtEndToEnd.t.sol`, `script/DeployPlanE.s.sol`
- Modified: `src/ChallengeGame.sol`, `src/interfaces/IChallengeGame.sol` (court seam — still live), `test/ChallengeGame.t.sol`, spec status header (v1c complete)
- Landed as a PR against `feat/guardian-econ-security-d`.
