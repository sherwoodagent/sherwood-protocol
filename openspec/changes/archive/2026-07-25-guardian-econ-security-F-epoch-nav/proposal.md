# Plan F — Epoch NAV Checkpointing

> Migrated from docs/superpowers/plans/2026-07-25-guardian-econ-security-F-epoch-nav.md (superpowers workflow) on 2026-08-01.

## Why

Predicate 5 (drawdown breach) was unenforceable on strategies that outlive one coverage epoch: without per-epoch NAV records there is no way to attribute a loss to the guardians actually covering the strategy when the breach surfaces, and expiring coverage left a gap instead of an orderly exit. Design spec §3.4a requires checkpointing NAV at every epoch boundary, attaching liability to the guardians covering the epoch in which the breach *surfaces* (claims-made attribution), and converting non-renewed coverage into a forced wind-down.

## What Changes

- New non-upgradeable `CoverageEpochs` contract owning the per-strategy epoch schedule:
  - `openCover` (permissionless, proposal must be `Executed`) snapshots a baseline NAV from `IPriceRouter.valueStrategy` — never `totalAssets()` — and copies the epoch schedule from `ExposureLedger`.
  - `checkpoint` (permissionless, once per epoch at/after the boundary) records NAV and evaluates cumulative drawdown from baseline against the proposal's declared `maxDrawdownBps`; a breach sets `breached` + `breachEpoch` and emits `DrawdownBreached`. Passive mandates (`maxDrawdownBps == 10_000`) checkpoint but never breach.
  - `commitRenewal` — guardians commit to cover epoch N+1 strictly before `boundary(epoch) - renewalLeadTime` (default 3 days), booking real exposure via `exposureLedger.recordApproval`; sequencing closes the discontinuous exit run.
  - `coverersOf` — claims-made attribution: epoch 0 = original ledger approvers (filtered to non-zero `committedUsd`, mirroring `ChallengeGame._accused`); epoch N > 0 = the renewers.
  - `flagWindDown` — permissionless; fires when a boundary passes with no coverers for the beginning epoch, or when `checkpointGrace` expires with no successful checkpoint (unpriceable strategy).
- `ChallengeGame.file` gains an `epoch` argument; predicate-5 challenges with `epoch > 0` accuse `CoverageEpochs.coverersOf` instead of the ledger approvers; a cited epoch with no coverers reverts `NoCoverage`.
- `SyndicateGovernor.settleProposal` honours the wind-down flag: settle becomes permissionless immediately, bypassing the `strategyDuration` wait. `_coverageEpochs` added append-only from `__gap` (layout goldens updated).
- End-to-end suites (`CoverageEpochs.t.sol`, `CoverageEpochsEndToEnd.t.sol`) and `DeployPlanF.s.sol` with load-bearing pre-flights.

## Capabilities

- epoch-nav
- challenge-game
- syndicate-governor
- guardian-coverage

## Impact

- New: `src/CoverageEpochs.sol`, `src/interfaces/ICoverageEpochs.sol`, `test/CoverageEpochs.t.sol`, `test/CoverageEpochsEndToEnd.t.sol`, `script/DeployPlanF.s.sol`
- Modified: `src/ChallengeGame.sol`, `src/interfaces/IChallengeGame.sol`, `src/SyndicateGovernor.sol`, `src/interfaces/ISyndicateGovernor.sol` (storage-layout golden updated for the appended field)
