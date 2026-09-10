## ADDED Requirements

### Requirement: Every non-asset batch target is a registered strategy

For every governor-batch call whose `target` is not the vault's underlying `asset()`, the guard SHALL require that the protocol's `StrategyFactory` holds `target` as a registered strategy whose code is unchanged since registration, and SHALL revert `NotARegisteredStrategy(target)` otherwise. The vault SHALL resolve the factory live through `governor → tierRegistry() → strategyFactory()` and read `isRegisteredStrategy(target)` on it; every hop SHALL be fail-closed — a governor or registry that does not answer, an unwired (`address(0)`) factory, or a factory that does not answer the selector with one word SHALL read as "not registered". Admission is not endorsement: the batch's effect on custody is bounded by the outflow meter, the queue reserve and the buffer floor, and its price by the tier snapshotted at propose. The vault SHALL NOT decode recipients, consult any allowlist, or probe a callee's `vault()` inside the guard.

#### Scenario: Unregistered contracts are refused whatever the calldata
- **WHEN** a batch names Morpho directly, the withdrawal queue, the governor, the vault itself, the tier registry or any contract nobody registered
- **THEN** `executeGovernorBatch` reverts `NotARegisteredStrategy(target)` before any call executes

#### Scenario: A registered strategy is admitted with any selector
- **WHEN** a batch approves a registered hand-written strategy and calls it with a selector no registry names, pulling at most `maxNetOutflow`
- **THEN** the batch executes

#### Scenario: A code change de-registers
- **WHEN** a registered strategy's code changes after registration and a batch names it
- **THEN** the batch reverts `NotARegisteredStrategy(target)`

#### Scenario: Unwired factory refuses every non-asset target
- **WHEN** the registry's `strategyFactory()` is `address(0)` and a batch names a strategy that was registered elsewhere
- **THEN** the batch reverts `NotARegisteredStrategy(target)`; asset calls are still admitted under the asset rules

#### Scenario: A factory that does not answer fails closed
- **WHEN** `isRegisteredStrategy` on the resolved factory reverts or returns other than one word
- **THEN** the batch reverts `NotARegisteredStrategy(target)`

### Requirement: On the asset, transferFrom draws from the vault and no allowance survives the batch

For every governor-batch call whose `target` is `asset()`: `transferFrom` whose first argument word is not the vault's address SHALL revert `TransferFromNotVault(from)` (calldata shorter than 36 bytes reads `from` as zero and is refused); every other selector SHALL be admitted. The guard SHALL record the spender of every `approve(address,uint256)` and `increaseAllowance(address,uint256)`, and after the batch's delegatecall returns — before the outflow, reserve and buffer checks — the vault SHALL `forceApprove(spender, 0)` on `asset()` for each recorded spender. `transfer` and `transferFrom(vault, …)` are metered like any outflow. The rule SHALL apply on the execute, settlement and emergency batch paths alike. The asset is a plain ERC-20 by deployment; operator-style grants (`authorizeOperator`) are out of scope.

#### Scenario: transferFrom from an LP is refused
- **WHEN** a batch contains `asset.transferFrom(lp, x, n)` where `lp` holds a standing deposit allowance to the vault
- **THEN** the batch reverts `TransferFromNotVault(lp)` before any call executes and the LP's allowance is untouched

#### Scenario: transferFrom from the vault is admitted and metered
- **WHEN** a batch approves the vault itself and calls `asset.transferFrom(vault, x, n)`
- **THEN** the batch executes iff `n <= maxNetOutflow`, else reverts `MaxNetOutflowExceeded`

#### Scenario: transfer is admitted and metered
- **WHEN** a batch contains `asset.transfer(x, n)`
- **THEN** the batch executes iff `n <= maxNetOutflow`, else reverts `MaxNetOutflowExceeded`

#### Scenario: Every recorded spender reads zero allowance after the batch
- **WHEN** a batch grants two spenders via `approve` or `increaseAllowance`, one of which pulls inside the batch and one of which does not
- **THEN** after `executeGovernorBatch` returns, `asset.allowance(vault, spender)` is zero for both

#### Scenario: Approve-then-drain in a later block is impossible
- **WHEN** a batch approves `attacker` for `type(uint256).max` and no call pulls
- **THEN** in the next block `asset.transferFrom(vault, attacker, 1)` by `attacker` reverts for insufficient allowance

## MODIFIED Requirements

### Requirement: Governor batch execution
`executeGovernorBatch(calls, callCaps, maxNetOutflow)` SHALL be callable only by the governor resolved live from the factory, only while unpaused, and non-reentrantly. Before executing, the vault SHALL verify the shared executor library's bytecode still matches the codehash stamped at initialization (`ExecutorCodehashMismatch` on drift), run the structural batch guard (registered-strategy targets, asset `transferFrom` from the vault only), then delegatecall the batch, bubbling any failure's revert data. After success it SHALL reset every allowance the batch granted on `asset()` to zero, emit `GovernorBatchExecuted(governor, callCount)`, and enforce, in order: net asset outflow of the batch not exceeding `maxNetOutflow` (`MaxNetOutflowExceeded`), idle balance not below the queue reserve (`QueueReserveBreached`), and the idle-liquidity buffer (`BufferBreached`).

#### Scenario: Non-governor caller rejected
- **WHEN** any address other than the factory-resolved governor calls `executeGovernorBatch`
- **THEN** the call reverts `NotGovernor`

#### Scenario: Swapped executor bytecode rejected
- **WHEN** the code at the executor implementation address no longer matches the initialization-time codehash
- **THEN** the batch reverts `ExecutorCodehashMismatch` before any call executes

#### Scenario: Net-outflow ceiling
- **WHEN** a batch moves more of the vault asset out of custody than `maxNetOutflow`
- **THEN** the batch reverts `MaxNetOutflowExceeded(netOutflow, cap)`

## REMOVED Requirements

### Requirement: Privileged-target guard on batches
**Reason**: The only protocol function reachable because `msg.sender == vault` is on the withdrawal queue (`onlyVault`), and the queue — like every other protocol contract — answers no `IStrategy` getter, so it cannot register and is refused by the registered-strategy rule. A denylist enumerating protocol contracts was a list of what someone thought of.
**Migration**: `DisallowedBatchTarget` and `isPrivilegedBatchTarget` are deleted from `ISyndicateVault`; a batch naming the queue, the vault or the governor now reverts `NotARegisteredStrategy(target)` at execute and at propose.

### Requirement: Value-moving selector guard on batches
**Reason**: An allowlist over calldata the proposer writes is a list of what someone thought of; every audit round found a sibling selector (Permit2, DSToken, ERC1363, ERC4626) the enumeration missed. Non-asset targets are registered strategies, priced rather than recognised; on the asset only `transferFrom` from another account escapes the meter and the reset.
**Migration**: `DisallowedTransferTarget`, `MalformedCall`, `AdapterVaultMismatch`, `TierRegistryUnresolved`, `DisallowedBatchCallee` and `UnrecognizedAssetSelector` are deleted from `ISyndicateVault`.

### Requirement: transferFrom source guard on batches
**Reason**: Restated as the asset rule above: `transferFrom` on `asset()` with `from != vault` is refused; source-bearing selectors on other tokens are not enumerated because other tokens are not batch targets unless registered.
**Migration**: `DisallowedTransferFromSource` is deleted; `asset.transferFrom(lp, …)` in a batch now reverts `TransferFromNotVault(lp)`.
