# portfolio-strategy Specification

## Purpose
TBD - created by archiving change portfolio-swap-adapter-allowlist. Update Purpose after archive.
## Requirements
### Requirement: The proposer-supplied swap adapter must be an allowed counterparty in the vault's tier registry

`PortfolioStrategy._initialize` SHALL, before writing any state, resolve the
tier registry through the walk `vault() → governor() → tierRegistry()` and
revert `AdapterNotAllowed(swapAdapter, registry)` unless
`isCounterpartyAllowed(swapAdapter_)` returns true in the resolved registry.
The strategy's internal `forceApprove(swapAdapter, …)` calls hand the adapter
the basket's funds one frame below the vault's batch guard, which admits the
strategy clone and never sees the adapter, so this binding is the only check
on where those approvals go.

Every hop of the walk SHALL be a raw staticcall hardened against hostile or
absent targets: a codeless target, a reverting call, a return shorter than one
word, or a returned word with dirty upper bits SHALL each resolve the hop to
"unset". When the walk yields no registry, initialization SHALL revert
`TierRegistryUnresolved`. The allowlist read itself SHALL be a length-checked
raw staticcall where a codeless registry, a revert, or a malformed return reads
as "not allowed". No hop of the walk reads proposer input: it starts at
`vault()`, which is BaseStrategy state fixed before `_initialize` runs.

#### Scenario: Adapter not allowlisted
- **WHEN** a proposer initializes a clone naming a swap adapter that is not an allowed counterparty in the vault's tier registry
- **THEN** `_initialize` reverts `AdapterNotAllowed(swapAdapter, registry)` before any state is written

#### Scenario: Allowlisted adapter accepted
- **WHEN** the named swap adapter is an allowed counterparty
- **THEN** the adapter check passes and initialization continues

#### Scenario: Unresolved walk refuses initialization
- **WHEN** the walk from `vault()` cannot resolve a tier registry
- **THEN** `_initialize` reverts `TierRegistryUnresolved`

### Requirement: The swap adapter binding is immutable after initialization and re-checked before capital moves

The swap adapter SHALL be fixed at initialization; no parameter update can
change it. `_execute` SHALL re-check, before pulling any vault funds, that the
adapter and every slot's price feed are still allowed counterparties and that
the vault asset is still priced at $1 (see the USD-asset requirement), and SHALL
revert otherwise. `_settle` SHALL NOT read the registry or the peg, so a
demotion between execution and settlement cannot strand the basket: the
proposal can always unwind.

`_updateParams` SHALL accept only a tighter slippage tolerance: a non-empty
weights array SHALL revert `WeightsFrozen`, and non-empty route data SHALL
revert `RoutesFrozen`.

#### Scenario: Adapter demoted before execute
- **WHEN** an initialized clone's adapter loses its counterparty grant before the proposal executes
- **THEN** `_execute` reverts `AdapterNotAllowed` and no vault funds move

#### Scenario: Adapter demoted mid-strategy
- **WHEN** an executed clone's adapter is removed from the allowlist before settlement
- **THEN** settlement still runs, because `_settle` performs no allowlist read

#### Scenario: Weights or routes cannot be changed
- **WHEN** the proposer submits a parameter update carrying new weights or new route data
- **THEN** the update reverts `WeightsFrozen` or `RoutesFrozen` respectively

### Requirement: `rebalanceDelta` re-checks the swap adapter and the price feeds on every call

`rebalanceDelta()` is proposer-only, runs only in the Executed state, and
prices every slot off its push feed. It SHALL, before any swap, re-resolve the
tier registry and revert `AdapterNotAllowed(swapAdapter, registry)` unless the
bound adapter is still an allowed counterparty, and revert
`PriceSourceNotAllowed(priceSource, registry)` unless every slot's feed still
is. An unresolved walk SHALL revert `TierRegistryUnresolved`. This narrows a
demotion's window to "no further rebalance", so a demoted adapter cannot keep
receiving fresh approvals through repeated rebalances.

#### Scenario: Rebalance after the adapter is demoted
- **WHEN** the proposer calls `rebalanceDelta` after the bound adapter's counterparty grant is removed
- **THEN** the call reverts `AdapterNotAllowed(swapAdapter, registry)` before any swap or approval

#### Scenario: Rebalance with the adapter still allowlisted
- **WHEN** the proposer calls `rebalanceDelta` and the bound adapter and every feed are still allowed counterparties
- **THEN** the re-checks pass and the rebalance proceeds as before

### Requirement: Swap slippage tolerance is floored at MIN_SLIPPAGE_BPS

`PortfolioStrategy` SHALL enforce `MIN_SLIPPAGE_BPS = 50` (0.5%) as a floor on
`maxSlippageBps`, alongside the existing `MAX_SLIPPAGE_CEILING_BPS = 1_000`
ceiling. `_initialize` SHALL revert `InvalidSlippage` when `maxSlippageBps_` is
below the floor or above the ceiling. `_updateParams` SHALL revert
`InvalidSlippage` when a non-zero new tolerance is below the floor or above the
current value (tighten-only); a zero value keeps the current tolerance. Every
swap — at execute, at settle and in `rebalanceDelta` — SHALL floor its output at
the slot's feed price less `maxSlippageBps`.

#### Scenario: Zero slippage at init rejected
- **WHEN** a proposer initializes a clone with `maxSlippageBps = 0`
- **THEN** initialization reverts `InvalidSlippage`

#### Scenario: Floor and ceiling accepted at init
- **WHEN** a proposer initializes with `maxSlippageBps` equal to `MIN_SLIPPAGE_BPS` or to `MAX_SLIPPAGE_CEILING_BPS`
- **THEN** initialization succeeds

#### Scenario: Tightening below the floor rejected
- **WHEN** the proposer calls `updateParams` with a non-zero `newMaxSlippageBps` below `MIN_SLIPPAGE_BPS`
- **THEN** the update reverts `InvalidSlippage`

#### Scenario: Zero keeps the current tolerance
- **WHEN** the proposer calls `updateParams` with `newMaxSlippageBps = 0` and no weights or route data
- **THEN** the tolerance is unchanged

