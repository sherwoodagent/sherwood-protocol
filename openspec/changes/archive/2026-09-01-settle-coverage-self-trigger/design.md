# Design — settleCoverage self-trigger (issue #33)

All file:line references are to `origin/main` @ `388460ce` unless a branch is named.

## D1 — Call sites, and the trigger-window math that forces two of them

**The gate being satisfied.** `settleCoverage` (src/ExposureLedger.sol:1581) reverts
`ReviewNotClosed` unless `pv.executeBy != 0 && block.timestamp > pv.executeBy`
(:1602) — STRICTLY after the execution deadline, because a proposal is executable
while `block.timestamp <= executeBy` and settling must not overlap the last
executable instant (its own natspec, :1599-1601). Any self-trigger that can run at
or before `executeBy` is a deterministic no-op (or, unguarded, a deterministic
caught revert).

**Settlement is NOT reliably past `executeBy`.** The timing facts:

- Execution requires `Approved`, which requires `block.timestamp > reviewEnd`
  (`ProposalLifecycle._afterVote`, src/ProposalLifecycle.sol:126) and
  `block.timestamp <= executeBy` (:109), so `reviewEnd < executedAt <= executeBy`.
- `executeBy = reviewEnd + executionWindow` (src/SyndicateGovernor.sol:1003;
  collaborative path :779 uses the Draft-snapshotted window), with
  `executionWindow ∈ [1 hours, 7 days]` (GovernorParameters.sol:41-42).
- `settleProposal` admits anyone at `executedAt + strategyDuration` and the
  proposer at `executedAt + 1 hours` (`MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE`,
  src/SyndicateGovernor.sol:89, :464-468). `strategyDuration` has no floor above
  1 hour and no relation to `executionWindow`.

Counterexample: `executionWindow = 7 days`, executed at `reviewEnd + 1 hour`,
`strategyDuration = 1 day` → non-proposer settles at `reviewEnd + 1d 1h`, five-plus
days BEFORE `executeBy`. The proposer self-settle path is worse (`+1 hour`). The
emergency paths (`unstick`, `finalizeEmergencySettle`) share the
`executedAt + strategyDuration` wait and the same non-guarantee. So **no point
inside the settlement transaction is unconditionally past `executeBy`**, and the
design must say so rather than pretend otherwise.

**Call site 1 — `_finishSettlement` tail (primary).** The trigger goes at the very
end of `_finishSettlement` (src/SyndicateGovernor.sol:1299-1366), after
`emit ProposalSettled` (:1365), guarded by `block.timestamp > proposal.executeBy`:

- One insertion covers all three settlement entrypoints: `settleProposal` (:460),
  and the emergency paths via `_finishSettlementHook` → `_finishSettlement`
  (:212-214, GovernorEmergency.sol:66/:115).
- By this point state is `Settled`, `_activeProposal` cleared, `_decOpen()` done,
  fees charged/escrowed, the vault notified — CEI is complete; the trigger is pure
  epilogue (see D2 for reentrancy).
- LAST-OPERATION placement is load-bearing for the 63/64 rule: if the child OOGs it
  consumes up to 63/64 of remaining gas, and the only work left to fund is the
  function return — settlement itself can no longer be taken down by a starved
  child (same reasoning ChallengeGame documents around its best-effort children,
  src/ChallengeGame.sol:107-115).
- The guard makes the pre-`executeBy` case an explicit, documented SKIP (no event,
  no external call) instead of a caught `ReviewNotClosed`. Skip and failure are
  different things: the skip is deterministic from on-chain state the governor
  already holds (one SLOAD), expected in normal operation (proposer self-settles),
  and will be retried by call site 2; emitting a failure event for it would train
  operators to ignore the event that matters.

**Call site 2 — `reclaimProposerBond` tail (the provably-past-`executeBy`
backstop).** Same guarded best-effort block at the end of `reclaimProposerBond`
(src/SyndicateGovernor.sol:646-720), after `releaseBond` (:719). Why this point is
reliably inside `settleCoverage`'s window for every executed proposal:

- The Settled-proposal reclaim gate requires
  `block.timestamp >= executedAt + pinnedLedger.challengeWindow()` (:695).
