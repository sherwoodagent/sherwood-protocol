# Coverage and underwriting

Guardians who Approve are underwriters. `ExposureLedger` is the coverage book.
A coverage **shortfall scales** the proposal rather than blocking it. Guardian
daemons that treat a shortfall as disqualifying are implementing a rule the
contracts do not enforce.

The [proposer bond](proposer-bond.md) is a separate WOOD pull at propose, quoted
from this same `requiredCoverage`.

## requiredCoverage

`SyndicateGovernor._snapshotTierAndGate` writes `proposal.requiredCoverage` at
propose. Read it with `getRequiredCoverage(proposalId)`.

Coverage is the sum of per-call contributions across **both** execute and
settlement calls. `_scanCalls` is the arithmetic:

```
coverage += (cap_i * boundBps) / 10_000;
```

`boundBps` is `TierRegistry.tierOf(target, selector)`: the certified extractable
bound for tier 0/1, or `10_000` (full notional of the declared cap) for tier 2
or uncertified selectors. Proposal **tier** is the max across execute calls
only. With no `TierRegistry` wired, `_resolveTierAndCoverage` returns
`(2, maxCapital)`.

A sandbox payload is priced at full funding and forced to tier 2
(`coverage_ += sandboxFunding`). Zero coverage is specified: an all-zero-cap
batch prices to zero and skips the approve-quorum gate; the per-call meter
(`CallCapExceeded` on any outflow) is the protection.

Propose-time gates against the **declared** coverage **do** block:
`requireWithinCoveredTvlCap` (`CoveredTvlCapExceeded`),
`requireWithinCoverageHorizon` (`CoverageHorizonExceeded`), and
`proposerBondWood` (fail-closed on `NoWoodPrice`). At execute, live coverage
above the snapshot reverts `CoverageRegressed`. Those are not the shortfall
path.

## Approve is underwriting

The hook is `GuardianRegistry.voteOnProposal` → `ExposureLedger.recordApproval`
(first Approve, and Block → Approve). The registry writes vote state, then
calls the ledger (CEI).

The approve vote carries a WOOD amount: `voteOnProposal(governor, proposalId,
support, lockWood)` → `recordApproval(governor, proposalId, guardian, lockWood)`.
The ledger locks `min(lockWood, free budget)` WOOD, where

```
free budget = kNumerator * slashableStake(guardian) − openExposure(guardian)
```

all in WOOD. Nothing is converted to USD on this path and no price is read. A
guardian with no free budget is **not rejected at vote time** — the ledger locks
zero, the vote still counts as weight, and the cap shows up as an execute-time
shortfall rather than a reverted vote. An asset-feed outage likewise locks
nothing rather than reverting, so Block votes cannot keep working while Approve
votes fail; a WOOD-feed outage is not a failure case at all, because the lock
needs no price.

`releaseApproval` unwinds Approve → Block (`CoverageFrozen` while a challenge
is live); `retireApproval` clears a lock once its proposal is past
challengeability. The execute-time quorum reads the ledger's own `_approversOf`
list, never the registry.

## Declared coverage locks

The lock is the declaration. One figure per (proposal, guardian) —
`lockOf(governor, proposalId, guardian)` — is at once the guardian's booking
(what the capacity check counts), their pledge (what a conviction takes) and
the slash base. It is written once by `recordApproval` and erased only by
release or retirement, both of which a filed challenge blocks. The adversary is
anyone who could move a guardian's slash base while a challenge is live; with
booking and pledge the same storage there is no permissionless pass that can
shrink or grow it.

Historical note: the ledger used to reserve the proposal's **full** USD
requirement for every approver and rely on a later `settleCoverage` pass to
collapse each reservation to a pro-rata share. That pass had no sound moment to
run (SHE-212, SHE-225) and is gone; the following properties replace it.

- **No cohort cap.** The locks on a proposal may sum to more than its
  requirement. Over-subscription is a well-covered proposal; nothing is
  pro-rated or written down, and each lock stays that guardian's own liability.
  Under-subscription needs no new machinery — the shortfall path below already
  scales the proposal.
- **Capacity is WOOD, with no price.** `openExposure(guardian)` walks the epoch
  buckets (width `epochLength`, 60-day horizon, 16-bucket scan bound) in WOOD.
  A bucket recycles budget once `bucketEnd + challengeWindow` has elapsed, or
  earlier on release or retirement. A stale or manipulated WOOD feed can neither
  starve nor inflate a guardian's budget.
- **`kNumerator = 1` contains a conviction.** At the default, `Σ locks ≤ stake`,
  so burning proposal A's lock leaves `stake − lock_A ≥ Σ other locks`: every
  other proposal the guardian backs stays fully covered. Any `k > 1` is
  deliberate leverage that gives exactly that property up — a guardian may lock
  more across proposals than they hold, and one conviction may leave the others
  under-covered by the excess. The adversary is an operator raising `k` for
  capital efficiency without seeing that it reintroduces cross-proposal
  contagion. `setKNumerator(0)` reverts `InvalidParameter`.
