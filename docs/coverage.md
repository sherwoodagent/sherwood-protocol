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

`recordApproval` reserves `min(free bond, the proposal's full coverage in USD)`,
not the uncovered remainder. An under-bonded guardian is **not rejected at vote
time** — it commits what it can. The cap
(`k * slashableBondUsd − openExposureUsd`) is enforced by booking zero, not by
reverting the vote. Pricing failures also book nothing rather than revert, so
Block votes cannot keep working while Approve votes fail.

`releaseApproval` unwinds Approve → Block (`CoverageFrozen` while a challenge
is live). The execute-time quorum reads the ledger's own `_approversOf` list,
never the registry.

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

Each remaining approver contributes through `_sharedSlashableUsd`:
`min(reserved at vote, shared slashable bond now)`, anchored at
`block.timestamp`. The loop sums reservations, not allocations. This is not an
indemnity — slash proceeds are burned.

## Proposer bond

Quoted from this book at propose:

```
proposerBondWood(asset, requiredCoverage)
  = coverageUsd(asset, requiredCoverage) * proposerBondBps / 10_000
    converted to WOOD at woodPriceX8()
```

Default `proposerBondBps` = 100 (1%). See [proposer-bond.md](proposer-bond.md).
The bond is not resized if guardian coverage later falls short.
