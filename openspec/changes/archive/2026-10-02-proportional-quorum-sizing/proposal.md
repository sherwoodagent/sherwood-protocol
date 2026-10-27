# Coverage-proportional proposal sizing — an 80%-covered proposal runs at 80% size (issue #27)

## Why

**The approve quorum is a cliff with no safety rationale.** `ExposureLedger.requireApproveQuorum` (src/ExposureLedger.sol:1298-1334 on main @ 388460c) sums each covering approver's `min(live slashableBondUsd, reserved)` and early-returns once the aggregate clears `needUsd`; otherwise the loop falls through to `revert InsufficientApproveCoverage()`. There is no partial-size path. `SyndicateGovernor.executeProposal` (:453) and `settleProposal` (:476) then pass the raw declared `proposal.maxCapital` to `executeGovernorBatch` regardless. A proposal that raises **80% of its required coverage does not run at 80% size — it does not run at all.**

With a small guardian cohort that is the common case, not an edge case, and #37's surviving half made it bite at every tier: `quorumTierThreshold == 0` is pinned by DeployPlanB PRE-FLIGHT 4, so a covering quorum is required for every coverage-consuming proposal, while the tier-2 envelope cap that would have made tier-2 coverage affordable was dropped (owner decision 2026-07-31). For uncertified targets — priced at full notional — the cliff is the default path. Issue #42 ranks *cohort never forms* as the joint-highest launch risk; this is the mitigation that does not require the cohort to exist first.

80% coverage is 80% of the protection, not zero. Coverage protects by compensating-after (needs a challenge, a court, a conviction — and the slash is punitive, not compensatory); a spending ceiling protects by preventing, which needs none of those. Sizing by coverage makes the depositor-facing claim precise and true without a working court: **nothing can move beyond what guardians have staked against it.**

**Owner decision (2026-08-03): option A.** Derive `effectiveMaxCapital` at execute time, **store it on the proposal**, and reuse the stored value at settle. Option B (recompute live at both call sites) was rejected because coverage can drop between execute and settle (a guardian withdrawing, or slashed on an unrelated proposal), which would cap settlement BELOW what the position legitimately deployed at execution — stranding capital in a position it can no longer unwind at full size. Full rationale in design.md D4.

## What Changes

