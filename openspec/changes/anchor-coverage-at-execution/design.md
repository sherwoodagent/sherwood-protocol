# Design: anchor-coverage-at-execution

## Context

See proposal.md for motivation. Verified state of current main (all line
numbers current as of `d6a1621`):

**The two sides of the seam:**

- `src/ExposureLedger.sol:534-536` — `_slashableBondUsd(guardian, priceX8)`
  returns `(swood.guardianStake(guardian) * priceX8) / 1e8`. LIVE:
  `StakedWood.guardianStake` (src/StakedWood.sol:584-586) returns
  `_guardians[g].stakedAmount`.
- `src/StakedWood.sol:1336-1384` — `_slashOne` recovers
  `slashBps × min(snapOwnRaw, live)` where `snapOwnRaw =
  max(_liabilityCheckpoints[g]@anchor, _stakeCheckpoints[g]@anchor)`
  (lines 1348-1352). The anchor is the caller's `openedAt` parameter.

**Who passes which anchor:**

- Verdict path: `src/ChallengeGame.sol:1094` passes `c.executedAt`, pinned at
  filing from the governor's `p.executedAt` (ChallengeGame.sol:604, 751).
  This anchor was moved from `filedAt` to `executedAt` by commit `4e2823c`
  (2026-07-27 21:41 UTC, PR #25 review fix F1) — AFTER issue #35 was filed
  (2026-07-27 02:30 UTC), which is why the issue's "verdict anchored at
  openedAt" wording is stale.
- Review path: `src/GuardianRegistry.sol:788` passes `r.openedAt`
  (= `openReview`'s `block.timestamp - 1`, GuardianRegistry.sol:724,733).
  Fires only when the review BLOCKS (`resolveReview`, line 778) — a blocked
  proposal never executes and never reaches any coverage consumer.

**Why the execute-time gate is already sound:**
`SyndicateGovernor.execute` stamps `proposal.executedAt = block.timestamp`
at src/SyndicateGovernor.sol:382 and calls
`requireApproveQuorum` at :429-430 in the same transaction.
`requireApproveQuorum` (ExposureLedger.sol:1195-1227) sums
`min(live bond, reserved)`; every sWOOD stake mutation pushes checkpoints
keyed `block.timestamp`, so the checkpoint at `executedAt` equals the live
stake the gate read. The WOOD the gate counted is exactly the WOOD
`_slashOne` can recover at the `executedAt` anchor. Additionally, the
degenerate PoC ("booked, reachable 0 when not staked at open") is dead:
`voteOnProposal` reverts on zero weight at `r.openedAt`
(GuardianRegistry.sol:451-452), so a guardian who was not staked at review
open cannot vote, and `recordApproval` (the only booking writer, called from
the vote at GuardianRegistry.sol:473/507) is never reached for it.

**The residual defect (confirmed):** four ledger reads run AFTER
`executedAt` and still price guardians at live stake:

1. `allocatedUsd` — ExposureLedger.sol:1339
2. `_effectiveTotal` — :1383 (feeds `liabilityUsd` :1356-1366, which
   `ChallengeGame.file` uses to size the challenger's bond,
   ChallengeGame.sol:720-735, and stores as `frozenCoverageUsd` :748)
3. `settleCoverage` — :1510
4. `_effectiveReservedTotal` — :1588

A guardian may call `stakeAsGuardian` at any time (StakedWood.sol:531 —
permissionless, only a pending unstake blocks it), so an accused approver
can top up between `executedAt` and file/settle. The settle-path natspec at
:1531-1533 claims the booking is bounded by "the most a conviction could
ever take" — false for post-execution top-ups.

**Reachable magnitude.** Per approver the overstatement is
`min(live·priceNow, reserved) − min(snap@executedAt·priceNow, reserved)`.
`reserved ≤ min(kNumerator·bond@vote·price@vote − openExposure, needUsd)`
(recordApproval, :930-944; `kNumerator` defaults to 1, owner-settable,
:185). With k = 1 it takes a WOOD price decline between vote and read to
open the gap: price falls by factor f, reachable drops to ≈ reserved·f, and
a top-up of `(1−f)/f × snap` WOOD restores the read to the full `reserved`
— at f = 0.5 half the counted coverage is unreachable, and as f → 0 the
unreachable share → 100% (bounded only by the attacker's willingness to
lock WOOD; the top-up is unslashable by this verdict yet exits only through
the normal cooldown + `CoverageStillOpen` gates). With k > 1 no price move
is needed. Cohort-level, the inflated figure saturates at `needUsd`
(`liabilityUsd`'s ceiling), which is also the ceiling on the challenger-bond
inflation: `bond = frozenCoverage × challengerBondBps`, so the attack can
raise a filing bond to its needUsd-priced maximum using capital the
conviction cannot touch.

**Constraints:** storage layouts of SyndicateGovernor, SyndicateFactory,
GuardianRegistry, and StakedWood are golden-pinned
(script/check-layout-goldens.sh:212-229). ExposureLedger is not pinned.
PR #114 (SyndicateVault/queue) and PR #98/#122 (StakedWood consent-gate,
far from slash logic) are open; neither touches these functions.

## Goals / Non-Goals

**Goals:**

- After `executedAt`, every per-proposal coverage figure the ledger produces
  is bounded by what `_slashOne` can recover at the `executedAt` anchor.
- One shared implementation of the slash basis, so ledger and sWOOD cannot
  drift (the class of bug this issue is).
- Zero storage changes in any contract; all four layout goldens byte-identical.
- Preserve — do not accidentally half-fix or invalidate — the standing
  analyses of #83 and #110 (see Decisions).

**Non-Goals:**

- Fixing the review-path (`openedAt`-anchored) slash sizing. It fires only
  on blocked proposals, where no coverage consumer exists and vote weight is
  snapshotted at the same `openedAt`; a post-open top-up buys neither weight
  nor coverage nor slash exposure there. The `min(snap@open, live)` clamp is
  the deliberate anti-over-slash design (StakedWoodSlashing.t.sol:425-427
  tests it as intended behavior).
- #83's fix (snapshot `committedUsd` into the `Case` at `refer`) and #110's
  fix (cap re-check on upward `_rebook`). Both remain necessary and are
  sequenced separately.
- Changing `requireApproveQuorum`'s behavior (already aligned; natspec only).

## Decisions

### D1 — Anchor the ledger's read (candidate (a)), not the quorum's use (candidate (b))

The task's candidate (b) — "cap `requireApproveQuorum`'s USE against the
anchor at read time" — is moot on current main: the gate already runs at the
anchor instant and is provably equal to the anchored read (Context). The
divergence lives in the post-execution readers, so the fix is candidate (a)
reshaped: make `_slashableBondUsd` anchor-aware and route the four
post-execution call sites through the anchored form. `recordApproval`'s
budget cap and the public `slashableBondUsd(guardian)` view stay live: before
execution there is no anchor, and any stake present at execution is
reachable — anchoring them at nothing would be meaningless, and at
`openedAt` would be wrong (it would exclude reachable pre-execution top-ups
and re-open the disenfranchisement failures reviews M3/N1/N4 removed).

### D2 — The anchored basis lives in StakedWood, next to `_slashOne`

New view on StakedWood:

```solidity
function slashableStakeAt(address guardian, uint256 anchor)
    external view returns (uint256);
// = min(max(liability@anchor, votableStake@anchor), stakedAmount)
```

with `_slashOne` refactored to size from the same internal helper
(`_slashableAt(guardian, anchor)`), so the view is the slash basis by
construction rather than by parallel maintenance. Alternative considered:
compose it in the ledger from `getPastStake` + a new liability getter —
rejected because it duplicates the `max(liability, votable)` +
`min(·, live)` logic in a second contract, which is exactly the
"two sites price the same bond differently" divergence class the codebase
already documents (ExposureLedger.sol:1250-1255). View-only: StakedWood's
golden is unaffected.

### D3 — The ledger learns `executedAt` through `ProposalViewLite`

Append `uint256 executedAt` to `ILedgerGovernorMinimal.ProposalViewLite`
(ExposureLedger.sol:26-32) and to `SyndicateGovernor.ProposalViewLite` /
`getProposalView` (SyndicateGovernor.sol:909-915). The governor already
stores `proposal.executedAt`; this is a memory-struct/ABI extension with no
storage change (governor golden unaffected). All four anchored call sites
already load `getProposalView` or can reach it; `_effectiveTotal` and
`_effectiveReservedTotal` gain an `anchor` parameter threaded from their
callers rather than re-reading the view per guardian. Alternatives
considered: (i) a separate `proposalExecutedAt(uint256)` getter — second
ABI surface for one field, rejected; (ii) the ledger stamping its own
anchor — requires a state write from the execute path (the quorum gate is a
view) or a new governor→ledger call, strictly more invasive, rejected.
Consumers of `getProposalView` are the ledger and test mocks only (verified
by sweep — src has zero other callers), so the ABI change is contained.

### D4 — Anchored form keeps the live clamp: `min(snap@executedAt, live)`

The anchored read clamps to live stake exactly as `_slashOne` does. Dropping
the clamp would book capital a concurrent conviction already burned —
overstatement in the opposite direction — and would change #83's zeroing
mechanics as a side effect (see D6). "Reachable now" is
`min(snap@anchor, live-now)`; a further live drop before the verdict can
only come from another slash, which is the deliberate no-double-recovery
min in `_slashOne` itself.

### D5 — `requireApproveQuorum` unchanged in behavior; alignment becomes documented invariant

The gate keeps its live read. Its natspec (and `SyndicateGovernor.execute`'s,
at the :382/:429 ordering) gains the invariant: the gate MUST run in the
transaction that stamps `executedAt`, after the stamp — that ordering is
what makes live == anchored at the only instant the gate is load-bearing.
Alternative (anchoring the gate too) is behavior-identical today but adds a
`getProposalView` round-trip to the hot execute path for no observable
difference; rejected on minimal-blast-radius grounds. If a future refactor
moves the gate out of the execute transaction, the documented invariant —
not silent luck — is what breaks.

### D6 — Explicit #83 interaction (checked against #83's CURRENT state)

#83 is no longer "no reachable trigger": its comment thread escalates it to
a reachable vulnerability — a concurrent 100%-severity conviction zeroes
`stakedAmount`; permissionless `settleCoverage` then reads `liveG == 0 →
mine == 0 → _rebook(key, g, 0)`; `_recordAccused` at `refer` skips the
zeroed guardian; the guardian votes on its own case at full pre-slash weight
(`TokenCourt` snapshots ballot weight at `executedAt - 1`). What #83's
chain assumes about THIS read is precisely that `settleCoverage`'s
per-guardian basis has a live term that a concurrent slash drives to zero.

Effect of this change on that chain, term by term:

- The zeroing route is PRESERVED. The anchored basis `min(snap@anchor,
  live)` retains the live clamp (D4), so `live == 0 → mine == 0` exactly as
  before. #83's reachable trigger is neither closed nor widened, and its
  Case-snapshot fix remains necessary. (It could not be closed here anyway:
  a WOOD price collapse zeroes `mine` through the price factor under either
  basis.)
- The LIFTING lever is REMOVED. #83 flagged, unverified, that a residue
  top-up could lift a zeroed booking back above zero. Under the anchored
  basis, post-execution capital no longer raises `mine`, so a booking can
  rise between settlement passes only via price recovery or re-staking
  after a full slash (`min(snap, live)` with pre-slash `snap` tracks the
  re-staked `live`) — both of which exist under the current live basis too.
  Net: this change strictly narrows the levers on #83's seam and changes no
  conclusion in it. There is one observable interaction: TokenCourt's
  accused filter reads `committedUsd`, and this change alters the
  post-execution rebook magnitudes — but membership is a zero/nonzero test,
  and every zero/nonzero transition route that exists after this change
  existed before it.
- Convergence note for #83's implementer: this change moves the ledger's
  booking basis to the same instant TokenCourt already snapshots ballot
  weight (`executedAt − 1` vs `executedAt` — one second apart by
  construction, ChallengeGame.sol:1080-1081). Snapshotting `committedUsd`
  into the `Case` at `refer` on top of anchored bookings yields two reads
  anchored at effectively one instant, which is the "one list read from one
  place" property the stale TokenCourt natspec claims today.

#110 (upward `_rebook` bypasses the batching cap, UPHELD) is likewise
preserved: its precondition 4 — `_effectiveReservedTotal` falls between
passes when a co-approver is slashed — survives, since the live clamp
stays. This change narrows precondition 4's other lever (top-ups no longer
move the total for executed proposals) but does not substitute for #110's
cap re-check.

### D7 — Natspec corrections ride along

- ExposureLedger.sol:1531-1533 ("the most a conviction could ever take") —
  true again under the anchored basis; reword to name the anchor.
- `liabilityUsd`'s "cannot drift apart" (:1346-1350) and `_effectiveTotal`'s
  discount rationale (:1368-1376) — name the anchored basis and its
  adversary (post-drain top-up pricing up its own prosecution), house style.

## Risks / Trade-offs

- [uint32 checkpoint lookup: `slashableStakeAt` casts `anchor` to uint32
  like `_slashOne` does] → same guard as `slashVerdict`: revert on
  `anchor > block.timestamp` in the view (mirrors `VerdictNotPast`,
  StakedWood.sol:1217) so a future-dated anchor cannot wrap the lookup.
- [Ledger→sWOOD call surface grows: anchored reads call `slashableStakeAt`
  per approver per read] → same cost class as the existing `guardianStake`
  staticcall; the price is still hoisted loop-invariant. Two checkpoint
  binary searches per guardian are added on post-execution paths only
  (views + permissionless settle), not on the vote or execute hot paths.
- [ABI change to `getProposalView` breaks mocks silently at decode] → the
  sweep found every implementer: test/ExposureLedger.t.sol:75-110,
  test/RegistryExposureHook.t.sol:48-83; update in the same commit.
  MockStakedWood (test/mocks/MockStakedWood.sol) and the inline sWOOD mock
  in test/ExposureLedger.t.sol:16-20 gain `slashableStakeAt`.
- [A proposal executed but never challenged: anchored settle books less
  than live would have] → deliberate — the booking's only teeth are the
  verdict; budget released early by a smaller booking is budget that was
  never recoverable collateral.
- [Behavior shift for honest top-ups: a guardian who tops up post-execution
  intending to strengthen coverage no longer moves the figures] → correct
  by construction (the verdict cannot reach it); honest capital counts for
  the next proposal's `recordApproval` instead.
- [Tests relying on live post-execution reads] → sweep found none that
  depend on the buggy direction: `test_allocatedUsd_excludesBondThatIsNoLongerThere`
  and `test_settleCoverage_survivesABondCollapseBeforeSettling` exercise the
  live clamp DOWNWARD (preserved by D4);
  `test_settleCoverage_cannotBePinnedAtAPriceTrough` and
  `test_approveQuorum_priceCrashShrinksCommittedShare` exercise price, not
  stake. StakedWoodSlashing.t.sol:425-427 tests the at-open clamp on the
  review path, untouched.

## Post-merge audit hardening (2026-08-03, Pashov review on PR #152)

A 12-agent Pashov security review of this change's merged diff found two
CONFIRMED findings against the anchoring mechanism this design introduced.
Both are hardening of the same seam, not a reopening of D1-D7 above.

### D8 — Same-block top-up into the anchor itself (finding 1, confidence 90)

**The gap.** `Checkpoints.Trace224.upperLookupRecent` is INCLUSIVE of
`key == anchor`. `stakeAsGuardian` has no guard against landing in the same
block as the event an anchor values, and TWO different callers pass
`_slashableAt`/`_slashOne` an anchor with different pre-conditions:

- `slashGuardians`' `openedAt` = `GuardianRegistry.openReview`'s
  `ts1 = block.timestamp - 1` — already hardened AT THE SOURCE against a
  same-block stake, by the identical `-1` pattern this design's own D1-D7
  narrative did not need to touch.
- `slashVerdict`'s `openedAt` / `slashableStakeAt`'s `anchor` — a RAW instant
  (`SyndicateGovernor.executeProposal`'s `executedAt`, forwarded verbatim by
  `ChallengeGame`/`ExposureLedger`), with NO caller-side offset. A same-block
  `stakeAsGuardian` pushes a checkpoint at exactly `key == anchor`, which the
  inclusive lookup then counts as if it existed AT the anchor — defeating
  this design's whole premise (D1: "any stake present at execution is
  reachable" was meant to describe PRE-existing stake, not stake added in the
  same instant the anchor is trying to exclude).

