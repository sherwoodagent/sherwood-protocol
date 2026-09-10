## ADDED Requirements

### Requirement: Asset calls are approve-only and no allowance survives the batch

For every governor-batch call whose `target` is the vault's underlying `asset()`, the guard SHALL admit exactly `approve(address,uint256)` with at least 68 bytes of calldata and SHALL revert `DisallowedAssetSelector(selector)` for any other selector, for calldata shorter than 4 bytes, and for `approve` calldata shorter than 68 bytes. The guard SHALL record the spender of every admitted `approve`, and after the batch's delegatecall returns — before the outflow, reserve and buffer checks — the vault SHALL `forceApprove(spender, 0)` on `asset()` for each recorded spender. Capital therefore leaves the vault only through an allowance a callee pulls inside the same transaction; an allowance granted and not used is gone before the transaction ends. The rule SHALL apply on the execute, settlement and emergency batch paths alike.

#### Scenario: transfer on the asset is refused
- **WHEN** a batch contains `asset.transfer(x, n)`
- **THEN** the batch reverts `DisallowedAssetSelector(0xa9059cbb)` before any call executes

#### Scenario: transferFrom on the asset is refused whatever its source
- **WHEN** a batch contains `asset.transferFrom(lp, vault, n)` (the LP deposit-allowance confiscation shape) or `asset.transferFrom(vault, x, n)`
- **THEN** the batch reverts `DisallowedAssetSelector(0x23b872dd)`

#### Scenario: Every non-approve asset selector is refused
- **WHEN** a batch contains `asset.permit(...)`, `asset.increaseAllowance(...)`, `asset.transferAndCall(...)`, or any selector other than `approve`
- **THEN** the batch reverts `DisallowedAssetSelector(selector)`

#### Scenario: Every approved spender reads zero allowance after the batch
- **WHEN** a batch approves two spenders, one of which pulls inside the batch and one of which does not
- **THEN** after `executeGovernorBatch` returns, `asset.allowance(vault, spender)` is zero for both

#### Scenario: Approve-then-drain in a later block is impossible
- **WHEN** a batch approves `attacker` for `type(uint256).max` and no call pulls
- **THEN** in the next block `asset.transferFrom(vault, attacker, 1)` by `attacker` reverts for insufficient allowance

### Requirement: Any other target with any selector is admitted and metered

A governor-batch call whose `target` is neither a privileged target nor `asset()` SHALL be admitted by the guard regardless of selector or calldata; admission is not endorsement. The batch's effect on custody SHALL be bounded only by the outflow meter (`MaxNetOutflowExceeded`), the queue reserve (`QueueReserveBreached`) and the buffer floor (`BufferBreached`), and its price is set by the tier the governor snapshotted at propose (`tierOf` returns tier 2 with full notional for an uncertified pair). The vault SHALL NOT consult the TierRegistry, decode recipients, or probe a callee's `vault()` inside the guard.

#### Scenario: Arbitrary contract, arbitrary selector, within the cap
- **WHEN** a batch approves an arbitrary contract and calls it with an arbitrary selector, and the contract pulls at most `maxNetOutflow`
- **THEN** the batch executes

#### Scenario: Arbitrary contract pulling past the cap
- **WHEN** the same contract pulls more than `maxNetOutflow`
- **THEN** the batch reverts `MaxNetOutflowExceeded`

## MODIFIED Requirements

### Requirement: Governor batch execution
`executeGovernorBatch(calls, callCaps, maxNetOutflow)` SHALL be callable only by the governor resolved live from the factory, only while unpaused, and non-reentrantly. Before executing, the vault SHALL verify the shared executor library's bytecode still matches the codehash stamped at initialization (`ExecutorCodehashMismatch` on drift), run the structural batch guard (privileged-target denylist, asset-only-`approve`), then delegatecall the batch, bubbling any failure's revert data. After success it SHALL reset every allowance the batch granted on `asset()` to zero, emit `GovernorBatchExecuted(governor, callCount)`, and enforce, in order: net asset outflow of the batch not exceeding `maxNetOutflow` (`MaxNetOutflowExceeded`), idle balance not below the queue reserve (`QueueReserveBreached`), and the idle-liquidity buffer (`BufferBreached`).

