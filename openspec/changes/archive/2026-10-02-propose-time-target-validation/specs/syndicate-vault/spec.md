# syndicate-vault (delta)

## MODIFIED Requirements

### Requirement: Privileged-target guard on batches

`_guardBatchCalls` SHALL reject any governor batch containing a call whose `target` is the vault itself or the vault's bound withdrawal queue, reverting `DisallowedBatchTarget(target)`. This target check SHALL be enforced **unconditionally on every call in the batch, before the value-moving-selector switch and independently of whether a TierRegistry is wired** — it SHALL NOT be skipped by the `registry == address(0)` degrade-open path that gates the selector guard. Because `_guardBatchCalls` runs inside `executeGovernorBatch`, the guard SHALL apply on the execute, settlement, and both emergency batch paths alike.

The privileged-target membership test SHALL be implemented exactly once and exposed as an external view (`isPrivilegedBatchTarget(address)`), and every consumer — `_guardBatchCalls` internally, the governor's propose-time validation externally — SHALL answer through that single implementation. No consumer may restate the address set: the set is a target CLASS expected to grow, and a second copy is how a propose-time check and the execution-time guard drift apart. Execution-time enforcement in `executeGovernorBatch` SHALL remain authoritative regardless of whether any earlier (propose-time) check ran, degraded open, or was skipped.

The adversary is a governor batch that carries `msg.sender == vault` into a vault-only entrypoint: because batches execute via `delegatecall`, calling the withdrawal queue's `onlyVault` functions (`queueRedeem`, `queueDeposit`, `stampSettlement`) satisfies its `onlyVault` gate while moving zero vault `asset()` balance in the same transaction — so the net-outflow meter, the queue-reserve check, and the tier-2 coverage price all read it as harmless. Blocking the vault and the queue as batch targets is the complete boundary: no legitimate strategy batch targets either address (they target strategy adapters, the asset token, or external protocols).

#### Scenario: Queue-targeting batch call is rejected

- **WHEN** a governor batch contains a call whose `target` is the bound withdrawal queue (e.g. `queueRedeem(attacker, victimShares, pid)`)
- **THEN** `executeGovernorBatch` reverts `DisallowedBatchTarget(withdrawalQueue)` before any call executes, even though the call moves no vault `asset()` balance and would otherwise clear the outflow meter and tier-2 coverage

#### Scenario: Vault self-targeting batch call is rejected

- **WHEN** a governor batch contains a call whose `target` is the vault itself (`address(this)`)
- **THEN** `executeGovernorBatch` reverts `DisallowedBatchTarget(vault)`

#### Scenario: Guard fires even without a wired TierRegistry

- **WHEN** the calling governor exposes no TierRegistry (getter missing or returning `address(0)`) and a batch targets the withdrawal queue
- **THEN** the batch still reverts `DisallowedBatchTarget` — the target guard runs outside the registry-less degrade-open path that skips the selector guard

#### Scenario: Emergency path is covered

- **WHEN** the vault owner drives `emergencySettleWithCalls` / `finalizeEmergencySettle` (or `unstick`) with owner-supplied calls that target the withdrawal queue, bypassing the LP vote and coverage quorum
- **THEN** the batch reverts `DisallowedBatchTarget` because `_guardBatchCalls` runs on every `executeGovernorBatch` invocation regardless of entrypoint

#### Scenario: Honest strategy batch is unaffected

- **WHEN** a governor batch targets only strategy adapters, the vault's underlying asset token, or external protocol contracts (never the vault or its queue)
- **THEN** the target guard passes every call and the batch proceeds under the existing selector, outflow, reserve, and buffer checks

#### Scenario: View and guard answer identically

- **WHEN** `isPrivilegedBatchTarget(target)` is queried for any address
- **THEN** it SHALL return true exactly for the addresses `_guardBatchCalls` would reject as targets (the vault, and the bound queue when one is set) — the view and the guard are two callers of one predicate, so no target can be accepted by one and rejected by the other