- **`ExposureLedger.requireApproveQuorum` stops reverting on a shortfall and returns the coverage figures instead.** New signature (design.md D1): `function requireApproveQuorum(address governor, uint256 proposalId, address asset, uint256 requiredCoverage) external view returns (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd)` — both USD-18, from the same price read. The `n == 0` revert stays, and so does its generalization: a summed coverage of zero still reverts `InsufficientApproveCoverage` (a genuinely uncovered proposal is an error, not a partial success — R1's identified-bonded-signer floor, design.md D2). The quorum-reached early exit is preserved; a clamped surplus report is harmless because the scale factor clamps at 1.
- **`IExposureLedger.sol:91` gains the return values.** ABI note: return types do not enter the selector, so the on-chain selector is unchanged and existing high-level callers that expect no return data are unaffected (extra returndata is ignored); off-chain ABI consumers regenerate. Caller enumeration (design.md D1): ONE production call site — `SyndicateGovernor.executeProposal` (src/SyndicateGovernor.sol:447) — plus test call sites in `test/ExposureLedger.t.sol` and `test/CoverageEndToEnd.t.sol`. No other `src/` contract calls it (verified by grep; `WoodTwapOracle.sol:42` is a comment reference only).
- **`SyndicateGovernor.executeProposal` derives and stores the effective cap.** `effectiveMaxCapital = maxCapital` when `coverageRaisedUsd >= requiredCoverageUsd`, else `floor(maxCapital * coverageRaisedUsd / requiredCoverageUsd)` — the ratio form of the issue's `min(maxCapital, coverageRaisedUsd * 10_000 / boundBps)`, corrected for units (the issue's shorthand mixes USD with asset units and a single `boundBps` that is actually a per-call sum; design.md D3 carries the dimensional analysis). Stored in a new `uint256 effectiveMaxCapital` field APPENDED to `StrategyProposal` (after `proposerBondLedger`, below the struct's "APPENDED FIELDS ONLY BELOW" line). When the quorum gate does not run (no ledger wired, or `requiredCoverage == 0`), `effectiveMaxCapital := maxCapital` is stored anyway so settle-side reads never see 0-means-unset ambiguity (design.md D5). The execute batch runs under the effective cap; a new event `EffectiveMaxCapitalSet(proposalId, declaredMaxCapital, effectiveMaxCapital, coverageRaisedUsd, requiredCoverageUsd)` makes the sizing auditable.
- **`settleProposal` reuses the stored value** — the settlement batch runs under the SAME `effectiveMaxCapital` as execution, however much later it runs and however coverage moved in between.
- **Per-call caps (issue #43, must land first) scale by the same factor.** Consuming #43's recorded seam (its design.md D7): read `getCallCaps(proposalId) -> (executeCallCaps[], settlementCallCaps[])`, scale every cap by `coverageRaisedUsd / requiredCoverageUsd` (floor; exact because coverage is linear in the cap vector), re-assert `Σ effectiveCaps <= effectiveMaxCapital` after floor-rounding, and persist the scaled settlement caps at execute so settlement scales identically weeks later. Design.md D7 here; flagged as dependent on #43's landed shape.
- **Storage golden regenerated**: `script/syndicate-governor-layout.golden.json` — append-only diff (the new struct member extends the `StrategyProposal` type entry; no existing slot/offset/label may change), with an explicit review-the-diff task.
- **No change to the ledger's liability/settlement denominators** (`liabilityUsd`, `settleCoverage`, `allocatedUsd` keep pricing from the propose-time `requiredCoverage`): slashing is punitive, not compensatory — the rate does not depend on deployed size — and reservations were booked at declared coverage; `settleCoverage`'s existing over-reservation release handles the cushion (design.md D8).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `guardian-coverage`: "Execute-time approve quorum" becomes a measurement that reverts only on zero coverage — it reports raised-vs-required instead of gating all-or-nothing.
- `syndicate-governor`: "Execution safety guards" derives, stores, and executes under the coverage-proportional effective cap; "Settlement and P&L" settles under the stored effective cap; a new requirement "Coverage-proportional effective capital" pins the derivation, storage, and reuse semantics.

## Impact

- `src/ExposureLedger.sol` — `requireApproveQuorum` control flow (revert-on-shortfall -> return-the-figures); natspec rewrite (the "eligibility floor" framing becomes "sizing measurement with a zero floor").
- `src/interfaces/IExposureLedger.sol:91` — declaration gains the two return values.
- `src/SyndicateGovernor.sol`, `src/interfaces/ISyndicateGovernor.sol` — `StrategyProposal.effectiveMaxCapital` (appended), derivation + storage in `executeProposal`, reuse in `settleProposal`, `EffectiveMaxCapitalSet` event, `getEffectiveMaxCapital(proposalId)` view; post-#43: cap-vector scaling + persisted scaled settlement caps.
- `script/syndicate-governor-layout.golden.json` — regenerated, append-only.
- Tests: `test/ExposureLedger.t.sol` (every `requireApproveQuorum` call site — mechanical: the reverting cases keep `vm.expectRevert`, the passing cases may assert the returned pair), `test/GovernorCoverageGates.t.sol`, `test/CoverageEndToEnd.t.sol`, plus the issue's four obligations (see tasks.md §6).
- Deployment reality (verified 2026-08-03, this worktree): `broadcast/` has entries only for chains 8453, 84532, 46630 — **no chain-4663 entry exists**, so no governor beacon proxy is live on the target chain; the Base 8453 lineage is legacy/no-upgrades by standing decision. The appended field is additive with no same-slot placeholder needed. The append-only discipline is followed anyway (the struct's own comment warns reordering corrupts upgraded governors' proposals).
- **Not touched**: PR #158's machinery (`_sharedSlashableUsd`, `_effectiveTotal`, `_effectiveReservedTotal`, `allocatedUsd`, `settleCoverage`) — verified that neither PR #152 nor PR #158 modified `requireApproveQuorum` itself (PR #152 design D5 explicitly kept it unchanged; PR #158's diff has no hunk in it), so this change's rewrite target is clear. `TierRegistry` (off-limits #45) — untouched.

## Sequencing (hard ordering — record of 2026-08-03)

**#35/#154's fix (PR #158) -> #43 (per-call capital) -> #27 (this).** Implementation MUST NOT start until both predecessors are merged; tasks.md §0 lists exactly what to re-verify against each one's landed shape:

1. **PR #158** (`fix/issue-35-booking-anchor`): merged shape assumed here — `requireApproveQuorum` body untouched; `_sharedSlashableUsd` pro-rata sharing applies to the post-execution read family only. If #158 lands having ALSO touched the gate, re-read the current shape and re-derive design.md D6 before writing code.
2. **#43** (`feat/issue-43-per-call-capital`, openspec change `per-call-capital-declarations` @ 062e8c0): interface assumed here — `getCallCaps(uint256) returns (uint256[] memory, uint256[] memory)`, caps as batch ARGUMENTS (vault/lib never read proposal storage), coverage linear in the cap vector. If #43 merges with a different seam, design.md D7 names what moves.
