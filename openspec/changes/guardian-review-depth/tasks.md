All groups land in the `sherwood-guardian` repo. This repo carries the spec only.

## 1. Prove the warp before building on it

- [x] 1.1 Take one real proposal on the vnet and run `openReview` → warp to `reviewEnd` → `resolveReview` → `executeProposal` → warp `strategyDuration` → `settleProposal` on a fork with no oracle mocking; record what reverts first — ran on vnet 9994663, governor 0xFBeC18B3 pid 3. The warp works: settleProposal succeeded through the real entrypoint
- [x] 1.2 Confirm the expected failure is `StalePrice()` from `PortfolioStrategy`, and enumerate every other staleness or freshness check reached during the run — **CORRECTED**: `StalePrice()` does not fire, and the earlier note here was wrong about why. Re-running the same proposal with `RESTAMP_FEEDS=false` settles identically (same `totalAssetsAfter`), so the settle path of these strategies reaches no staleness-checked feed at all. Re-stamping is currently unexercised rather than load-bearing, and the control arm has produced no disagreement on any proposal measured so far. A settle leg that DOES price through an oracle is still untested.
- [x] 1.3 Measure the capital round trip for that proposal — `totalAssets()` after settlement against `getCapitalSnapshot` — to get a first data point for the drawdown bound — capital snapshot 1_500_000_000 vs totalAssets 1_482_919_917 after settlement: a 17_080_083 shortfall, ~114 bps. One sample, not a distribution
- [x] 1.4 Record whether `vm.warp` alone breaks anything beyond oracle freshness; if it does, stop and re-scope before group 2 — nothing broke beyond oracle freshness. Group 2 proceeds

## 2. Lifecycle harness

- [ ] 2.1 Vendor the protocol ABIs the harness needs (`SyndicateGovernor`, `GuardianRegistry`, `SyndicateVault`) as a submodule rather than hand-written interfaces, so a shape divergence fails to compile instead of returning empty data — HELD: the harness uses narrow hand-written interfaces for now; vendoring the protocol as a submodule is a bigger change than this branch should carry.
- [x] 2.2 Rewrite `foundry/test/SimulateProposal.t.sol` to drive `openReview`, `resolveReview`, `executeProposal`, and `settleProposal` in sequence, modelled on `test/governor/ProposalLifecycle.t.sol` in the protocol repo — `foundry/test/LifecycleSimulation.t.sol`; settle leg verified against a live Executed proposal. Execute leg still needs a fork pinned before voteEnd
- [x] 2.3 Advance `block.timestamp` by `strategyDuration` and `block.number` by a per-chain blocks-per-second constant between the execute and settle legs
- [x] 2.4 Refuse to start when no blocks-per-second constant is configured for the connected chain — `BLOCKS_PER_SECOND` is required, not defaulted
- [x] 2.5 Add `vm.mockCall` restamping of each consulted feed's `latestRoundData`, preserving the answer and setting `updatedAt` to the current timestamp — 16 feeds re-stamped before and after the warp, answers preserved
- [x] 2.6 Emit the invariant measurements — capital snapshot, `totalAssets()` after settlement, residual allowances, residual non-asset balances, native balance — as parseable log lines — `INV ` lines for snapshot, totalAssets, asset balance, native, residual tokens and allowances. Snapshot is captured BEFORE settlement, which clears it — plus `INV spendersChecked`/`tokensChecked` counts and an `INV END` sentinel, so a truncated log cannot read as clean
- [ ] 2.7 Retire the pranked raw-call path only after group 5 confirms verdict parity — HELD by design: retirement waits on 5.1 parity.

## 3. Carry the measurements into the verdict

