# Design — Plan F Epoch NAV Checkpointing (§3.4a)

> Migrated from docs/superpowers/plans/2026-07-25-guardian-econ-security-F-epoch-nav.md (superpowers workflow) on 2026-08-01. This plan had no dedicated design doc; the design content below is the plan's own architecture notes. The master guardian-economic-security design (§3.4a and the surrounding sections) lives in `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/design.md` and is not duplicated here.

## Context

§3.4a of the guardian-economic-security design requires that drawdown liability attach to the guardians covering the epoch in which a breach *surfaces*, so no guardian is committed longer than one epoch + challenge window however long the strategy runs. A new non-upgradeable `CoverageEpochs` contract owns the per-strategy epoch schedule: it snapshots a baseline NAV when a proposal executes, accepts renewal commitments for epoch N+1 strictly before epoch N's boundary, checkpoints NAV at each boundary via the same `PriceRouter.valueStrategy` the vault's Lane A already trusts, and evaluates cumulative drawdown against the proposal's declared envelope. `ChallengeGame` learns to ask it who was covering a given epoch; a strategy nobody renews is flagged for wind-down, making `settleProposal` permissionlessly callable ahead of `strategyDuration`.

## Goals / Non-Goals

- Goals: enforceable predicate 5 across epochs; claims-made liability attribution; orderly wind-down instead of a coverage gap; renewal sequencing that closes the last-moment exit run.
- Non-Goals: premium pricing/repricing at renewal (§3.10, Plan G); mid-epoch exit / loss-portfolio transfer (deferred to v2 per §3.4a); any fund movement by `CoverageEpochs` (it holds no tokens).

## Decisions

### Two facts that shape the design

**1. `totalAssets()` is the wrong NAV source, and using it would fabricate catastrophic drawdowns.**

`SyndicateVault.totalAssets()` is `idle float + liveNav`, where `liveNav` comes from `_laneState()`:

```solidity
try IPriceRouter(pr).valueStrategy(active) returns (uint256 v, bool ok) {
    if (ok) { liveNav = v; laneA = true; }
} catch {} // fail-closed: laneA stays false
```

When the router cannot price the strategy — outage, stale feed, unsupported venue — `laneA` is false and **`liveNav` is silently 0**. That is correct for the vault (it falls back to float-only NAV and routes LP flow through the async queue), but catastrophic for a checkpoint: a checkpoint reading `totalAssets()` during a router outage would record a ~100% loss, breach the drawdown envelope, and expose honest guardians to a 100% slash over an oracle hiccup. So `CoverageEpochs` **must call `valueStrategy` directly and refuse to checkpoint when `instantOK` is false.** Never `totalAssets()`.

**2. Renewal-before-checkpoint closes the *jump*, not the *drift*.**

§3.4a says renewal commits before the boundary NAV "is revealed", so the exit-run failure mode is "closed by sequencing, not trust." That is true only in a narrow sense: `valueStrategy` is a **public view**, so a guardian can read it continuously and compute what the boundary checkpoint will almost certainly say. Sequencing therefore does *not* create real information asymmetry about a gradually deteriorating strategy — it only prevents renewing (or refusing to renew) on a **discontinuous** move landing between `renewalDeadline` and the boundary: a hack, a depeg, a liquidation cascade.

| Failure | Defence |
| --- | --- |
| Bad news lands in the last hours before a boundary | **Sequencing** — renewal already closed |
| Strategy deteriorates visibly across the epoch | **Repricing** — §3.10 prices each epoch, so a riskier strategy costs more to renew; if nobody will pay, it winds down (§3.4a: "adverse-selection repricing at renewal is a feature") |

`renewalLeadTime` must be long enough that the jump window is meaningful, short enough that guardians are not committing against badly stale information. Pinned at 3 days against a 28-day epoch, bounded `(0, epochLength / 2]`.

### Pinned design decisions