- The ledger enforces `challengeWindow >= registry.reviewPeriod() +
  MAX_GOVERNOR_EXECUTION_WINDOW` where `MAX_GOVERNOR_EXECUTION_WINDOW = 7 days`
  (src/ExposureLedger.sol:142, enforced at setChallengeWindow :762-768 and
  re-checked at setGuardianRegistry :737-741; default `challengeWindow = 14 days`).
- The governor caps `executionWindow <= MAX_EXECUTION_WINDOW = 7 days`
  (GovernorParameters.sol:42), and `executedAt > reviewEnd`, so
  `executeBy − executedAt < executionWindow <= 7 days <= challengeWindow`.
- Therefore `executedAt + challengeWindow > executeBy` — strictly — whenever the
  reclaim gates pass. For `Expired` proposals the state itself implies
  `block.timestamp > executeBy` (ProposalLifecycle.sol:109). For
  `Rejected`/`Cancelled` proposals reclaimed before `executeBy`, the guard skips —
  exactly matching what the ledger's own gate would refuse.
- The caller is the one actor with a standing incentive: the proposer recovering
  their WOOD bond. This satisfies issue #33's "existing transaction that already
  runs at that point in the lifecycle" without inventing a keeper or a payment.
- The trigger runs only on the successful-release path, not the
  forfeiture-acknowledge early return (:670-674): a forfeited bond means a
  conviction landed, and the conviction machinery already rewrites the cohort's
  bookings through the slash path; adding the trigger there would widen blast
  radius for a path that has its own repricing.
- The edge where the `challengeWindow` floor is not enforced (no guardian registry
  wired on the ledger when the window was set) is a configuration edge, not a
  safety hole: the `block.timestamp > executeBy` guard makes the trigger correct
  under ANY parameterization — worst case it skips, which is the status quo.

**Documented residual gap.** A proposal with no reclaimable proposer bond (no
escrow wired at propose, or zero-priced bond) that also settled before `executeBy`
fires neither trigger. Backstops unchanged from today: the permissionless external
`settleCoverage` and epoch-bucket expiry. This is accepted: the residual is the
exception (bond escrow is wired in the sanctioned deploy), where today it is the
rule.

**Rejected placements.**

- `_commitState`'s Approved→Expired edge (reliably past `executeBy`): rejected —
  `_commitState` lives in the abstract `ProposalLifecycle`, which holds no
  exposure-ledger reference, so this needs a new virtual hook wired through the
  base; and `_commitState` runs at the top of EVERY mutating entrypoint (`vote`,
  `cancelProposal`, `vetoProposal`, ...), putting a try/catch external call on hot
  paths that have nothing to do with settlement. `reclaimProposerBond` already
  covers the Expired case (Expired is one of its admitted terminal states) with
  none of that blast radius.
- Unguarded try/catch in `_finishSettlement`: rejected — every early self-settle
  would emit `CoverageSettleFailed` for a statically-knowable, expected condition
  (see the skip-vs-failure distinction above).
- A dedicated public `pokeCoverage()` on the governor: rejected as option-A-shaped
  (still needs an uncompensated caller; the external `settleCoverage` already IS
  that surface).

## D2 — Failure handling: the `AdapterDemotionFailed` pattern, exactly

House precedent (src/ChallengeGame.sol:1245-1250):

```solidity
if (c.adapterTarget != address(0)) {
    try tierRegistry.demoteByChallenge(c.adapterTarget, c.adapterSelector) {}
    catch {
        emit AdapterDemotionFailed(challengeId, c.adapterTarget, c.adapterSelector);
    }
}
```

with `event AdapterDemotionFailed(uint256 indexed challengeId, address indexed
target, bytes4 indexed selector)` (IChallengeGame.sol:381) — zero-address-guarded,
bare catch, all-indexed identifying fields, no revert-data payload, terminal path
never bricked.

This change's mirror, in a single private helper so both call sites cannot drift:

```solidity
/// best-effort; never reverts. See design D1/D2 of settle-coverage-self-trigger.
function _settleCoverageBestEffort(uint256 proposalId, StrategyProposal storage proposal) private {
    if (block.timestamp <= proposal.executeBy) return; // ledger would revert ReviewNotClosed — retried at reclaim
    address ledger = proposal.proposerBondLedger;       // pinned at propose (issue #116)
    if (ledger == address(0)) ledger = _exposureLedger; // pre-pin fallback, same rule as the reclaim gates (:686-687)
    if (ledger == address(0)) return;                   // no ledger, no coverage was ever booked
    try IExposureLedger(ledger).settleCoverage(address(this), proposalId) {}
    catch {
        emit CoverageSettleFailed(proposalId, ledger);
    }
}
```

- **Event**: `event CoverageSettleFailed(uint256 indexed proposalId, address
  indexed ledger);` in `ISyndicateGovernor`. Shape matches the precedent:
  `<Thing><Action>Failed`, indexed identifying id + the collaborator address that
  failed (compare also `ProposerBondForfeitureFailed(challengeId, governor,
  proposalId, bondEscrow)`, IChallengeGame). `proposalId` identifies the review
  key (the governor is the emitter, so the pair is unambiguous); `ledger` tells the
  operator where to point the manual retry.
- **The catch stays bare, deliberately** — same argument as the precedent's own
  natspec (ChallengeGame.sol:1212-1228): everything reaching it is either
  ledger-side (`NoWoodPrice` from `woodPriceX8()` during a feed outage — the one
  realistic revert; `ReviewNotClosed` is unreachable under the guard because guard
  and gate read the same clock and the same `executeBy`) or gas starvation, and
  revert-data filtering can distinguish neither reliably (an OOG child returns
  empty data). Bubbling would convert a capacity-relief miss into a
  settlement/reclaim-liveness failure — the exact inversion the fee waterfall's
  escrow design (`FeeTransferFailed`) exists to prevent on the same function.
- **Success-with-no-effect is not a failure**: `settleCoverage` RETURNS (no revert)
  when the asset coverage is unpriceable (:1611-1617) — its own retry-later
  contract. No event fires; the reservation stays; the next trigger or any external
  call repairs it. The failure event means "the call reverted", nothing broader.
- **Ledger resolution** is the reclaim gates' pinned-first rule (issue #116).
  Inside `_finishSettlement` the pin and the live slot provably coincide
  (`setExposureLedger` refuses while `_openProposalCount > 0`,
  src/SyndicateGovernor.sol:1742-1755, and the proposal was open until this
  transaction), but at reclaim time the live slot may have been re-pointed — one
  rule everywhere, and it is the pin.
- **Reentrancy**: both call sites run inside `nonReentrant` frames after all
  effects (state `Settled`/bond zeroed) and after the existing external
  interactions. `settleCoverage` re-enters the governor only through
  `getProposalView`/`getRequiredCoverage` — `view` functions compiled to
  STATICCALL — and otherwise touches only trusted collaborators (sWOOD, oracle,
  its own buckets). No new reentrancy surface.

## D3 — Gas: estimate, and why there is deliberately no gas floor

**What one `settleCoverage` pass costs.** Per the post-#158 shape: fixed overhead
of the cross-contract `getProposalView` staticcall (struct copy),
`getRequiredCoverage`, `coverageUsd` self-call + asset-feed read, and
`woodPriceX8()` — roughly 40-60k. Then two loops over the approver list plus a
residue pass; each approver costs two `_sharedSlashableUsd` evaluations (each = one
sWOOD staticcall + an `openExposureUsd` walk over ≤ `MAX_SCAN_BUCKETS = 16`
buckets) and, in the main loop, a `_rebook` (booking + bucket SSTOREs, plus a
second `openExposureUsd` walk on upward moves). Estimate **~50-120k per approver
cold**, so:

- typical cohort (3-5 approvers): **~0.3-0.7M gas added** to the settlement or
  reclaim transaction;
- worst case (`MAX_APPROVERS_PER_PROPOSAL = 100`, GuardianRegistry.sol:34): order
  **5-12M gas** — large, and exactly why the trigger is best-effort: a cohort too
  big for the caller's gas budget degrades to `CoverageSettleFailed` + status quo,
  never a bricked settlement or a stranded bond.

