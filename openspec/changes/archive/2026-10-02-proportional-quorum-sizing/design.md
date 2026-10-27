# Design: coverage-proportional proposal sizing (issue #27)

## Context

Verified on main @ 388460c (2026-08-03):

- `requireApproveQuorum` (src/ExposureLedger.sol:1298-1334): `external view`,
  computes `needUsd = coverageUsd(asset, requiredCoverage)` (USD-18), reverts
  `InsufficientApproveCoverage` at :1306 when the approver list is empty, sums
  `haveUsd += min(live, reserved)` per approver with a LIVE (`anchor = 0`)
  `_slashableBondUsd` read, early-returns once `haveUsd >= needUsd`, and falls
  through to `revert InsufficientApproveCoverage()` at :1334.
- `SyndicateGovernor.executeProposal` gates through it at :447 (only when
  `ledger != address(0) && requiredCoverage != 0 && envelopeTier >=
  quorumTierThreshold`) and passes raw `proposal.maxCapital` to
  `executeGovernorBatch` at :453; `settleProposal` passes the same raw figure
  at :476. These are the ONLY two `executeGovernorBatch` call sites in the
  governor on main.
- **Neither PR #152 (merged #35 fix) nor PR #158 (open #154 fix) touched
  `requireApproveQuorum`'s body.** PR #152's design D5 records the gate as
  deliberately unchanged ("keeps its live read... natspec documents that
  alignment invariant as load-bearing"); PR #158's diff contains no hunk in
  the function — it rewires `_effectiveTotal`, `_effectiveReservedTotal`,
  `allocatedUsd`, and `settleCoverage` through the new `_sharedSlashableUsd`
  pro-rata helper (its design D8/D9). This issue's control-flow rewrite is
  therefore clear to spec against the current shape.
- `coverageUsd(asset, amount)` (:842) returns USD-18
  (`amount * price * 1e18 / 10^assetDec / 10^feedDec`), same scale as
  `_slashableBondUsd`'s output, so `haveUsd` and `needUsd` are directly
  comparable and their ratio is dimensionless.
- `requiredCoverage` is ASSET-denominated: `_resolveTierAndCoverage` computes
  `coverage = maxCapital * (execBps + settleBps) / 10_000` (:1162), i.e.
  `maxCapital * Σ boundBps / 10_000` in vault-asset units.

## D1 — New `requireApproveQuorum` signature: return BOTH figures, stay `view`

```solidity
function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage)
    external
    view
    returns (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd);
```

- `requiredCoverageUsd` is `coverageUsd(asset, requiredCoverage)` — already
  computed first thing in the function. Returning it alongside the raised
  figure gives the governor the complete ratio from ONE external call and ONE
  feed read; making the governor call `coverageUsd` separately would double
  the feed reads and open a (theoretical, same-tx) two-read inconsistency for
  zero benefit.
- `coverageRaisedUsd` is the loop's existing `haveUsd` accumulator. The
  quorum-reached early exit is KEPT: once `haveUsd >= needUsd` the function
  returns immediately with a possibly-clamped surplus. That is sound because
  the consumer computes `min(1, haveUsd/needUsd)` — surplus never raises the
  cap above the declared `maxCapital`, so an exact surplus figure buys
  nothing and the early exit keeps the gas profile of the common
  (fully-covered) case unchanged.
- The function stays `view`. The governor does the storing; the ledger stays
  a pure measurement. This also keeps every existing test harness pattern
  (direct static calls) working.
- The name is retained despite no longer being purely a "require": it still
  reverts on the zero floor (D2), one production call site exists, and the
  churn of renaming across ~40 test call sites buys no clarity that natspec
  cannot. (Implementer MAY rename to `approveCoverage` if review prefers;
  the spec delta pins semantics, not the identifier.)
- **ABI impact**: return types are not part of the function selector, so the
  4-byte selector is unchanged. Solidity high-level callers compiled against
  the OLD interface ignore extra returndata on a call declared to return
  nothing — existing deployed callers (there are none live: no chain-4663
  deployment, see proposal Impact) and un-recompiled integrations do not
  break at the call level. Off-chain ABI consumers (indexers, scripts)
  regenerate. Callers enumerated on main: `SyndicateGovernor.sol:447`
  (production, updated by this change); `test/ExposureLedger.t.sol` (~30
  sites) and `test/CoverageEndToEnd.t.sol` (3 sites) — mechanical updates;
  no other `src/` caller (grep-verified; `WoodTwapOracle.sol:42` mentions the
  name in a comment only).

## D2 — The revert set that survives: empty set AND zero aggregate

Two reverts remain, both `InsufficientApproveCoverage`:

1. `n == 0` (:1306 today) — a genuinely empty approver set. Kept verbatim
   per the owner's decision.
2. `coverageRaisedUsd == 0` with `n > 0` — every listed approver's
   reservation was released (vote changes) or its live bond is worthless.
   This is the SAME promise the current natspec makes ("Zero committed
   coverage ALWAYS reverts, even at zero required coverage — a tier-gated
   proposal requires an identified signer") and the same R1 floor the issue
   itself demands ("Zero coverage -> zero effective ceiling. Nothing of value
   moves without an identified, slashable approver."). Reverting is strictly
   better than returning 0 and letting the governor execute a
   zero-effective-cap batch: a zero-cap execution starts the strategy clock,
   burns the cooldown, accrues management fees against a position that can
   hold nothing, and consumes the proposal — all pure waste. Zero coverage
   is an error, not a size.

Partial-but-nonzero coverage RETURNS — that is the entire point of the
change. No `minViableCapital` proposer floor ships in this pass: the owner's
2026-08-03 decision selected plain option A (the floor was an alternative
raised in earlier triage, option (b) of the overnight-loop comment, and was
not adopted). Recorded as future work; a proposer who considers a scaled-down
size non-viable can simply not execute (execution is permissionless but the
proposal expires at `executeBy` untouched) or cancel.

## D3 — The exact formula, dimensionally checked

The issue's shorthand `effectiveMaxCapital = min(maxCapital,
coverageRaisedUsd * 10_000 / boundBps)` does not survive dimensional
analysis as written: `coverageRaisedUsd` is USD-18 while `maxCapital` is
vault-asset units, and "boundBps" is not a single number — coverage is
`maxCapital * Σ boundBps / 10_000` summed over execute AND settlement calls
(and becomes `Σ cap_i * boundBps_i / 10_000` after #43). The dimensionally
correct general form is the RATIO form, which this change pins:

```
s                   = min(1, coverageRaisedUsd / requiredCoverageUsd)   // dimensionless, both USD-18
effectiveMaxCapital = floor(maxCapital * coverageRaisedUsd / requiredCoverageUsd), clamped to maxCapital
                    = maxCapital                                        when coverageRaisedUsd >= requiredCoverageUsd
```

Equivalence with the issue's intent: `requiredCoverageUsd` is linear in
`requiredCoverage` (a price multiplication), and `requiredCoverage` is linear
in `maxCapital` (`* Σ boundBps / 10_000`), so
`maxCapital * haveUsd / needUsd == usdToAsset(haveUsd) * 10_000 / Σ boundBps`
— the issue's formula, generalized to the real multi-call `Σ boundBps` and
with the USD->asset conversion made explicit. The ratio form needs no second
feed read and no re-derivation of `Σ boundBps` at execute.

Rounding: FLOOR, matching `coverageUsd`'s own floor discipline — the
effective cap errs to the small side, never above what was covered. Overflow:
`maxCapital <= totalAssets() * maxCapitalBps / 10_000` at propose and
`coverageRaisedUsd <= needUsd` in the scaling branch (the branch only runs on
shortfall), so the product is bounded by `maxCapital * needUsd`; use
`Math.mulDiv` if the implementer wants belt-and-braces, but plain
`a * b / c` is safe at any remotely realistic scale (asset units ~1e30 max
times USD-18 ~1e30 max is < 2^256).

Gate condition unchanged: the quorum (and therefore the sizing) runs only
when `ledger != address(0) && requiredCoverage != 0 && envelopeTier >=
quorumTierThreshold`. The `requiredCoverage == 0` optimistic-passage path and
the no-ledger path are not resized (D5).

## D4 — Option A: store at execute, reuse at settle (owner decision, do not re-litigate)

`effectiveMaxCapital` is computed ONCE, in `executeProposal`, stored on the
proposal, and `settleProposal` reuses the stored value.

Rejected — option B, recompute live at both call sites: coverage can
legitimately drop between execute and settle (a guardian withdrawing after
the coverage horizon, or slashed on an UNRELATED proposal's conviction). A
live recompute at settle would then cap the settlement batch BELOW the size
the position legitimately deployed at execution — stranding capital in a
position it can no longer unwind at full size. An honest unwind is
net-INFLOW (the settle cap exists only to stop a malicious proposer who
parked extraction in `settlementCalls`), so under-capping settle punishes
exactly the honest path while the attack it guards against is already
bounded by the execute-time figure. One cap for the strategy's whole
lifecycle is the correct invariant; the cost is one appended storage field.

Storage shape:

- New field `uint256 effectiveMaxCapital` appended to
  `ISyndicateGovernor.StrategyProposal` as the LAST member, after
  `proposerBondLedger`, below the existing "APPENDED FIELDS ONLY BELOW
  (beacon-upgraded governors; storage parity)" divider. The struct is the
  value type of the `_proposals` mapping; appending a member changes only the
  struct type's size in the layout's `types` section — no existing member's
  slot/offset moves. `script/syndicate-governor-layout.golden.json` is
  regenerated and the diff reviewed as append-only (tasks §5).
- Deployment reality, re-verified in this worktree rather than trusted:
  `broadcast/` contains ONLY `8453`, `84532`, `46630` chain directories
  across all scripts — no `4663` entry anywhere, so no governor beacon proxy
  exists on the target chain and there are no live proposals whose storage a
  reordering could corrupt. The Base 8453 lineage is legacy/no-upgrades by
  standing decision (its vault impl has 18 bytes of EIP-170 headroom and
  takes no upgrades). The field is therefore purely additive TODAY — but the
  append-only discipline is followed anyway because the struct's own comment
  makes it a standing rule, not a per-deployment judgment.

## D5 — `effectiveMaxCapital` is ALWAYS written at execute; 0 never means "unset" after execution

`executeProposal` stores the field on every path, not only when the quorum
gate runs:

- Gate runs (ledger wired, `requiredCoverage != 0`, tier at/above
  threshold): store the D3 formula's result.
- Gate skipped (no ledger, `requiredCoverage == 0`, or tier below
  threshold): store `maxCapital` unchanged — nothing measured coverage, so
  nothing scales.

`settleProposal` then reads `proposal.effectiveMaxCapital` unconditionally.
Because the field is written on every execute path and no pre-change
proposals exist on any live chain (D4), settle never observes the zero
default on an `Executed` proposal; an implementer MAY add a defensive
`effectiveMaxCapital == 0 ? maxCapital : effectiveMaxCapital` read, but the
spec does not require the fallback and tests pin the always-written
behavior.

Floor-to-zero: with dust coverage, `floor(maxCapital * haveUsd / needUsd)`
can be 0 while `haveUsd > 0`. The batch then runs under a zero net-outflow
cap: calls may run but nothing of value may leave. This is fail-closed and
accepted (it mirrors #43's D7 position that a cap flooring to zero
"disables that call's outflow entirely — fail-closed and correct"); the
proposer's remedy is more coverage or cancellation. Tests pin it.

New event, emitted at execute on every path:

```solidity
event EffectiveMaxCapitalSet(
    uint256 indexed proposalId,
    uint256 declaredMaxCapital,
    uint256 effectiveMaxCapital,
    uint256 coverageRaisedUsd,     // 0 when the gate was skipped
    uint256 requiredCoverageUsd    // 0 when the gate was skipped
);
```

Voters priced `maxCapital`; indexers, guardians, and the proposer must be
able to see the size the strategy ACTUALLY ran at without replaying ledger
state. `getRiskEnvelope` keeps returning the DECLARED envelope (it documents
the proposer's declaration); a new view `getEffectiveMaxCapital(uint256
proposalId) returns (uint256)` exposes the stored figure (0 before
execution).

## D6 — Interplay with PR #158's shared-stake model (D8/D9): the gate's per-term read is deliberately NOT pro-rated

PR #158 (issue #154) routes the POST-execution read family —
`_effectiveTotal`, `_effectiveReservedTotal`, `allocatedUsd`,
`settleCoverage` — through `_sharedSlashableUsd(guardian, reserved, priceX8,
anchor)`, which pro-rates a guardian's slashable basis across every open
proposal it backs (`share = slashable * reserved / openExposureUsd(g)`,
clamped to `reserved`), enforcing: the sum of claimed-recoverable-from-g
across open proposals never exceeds g's one real bond. It did NOT touch
`requireApproveQuorum`, whose per-term read stays `min(live slashableBondUsd
(anchor 0), reserved)` — unshared.

This change KEEPS the gate's unshared read for the returned
`coverageRaisedUsd`. Reasons:

- **The gate is an eligibility/sizing measurement, not a recovery claim.**
  PR #158's invariant governs what convictions can RECOVER; the execute-time
  figure answers "how much bonded conviction stands behind this proposal
  now". PR #152's D5 made the gate's live-read/anchored-read agreement at
  the `executedAt` instant a documented, load-bearing invariant — rebasing
  the gate onto the shared basis would change its semantics beyond this
  issue's scope and disturb that invariant's test surface.
- **The residual is not new and not worsened.** Under a shared read, a
  guardian backing two open proposals would size BOTH down even when each is
  fully reserved — a liveness regression this issue exists to remove, in
  exchange for closing a sizing overlap that the CURRENT binary gate already
  permits in full (today both proposals pass at 100% against the same bond;
  after this change both still size at most as they do today). The
  recovery-side invariant — the one with a safety claim attached — is
  enforced by #158 regardless of what the sizing read says. This mirrors
  #158's own D9 precedent of accepting a bounded residual asymmetry
  (pledge-basis vs booking-basis) rather than building a general sharing
  ledger at the wrong layer.
- Accepted and recorded: two simultaneously-open proposals sharing a
  guardian can, combined, deploy more than that guardian's single bond
  covers. That is exactly today's exposure under the binary gate, bounded by
  the same reservation bookkeeping (`recordApproval` books against a
  guardian's free budget, which already prevents unbounded stacking), and
  the depositor-facing claim holds per proposal at execution time.

RE-VERIFY AT IMPLEMENTATION (tasks §0): if PR #158 merges with a different
shape — in particular if review pushes `_sharedSlashableUsd` into the gate —
re-derive this decision against the landed code; if the gate's per-term read
becomes shared, the returned `coverageRaisedUsd` inherits it and this
section's residual paragraph is moot.

**RE-VERIFIED (2026-08-03, this implementation): the gate IS shared.** This
assumption was WRONG as written — not because PR #158 itself touched the gate
(it didn't; PR #152/#158's diffs have no hunk in `requireApproveQuorum`, as
D1/D6 above record), but because a POST-MERGE follow-up commit
(`0ea33d6`, "fix(guardian-coverage): remediate 4 PR #158 audit findings",
landed same-day ahead of this implementation) routed
`requireApproveQuorum`'s per-term read through `_sharedSlashableUsd` to close
Pashov re-audit finding [88] — exactly the residual this section flagged as
"accepted." Per this section's own instruction, the residual paragraph above
is now moot: `coverageRaisedUsd` inherits the shared/pro-rated basis, and this
change's implementation consumes whatever `haveUsd` the gate produces without
caring which basis it used — D1's signature and D2's revert set are
unaffected either way. Confirmed via `test_finding1_requireApproveQuorum_sharedAcrossOpenProposals`
in `test/ExposureLedger.t.sol`, updated for issue #27 (nonzero dilution now
sizes instead of reverting) and passing against the shared-read gate.

## D7 — Consuming #43's per-call caps (spec'd against `per-call-capital-declarations` @ 062e8c0, UNMERGED — re-verify)

#43's openspec change records the exact seam for this issue (its design.md
D7). What this change consumes, verbatim from that record:

1. `getCallCaps(uint256 proposalId) external view returns (uint256[] memory
   executeCallCaps, uint256[] memory settlementCallCaps)` — the stored,
   immutable propose-time declarations.
2. Linearity: `requiredCoverage` is linear in the cap vector;
   `coverage(floor(s * caps)) <= s * coverage(caps)` — pro-rata scaling of
   caps scales coverage by the same factor, never upward. So the SAME `s =
   coverageRaisedUsd / requiredCoverageUsd` that scales `maxCapital` scales
   every cap: `effectiveCap_i = floor(cap_i * coverageRaisedUsd /
   requiredCoverageUsd)`.
3. Caps are batch ARGUMENTS (`executeGovernorBatch(calls, callCaps,
   maxNetOutflow)`-shaped; the vault and lib never read proposal storage), so
   this change alters only WHICH numbers the governor passes.

The two edges #43's record obliges this change to handle, and how:

- **Rounding re-assert.** Term-wise floors do not automatically keep
  `Σ effectiveCaps <= effectiveMaxCapital` (the batch bound is itself
  floored). After scaling, the governor SHALL re-assert the sum per batch
  and, on violation, clamp the LARGEST scaled cap down by the excess
  (deterministic, single-term, preserves as much of the batch as possible;
  the excess is at most `numCalls - 1` asset-wei by the floor bound, so the
  clamp is dust-sized). A scaled cap that floors to zero stays zero —
  fail-closed per #43's own record.
- **Settlement symmetry, persisted.** The settlement caps SHALL be scaled by
  the same factor AT EXECUTE and PERSISTED (appended governor mapping
  `_effectiveSettlementCallCaps[proposalId]`, same appended-storage
  discipline as #43's caps mappings — its D7 explicitly leaves this seam),
  so `settleProposal` weeks later passes byte-identical caps with no live
  recompute. Persisting the SCALED CAPS rather than the scale factor avoids
  re-running division (and its rounding) at settle. The execute-leg scaled
  caps need no persistence — they are computed and consumed in the same
  call.

If #43 lands with a different seam (interface name, caps-in-storage-read-by
-vault, different meter semantics), THIS section moves, not the core: D1-D6
are independent of #43 (they operate on `maxCapital` and the coverage ratio
alone). Tasks §0 pins the re-verification. Until #43 lands, the spec deltas
in this change describe the cap-vector scaling conditionally ("when per-call
capital declarations are in force").

**RE-VERIFIED (2026-08-03, this implementation): #43 landed exactly as
assumed here**, as PR #180 (`feat/issue-43-per-call-capital-rebased`):
`getCallCaps(uint256) -> (uint256[] memory executeCallCaps, uint256[] memory
settlementCallCaps)`, caps threaded as batch ARGUMENTS through
`executeGovernorBatch(calls, callCaps, maxNetOutflow)`, `Σ executeCallCaps <=
maxCapital` and `Σ settlementCallCaps <= maxCapital` validated separately per
batch at propose (`SyndicateGovernor._validateAndStoreBatch`). Given the clean
match, this change implements the FULL scaling described above (not deferred
as a follow-up): `_deriveAndStoreEffectiveCapital` scales both leg's caps by
the same ratio via `_scaleCaps` (which includes the largest-cap-clamp
re-assert, provably a no-op given the propose-time `Σ caps <= maxCapital`
invariant but kept as defense-in-depth per this section's own instruction),
and persists the scaled settlement caps in a new appended mapping
`_effectiveSettlementCallCaps`. Covered by
`test_execute_perCallCapsScaleByTheSameCoverageRatio` in
`test/GovernorCoverageGates.t.sol`.

## D8 — Ledger liability and settlement denominators do NOT scale

`liabilityUsd`, `allocatedUsd`, `settleCoverage`, and the challenge game keep
pricing from the propose-time `requiredCoverage` (via
`getRequiredCoverage`). Not scaling them is deliberate:

- The slash is PUNITIVE, NOT COMPENSATORY (the ledger's own natspec): the
  slash rate does not depend on the size of the loss, so a smaller executed
  size does not overstate anyone's punishment — conviction slashes at the
  severity ceiling either way.
- Reservations were booked at declared coverage by `recordApproval`;
  `settleCoverage`'s existing over-reservation release already collapses the
  cushion to pro-rata allocations after the execution window. An
  80%-executed proposal against a 100% liability denominator only leaves the
  cohort MORE bonded per deployed dollar — conservative in the safe
  direction.
- Scaling the denominators would couple this change into exactly the
  #154-hardened accounting (`_effectiveTotal` et al.) that PR #158 just
  settled, for no safety gain.

Interaction with #33 (settleCoverage self-trigger): none — #33 changes WHEN
settleCoverage runs, not the figures; both compose with the unscaled
denominators.

## Sequencing and re-verification ledger

Order: **PR #158 (issues #35/#154) -> #43 -> this change.** Both
predecessors' shapes are assumptions of record:

| Assumption | Source | Re-verify before implementing |
|---|---|---|
| `requireApproveQuorum` body untouched by #152/#158; live unshared per-term read | PR #152 design D5; PR #158 diff (no hunk) | `git log -L` on the function after #158 merges; if touched, re-derive D1/D6 |
| Post-execution reads pro-rated via `_sharedSlashableUsd`; gate excluded | PR #158 design D8/D9 | Confirm merged design.md D8/D9 text unchanged |
| `getCallCaps(uint256) -> (uint256[], uint256[])`; caps as batch arguments; coverage linear in caps | #43 change `per-call-capital-declarations` @ 062e8c0 (unmerged) | Diff #43's landed spec against D7 here; adjust scaling/persistence plumbing only |
| No chain-4663 broadcast entries; Base legacy no-upgrades | this worktree's `broadcast/` (2026-08-03) | Re-list `broadcast/` — if a 4663 governor deployment appeared, the append-only rule becomes load-bearing (it is followed either way) |
| `syndicate-governor-layout.golden.json` reflects pre-#43 layout | main @ 388460c | Regenerate AFTER rebasing onto #43 (its two mappings + parameter land first) |
