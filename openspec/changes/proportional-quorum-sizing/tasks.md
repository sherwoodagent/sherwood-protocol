# Tasks: proportional-quorum-sizing (issue #27)

## 0. Preconditions — DO NOT START IMPLEMENTATION UNTIL ALL CHECKED

Sequencing of record: **PR #158 (issues #35/#154) -> #43 -> this change.**

- [ ] 0.1 PR #158 (`fix/issue-35-booking-anchor`) is MERGED. Re-verify its
      landed shape against design.md's assumptions: `requireApproveQuorum`'s
      body untouched (`git log -L :requireApproveQuorum:src/ExposureLedger.sol`
      since 388460c), post-execution reads routed through
      `_sharedSlashableUsd`, gate excluded from the sharing. If the gate WAS
      touched, re-derive design D1/D6 against the landed code before any
      implementation.
- [ ] 0.2 Issue #43 (`per-call-capital-declarations`) is MERGED. Diff its
      landed interface against design D7's assumptions: `getCallCaps(uint256)
      -> (uint256[] memory, uint256[] memory)`, caps threaded as batch
      ARGUMENTS (vault/lib never read proposal storage), coverage linear in
      the cap vector, `Σ caps <= maxCapital` validated per batch at propose.
      If the seam differs, update design D7 and spec delta scenario "Per-call
      caps scale by the same factor" — D1-D6 are unaffected.
- [ ] 0.3 Rebase this change's branch onto post-#43 main; regenerate nothing
      yet (goldens are task 5, AFTER the struct edit).
- [ ] 0.4 Re-list `broadcast/` — confirm still no chain-4663 entry (design
      D4's deployment-reality assumption). If a 4663 governor deployment
      appeared, the append-only rule is now load-bearing: double-review task
      2.1's placement and task 5's diff.

## 1. ExposureLedger — the measurement (design D1, D2)

- [ ] 1.1 Change `requireApproveQuorum` (src/ExposureLedger.sol:1298 on
      388460c) to `returns (uint256 coverageRaisedUsd, uint256
      requiredCoverageUsd)`: keep the `n == 0` revert; keep the per-approver
      `min(live, reserved)` terms on the LIVE (`anchor = 0`) basis; keep the
      `haveUsd >= needUsd` early exit (now `return (haveUsd, needUsd)`);
      replace the fall-through `revert InsufficientApproveCoverage()` with
      `if (haveUsd == 0) revert InsufficientApproveCoverage(); return
      (haveUsd, needUsd);`.
- [ ] 1.2 Rewrite the function's natspec: "eligibility floor" framing becomes
      "coverage measurement with a zero floor"; keep the LIVE-read invariant
      note (PR #152 design D5 — the gate runs in the same tx as the
      `executedAt` stamp); document that partial shortfall returns and only
      zero coverage reverts; keep the `NoWoodPrice`-propagates note.
- [ ] 1.3 Update `IExposureLedger.sol:91` with the return values + natspec.
      Confirm by grep that `SyndicateGovernor.sol` is the ONLY `src/` caller
      (WoodTwapOracle mentions the name in a comment only).
- [ ] 1.4 Sweep `test/ExposureLedger.t.sol` and `test/CoverageEndToEnd.t.sol`
      call sites: reverting cases keep `vm.expectRevert` unchanged;
      previously-reverting SHORTFALL cases become assertions on the returned
      pair; passing cases may ignore or assert the return. Mechanical, no
      semantic rewrites.

## 2. Governor — derive, store, execute, settle (design D3, D4, D5)

- [ ] 2.1 Append `uint256 effectiveMaxCapital` as the LAST member of
      `ISyndicateGovernor.StrategyProposal` (after `proposerBondLedger`,
      below the "APPENDED FIELDS ONLY BELOW" divider), with natspec: set at
      execute on every path; immutable thereafter; settle reuses it (owner
      decision 2026-08-03, option A — recompute-at-settle rejected because a
      coverage drop between execute and settle would strand deployed capital).
- [ ] 2.2 In `executeProposal`: capture `(coverageRaisedUsd,
      requiredCoverageUsd)` from the gate call (SyndicateGovernor.sol:447 on
      388460c); compute `effectiveMaxCapital` per design D3 (clamp to
      `maxCapital`, floor division; plain `a * b / c` with a comment on the
      overflow bound, or `Math.mulDiv`); on gate-skipped paths set
      `effectiveMaxCapital = maxCapital`. Store BEFORE the batch call; pass
      `proposal.effectiveMaxCapital` to `executeGovernorBatch` instead of
      `proposal.maxCapital`.
- [ ] 2.3 In `settleProposal`: pass the STORED `proposal.effectiveMaxCapital`
      to the settlement `executeGovernorBatch` instead of
      `proposal.maxCapital`.
- [ ] 2.4 Add `event EffectiveMaxCapitalSet(uint256 indexed proposalId,
      uint256 declaredMaxCapital, uint256 effectiveMaxCapital, uint256
      coverageRaisedUsd, uint256 requiredCoverageUsd)` (zeros for the USD pair
      when the gate was skipped), emitted at execute on every path.
- [ ] 2.5 Add view `getEffectiveMaxCapital(uint256 proposalId) returns
      (uint256)` (+ interface). `getRiskEnvelope` unchanged — it reports the
      declaration.

## 3. Per-call cap scaling (design D7 — shape depends on #43's landed seam, re-verify per task 0.2)

- [ ] 3.1 At execute, scale the execute-leg caps: `effectiveCap_i =
      floor(cap_i * coverageRaisedUsd / requiredCoverageUsd)` (identity when
      coverage was full or the gate skipped); re-assert `Σ effectiveCaps <=
      effectiveMaxCapital`, clamping the LARGEST scaled cap by the excess on
      violation (dust-sized by the floor bound); pass the scaled caps to the
      batch.
- [ ] 3.2 At execute, scale the settlement caps by the SAME factor and
      persist them (appended mapping `_effectiveSettlementCallCaps`, same
      appended-storage discipline as #43's caps mappings); same per-batch
      re-assert against `effectiveMaxCapital`.
- [ ] 3.3 In `settleProposal`, pass the PERSISTED scaled settlement caps — no
      recompute at settle.

## 4. Tests (the issue's four obligations + this change's edges)

- [ ] 4.1 40% coverage -> executes with `effectiveMaxCapital` at 40% of
      declared; the vault's outflow meter reverts an attempt to move more
      (issue obligation 1).
- [ ] 4.2 Zero covering approvers (empty set AND all-zero contributions) ->
      still reverts `InsufficientApproveCoverage`, proposal stays `Approved`
      (issue obligation 2, design D2).
- [ ] 4.3 Surplus coverage -> `effectiveMaxCapital == maxCapital` exactly
      (issue obligation 3).
- [ ] 4.4 Settlement uses the same effective ceiling as execute (issue
      obligation 4): execute at partial coverage, then slash a covering
      guardian on an UNRELATED proposal, warp past `strategyDuration`
      (forward-only — `vm.warp` backwards does not take effect), settle;
      assert the settle batch ran under the stored figure, not a live
      recompute. Use `vm.getBlockTimestamp()` for anchors, never a cached
      `block.timestamp` local across warps.
- [ ] 4.5 Dust coverage floors `effectiveMaxCapital` to 0 -> execution
      proceeds, zero net outflow permitted, batch with any outflow reverts
      (design D5 fail-closed).
- [ ] 4.6 Gate-skipped paths (`requiredCoverage == 0` / no ledger) store
      `effectiveMaxCapital == maxCapital`; `EffectiveMaxCapitalSet` emitted
      with zero USD figures.
- [ ] 4.7 Post-#43: per-call caps scale by the same factor; `Σ effectiveCaps
      <= effectiveMaxCapital` holds after floor-rounding (construct a case
      where term-wise floors would exceed the floored batch bound and assert
      the largest-cap clamp); a cap that floors to zero disables that call's
      outflow; persisted settlement caps are byte-identical at settle.
- [ ] 4.8 Update `test/GovernorCoverageGates.t.sol` shortfall cases: the old
      "reverts on partial coverage" assertions become "executes at scaled
      size" assertions (keep one renamed test documenting the removed cliff).

## 5. Storage golden (design D4)

- [ ] 5.1 Regenerate `script/syndicate-governor-layout.golden.json` AFTER the
      struct edit (and after #43's own regeneration is in the base).
- [ ] 5.2 REVIEW THE DIFF as its own task: append-only — the only changes are
      the `StrategyProposal` type's new trailing member and its
      `numberOfBytes` (plus this change's appended mapping from task 3.2); NO
      existing label/slot/offset/type may move. A non-append diff is a bug in
      this change, not a golden to update.
- [ ] 5.3 `./script/check-layout-goldens.sh` passes.

## 6. Validation

- [ ] 6.1 Full non-integration suite green; run forge in the FOREGROUND with
      the repo's build-lock discipline (serialize on `pgrep -x forge`, never
      judge a build through a piped exit code).
- [ ] 6.2 `forge fmt` with a CI-matching forge version.
- [ ] 6.3 `openspec validate --changes --strict` clean.
- [ ] 6.4 Comment on issue #27 with the landed shape (use `--body-file` —
      never inline backticks in `gh` bodies).