- **D1 — NAV source is `IPriceRouter.valueStrategy(strategy)`, fail-closed on `instantOK == false`.** Never `totalAssets()`. See fact 1.
- **D2 — Baseline is the NAV at `openCover`, not at `executedAt`.** `openCover` is permissionless and may run some blocks after execution. Recording the NAV actually observed is honest; back-dating a number nobody read is not. `openCover` is callable only while the proposal is `Executed`, and the drawdown denominator is this observed baseline.
- **D3 — Epoch schedule is copied from `ExposureLedger`, not re-derived.** Read `epochLength()` and `epochGenesis()` once at `openCover` and store them on the cover. `ExposureLedger.epochLength` is immutable, but reading once means a future ledger re-point cannot retroactively re-slice a live strategy's epochs.
- **D4 — A missed checkpoint is not an acquittal.** If nobody calls `checkpoint()` at a boundary, the epoch stays uncheckpointed and the *next* checkpoint evaluates cumulative loss against the same baseline. Drawdown is measured cumulatively from baseline, never epoch-over-epoch, so skipped boundaries cannot launder a loss.
- **D5 — Passive mandates (`maxDrawdownBps == 10_000`) checkpoint but never breach.** §3.4a(c): their epochs still record NAV to feed §6 monitoring, but they carry no predicate-5 liability. The skip is an explicit branch, not an accident of the `>` comparison.
- **D6 — Unpriceable at the boundary → wind-down, after a grace window.** A checkpoint that cannot be taken because `instantOK` is false may be retried anywhere inside `checkpointGrace`. If the grace expires with no successful checkpoint, the cover is flagged `windDown`. A strategy whose value cannot be established cannot be underwritten, and the alternative — carry on uncovered — is exactly the gap §3.4a exists to prevent.
- **D7 — Wind-down seizes nothing.** It sets a flag making `settleProposal` permissionlessly callable ahead of `strategyDuration`. The existing settlement path does the unwinding. `CoverageEpochs` never moves funds; it holds no tokens at all.

### Attribution and challenge integration

- `coverersOf(governor, proposalId, epoch)`: epoch 0 = the original approvers from `exposureLedger.approversOf`, filtered to non-zero `committedUsd` **exactly as `ChallengeGame._accused` does** (one definition of "covering", not two); epoch N > 0 = the guardians who committed renewal for epoch N.
- `ChallengeGame.file` gains an `epoch` argument. Only `Predicate.Drawdown` (predicate 5) with `epoch > 0` is epoch-scoped — it is the only predicate that can surface on a later watch than the approval it came from. Epoch 0 and all other predicates keep the ledger path so every pre-Plan-F challenge behaves identically. A cited epoch with no coverers reverts `NoCoverage` rather than producing an empty accused set (an empty set would be a silent no-op challenge).
- `SyndicateGovernor` is beacon-upgradeable with golden-pinned layout: `_coverageEpochs` is an **append-only** field carved from `__gap`, exactly as Plan B added `_exposureLedger` and `_bondEscrow`.

### Deploy pre-flights (load-bearing)

- `governor.coverageEpochs() == address(0)` — do not steal the role from a live instance.
- `priceRouter != address(0)` and `valueStrategy` answers `ok == true` for a known strategy — a router that cannot price makes every checkpoint revert and every cover wind down.
- `exposureLedger` matches the one `ChallengeGame` uses — two ledgers means two different accused sets.
- `renewalLeadTime > 0 && renewalLeadTime <= epochLength / 2` — a zero lead time silently deletes the sequencing property.
- `checkpointGrace < epochLength` — a grace longer than an epoch means the wind-down flag can never fire.

## Risks / Trade-offs

Known gaps named at PR time:

1. **Sequencing closes the jump, not the drift** — `valueStrategy` is a public view, so a guardian can watch a slow decline and decline to renew. Repricing (§3.10, Plan G) is the intended answer and was **not built yet**, so until Plan G ships a deteriorating strategy is renewed at a flat price or not at all.
2. **`openCover` is permissionless and unforced.** Nothing compels anyone to open a cover; an unopened strategy has no checkpoints and no epoch liability. Candidate later fix: have execution call it.
3. **Checkpoints are permissionless and unpaid** — the same liveness problem as the court panel. A missed boundary is not an acquittal (D4), but it does delay breach surfacing.
4. **Baseline is the NAV at `openCover`, not at execution** (D2) — a cover opened late bakes in any drift since execution.
5. **Wind-down does not force liquidation** — it only unlocks permissionless settle. Someone must still call it.
