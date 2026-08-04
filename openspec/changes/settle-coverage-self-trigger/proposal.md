# settleCoverage self-triggers from settlement and bond reclaim (issue #33)

## Why

**A relief mechanism nobody triggers relieves nothing.** `ExposureLedger.settleCoverage` (src/ExposureLedger.sol:1581) is permissionless, unpaid, and — verified on `origin/main` @ `388460ce` — called by nothing in `src/` or `script/`. Left uncalled, every approver's reservation stays at the full `needUsd` instead of collapsing to its pro-rata allocation, so a proposal with A approvers keeps `A × coverage` of aggregate cohort budget booked until the epoch bucket expires (weeks: buckets expire at `bucketEnd + challengeWindow`, `challengeWindow` defaults to 14 days). Measured on the `CoverageEndToEnd` fixture (issue #33): four approvers on a $1,000 proposal hold 4,000e18 of budget while the review is open and still hold it after settlement — 1,000e18 once `settleCoverage` runs. The direction is safe (over-reserved, never under) but it silently caps how many concurrent proposals the cohort can back — the exact capacity problem `settleCoverage` was added to relieve.

**Owner decision: option B — fold the call into settlement so it self-triggers.** Option A (runbook line + keeper job) was rejected as a zero-code stopgap only: no keeper is load-bearing today and none should become so. Option C (caller incentive) was rejected as the largest new-money-flow surface for a mechanism with no adversarial pressure. This is issue #33's own middle option: "fold it into an existing transaction that already runs at that point in the lifecycle."

## What Changes

- **`SyndicateGovernor` gains one private helper and two call sites — no ledger changes, no storage changes, no new parameters.** A best-effort trigger, `try ledger.settleCoverage(address(this), proposalId) {} catch { emit CoverageSettleFailed(...); }`, guarded by `block.timestamp > proposal.executeBy` (the exact mirror of the ledger's own `ReviewNotClosed` gate, src/ExposureLedger.sol:1602), fires from:
  1. **The end of `_finishSettlement`** (src/SyndicateGovernor.sol:1299-1366) — after state finalization, fees, `onProposalSettled`, and the `ProposalSettled` emit, as the LAST operation. This covers all three settlement entrypoints in one place: `settleProposal`, `unstick`, and `finalizeEmergencySettle` (the emergency paths route through `_finishSettlementHook` → `_finishSettlement`, :212-214). Settlement is NOT reliably past `executeBy` (a proposer self-settle at `executedAt + 1 hours`, or any `strategyDuration` shorter than the remaining execution window, lands before it — design.md D1), hence the guard: at or before `executeBy` the trigger is skipped silently rather than attempted-and-caught.
  2. **The end of `reclaimProposerBond`** (src/SyndicateGovernor.sol:646-720) — after a successful `releaseBond`. This is the backstop that IS provably past `executeBy` for every executed proposal: the reclaim gate waits `executedAt + challengeWindow` on the pinned ledger, and that ledger enforces `challengeWindow >= reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW (7 days)` (src/ExposureLedger.sol:739, :765) while `executeBy − executedAt < executionWindow <= 7 days` — so the early-self-settle proposals the first trigger had to skip get settled here, by a caller (the proposer) with an existing economic motive (their WOOD bond). For Expired proposals the state itself implies `block.timestamp > executeBy`.
- **New event `CoverageSettleFailed(uint256 indexed proposalId, address indexed ledger)`** in `ISyndicateGovernor` — the house best-effort pattern, mirroring `ChallengeGame`'s `AdapterDemotionFailed` (bare catch, failure surfaced as an event, terminal path never bricked; src/ChallengeGame.sol:1245-1250).
- **Ledger resolution matches the reclaim gates' pinned-first rule** (issue #116): `proposal.proposerBondLedger`, falling back to the live `_exposureLedger` slot for a pre-pin proposal, skipping entirely when both are zero.
- **No gas floor** (deliberate contrast with issue #51's `DEMOTION_GAS` — design.md D3): a gas-starved trigger degrades to the exact pre-change status quo, surfaced by the event and permissionlessly repairable via the unchanged external `settleCoverage`.
- **Spec-text correction in `guardian-coverage`**: the main spec's "idempotent via a settled flag" / "Double settlement returns without re-dividing" language predates the ledger's re-runnable design and contradicts the code (`_settled` is written at src/ExposureLedger.sol:1606/:1641/:1716 and read nowhere — verified on main and unchanged by PR #158). The delta rewrites it to the actual re-runnable contract this change's idempotence argument rests on. No ledger code changes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-governor`: "Settlement and P&L" gains the settlement-finalization trigger (all three entrypoints); "Risk tiering and proposer bond at propose" gains the bond-reclaim backstop trigger.
- `guardian-coverage`: "Coverage settlement returns over-reservations" — text correction to the re-runnable contract plus a note naming the two governor self-trigger consumers; ledger behavior unchanged.

## Impact

- `src/SyndicateGovernor.sol` — private helper + two call sites (`_finishSettlement`, `reclaimProposerBond`).
- `src/interfaces/ISyndicateGovernor.sol` — `CoverageSettleFailed` event + natspec.
- Tests: trigger/skip/failure/idempotence/backstop coverage plus a gas snapshot (tasks §3).
- **No storage changes** — `script/syndicate-governor-layout.golden.json` must diff ZERO (a diff is a bug in this change).
- Bytecode: governor ~25.2 KB against Robinhood 4663's 98,304-byte limit — ample margin.
- **Not touched**: `src/ExposureLedger.sol` (issue #154/#35 machinery — this change only adds callers), `TierRegistry`, `ChallengeGame`, `GuardianRegistry`, deploy scripts.

## Sequencing

**#35/#154's fix (PR #158, branch `fix/issue-35-booking-anchor`) → #43 (`per-call-capital-declarations`, branch `feat/issue-43-per-call-capital`) → #33 (this).**

- **After PR #158**: `settleCoverage` is a named consumer of #158's `_sharedSlashableUsd` accounting fix (its per-guardian clamp, diff hunk `@@ -1651,8 +1729,11`). Verified against the PR #158 diff: `settleCoverage`'s signature, its `executeBy` gate (:1602), and the write-only `_settled` flag are all untouched — only the internal clamp line changed. This change calls the post-fix function through the unchanged external interface, so it is content-independent of #158; **re-verify on rebase** that gate, signature, and `_settled` still hold if #158 merges with a different shape.
- **After #43**: #43 (spec-only as of branch head `062e8c0`; no Solidity yet, no open PR) will edit `settleProposal`/`unstick`/`finalizeEmergencySettle` to thread per-call caps into `executeGovernorBatch`, and re-price `requiredCoverage`. It does NOT restructure `_finishSettlement`'s epilogue or `reclaimProposerBond` — this change's two insertion points are in regions #43 leaves alone. Semantic interaction only: #43 shrinks the `requiredCoverage` NUMBER `settleCoverage` reads through the unchanged `getRequiredCoverage` view, so the trigger simply collapses reservations to a smaller need. **Re-verify on rebase**: `_finishSettlement`'s tail and `reclaimProposerBond`'s tail unchanged; `getRequiredCoverage` still a view with the same signature. #43's implementation had not stabilized beyond its openspec proposal at spec time — if its final code moves the finalization epilogue, the trigger moves with it (the requirement is "last operation of finalization", not a line number).
- No conflict with off-limits #35/#45 worktrees or PRs #156/#157.
