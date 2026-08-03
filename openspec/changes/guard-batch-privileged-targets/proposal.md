## Why

A governor batch runs via `delegatecall` from the vault, so every sub-call carries `msg.sender == vault`. `BatchExecutorLib.executeBatch` never constrains `calls[i].target`, and `_guardBatchCalls` only inspects call *selectors*, not the target. A batch can therefore call the bound `VaultWithdrawalQueue`'s `onlyVault` entrypoints (`queueRedeem`, `queueDeposit`, `stampSettlement`) directly. None of the existing guards price this: the net-outflow meter sees `netOutflow == 0` (no vault `asset()` moves in the same tx — the value leaves later via `queue.claim`), and the coverage layer resolves an uncertified target to tier 2 with `requiredCoverage = maxCapital * 10_000 / 10_000 = maxCapital`, so a `maxCapital = 1` proposal needs ~1 wei of coverage and clears with any single approver. The result is a steal-victim-shares primitive (issue #93) and a permanent settlement-brick DoS, both also reachable through `GovernorEmergency.emergencySettleWithCalls` with no LP vote and no coverage quorum.

## What Changes

- `SyndicateVault._guardBatchCalls` SHALL reject any batch call whose `target` is the vault itself (`address(this)`) or the vault's bound withdrawal queue (`_withdrawalQueue`), reverting with a new dedicated error.
- The target check SHALL run **before** the value-moving-selector switch and **outside** the `registry == address(0)` early return, so it fires unconditionally on every governor batch regardless of whether a TierRegistry is wired — closing the queue path even on registry-less vaults.
- A new error `DisallowedBatchTarget(address target)` SHALL be added (the existing `DisallowedTransferTarget(target, selector, recipient)` is a distinct 3-arg selector-guard error and cannot be reused).
- Applies to all four batch entrypoints, since `_guardBatchCalls` runs inside `executeGovernorBatch`: execute (`executeProposal`), settlement (`settleProposal`), and both emergency paths (`unstick` / `finalizeEmergencySettle`).

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `syndicate-vault`: adds a privileged-target guard to governor batch execution — the vault and its bound withdrawal queue become disallowed batch targets, enforced unconditionally (independent of the TierRegistry). No legitimate batch targets either address (verified: all execute/settlement batches target strategy adapters, the asset token, or external protocols), so this is a pure tightening with no functional regression.

## Impact

- **Code**: `src/SyndicateVault.sol` — `_guardBatchCalls` (add the target check + the new error). No change to `BatchExecutorLib`, the governor, or the queue.
- **Errors/ABI**: new `DisallowedBatchTarget(address)` custom error surfaced on the vault.
- **Behavior**: strictly rejects previously-accepted-but-malicious batches; honest strategy batches (adapter/token/protocol targets) are unaffected.
- **Tests**: `test/SyndicateVault.t.sol` (guard unit + positive 6-step steal reproduction), plus an emergency-path check that `finalizeEmergencySettle` with a queue-targeting call reverts.