#### Scenario: Non-governor caller rejected
- **WHEN** any address other than the factory-resolved governor calls `executeGovernorBatch`
- **THEN** the call reverts `NotGovernor`

#### Scenario: Swapped executor bytecode rejected
- **WHEN** the code at the executor implementation address no longer matches the initialization-time codehash
- **THEN** the batch reverts `ExecutorCodehashMismatch` before any call executes

#### Scenario: Net-outflow ceiling
- **WHEN** a batch moves more of the vault asset out of custody than `maxNetOutflow`
- **THEN** the batch reverts `MaxNetOutflowExceeded(netOutflow, cap)`

### Requirement: Privileged-target guard on batches

`_guardBatchCalls` SHALL reject any governor batch containing a call whose `target` is a privileged protocol contract, reverting `DisallowedBatchTarget(target)`. The privileged set SHALL be every protocol contract the vault can resolve from its own wiring, fixed by deployment and not owner-extensible: the vault itself, its bound withdrawal queue, its factory, its governor, the governor's tier registry, that registry's strategy factory, the governor's exposure ledger, the ledger's coverage freezer (the challenge game), the governor's guardian registry and that registry's staked-WOOD token. Resolution SHALL be fail-soft — a collaborator the governor cannot name reads as absent, never as a revert — so the check runs on every batch regardless of how much of the protocol is wired. The check SHALL run on every call before any other rule and on the execute, settlement and both emergency batch paths alike. The same predicate SHALL be exposed as `isPrivilegedBatchTarget(target)` for the governor's propose-time validation.

The adversary is a governor batch that carries `msg.sender == vault` into a vault-only entrypoint (the queue's `onlyVault` functions), or that drives any protocol contract's vault-authorised surface, while moving zero `asset()` balance — invisible to the outflow meter and priced at nothing.

#### Scenario: Any privileged contract as a batch target is rejected
- **WHEN** a governor batch contains a call whose `target` is the vault, the queue, the governor, the tier registry, the strategy factory, the syndicate factory, the exposure ledger, the challenge game, the guardian registry or sWOOD
- **THEN** `executeGovernorBatch` reverts `DisallowedBatchTarget(target)` before any call executes

#### Scenario: Guard fires with a partially wired governor
- **WHEN** the calling governor exposes no `exposureLedger()` / `guardianRegistry()` getter and a batch targets the withdrawal queue
- **THEN** the batch still reverts `DisallowedBatchTarget(queue)`

#### Scenario: Emergency path is covered
- **WHEN** the vault owner drives `emergencySettleWithCalls` / `finalizeEmergencySettle` with owner-supplied calls that target a privileged contract or a non-`approve` asset selector
- **THEN** the batch reverts under the same rule as a governor-driven batch

#### Scenario: Honest strategy batch is unaffected
- **WHEN** a governor batch targets only strategy contracts, the asset token (with `approve`), or external protocol contracts
- **THEN** the guard passes every call and the batch proceeds under the outflow, reserve and buffer checks

## REMOVED Requirements

### Requirement: Value-moving selector guard on batches
**Reason**: An allowlist over calldata the proposer writes is a list of what someone thought of; every audit round found a sibling selector (Permit2, DSToken, ERC1363, ERC4626) the enumeration missed. The asset rule admits one selector and refuses the rest; non-asset targets are priced, not recognised.
**Migration**: `DisallowedTransferTarget`, `MalformedCall`, `AdapterVaultMismatch`, `TierRegistryUnresolved` and `DisallowedBatchCallee` are deleted from `ISyndicateVault`; batches no longer need any registry entry to execute.

### Requirement: transferFrom source guard on batches
**Reason**: The standing allowance it protected is the LP deposit allowance on `asset()`, and `transferFrom` on the asset is refused outright by the asset rule. Source-bearing selectors on other tokens are not enumerated.
**Migration**: `DisallowedTransferFromSource` is deleted; `asset.transferFrom(...)` in a batch now reverts `DisallowedAssetSelector(0x23b872dd)`.
