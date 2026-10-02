# syndicate-vault (delta)

## ADDED Requirements

### Requirement: Per-call gross-outflow metering in the batch executor
The shared batch executor library's `executeBatch(calls, asset, caps)` SHALL, when `caps` is non-empty, meter every call: `outflow_i = max(0, assetBalanceBefore_i − assetBalanceAfter_i)` measured on the executing vault's balance of `asset` (the library runs under delegatecall, so `address(this)` is the vault), and SHALL revert the entire batch with `CallCapExceeded(i, outflow_i, caps[i])` when any call's gross outflow exceeds its declared cap — fail-closed on money; there is no mode that lets the spend proceed while only the accounting objects. Metering SHALL be GROSS across calls: an inflow during call *j* SHALL NOT increase any other call's remaining budget (each call is judged against its own cap from its own pre-call snapshot; netting within one atomic call is inherent and permitted). A non-empty `caps` array whose length differs from `calls` SHALL revert `CapsLengthMismatch`. An empty `caps` array SHALL skip per-call metering entirely — reserved for callers with no propose-time declaration (the guardian-reviewed emergency path), which remain bounded by the vault's batch-level checks. The library SHALL remain stateless and access-control-free (the calling vault enforces authorization and custody limits), SHALL bubble sub-call revert data unchanged, and SHALL NOT retain the previous unmetered `executeBatch(calls)` selector — a mis-wired vault must fail closed, never fall back to unmetered execution. The library's `simulateBatch(calls, asset, caps)` SHALL accept the same inputs and report each call's success, return data, and measured gross outflow on `address(this)`, so a proposer can size caps from a dry-run executed in the vault's context (an `eth_call` with a state override placing the library at the vault); the vault exposes no simulation entrypoint of its own.

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
- **WHEN** a proposer dry-runs a batch through `simulateBatch` in the vault's context with candidate caps
- **THEN** the result reports each call's gross outflow so caps can be sized to observed behavior, and simulation never enforces authorization (eth_call usage, matching today's `simulateBatch` contract)
