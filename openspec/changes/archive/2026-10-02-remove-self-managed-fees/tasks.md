# Tasks

Ordering note: this change is third in the `propose()` chain
**#147 → #118 → this → #43**. Rebase over #147/#118 before implementing;
expect #43 to rebase over this. Line references are against `e34526c` and
will drift with the chain.

Build-machine note: this repo is `via_ir = true` on a 16 GB machine that
OOM-kills concurrent solc runs. Serialize every forge command behind the
build lock (`while pgrep -x forge >/dev/null; do sleep 30; done`, foreground,
no piped exit codes).

- [ ] 1. **Interface**: delete `selfManagesFees()` from
  `src/interfaces/IStrategy.sol` (`:64-66`, the declaration and its notice).

- [ ] 2. **BaseStrategy**: delete the default implementation and natspec,
  `src/strategies/BaseStrategy.sol:134-141`.

- [ ] 3. **Struct**: delete `StrategyProposal.selfManagesFees` and its natspec
  from `src/interfaces/ISyndicateGovernor.sol:116-120`. Do NOT leave a
  placeholder — no governor is deployed (owner-confirmed, #151). Keep the
  `APPENDED FIELDS ONLY BELOW` marker where it is (it now follows
  `snapshotGuardiansFeeRecipient`).

- [ ] 4. **propose()**: delete the snapshot line and its comment block,
  `src/SyndicateGovernor.sol:272-278`. `propose` must end up making no call
  to the agent-supplied `strategy` address.

- [ ] 5. **Settlement**: at `src/SyndicateGovernor.sol:1327` pass literal
  `true` for `chargeNew`. Rewrite the surrounding self-managed comment block
  (`:1312-1323`) — the exemption is gone; keep the "Always called — see
  `chargeNew`" pointer. **Do NOT remove the `chargeNew` parameter** — update
  its `@param` natspec (`:1492-1498`): drop the `selfManagesFees` sentence,
  keep the crystallized-instant-exit sentence verbatim, and add: "Currently
  always `true`; the parameter survives for the crystallized-fee reason —
  re-evaluate after #54 (Lane A crystallization retirement) lands."

- [ ] 6. **Docs sweep in SyndicateGovernor**: remove the `selfManagesFees`
  escape-hatch paragraph from `_chargeManagementFee`'s natspec
  (`:1405-1410`). Then `grep -rn selfManagesFees src/` must return nothing.

- [ ] 7. **Golden layout**: regenerate with
  `./script/check-layout-goldens.sh --update-golden` and commit the updated
  `script/syndicate-governor-layout.golden.json` (field removed at `:437`;
  every later `StrategyProposal` member shifts). Confirm only the
  syndicate-governor golden changed.

- [ ] 8. **Tests — apply design.md D3 verdicts exactly**
  (`test/SyndicateGovernor.t.sol`):
  - [ ] 8.1 Delete `test_settlement_selfManagedStrategy_skipsPerformanceButPaysManagement` (`:625-644`) including its `vm.mockCall` on the selector.
  - [ ] 8.2 Rename/re-comment `test_settlement_nonSelfManagedStrategy_chargesNormalFees` (`:646-665`) to pin the universal rule (e.g. `test_settlement_strategyProposal_chargesNormalFees`); body unchanged.
  - [ ] 8.3 Delete `test_settlement_selfManagesFeesSnapshot_revertAfterProposeDoesNotBrickSettle` (`:666-693`) — deleted WITH the mechanism, not weakened (see D3 preamble; keep that framing in the PR description).
  - [ ] 8.4 Delete `test_settlement_selfManagesFeesSnapshot_toctouFlipIgnored` (`:700-722`) — same framing.
  - [ ] 8.5 Replace `test_propose_eoaStrategyRevertsAtPropose` (`:723-740`) with its inverse: propose with a codeless `strategy` address succeeds (pins the delta spec's "Strategy address is not probed at propose" scenario). Reference #58/#118 in the comment for the provenance follow-up.
  - [ ] 8.6 Update the `_createAndExecuteProposalWithStrategy` helper docstring (`:197-199`) — it no longer exists for the flag read.

- [ ] 9. **Mock**: strip `selfFee`, `revertOnSelfManagesFees`, both setters,
  and `selfManagesFees()` from `test/mocks/MockStrategyAdapter.sol`
  (`:13-26`, `:55-61`). Leave the rest untouched
  (`GovernorAdapterBinding.t.sol` uses it as a plain strategy address).

- [ ] 10. **Verify**: `grep -rn selfManagesFees src/ test/ script/` returns
  nothing outside `openspec/`; full `forge test` green behind the build lock;
  `./script/check-layout-goldens.sh` passes; `forge fmt` with a CI-matching
  forge version.

- [ ] 11. **Record the #54 follow-up**: comment on #54 (or its change's
  tasks) that once `consumeCrystallizedPerf` is removed, `chargeNew` in
  `_chargePerformanceFee` may become vacuous and its removal should be
  decided there (design.md D1).
