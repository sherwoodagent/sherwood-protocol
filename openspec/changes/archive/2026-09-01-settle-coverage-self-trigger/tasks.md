# Tasks: settle-coverage-self-trigger (issue #33)

Sequencing gate: implement only after PR #158 (`fix/issue-35-booking-anchor`) and
issue #43 (`per-call-capital-declarations`) have merged — see proposal.md
Sequencing and tasks §0.

## 0. Rebase re-verification (repeat after each upstream merge)

- [x] 0.1 After #158 merges: confirm `settleCoverage`'s external signature, the
      `executeBy` gate (`pv.executeBy == 0 || block.timestamp <= pv.executeBy`
      → `ReviewNotClosed`), the unpriceable-return branch, and the write-only
      `_settled` flag are unchanged from `origin/main` @ `388460ce` (+ the one
      clamp-line edit in the #158 diff). Anything else moved → update design
      D4/D5 before coding.
- [x] 0.2 After #43 merges: confirm `_finishSettlement` still ends with the
      finalization epilogue (state → fees → `onProposalSettled` →
      `ProposalSettled`), `reclaimProposerBond`'s tail is unchanged, and
      `getRequiredCoverage(uint256)` remains a view with the same signature.
      If #43 moved the epilogue, the trigger moves with it (requirement is
      "last operation of finalization", not a line number).

## 1. Interface (design D2)

- [x] 1.1 Add `event CoverageSettleFailed(uint256 indexed proposalId, address
      indexed ledger);` to `src/interfaces/ISyndicateGovernor.sol`, natspec
      naming: the house best-effort pattern it mirrors
      (`IChallengeGame.AdapterDemotionFailed`), the adversary statement from
      design D3 (a gas-dialling caller achieves only the pre-change baseline,
      visibly and repairably), and the repair path (anyone re-calls the
      permissionless `ExposureLedger.settleCoverage`).

## 2. Governor (design D1, D2)

- [x] 2.1 Add private `_settleCoverageBestEffort(uint256 proposalId,
      StrategyProposal storage proposal)` to `src/SyndicateGovernor.sol` exactly
      per design D2: `executeBy` guard first (silent skip at or before),
      pinned-first ledger resolution (`proposal.proposerBondLedger`, fallback
      `_exposureLedger`, skip when both zero), bare
      `try IExposureLedger(ledger).settleCoverage(address(this), proposalId)`
      with `catch { emit CoverageSettleFailed(proposalId, ledger); }`. Natspec
      states the D1 timing math (why the guard exists; why reclaim is the
      provably-past-`executeBy` backstop) and cross-references the openspec
      change.
- [x] 2.2 Call it as the LAST statement of `_finishSettlement` (after
      `emit ProposalSettled`) — covers `settleProposal`, `unstick`,
      `finalizeEmergencySettle` via `_finishSettlementHook`.
- [x] 2.3 Call it as the LAST statement of `reclaimProposerBond` (after
      `releaseBond`), successful-release path only — NOT on the
      forfeiture-acknowledge early return.
- [x] 2.4 No storage additions, no new parameters, no gas-floor constant
      (decision D3). Verify `./script/check-layout-goldens.sh` passes with ZERO
      golden diffs (a diff here is a bug in this change, not a golden to
      update).

## 3. Tests

- [x] 3.1 Settlement past `executeBy` (non-proposer settle with
      `strategyDuration > executionWindow`, or warp past `executeBy` first):
      `settleProposal` collapses a 4-approver cohort's reservations from
      `4 × needUsd` to `needUsd` in the same transaction (assert via
      `openExposureUsd` / ledger `CoverageSettled` emit), no
      `CoverageSettleFailed`. Use `vm.getBlockTimestamp()` for time anchors
      (repo optimizer CSE gotcha) and forward-only warps.
- [x] 3.2 Proposer self-settle at `executedAt + 1 hours`, before `executeBy`:
      NO ledger call attempted (no `CoverageSettled`, no `CoverageSettleFailed`),
      reservations unchanged — the documented silent skip.
- [x] 3.3 Failure isolation: ledger mock whose `settleCoverage` reverts (and a
      variant reverting `NoWoodPrice` via an unset WOOD price on the real
      ledger): settlement still reaches `Settled` with fees processed,
      `CoverageSettleFailed(proposalId, ledger)` emitted. Same for the reclaim
      call site: bond still released.
- [x] 3.4 Emergency paths: `unstick` and `finalizeEmergencySettle` past
      `executeBy` both fire the trigger (they share `_finishSettlement`).
- [x] 3.5 Reclaim backstop: proposal settled BEFORE `executeBy` (trigger
      skipped), then `reclaimProposerBond` after the challenge-window gates →
      trigger fires and reservations collapse; assert
      `block.timestamp > executeBy` held structurally (fixture uses default
      `challengeWindow = 14 days` ≥ `reviewPeriod + 7 days`).
- [x] 3.6 Idempotence/convergence: external `settleCoverage` first, then
      settlement trigger, then reclaim trigger — bookings identical to a single
      pass at the same price; no double-release (re-runnable contract, design
      D4). Hoist any argument-position reads before `vm.prank` (repo gotcha).
- [x] 3.7 Expired-unexecuted proposal with a bond: `reclaimProposerBond` fires
      the trigger (Expired implies past `executeBy`); with NO bond escrow wired
      the trigger surface is never reached and the external call still works —
      the documented residual.
- [x] 3.8 Gas snapshot: added cost of the trigger on `settleProposal` at 1 and
      4 approvers — measured ~28.5k / ~82.7k, comfortably under design D3's
      ~50-120k/approver + ~40-60k base envelope (D3 updated with the measured
      numbers). The MAX_APPROVERS=100 case was not separately measured (would
      require staking 100 real guardians) — extrapolated from the measured
      per-approver marginal instead; the best-effort framing (a child that
      exceeds the caller's budget degrades to `CoverageSettleFailed`, never a
      bricked settlement) is exercised directly by the failure-isolation
      tests (3.3), just not at 100-approver scale specifically.

## 4. Validation

- [ ] 4.1 `openspec validate settle-coverage-self-trigger --strict` clean.
- [ ] 4.2 Full non-integration suite + `forge fmt` (CI-matching forge version)
      + `./script/check-layout-goldens.sh` clean. Serialize builds behind the
      repo's forge/solc lock discipline; run forge in the foreground.
- [ ] 4.3 Confirm governor runtime bytecode still comfortably under Robinhood
      4663's 98,304-byte limit (expected delta: well under 1 KB).
