# Token Court — single-layer WOOD-vote adjudication

> Migrated from docs/superpowers/plans/2026-07-28-token-court.md + docs/superpowers/specs/2026-07-28-token-court-design.md (superpowers workflow) on 2026-08-01.

## Why

The two-layer Court of PR #26 (5-person bonded panel + token-vote appeal + bad-faith track) was replaced by a single WOOD-token vote per disputed challenge. The token layer was already sovereign (appeal and bad-faith track were both token votes — the panel was a fast path, not an authority); a fixed panel of 5 is a liveness single point of failure, an election ops burden, and a centralization optic; and industry practice (UMA, Nexus Mutual, Symbiotic) runs token-side adjudication. Deleting the panel removed ~40% of Court.sol without changing who ultimately decides. See design.md §1 for the full rationale, the locked-decisions table, and the corrected capture-economics framing (the court is a backstop against unsophisticated adversaries, not a determined attacker — per `openspec/changes/archive/2026-07-29-court-incentives/design.md` §6).

## What Changes

- **Deleted:** `src/Court.sol`, `src/interfaces/ICourt.sol`, their test suites, and `script/DeployPlanE.s.sol` — panel roster, panel bonds, appeal bonds, bad-faith track, panel rewards, court custody bookkeeping.
- **New `TokenCourt.sol`** (plain `Ownable2Step`, non-upgradeable, holds NO WOOD ever): `refer(challengeId)` (permissionless; clock check `remaining >= voteWindow + FINALIZE_BUFFER`; snapshot pinned at `executedAt - 1`; accused set recorded from the game's ledger with released commitments excluded), `vote(caseId, guilty)` (one vote per address, aged `getPastVotes` weight, accused barred, zero weight reverts), `finalize(caseId)` (participation floor over `total - accusedWeight` same-basis; below floor → `Inconclusive`; tie → `NotGuilty`; state written before the external `rule` call; terminal-race try/catch emitting `ChallengeAlreadyTerminal`).
- **`ChallengeGame` gains** a three-valued `Verdict` (`Guilty`/`NotGuilty`/`Inconclusive`), `Status.Inconclusive` (append-only), `_refundAll` (challenger bond returned whole, pool booked into #50's pull machinery, freeze released, no conviction mark — the proposal is re-challengeable), best-effort auto-referral on dispute-pool completion (`try court.refer` with `AutoReferFailed` on catch), and `setFilingsPaused` gating `file` only — the entire human backstop; dispute/resolve/rule/claims always run.
- Defaults: `voteWindow = 5 days`, `FINALIZE_BUFFER = 1 days`, `participationFloorBps = 1_000`, `MAX_VOTE_WINDOW = 14 days`; per-case pinning of window and game.
- End-to-end arcs (guilty, not-guilty, inconclusive, both orderings of the timeout race), `DeployTokenCourt`/`WireTokenCourt` scripts with launch-math pre-flights (`voteWindow + FINALIZE_BUFFER <= disputeTimeout - autoSlashDelay`; `participationFloorBps < ageFloorBps`).
- PR #26 closed unmerged with a pointer to the design; net roughly −3,500 lines against #26.

## Capabilities

- token-court
- challenge-game

## Impact

- Deleted: `src/Court.sol`, `src/interfaces/ICourt.sol`, `test/Court.t.sol`, `test/CourtEndToEnd.t.sol`, `test/deploy/DeployPlanEPreflight.t.sol`, `script/DeployPlanE.s.sol`
- New: `src/TokenCourt.sol`, `src/interfaces/ITokenCourt.sol`, `test/TokenCourt.t.sol`, `test/TokenCourtEndToEnd.t.sol`, `script/DeployTokenCourt.s.sol`, `test/deploy/DeployTokenCourtPreflight.t.sol`
- Modified: `src/ChallengeGame.sol`, `src/interfaces/IChallengeGame.sol` (Verdict enum, `_refundAll`, auto-refer, filings pause)
- `StakedWood`, `ExposureLedger`, `TierRegistry`, escrows untouched; nothing upgradeable changed (layout goldens no-op)