These are estimates to be pinned by the gas-snapshot task (tasks §3.8) before
merge; the design holds for any value because failure is free (see below).

**Measured (tasks §3.8, `SettleCoverageSelfTrigger.t.sol::test_gasSnapshot_triggerCost_1And4Approvers`)**:
added cost of the `settleProposal` trigger, isolated by diffing against an
identical proposal whose trigger skips (settled at/before `executeBy`) — **1
approver: ~28.5k gas; 4 approvers: ~82.7k gas** (~18-27k/approver marginal,
plus a smaller fixed base than estimated). Both come in comfortably under the
~40-60k base + ~50-120k/approver envelope above — the estimate was
conservative. The `MAX_APPROVERS_PER_PROPOSAL = 100` worst case was not
separately measured (would require staking and seating 100 real guardians);
the per-approver marginal measured here (~18-27k) extrapolates to roughly
2-3M gas at 100 approvers, still well inside the design's original 5-12M
order-of-magnitude bound and still exactly why the trigger is best-effort.

**No existing settlement gas budget to fit inside.** Verified: `gasleft()` appears
only in ChallengeGame (:1130-1134); the issue #51 floors
(`SLASH_GAS_PER_APPROVER = 180_000`, `SLASH_GAS_BASE = 2_000_000`,
`DEMOTION_GAS = 200_000`) are ChallengeGame constants guarding ITS settle path.
`settleProposal`/`reclaimProposerBond` carry no analogous constant on main.

**Decision: no gas floor here — the #51 prior art argues the OPPOSITE conclusion
for this call.** `DEMOTION_GAS` exists because a caller could dial gas so the
conviction landed but the best-effort demotion starved — selecting, with gas alone,
which SAFETY consequence of a verdict took effect, unrepairably (the settle is
one-shot). Here the child's failure restores the exact pre-change status quo
(over-reserved — the conservative direction, the ledger's own "safe to skip"
contract, :1543-1545), is surfaced by an event, and is permissionlessly repairable
by anyone calling the unchanged external `settleCoverage`. A gas-dialling caller
gains nothing they don't already have today by simply not calling `settleCoverage`.
A floor would instead make settlement/reclaim REVERT when gas is short — converting
a capacity-relief liveness aid into a settlement-liveness risk, the known-bad
trade. Adversary statement for the natspec: the caller who starves the trigger to
keep a rival cohort's budget locked achieves only the pre-change baseline, visibly,
and anyone may undo it.

## D4 — Idempotence: re-runnable is the mechanism, and the spec text was stale

Verified on `origin/main` @ `388460ce` AND against PR #158's full diff:

- `_settled` (src/ExposureLedger.sol:319) is assigned at :1606, :1641, :1716 and
  **read nowhere** — write-only, load-bearing for nothing. #158 touches none of
  those lines.
- `settleCoverage` is re-runnable BY DESIGN and documents it as the security
  property (:1547-1571): every pass re-derives the entire split from the unchanged
  `_reservedUsd` pledges at the CURRENT price — never from a prior pass's bookings
  — `_rebook` moves bookings both directions bounded by the pledge and the #110
  cap re-check, and no funds move (bookings only).

Consequences for the self-trigger:

- **Self-trigger + independent external caller, any order, any count**: passes
  converge to the same pledge-derived split; a pass at a price trough is repaired
  by any later pass. No double-application is representable — there is no
  cumulative state, only rewritten bookings.
- **No double-charge**: `settleCoverage` transfers nothing; fees/bond transfers in
  the host functions completed before the trigger and are not re-entered.
- **No double-emit beyond existing semantics**: the ledger emits one
  `CoverageSettled` per successful pass — already true for repeated external calls
  today; the trigger adds no success-side emit of its own.
- **Settlement retries**: `_finishSettlement` runs at most once per proposal
  (Executed → Settled is one-way; `settleProposal`/`unstick`/
  `finalizeEmergencySettle` all gate on `Executed` and a failed settlement batch
  reverts BEFORE finalization, so a retry that finally succeeds fires the trigger
  exactly once). `reclaimProposerBond`'s trigger also fires at most once (second
  call reverts `NoBondToReclaim` at :657 before reaching the tail). Worst case
  both fire — two passes, converging, per the re-runnable contract.

