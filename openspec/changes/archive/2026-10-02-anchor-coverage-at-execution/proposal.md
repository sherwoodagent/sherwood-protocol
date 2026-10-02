# Anchor post-execution coverage reads at `executedAt` (issue #35)

## Why

`ExposureLedger` values a guardian's slashable bond from LIVE stake
(`_slashableBondUsd` reads `swood.guardianStake(g)`), while the verdict slash
that backs an executed proposal recovers at most
`min(checkpoint@executedAt, live)` (`StakedWood._slashOne`, anchored by
`ChallengeGame` at the proposal's execution instant). Every ledger read that
runs AFTER execution — `allocatedUsd`, `liabilityUsd`/`_effectiveTotal`,
`settleCoverage`/`_effectiveReservedTotal` — therefore counts post-execution
stake top-ups as coverage that the conviction provably cannot take. An accused
cohort can permissionlessly top up after the drain to inflate
`liabilityUsd`, raising the challenger's filing bond (`ChallengeGame.file`
sizes the bond off it) with capital that is locked but unslashable, and
`settleCoverage`'s residue top-up credits bookings past the conviction's
reach — its own natspec ("the most a conviction could ever take") is
currently false.

The headline PoC in issue #35 (quorum passes on coverage the verdict cannot
reach) is stale on current main: commit 4e2823c re-anchored the verdict at
`executedAt`, and `requireApproveQuorum` runs in the same transaction that
stamps `executedAt`, so the execute-time gate and the verdict already agree.
What remains — and what this change fixes — is the post-execution read
family, plus making the gate/verdict agreement structural instead of an
accident of call ordering.

## What Changes

- `StakedWood` gains a view `slashableStakeAt(address guardian, uint256 anchor)`
  returning exactly the verdict slash basis:
  `min(max(liabilityCheckpoint@anchor, stakeCheckpoint@anchor), liveStake)`.
  `_slashOne` is refactored to size from the same internal helper so the view
  and the slash can never drift. View-only — no storage change; the
  StakedWood layout golden is untouched.
- `SyndicateGovernor.getProposalView` / `ILedgerGovernorMinimal.ProposalViewLite`
  gain an `executedAt` field (0 until executed). Memory-struct/ABI extension
  only — no storage change; the governor layout golden is untouched.
- `ExposureLedger`'s slashable-bond read becomes anchor-aware: when the
  proposal has executed (`executedAt != 0`), `allocatedUsd`,
  `liabilityUsd`/`_effectiveTotal`, and `settleCoverage`/
  `_effectiveReservedTotal` value each approver at
  `min(slashableStakeAt(g, executedAt), reserved)` (priced at the current
  WOOD price) instead of live stake. Pre-execution reads (`recordApproval`'s
  budget cap, the public `slashableBondUsd` view) stay live — no anchor
  exists yet, and any stake present at execution is reachable.
- `requireApproveQuorum` keeps its live read (provably equal to the anchored
  read at the only instant it gates — `executedAt` is stamped at
  `SyndicateGovernor.sol:382` before the gate at `:429` in the same tx) but
  its natspec documents that alignment invariant as load-bearing.
- Corrects the false natspec claims: `settleCoverage`'s residue bound
  ("the most a conviction could ever take"), `liabilityUsd`'s "cannot drift
  apart", and `_effectiveTotal`'s discount rationale.
- Out of scope, documented as deliberate: the review-path slash
  (`GuardianRegistry.resolveReview`, anchored at `r.openedAt`) fires only on
  BLOCKED proposals, which never reach any coverage consumer, and vote weight
  is likewise snapshotted at `openedAt` — a post-open top-up buys neither
  weight nor coverage there. Also out of scope: issue #83's Case-snapshot fix
  and issue #110's upward-rebook cap, which this change is designed not to
  disturb (see design.md).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `guardian-coverage`: slashable bond valuation, pro-rata allocation, and
  coverage settlement gain an execution-anchored basis — after `executedAt`,
  per-approver coverage is capped at what the verdict slash can actually
  reach, not live stake.
- `guardian-staking`: new requirement — the staking contract exposes the
  verdict slash basis (`slashableStakeAt`) as a view sharing one
  implementation with `_slashOne`.

## Impact

- `src/StakedWood.sol` — new view + `_slashOne` refactor (no storage change;
  golden-pinned, golden unchanged).
- `src/ExposureLedger.sol` — anchor-aware `_slashableBondUsd` and its four
  post-execution callers; natspec corrections. Not layout-pinned; no storage
  change anyway.
- `src/SyndicateGovernor.sol` — `ProposalViewLite`/`getProposalView` field
  append (no storage change; golden-pinned, golden unchanged).
- `src/interfaces/IStakedWood.sol` — new view declaration.
- Test mocks that implement the minimal governor/staking interfaces must add
  the new field/view: `test/ExposureLedger.t.sol` (inline mocks),
  `test/RegistryExposureHook.t.sol`, `test/mocks/MockStakedWood.sol`, plus
  any harness decoding `getProposalView`.
- Interacts with open issues #83 and #110 (both read the same
  `settleCoverage` seam); this change preserves both analyses — see
  design.md for the explicit compatibility argument.