**Where the fix lives, and why not inside `_slashableAt`.** The first attempt
put `anchor - 1` inside the shared `_slashableAt` itself. That regressed six
pre-existing `StakedWoodSlashing.t.sol` tests: because `slashGuardians`'
`openedAt` is ALREADY `ts1`-offset by the time it reaches `_slashOne`, a
second `-1` inside the shared function double-shifts it, wrongly excluding a
checkpoint that genuinely existed AT `ts1` (one real second before review
opened). The correct fix pushes the offset to the two RAW-anchor callers
instead, leaving `_slashableAt`/`_slashOne` exactly as D2 specified:

- `slashableStakeAt(guardian, anchor)`: looks up `_slashableAt(guardian,
  anchor == 0 ? 0 : anchor - 1)`. `anchor == 0` passes through unchanged —
  that is the separate, pre-existing, out-of-scope "direct call returns ~0"
  landmine (no live caller reaches it: `ExposureLedger._slashableBondUsd`
  branches to live `guardianStake` before ever anchoring at 0).
- `slashVerdict(caseKey, openedAt, ...)`: computes `lookupAnchor = openedAt -
  1` once (after rejecting `openedAt == 0`, see the defense-in-depth note
  below) and passes `lookupAnchor` — not the raw `openedAt` — into
  `_slashOne`. `slashGuardians` is untouched: it still passes its own
  (already-hardened) `openedAt` straight through.

