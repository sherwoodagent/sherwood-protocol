# Tasks

> Sequencing: land AFTER #147 (PortfolioStrategy `forceApprove`), BEFORE #151
> (`selfManagesFees` deletion — also edits `propose`) and #43 (per-call capital —
> changes `propose()`'s signature). This change keeps `propose`'s signature
> frozen so both rebase cleanly. Line references below are against
> `origin/main` @ `e34526c`.

## 1. Vault — single-source the predicate

- [ ] 1.1 `src/SyndicateVault.sol`: extract the Part 1 membership test from `_guardBatchCalls` (:638-643) into `_isPrivilegedBatchTarget(address target) private view returns (bool)` — `target == address(this) || (_withdrawalQueue != address(0) && target == _withdrawalQueue)`. `_guardBatchCalls`'s Part 1 loop calls it; behavior and revert (`DisallowedBatchTarget(target)`) unchanged.
- [ ] 1.2 Add `isPrivilegedBatchTarget(address) external view returns (bool)` wrapping 1.1, plus the declaration on `ISyndicateVault` with natspec stating: this is the SAME predicate `_guardBatchCalls` enforces, exposed so the governor's propose-time check cannot drift from it; consumers must never restate the address set.
- [ ] 1.3 Do NOT relocate Part 1 below Part 2's degrade-open returns while refactoring — `test_targetGate_bitesEvenWithNoTierRegistryWired` / `test_targetGate_bitesEvenWhenGovernorHasNoTierGetter` pin this and must stay green untouched.

## 2. Governor — propose-time rejection

- [ ] 2.1 `src/SyndicateGovernor.sol`: add a private helper (e.g. `_rejectPrivilegedTargets(address vault, BatchExecutorLib.Call[] calldata a, BatchExecutorLib.Call[] calldata b)`) called from `propose` after the `TooManyCalls` cap (:241-243) and before `proposalId = ++_proposalCount` (:258) — i.e. with the other cheap input validation, before any state write or state-changing external call (`lockBond`). Hoisted to a helper for `propose`'s documented Yul stack budget.
- [ ] 2.2 In the helper, resolve the predicate degrade-open: staticcall `isPrivilegedBatchTarget` once as a capability probe (failure or malformed return ⇒ skip the check entirely — a pre-upgrade vault must not brick `propose`; `executeGovernorBatch` remains authoritative). When available, check every target of BOTH arrays and revert `ISyndicateVault.DisallowedBatchTarget(target)` on a hit — the vault's error, imported, same selector as the execution-time rejection.
- [ ] 2.3 Denylist half ONLY. No `isAdapterAllowed` / tier-registry consultation at propose (design.md Decision 2 — mutable and, post PR #149, codehash-sensitive state).

## 3. Governor — claimUnclaimedFees latch

- [ ] 3.1 Add `nonReentrant` to `claimUnclaimedFees` (:1633).
- [ ] 3.2 Rewrite the `@dev` block at :1629-1632: the old text ("No `nonReentrant` required: CEI is respected…") was CORRECT, not wrong — the new text states CEI (slot zeroed before transfer) remains the primary defense and the latch is uniformity with every sibling entrypoint. Do not imply a vulnerability was closed.

## 4. Tests

- [ ] 4.1 New propose-time tests (natural home: `test/audit-fixes/Vault_batchQueueTargets_lifecycle.t.sol`, which owns the real-lifecycle harness): queue in `settlementCalls` reverts `DisallowedBatchTarget(queue)` at `propose`; vault in `executeCalls` reverts `DisallowedBatchTarget(vault)` at `propose`; a benign proposal still passes end to end.
- [ ] 4.2 Restructure the three gap-pinning tests per design.md's table: `test_sixStepQueueSteal_isRejectedAtExecuteProposal` and `test_queueTargetingSettlementBatch_isRejectedAtSettleProposal` assert the revert at `propose` (update the six-step trace comment — rejection now lands at step 3); retire `test_unstickWithQueueTargetingCalls_reverts` with a comment pointing at the unit-level `executeGovernorBatch` coverage that keeps the `unstick` path pinned.
- [ ] 4.3 Degrade-open test: against a vault stub WITHOUT the view, `propose` accepts a queue-targeting proposal and `executeProposal` still reverts `DisallowedBatchTarget` — proving the propose-time check never became load-bearing.
- [ ] 4.4 Predicate-parity test: `isPrivilegedBatchTarget` returns true for the vault and the bound queue, false for an adapter/asset/random address, matching what `executeGovernorBatch` accepts/rejects (the "View and guard answer identically" scenario).
- [ ] 4.5 Reentrancy tests: (a) a batch whose sub-call re-enters `claimUnclaimedFees` mid-settle now reverts `Reentrancy` (previously no-oped — pin the deliberate behavior change); (b) an ordinary external claim with a populated escrow slot still pays out under the latch.
- [ ] 4.6 Confirm untouched: all of `test/audit-fixes/Vault_batchQueueTargets.t.sol`, `test_unstickWithHonestCallsStillSettles`, and `GovernorEmergency.t.sol::test_finalizeEmergencySettle_vaultSelfTargetingCalls_reverts` pass without edits. If any needs edits, the change regressed the execution-time guard — stop and revisit.

## 5. Post-landing check for #150 (do not implement for it)

- [ ] 5.1 On the landed branch, run #150's PoC shape: pre-deploy a strategy clone, drive an unrelated proposal whose `executeCalls` call `clone.execute()`, confirm `propose` accepts and the ratchet flips (expected: this change does NOT subsume #150 — clones are legitimate targets outside the denylist). Record the outcome, either way, as a comment on #150.

## 6. Verify

- [ ] 6.1 `forge build` + full `forge test` in the FOREGROUND, serialized behind any live build (`while pgrep -x forge >/dev/null; do sleep 30; done` — guard the parent process; `pgrep -x solc` is inert, the binary is `solc-0.8.28`). Never judge a build through a piped exit code.
- [ ] 6.2 `forge fmt --check` on src/ and test/ with a CI-matching forge.
- [ ] 6.3 `openspec validate propose-time-target-validation --strict`.
