All groups land in the `sherwood-guardian` repo. This repo carries the spec only.

## 1. Prove the warp before building on it

- [ ] 1.1 Take one real proposal on the vnet and run `openReview` → warp to `reviewEnd` → `resolveReview` → `executeProposal` → warp `strategyDuration` → `settleProposal` on a fork with no oracle mocking; record what reverts first
- [ ] 1.2 Confirm the expected failure is `StalePrice()` from `PortfolioStrategy`, and enumerate every other staleness or freshness check reached during the run
- [ ] 1.3 Measure the capital round trip for that proposal — `totalAssets()` after settlement against `getCapitalSnapshot` — to get a first data point for the drawdown bound
- [ ] 1.4 Record whether `vm.warp` alone breaks anything beyond oracle freshness; if it does, stop and re-scope before group 2

## 2. Lifecycle harness

- [ ] 2.1 Vendor the protocol ABIs the harness needs (`SyndicateGovernor`, `GuardianRegistry`, `SyndicateVault`) as a submodule rather than hand-written interfaces, so a shape divergence fails to compile instead of returning empty data
- [ ] 2.2 Rewrite `foundry/test/SimulateProposal.t.sol` to drive `openReview`, `resolveReview`, `executeProposal`, and `settleProposal` in sequence, modelled on `test/governor/ProposalLifecycle.t.sol` in the protocol repo
- [ ] 2.3 Advance `block.timestamp` by `strategyDuration` and `block.number` by a per-chain blocks-per-second constant between the execute and settle legs
- [ ] 2.4 Refuse to start when no blocks-per-second constant is configured for the connected chain
- [ ] 2.5 Add `vm.mockCall` restamping of each consulted feed's `latestRoundData`, preserving the answer and setting `updatedAt` to the current timestamp
- [ ] 2.6 Emit the invariant measurements — capital snapshot, `totalAssets()` after settlement, residual allowances, residual non-asset balances, native balance — as parseable log lines
- [ ] 2.7 Retire the pranked raw-call path only after group 5 confirms verdict parity

## 3. Carry the measurements into the verdict

- [ ] 3.1 Extend `parseForgeOutput` in `src/simulator.ts` to read the invariant measurements, and stop hardcoding `gasUsed: 0` and `returnData: "0x"` when the harness emits both
- [ ] 3.2 Add the measurements to `RiskContext` in `src/risk.ts` — today `vaultAssetBefore` and `vaultAssetAfter` are parsed and then discarded, with no field to receive them
- [ ] 3.3 Add outcome risk codes: capital shortfall, residual allowance, residual non-asset balance, native imbalance, non-vault beneficiary
- [ ] 3.4 Check the decoded `recipient` on `exactInputSingle` and equivalent beneficiary fields, and check `call.value` — neither is examined today
- [ ] 3.5 Ship every outcome code at warning level initially; do not gate Approve on them until group 5 has measured false-positive rates
- [ ] 3.6 Unit-test each outcome code against a fixture that trips it and a fixture that does not, so no code ships vacuous

## 4. Control run and model

- [ ] 4.1 Run the unwarped control simulation at fork state with no mocking, alongside the warped run
- [ ] 4.2 Escalate verdict disagreement between the two runs into the unresolved band; block when the control run cannot complete
- [x] 4.3 Remove abstention from the verdict gate: every branch where a vote is castable resolves to Approve or Block, and a closed window reports a distinct non-verdict
- [ ] 4.4 Pass a `model` into `decide` from `src/index.ts` — the escalation tier exists in `judge.ts` and is unreachable today
- [ ] 4.5 Include both runs' evidence in the model's context, and keep Approve unreachable from the model
- [ ] 4.6 Unit-test that an unavailable model blocks and never falls through to the clean-path Approve

## 5. Calibration before enforcement

- [ ] 5.1 Run the lifecycle harness and the existing harness side by side across every proposal on the vnet, and diff the verdicts
- [ ] 5.2 Collect the round-trip cost distribution for honest proposals and derive `maxDrawdownBps` from it
- [ ] 5.3 Promote residual allowance, residual balance, native imbalance, and non-vault beneficiary to critical once each has fired zero false positives across the collected set
- [ ] 5.4 Promote the capital-shortfall code to critical only after `maxDrawdownBps` is measured, not before
- [ ] 5.5 Record the calibration data and the resulting bounds in the guardian repo's README so the numbers are auditable rather than folklore

## 6. Reconcile the parent change

- [ ] 6.1 Tick the tasks in `autonomous-guardian-agent` that `sherwood-guardian` already implements — groups 2 through 5 are live in the code and unticked in the file
- [ ] 6.2 Note in that change that `openReview` and `resolveReview` exist in `src/signer.ts` but are never called from `src/index.ts`, which `guardian-fleet` resolves by moving them to a keeper