**Spec correction carried in this change's `guardian-coverage` delta**: the main
spec (and the still-open anchor change's delta) says "idempotent via a settled
flag" and "Double settlement ... returns without re-dividing the settled numbers".
That describes an earlier design; the shipped code re-divides on every pass and
that is the property this change depends on. The delta rewrites the requirement to
the re-runnable contract. Ledger code is untouched — this is documentation
converging on reality, flagged here so reviewers don't read it as a behavior
change.

## D5 — Dependency on PR #158 (issues #35/#154): what was verified

Issue #154 found the ledger's anchored reads could double-count a guardian's
shared stake across simultaneously-open proposals; PR #158 (branch
`fix/issue-35-booking-anchor`) fixes it with `_sharedSlashableUsd(guardian,
reserved, priceX8, anchor)` — `share = slashable × reserved /
openExposureUsd(g)`, clamped to `reserved` — reusing `openExposureUsd` as the
shared denominator (option (a), pro-rata, per that change's design.md D9).
`settleCoverage` is one of the four named consumers: its per-guardian clamp
becomes `mine = _sharedSlashableUsd(g, reserved, priceX8, pv.executedAt)` (diff
hunk `@@ -1651,8 +1729,11`), and `_effectiveReservedTotal` (which `settleCoverage`
uses as its allocation denominator) gets the same treatment.

**Confirmed from the PR #158 diff: `settleCoverage`'s external signature, its
`executeBy` gate (:1602), its unpriceable-return branch, and the `_settled`
writes are all unchanged** — the only edit inside its body is the clamp line. This
change therefore composes with #158 purely through the unchanged external
interface; the self-trigger neither knows nor cares which clamp formula runs
inside. Re-verify on rebase (Sequencing section of proposal.md) only that this
remains true.

## D6 — Interaction with #43 (per-call capital declarations)

State at spec time: branch `feat/issue-43-per-call-capital` = `origin/main` + one
commit (`062e8c0`) adding the openspec change `per-call-capital-declarations`.
**Spec-only; no Solidity exists yet; no PR open.** Checked against its proposal
and design:

- #43 edits `propose`'s signature, `_resolveTierAndCoverage`'s coverage math, and
  the ARGUMENTS of the `executeGovernorBatch` calls inside `executeProposal`,
  `settleProposal`, `unstick`, `finalizeEmergencySettle`. It does not restructure
  `_finishSettlement`'s epilogue, `_finishSettlementHook`, or
  `reclaimProposerBond`. No textual or structural collision with this change's two
  insertion points.
- Semantic interaction: #43 re-prices `requiredCoverage` to the per-call sum. The
  ledger reads it through `getRequiredCoverage(proposalId)` (a view #43 keeps),
  so post-#43 the trigger collapses reservations to a SMALLER need — direction and
  mechanics unchanged.
- Because #43's implementation has not stabilized, this change records the
  dependency as a rebase checklist rather than assuming line stability: (1)
  trigger remains the last operation of `_finishSettlement` wherever that function
  ends up; (2) `reclaimProposerBond`'s tail unchanged; (3) `getRequiredCoverage`
  view signature unchanged. Sequencing: **#158 → #43 → #33 (this)**.

## D7 — What a repeated settlement attempt can and cannot do (summary table)

| Sequence | Outcome |
|---|---|
| settle before `executeBy` (proposer self-settle) → trigger skips → proposer reclaims bond after challenge window | reclaim trigger settles; provably past `executeBy` (D1) |
| settle after `executeBy` → trigger settles → reclaim later | second pass at reclaim re-derives same split (re-runnable); no double-apply |
| external `settleCoverage` first → settle/reclaim trigger after | converging passes; identical end state |
| trigger reverts (feed outage) at settle | `CoverageSettleFailed`; retried at reclaim; external call always available |
| settlement batch reverts pre-finalization, retried later | trigger never ran on the failed attempt (it sits after finalization); fires once on the successful one |
| bond forfeited by conviction | reclaim ack path skips the trigger; conviction slash path already reprices the cohort |
| no bond escrow wired AND settled early | documented residual (D1): external call / bucket expiry — the pre-change status quo |