- [x] 3.1 Extend `parseForgeOutput` in `src/simulator.ts` to read the invariant measurements, and stop hardcoding `gasUsed: 0` and `returnData: "0x"` when the harness emits both — `INV ` lines parsed into `SimRun.outcome`; exact decimals taken, forge's `[1.48e9]` annotation discarded as lossy
- [x] 3.2 Add the measurements to `RiskContext` in `src/risk.ts` — today `vaultAssetBefore` and `vaultAssetAfter` are parsed and then discarded, with no field to receive them — `RiskContext.outcome`; absent means NOT MEASURED and fires nothing
- [x] 3.3 Add outcome risk codes: capital shortfall, residual allowance, residual non-asset balance, native imbalance, non-vault beneficiary
- [x] 3.4 Check the decoded `recipient` on `exactInputSingle` and equivalent beneficiary fields, and check `call.value` — neither is examined today — also `ZERO_MIN_OUTPUT`, and native value split into sanctioned/unsanctioned
- [x] 3.5 Ship every outcome code at warning level initially; do not gate Approve on them until group 5 has measured false-positive rates
- [x] 3.6 Unit-test each outcome code against a fixture that trips it and a fixture that does not, so no code ships vacuous — each code has a tripping fixture and a non-tripping control

## 4. Control run and model

- [x] 4.1 Run the unwarped control simulation at fork state with no mocking, alongside the warped run — `simulateProposalDual`; re-stamping is opt-out so the control arm sees real freshness
- [x] 4.2 Escalate verdict disagreement between the two runs into the unresolved band; abstain when the control run cannot complete — `CONTROL_RUN_DISAGREED` warning; a control that cannot complete counts as disagreement, not corroboration
- [ ] 4.3 Pass a `model` into `decide` from `src/index.ts` — the escalation tier exists in `judge.ts` and is unreachable today, so every warning-band proposal abstains — BLOCKED: the adjudicator was built and then reverted by another session in `sherwood-guardian` (7894e1d). Rebuilding it here would resurrect a feature its author withdrew; needs a decision first.
- [ ] 4.4 Include both runs' evidence in the model's context, and keep the narrowing to Block or Abstain unchanged — BLOCKED: the adjudicator was built and then reverted by another session in `sherwood-guardian` (7894e1d). Rebuilding it here would resurrect a feature its author withdrew; needs a decision first.
- [ ] 4.5 Unit-test that an unavailable model abstains and never falls through to the clean-path Approve — BLOCKED: the adjudicator was built and then reverted by another session in `sherwood-guardian` (7894e1d). Rebuilding it here would resurrect a feature its author withdrew; needs a decision first.

## 5. Calibration before enforcement

- [x] 5.1 Run the lifecycle harness and the existing harness side by side across every proposal on the vnet, and diff the verdicts — `simulateBothHarnesses` runs both; the daemon now defaults to the lifecycle harness, which it previously did NOT (it invoked the legacy pranked replay while parsing INV lines the legacy harness never emits)
- [x] 5.2 Collect the round-trip cost distribution for honest proposals and derive `maxDrawdownBps` from it — three samples on vnet 9994663: 113 bps at 6h, 122 at 12h, 130 at 24h. Duration and basket are confounded across them, so the trend is not attributable
- [ ] 5.3 Promote residual allowance, residual balance, native imbalance, and non-vault beneficiary to critical once each has fired zero false positives across the collected set — HELD: promotion needs a sample that isolates duration from basket; three confounded points is not a distribution.
- [ ] 5.4 Promote the capital-shortfall code to critical only after `maxDrawdownBps` is measured, not before — HELD: promotion needs a sample that isolates duration from basket; three confounded points is not a distribution.
- [x] 5.5 Record the calibration data and the resulting bounds in the guardian repo's README so the numbers are auditable rather than folklore — recorded in the guardian README as a table, including what the sample does NOT establish

## 6. Reconcile the parent change

- [x] 6.1 Tick the tasks in `autonomous-guardian-agent` that `sherwood-guardian` already implements — groups 2 through 5 are live in the code and unticked in the file — groups 2-5 ticked after checking each against the source, not assumed from the commit log
- [x] 6.2 Note in that change that `openReview` and `resolveReview` exist in `src/signer.ts` but are never called from `src/index.ts`, which `guardian-fleet` resolves by moving them to a keeper — noted on task 5.3 of that change: `signer.ts` had all three actions, `index.ts` only called `castVote`