- **Slash = the lock, under the stake envelope.** `slashBpsFor` returns each
  approver's lock over their slash basis, in bps, rounded up (saturating at
  10_000 when the lock meets or exceeds the basis). `StakedWood` then clamps
  that rate into `[minSlashBps, maxSlashBps]` and burns `min(lock, basis)`. The
  basis is `min(stake at the anchor, live stake)`: `openedAt` on the review path
  (the at-open checkpoint from pashov #11, clamped to live so a concurrent slash
  is not double-counted) and `executedAt` on the verdict path. Denominating on
  the anchored basis rather than raw live stake is what stops a post-drain
  top-up from diluting the burn — double the stake after the fact and the burn
  is still the lock. On a blocked review the block's deterministic severity
  multiplies the lock-derived rate; it never replaces it. `minSlashBps` is the
  **single deterrence floor**: a 1-wei lock rounds up to 1 bps, contributes
  nothing to quorum, and is still floored to `minSlashBps` of everything the
  guardian holds. `maxSlashBps` must be 100% so a guardian who locked their
  whole stake can be burned for all of it (`DeployPlanB` pre-flights both). A
  zero lock owes 0 bps and is skipped.
- **WOOD is priced by one feed, capped by governance.** `woodPriceX8()` reads a
  single `AggregatorV3`-shaped WOOD/USD feed, takes `min(feed, woodUsdPriceX8)`
  — the cap is never served as a price — and applies `woodHaircutBps`. On chain
  4663 that feed is `WoodPoolFeed`: the lower of the Uniswap and Sushiswap
  WOOD/WETH pools' TWAPs over a window of at least 24h, converted through
  ETH/USD, with the idle tail extrapolated at most 5 minutes and each pool held
  to a WETH depth floor. A stale or shallow reading yields no price at all —
  `NoWoodPrice` — rather than a wrong one.
- **Cohort liability is the lock sum, capped at need.**
  `liabilityUsd(governor, proposalId)` returns
  `min(needUsd, Σ min(lock_i, live stake_i) × woodPriceX8())`;
  `unsharedLiabilityUsd` returns the same figure, since with no cohort cap there
  is no distinct shared basis. `ChallengeGame.file` sizes the challenger bond
  off it, so a cohort cannot lock surplus WOOD to price challengers out. The cap
  bounds bond sizing only — every full lock still burns on conviction. Both
  views revert on an unpriceable WOOD feed: sizing a bond off an unvouched price
  is the unsafe direction, so filing waits.
- **Fee attribution is the lock.** `GuardianRegistry.getApproverCoverage` reads
  `coverageUsdOf` — `min(lock, live slashable stake) × woodPriceX8()`,
  **uncapped**: a guardian who locked more took more risk and earns
  proportionally more, even when the cohort over-subscribed. No settlement step
  precedes payout; the lock a guardian holds at payout is their attribution.
  `priced == false` means the payout job must retry, not pay zeros.

## Shortfall scales rather than blocks

`IExposureLedger.requireApproveQuorum` is a coverage **measurement** with a
zero floor, not an all-or-nothing gate. It returns
`(coverageRaisedUsd, requiredCoverageUsd)` so the caller can size execution to
a coverage-proportional effective capital. It reverts `InsufficientApproveCoverage`
**only** when the approver set is empty or the raised aggregate is exactly
zero. A nonzero-but-partial aggregate is reported to the caller.

`SyndicateGovernor._deriveAndStoreEffectiveCapital` is that caller, inside
`executeProposal` after `executedAt` is stamped (same transaction). The gate
runs when:

```
gated = ledger != 0 && requiredCoverage != 0
     && envelopeTier >= quorumTierThreshold
```

Launch `quorumTierThreshold` is 0 (every tier). When the gate does not run,
`effectiveMaxCapital = maxCapital`. When it does:

```
(coverageRaisedUsd, requiredCoverageUsd) =
    requireApproveQuorum(this, proposalId, asset, requiredCoverage)

scale = gated && coverageRaisedUsd < requiredCoverageUsd
effectiveMaxCapital = scale
    ? (maxCapital * coverageRaisedUsd) / requiredCoverageUsd
    : maxCapital
```

Floor integer division. Dust coverage can floor to a zero net-outflow cap
(fail-closed). The scaling branch never divides by zero: a raised aggregate of
exactly zero already reverted.

The same ratio scales every per-call cap via `_scaleCaps`
(`(caps[i] * raised) / required`). Scaled settlement caps are persisted so
`settleProposal` reuses them and **never recomputes** coverage. Sandbox funding
is scaled by the same `effective / max` ratio.

`executeProposal` emits `EffectiveMaxCapitalSet`.

Silence still does not pass a gated proposal. Empty approvers or a zero
aggregate leaves the proposal `Approved` until `executeBy`. That is "no
underwriter on the hook," not a shortfall. A **partial** book is the shortfall
case, and it scales.

Each remaining approver contributes `min(lock, live slashableStake) ×
woodPriceX8()`: the lock they declared, valued at the live price, and no more
than their stake is now worth. This is the one place WOOD is converted to USD
for coverage; a guardian whose lock is worth less than when they declared it
(unstake, or a WOOD price fall) counts at the shrunken live value, so coverage
must hold in dollars at execution. The loop sums locks — there is no
pro-rating and no cross-proposal sharing. This is not an indemnity — slash
proceeds are burned.

## Proposer bond

Quoted from this book at propose:

```
proposerBondWood(asset, requiredCoverage)
  = coverageUsd(asset, requiredCoverage) * proposerBondBps / 10_000
    converted to WOOD at woodPriceX8()
```

Default `proposerBondBps` = 100 (1%). See [proposer-bond.md](proposer-bond.md).
The bond is not resized if guardian coverage later falls short.
