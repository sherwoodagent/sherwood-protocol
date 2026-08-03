# syndicate-vault (delta)

## MODIFIED Requirements

### Requirement: Governor batch execution
`executeGovernorBatch(calls, callCaps, maxNetOutflow)` SHALL be callable only by the governor resolved live from the factory, only while unpaused, and non-reentrantly — an accepted breaking change to the previous two-parameter ABI, upgraded in lockstep with the governor (a mixed-version pairing fails closed on the changed signature). Before executing, the vault SHALL verify the shared executor library's bytecode still matches the codehash stamped at initialization or at the last factory-driven executor re-point (`ExecutorCodehashMismatch` on drift), then delegatecall the library's metered `executeBatch(calls, asset(), callCaps)`, passing the vault's own underlying asset — the per-call meter and the vault's batch meter MUST measure the same token — and bubbling any failure's revert data (including the library's `CallCapExceeded` and `CapsLengthMismatch`). After success it SHALL emit `GovernorBatchExecuted(governor, callCount)` and enforce, in order: net asset outflow of the whole batch not exceeding `maxNetOutflow` (`MaxNetOutflowExceeded`), idle balance not below the queue reserve (`QueueReserveBreached`), and the idle-liquidity buffer (`BufferBreached`). The batch-level meter, reserve, and buffer checks SHALL be retained unchanged regardless of per-call metering: the library meters per-call GROSS outflow against declared coverage (what guardians priced); the vault meters whole-batch NET outflow against custody limits (what LPs are senior to) — two independent accounting layers, neither a substitute for the other, and the vault's layer is the only meter on empty-caps batches.

The vault SHALL expose a factory-only executor re-point (`setExecutorImpl(newImpl)`, callable only by the factory) that updates the executor address AND re-stamps the expected codehash in one transaction, rejecting zero and codeless targets — the migration primitive for the deploy-once shared library, reached through the factory's lifecycle-gated `pushExecutor`.

#### Scenario: Non-governor caller rejected
- **WHEN** any address other than the factory-resolved governor calls `executeGovernorBatch`
- **THEN** the call reverts `NotGovernor`

#### Scenario: Swapped executor bytecode rejected
- **WHEN** the code at the executor implementation address no longer matches the stamped codehash
- **THEN** the batch reverts `ExecutorCodehashMismatch` before any call executes

#### Scenario: Net-outflow ceiling
- **WHEN** a batch moves more of the vault asset out of custody than `maxNetOutflow`
- **THEN** the batch reverts `MaxNetOutflowExceeded(netOutflow, cap)`

#### Scenario: Per-call breach bubbles through the vault
- **WHEN** a delegatecalled batch call's gross outflow exceeds its declared cap
- **THEN** `executeGovernorBatch` reverts with the library's `CallCapExceeded(index, outflow, cap)` — the whole batch rolls back; no partial execution is observable

#### Scenario: Batch meter still binds when per-call metering is skipped
- **WHEN** the governor supplies an empty `callCaps` array (the emergency rescue path)
- **THEN** per-call metering is skipped and the batch remains bounded by `maxNetOutflow`, the queue reserve, and the buffer checks

#### Scenario: Executor re-point is factory-only and atomic
- **WHEN** any address other than the factory calls the vault's `setExecutorImpl`
- **THEN** the call reverts; and a factory-driven re-point SHALL leave the executor address and the expected codehash consistent in the same transaction (never a stale hash against a new address)

## ADDED Requirements

### Requirement: Per-call gross-outflow metering in the batch executor
The shared batch executor library's `executeBatch(calls, asset, caps)` SHALL, when `caps` is non-empty, meter every call: `outflow_i = max(0, assetBalanceBefore_i − assetBalanceAfter_i)` measured on the executing vault's balance of `asset` (the library runs under delegatecall, so `address(this)` is the vault), and SHALL revert the entire batch with `CallCapExceeded(i, outflow_i, caps[i])` when any call's gross outflow exceeds its declared cap — fail-closed on money; there is no mode that lets the spend proceed while only the accounting objects. Metering SHALL be GROSS across calls: an inflow during call *j* SHALL NOT increase any other call's remaining budget (each call is judged against its own cap from its own pre-call snapshot; netting within one atomic call is inherent and permitted). A non-empty `caps` array whose length differs from `calls` SHALL revert `CapsLengthMismatch`. An empty `caps` array SHALL skip per-call metering entirely — reserved for callers with no propose-time declaration (the guardian-reviewed emergency path), which remain bounded by the vault's batch-level checks. The library SHALL remain stateless and access-control-free (the calling vault enforces authorization and custody limits), SHALL bubble sub-call revert data unchanged, and SHALL NOT retain the previous unmetered `executeBatch(calls)` selector — a mis-wired vault must fail closed, never fall back to unmetered execution. The simulation entrypoint SHALL accept the same `(asset, caps)` inputs and report each call's success, return data, and measured gross outflow, so proposers can size caps from a dry-run instead of guessing.

#### Scenario: Refund does not refill an earlier budget
- **GIVEN** caps `[100, 0]` where call 1 sends 100 of the asset out and call 2 receives 150 back
- **WHEN** the batch executes
- **THEN** it succeeds (call 1 outflow 100 ≤ 100; call 2 outflow 0 ≤ 0) — and reordering the inflow FIRST would not license call 2 to overspend: with caps `[0, 100]` and the outflow second, the outflow call is still judged only against its own cap

#### Scenario: Breach reverts the whole batch
- **WHEN** call 3 of a five-call batch exceeds its cap
- **THEN** the entire batch reverts `CallCapExceeded(2, outflow, cap)` — calls 1-2's effects are rolled back and calls 4-5 never run

#### Scenario: Zero cap enforces zero outflow
- **WHEN** a call with cap 0 moves any nonzero amount of the vault asset out of custody
- **THEN** the batch reverts `CallCapExceeded` — a zero cap is a binding declaration, not an unmetered call

#### Scenario: Length mismatch fails fast
- **WHEN** `executeBatch` receives three calls and two caps
- **THEN** it reverts `CapsLengthMismatch` before executing any call

#### Scenario: Simulation reports per-call outflows
- **WHEN** a proposer dry-runs a batch via the simulation entrypoint with candidate caps
- **THEN** the result reports each call's gross outflow so caps can be sized to observed behavior, and simulation never enforces authorization (eth_call usage, matching today's `simulateBatch` contract)