This mirrors the two existing precedents named in the original finding
(`SyndicateGovernor`'s collaboration snapshot, `GuardianRegistry.openReview`'s
`ts1`) at the CALL SITE that owns a raw anchor, rather than baking a second,
conflicting offset into a function shared with a caller that already applied
one.

**Defense-in-depth, same pass:** `slashVerdict` now reverts
`InvalidParameter()` on `openedAt == 0` (a real verdict never legitimately
anchors at the zero timestamp; pre-fix this silently no-opped — no revert, no
event — under a mis-built or compromised `authorizedSlasher` input).
`slashGuardians` is NOT given the same guard: `StakedWoodSlashing.t.sol`
already has a dedicated test (`test_slashGuardians_openedAtZero_
uninformativeSnapshot`) documenting the review path's `openedAt == 0` no-op
as deliberate, registry-driven behavior, and forcing a revert there would
contradict that existing, intentional test rather than harden an unreached
path.

### D9 — A guardian's shared stake was not reserved across open proposals (finding 2, confidence 85)

**The gap.** `_effectiveTotal`/`_effectiveReservedTotal` clamped a guardian's
contribution to ONE proposal independently — `min(reserved,
slashableBondUsd(g, anchor))` — using the guardian's CURRENT total
live/anchored stake with no awareness of what that SAME stake simultaneously
backs on every OTHER still-open, already-executed proposal. Two
individually-correct anchored reads could therefore sum to more than the
guardian's one, finite, shared recoverable pool (proved: two $400
reservations against a guardian later slashed to $600 live both
independently reported $400 "recoverable" — $800 claimed against $600 real).
This requires no privileged action: it fires from ordinary multi-proposal
operation combined with an unrelated conviction landing in between.

