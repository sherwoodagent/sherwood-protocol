## Context

See proposal.md — Why. The constraints that shape the approach:

- The ledger keeps coverage in two families today: the **booking** (`_recorded[key][g].usd`, epoch `_buckets`, `_liveBookedUsd`) that the capacity check reads, and the **pledge** (`_reservedUsd`, `_committedUsd`, `_livePledgedUsd`) that the slasher reads. They are allowed to diverge — `_rebook` "never rewrites the pledge, only the booking" — and every SHE-212/SHE-225 symptom is a consequence of that permitted divergence.
- `slashBpsFor` was deliberately moved onto the pledge (pashov #13) because the booking is "a number anyone may move while a challenge is live". Any redesign must keep attacker-movable and oracle-dependent numbers off the punishment path.
- `StakedWood` already clamps every slash into `[minSlashBps, maxSlashBps]` of stake on both the review and verdict paths.
- `kNumerator` defaults to 1 and is owner-settable.
- The chain limit is 98,304 bytes. `ExposureLedger` is a plain constructor-deployed contract — not a proxy, no storage gap, no layout golden — so its storage may be restructured freely; the 16-bucket scan bound is what constrains it. (`SyndicateGovernor` IS layout-pinned and must diff zero.)
- Fresh deployment: no live proposal has to survive the upgrade.

## Goals / Non-Goals

**Goals:**
- One number per (proposal, guardian): the lock. Booking, pledge and slash base are the same storage, so the divergence class cannot be expressed.
- No price read on the approval path. Capacity and locks are WOOD; USD appears only at the execute-time quorum.
- The deterrence floor is a single existing parameter (`minSlashBps`), not a new one.
- Contagion between a guardian's proposals is exactly `kNumerator − 1` worth of leverage and nothing else.

**Non-Goals:**
- Changing the burn model (no compensation to depositors — proceeds still burn).
- Changing the epoch-bucket accounting, the coverage horizon, the scan bound, freeze/pin, or `retireApproval` beyond their unit of account.
- Migrating on-chain proposals. There are none to migrate.
- Revisiting `quorumTierThreshold`, `coveredTvlCapUsd`, or the proposer-bond ledger pin.

## Decisions

### D1 — Declare and lock in WOOD, not USD

The guardian passes a WOOD amount; the ledger locks exactly that. No conversion at approval.

*Why:* Coverage sizing is a USD question answered at execute (`requireApproveQuorum` already re-derives it live). The punishment is a WOOD question. Denominating the lock in WOOD removes the `woodPriceX8()` read from `recordApproval` entirely — and with it the "unpriceable WOOD books nothing, let the quorum decide" degraded path — while keeping the only necessary conversion where it already lives.

*Alternative rejected:* declare USD, convert to WOOD at approval price. Same lock semantics, one extra oracle read on a path that today has to tolerate oracle outage. Strictly worse.

### D2 — No cohort cap (SHE-227 Variant C)

The sum of locks across a cohort may exceed the requirement. Nothing is pro-rated, nothing is collapsed.

*Why:* A cap makes every guardian's booking a function of every other guardian's booking. That mutual dependence is the entire source of the rebalancing machinery (`settleCoverage`, `_rebook`, the residue rule, the trigger problem). Removing the cap removes the machinery rather than relocating it to approve time. Over-subscription is a well-covered proposal; under-subscription already scales `effectiveMaxCapital` through `_deriveAndStoreEffectiveCapital`.

*Alternative rejected:* cap at approve time and write later approvers down. That is `_rebook` moved earlier; first-approver-takes-the-line is already rejected in-source.

### D3 — Slash = locked WOOD, under the existing stake envelope

On conviction the burn for (key, guardian) is `min(lock, basis)`, where the basis is what `StakedWood._slashOne` already burns against — `min(stake at the anchor, live stake)`, anchored at `executedAt` for a verdict and `openedAt` for a review-path block — expressed to `StakedWood` as bps of that basis and then clamped to `[minSlashBps, maxSlashBps]` exactly as today. Denominating the rate on the basis rather than raw live stake is what stops a post-drain top-up from diluting the burn.

*Why:* The lock is written once by `recordApproval` and erased only by release/retire — the same lifecycle that made `_reservedUsd` safe as a slash predicate. `settleCoverage` no longer exists, so nothing permissionless can move it. The envelope clamp is what answers SHE-227's deterrence objection: `minSlashBps` is a bond-wide floor a guardian cannot declare their way under, so a 1-wei declaration contributes nothing to quorum and still costs `minSlashBps` of everything they hold. One floor, already owner-tunable, already enforced on both slash paths.

*Alternative rejected:* a separate declaration floor as a percentage of need (SHE-227's original floor). Redundant once `minSlashBps` does the deterrence work, and — as SHE-227 itself derives — gain and loss both scale with a need-relative floor, so it cannot make collusion a losing bet on its own.

### D4 — Keep `kNumerator`; state its property

Capacity is `kNumerator × slashable stake − Σ live locks`. At k = 1, `Σ locks ≤ stake`, so burning one lock leaves `stake − lock_A ≥ Σ_{j≠A} lock_j`: every other proposal the guardian backs stays fully covered. Above 1, that no longer holds by exactly the leverage chosen.

*Why keep it:* governance flexibility to trade containment for capital efficiency later, with the trade-off now written into the requirement rather than hidden in accounting.

*Alternative rejected:* hard-set to 1. Simpler, but removes a lever governance may want, and 1 is already the default.

### D5 — Buckets stay; their unit changes

Epoch buckets, wall-clock expiry at `bucketEnd + challengeWindow`, the 60-day horizon, the 16-bucket scan bound, `retireApproval`, freeze and pin all survive unchanged in shape. They now hold WOOD. `openExposureUsd` becomes `openExposureWood` (or is renamed to drop the unit suffix); the batching cap compares WOOD to WOOD.

*Why:* The bucket model already encodes "budget recycles once a commitment ages past challengeability" — the property `settleCoverage` was violating. With booking = pledge the buckets are sufficient on their own. SHE-213 (a frozen/pinned key outliving its bucket) is untouched by this change and is tracked separately.

### D6 — Challenger bond sized off the pledge sum, capped at need

`ChallengeGame.file` keeps reading the unshared pledge sum (deliberately not pro-rated), now `Σ locked_i × livePrice`, but capped at the proposal's priced need.

*Why:* The bond is anti-spam collateral sized to what a conviction can take *for this proposal*. Under no-cap the cohort may lock more than the need; a challenger should not have to post a bond against over-subscription they cannot recover. The full locks are still slashed on conviction — the cap applies to bond sizing only.

### D7 — Archive `settle-coverage-self-trigger` unfinished

Its 15 completed tasks wired `_settleCoverageBestEffort` into `_finishSettlement` and `reclaimProposerBond`; the 3 remaining are validation. This change deletes all of it.

*Why:* completing validation of code that is about to be removed is wasted work, and archiving the change would merge its delta into the main `syndicate-governor` spec, creating a requirement this change would then have to REMOVE. Archive without merging; note the reason in the archive.

## Risks / Trade-offs

- [Deterrence now rests on `minSlashBps` being set high enough] → It is owner-set and already bounds every slash; the spec states its role explicitly so it cannot be lowered casually. Launch value is a governance decision recorded in deployment-docs, not a code default.
- [A guardian can spread many tiny locks across many proposals] → Each contributes ~nothing to quorum (cannot help an attacker pass coverage) and each conviction still costs `minSlashBps` of the whole bond. The spread buys no cheaper penalty.
- [Contagion returns at k > 1] → Stated in the requirement as the property k trades away; default is 1.
- [Off-chain plumbing: SDK, CLI, daemon must pass the amount] → Breaking ABI on `voteOnProposal`; coordinated release. Fresh deployment removes the mixed-version window.
- [`StakedWood` slash paths take bps, not amounts] → Convert `min(locked, live)` to bps of live stake at the call site, rounding up so the burn never falls below the lock by truncation; the envelope clamp then applies. Saturates at 10_000 when locked ≥ live.
- [Storage layout] → The ledger is not upgradeable, so its storage is restructured outright with no golden to regenerate. The one layout-pinned contract touched is `SyndicateGovernor`, whose golden must diff ZERO (this change deletes code there, never storage).
- [36 test call sites assume full reservation + settle] → Rewritten to declarations. The SHE-212 reproduction flips to a "cannot happen" pin.

## Migration Plan

Fresh deployment of the guardian-economics stack (ledger, registry, sWOOD, challenge game) via the existing DeployPlanD ceremony with the same wiring order. No proxy upgrade of a live ledger, no state migration. Rollback is redeploying the previous stack; there is no in-place downgrade.

## Open Questions

None remaining. The daemon default was resolved by reading `sherwood-guardian`:

### D8 — The daemon's lock defaults to the placement it already computes

`judge.ts` already derives a prospective coverage placement per proposal — the guardian's own free capacity, bounded by an operator-configured per-proposal ceiling (`withinCeiling`), surfaced as `selfCoverageFloorMaxCapital` — before deciding APPROVE/ABSTAIN/BLOCK. The declared lock is that placement, in WOOD: `lockWood = min(freeWood, ceilingWood)` where `freeWood = kNumerator × guardianStake − openExposure` mirrors the chain's own price-free cap exactly (the daemon's `capacity.ts` rule — a capacity computed differently from the chain's is worse than none — applies). The daemon's existing USD capacity mirror in `ledger.ts` (`k × slashableBondUsd − openExposureUsd`) is replaced by that WOOD computation; its USD prospective-coverage reasoning for the quorum-shortfall decision stays, since that mirrors `requireApproveQuorum`, which is priced. No new knob: the operator ceiling that already bounds concentration is the lock's upper bound, expressed in WOOD.

*Why:* a fraction-of-capacity default would be a second number describing the same intent as the ceiling the operator already set. Reusing the placement keeps one source of truth and means a guardian never locks more than the daemon already judged it could safely carry.

*Consequence preserved from SHE-56:* the daemon deliberately approves with a ZERO reservation when it has no free capacity, because that approve is costless and unslashable while still adding vote weight. Under the lock model this stays true — a zero lock owes 0 bps and is skipped by the verdict path — so SHE-56's decision survives unchanged. Its in-code rationale cites the old pledge-vs-booking predicate and stale `ExposureLedger.sol` line numbers; task 7.3 rewrites that comment to the lock predicate.
