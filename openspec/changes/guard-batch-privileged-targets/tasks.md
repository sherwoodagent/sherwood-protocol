## 1. Implementation

- [x] 1.1 Add error `DisallowedBatchTarget(address target)` to `SyndicateVault` (alongside the existing `DisallowedTransferTarget` declaration in `src/SyndicateVault.sol`).
- [x] 1.2 In `_guardBatchCalls`, add a target check that runs for every call in `calls` **before** the `tierRegistry` staticcall and the `registry == address(0)` early return: `if (calls[i].target == address(this) || calls[i].target == _withdrawalQueue) revert DisallowedBatchTarget(calls[i].target);`. Keep the existing selector switch (approve/increaseAllowance/transfer/transferFrom) gated on a resolved nonzero registry as before.
- [x] 1.3 Update the `_guardBatchCalls` natspec: state the new adversary (a `delegatecall` batch carrying `msg.sender == vault` into a vault-only entrypoint) and note the target check is unconditional (independent of the registry), per the repo's "every guard states its adversary" house style.

## 2. Tests — target guard unit coverage

> Landed in `test/audit-fixes/Vault_batchQueueTargets.t.sol` rather than
> `test/SyndicateVault.t.sol` — the repo files per-finding regressions under
> `test/audit-fixes/`. Same coverage, conventional location.

- [x] 2.1 `test/SyndicateVault.t.sol`: a batch call targeting the bound withdrawal queue reverts `DisallowedBatchTarget(queue)`.
- [x] 2.2 A batch call targeting the vault itself (`address(this)`) reverts `DisallowedBatchTarget(vault)`.
- [x] 2.3 The guard fires even when the governor exposes no TierRegistry (getter missing or returning `address(0)`) — a queue-targeting batch still reverts `DisallowedBatchTarget`.
- [x] 2.4 Regression: an honest batch targeting a strategy adapter / the asset token / an external protocol (never the vault or queue) still passes the guard and proceeds under the existing selector/outflow/reserve/buffer checks.

## 3. Tests — end-to-end exploit reproduction

> 3.1/3.3 landed in `test/audit-fixes/Vault_batchQueueTargets_lifecycle.t.sol`
> (real `SyndicateGovernor`: `executeProposal` / `settleProposal` / `unstick`)
> and `test/governor/GovernorEmergency.t.sol` (`finalizeEmergencySettle`).

- [x] 3.1 Positive reproduction of issue #93's 6-step steal: victim `requestRedeem`; propose with `maxCapital = 1` and `executeCalls = [{target: withdrawalQueue, data: queueRedeem(attacker, victimShares, pid)}]`; assert `executeProposal` (which reaches `executeGovernorBatch`) reverts `DisallowedBatchTarget` at the guard. Include an assertion that, BEFORE the fix, the same batch would have passed the net-outflow meter (`netOutflow == 0`) and tier-2 coverage (`requiredCoverage == maxCapital`) — document via comment or a pre-guard sub-check so the test proves the guard is the thing that stops it.
- [x] 3.2 `queueDeposit`-targeting and `stampSettlement`-targeting batches are likewise rejected (the other two reachable queue effects named in the issue).
- [x] 3.3 Emergency path: driving `emergencySettleWithCalls` → `finalizeEmergencySettle` (and/or `unstick`) with a queue-targeting call reverts `DisallowedBatchTarget`, confirming the guard covers the owner-supplied, vote-less, coverage-less path.

## 4. Verification

- [ ] 4.1 (build + targeted suites verified locally; full suite pending CI) `forge build` and `forge test` pass (run with a CI-matching forge; serialize `via_ir` builds to avoid OOM on constrained machines).
- [x] 4.2 `openspec validate guard-batch-privileged-targets --strict` passes.
- [x] 4.3 `forge fmt --check` clean on `src/` and `test/`.