**Options considered** (per the audit's own framing): (a) pro-rata
distribution of the shared basis across every open proposal reserving
against the guardian; (b) first-settled-proposal-wins; (c) an explicit
per-guardian "committed-but-not-yet-recovered" escrow subtracted before every
clamp.

**Decision: (a), implemented by REUSING `openExposureUsd`, not a new ledger.**
`ExposureLedger` already maintains, for every guardian, exactly the
denominator this needs: `openExposureUsd(g)` sums `_buckets[g][epoch]` across
every currently-open proposal's booking (`_recorded[key][g].usd`), bounded by
the same `MAX_SCAN_BUCKETS` walk `_rebook`'s #110 cap-recheck already pays
for. A new internal helper, `_sharedSlashableUsd(guardian, reserved, priceX8,
anchor)`, computes `share = slashable * reserved / openExposureUsd(guardian)`
clamped to `reserved`, and replaces the bare `min(reserved, slashable)` clamp
in `_effectiveTotal`, `_effectiveReservedTotal`, `allocatedUsd`'s own
per-guardian term, and `settleCoverage`'s own per-guardian term. Two
proposals reading independently read the SAME `openExposureUsd(g)`
denominator, so their shares sum to at most the guardian's one `slashable`
basis — never more.

Rejected (b) and (c): (b) makes the reported figure depend on read order,
which is exactly the "figure a challenger is charged against must not drift
from the figure a conviction takes" property `liabilityUsd`'s own natspec
already promises; picking whichever proposal happens to be read/settled
first as the "winner" reintroduces that drift. (c) requires new per-guardian
storage (a cumulative-claimed counter) with its own decay/release
bookkeeping to avoid permanently starving a guardian after a proposal
resolves — solving a problem `_buckets`/`openExposureUsd` already solve via
wall-clock bucket expiry. (a) via the existing bucket sum was strictly
cheaper (one extra `openExposureUsd` view call, itself O(16)) and required no
new storage, so it was preferred per "pick whichever is simplest to implement
correctly and cheapest in gas."

**Why it generalizes to N proposals, not just two.** `openExposureUsd`
already sums over every bucket in its scan window regardless of how many
proposals fed them; the fix's cost and correctness argument are identical for
2 or 20 simultaneously-open proposals for the same guardian.

**Why a guardian with one open proposal sees no change.** When
`openExposureUsd(g)` equals exactly the one `reserved` term being read (the
common case — no other open commitment), the ratio reduces algebraically to
`slashable` unscaled: byte-identical to the pre-fix `min(reserved,
slashable)`. Verified against every pre-existing multi-proposal test in
`ExposureLedger.t.sol` (`test_settleCoverage_reRunCannotPushAGuardianPastItsCap`,
`test_settleCoverage_upwardRebookStopsAtTheRemainingHeadroom`) by hand-tracing
the exact arithmetic both call sites still had to satisfy — both continue to
pass unmodified.

**Known residual asymmetry, accepted.** `_effectiveReservedTotal`/
`settleCoverage` read `reserved` from `_reservedUsd` (the PLEDGE, fixed at
`recordApproval` and unchanged by settlement), while `openExposureUsd` sums
`_recorded` (the current BOOKING, which a settle pass can write down below
the pledge). When a guardian's pledge on one proposal exceeds its currently
booked total across all proposals — which only arises after that proposal's
OWN first settle has already written its booking down — the ratio can exceed
1 and gets clamped back to `reserved`, i.e. the PRE-fix behavior for that one
term. This never regresses below what existed before (same value, not a
smaller one) and only recurs in the narrow re-settle-after-partial-settle
window `_rebook`'s existing #110 cap-recheck already bounds separately; a
fully general pledge-basis sharing ledger would close it completely but was
judged not worth the added storage for a window that degrades no worse than
pre-fix.

**Invariant (also stated as a code comment above `_sharedSlashableUsd`):**
for any guardian g, the sum over all currently-open anchored proposals of
that proposal's claimed-recoverable-from-g must never exceed g's actual
live/anchored recoverable stake. Proven with a dedicated adversarial test
reproducing the audit's own numeric trace
(`test_finding2_sharedStakeAcrossOpenProposalsNeverOversumsTheRealRecoverableBond`),
plus a regression guard for the single-open-proposal case
(`test_finding2_singleOpenProposalIsUnaffectedByTheSharedStakeFix`).

## Migration Plan

Pure code + view additions; no storage migration, no golden regeneration
(`./script/check-layout-goldens.sh` must pass UNCHANGED — a golden diff in
this change is a bug). Deploy order unaffected (no new wiring). Rollback is
a revert of the code change.

## Open Questions

None.
