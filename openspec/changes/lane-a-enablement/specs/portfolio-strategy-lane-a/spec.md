# portfolio-strategy-lane-a — delta

## Purpose

Makes the weighted-basket portfolio strategy Lane-A-capable: it enumerates its spot holdings as router-priceable positions and can unwind exactly a requested shortfall to the vault in the same transaction, so instant exits work against a live basket during an active proposal.

## ADDED Requirements

### Requirement: Position enumeration mirrors the basket

While the strategy is in its executed (positions-held) state, `positions()` SHALL return one ERC-20 spot position per basket slot — venue = the slot's token, with an empty locator (the pricing adapter's governance registry, not the position, selects the feed) — and nothing else. Before execution and after settlement `positions()` SHALL return an empty set (Lane B float-only). The enumeration SHALL NOT include any value or quantity figures; the router reads quantities from the venues. Adversary: a divergence between reported positions and actual holdings that lets NAV omit (or double-count) basket value.

#### Scenario: Executed basket enumerates all slots
- **WHEN** the strategy holds an executed basket of N tokens
- **THEN** `positions()` returns exactly N spot positions, one per basket token

#### Scenario: Settled strategy reports no positions
- **WHEN** the strategy has settled back to the vault asset
- **THEN** `positions()` returns an empty array

#### Scenario: Rebalance in progress suspends enumeration
- **WHEN** a rebalance is mid-flight (sell leg done, buy leg pending)
- **THEN** `positions()` returns an empty array so Lane A fails closed rather than pricing a transiently distorted basket

### Requirement: Instant liquidity is quoted, conservative, and capped

`availableLiquidity()` SHALL report the vault-asset value the strategy can deliver in one transaction: its idle vault-asset balance plus a conservative estimate of what the basket can be sold for through the configured swap venue at current conditions. The estimate SHALL be no greater than the router-priced basket value and SHALL degrade to the idle balance alone when quoting is unavailable. Adversary: an overstated liquidity figure causing the vault to attempt an unwind that under-delivers and reverts exits that Lane A advertised as available.

#### Scenario: Quote unavailable degrades to idle balance
- **WHEN** the swap venue cannot quote a basket token
- **THEN** `availableLiquidity()` returns only the strategy's idle vault-asset balance

### Requirement: Shortfall unwind delivers exactly what the vault asked

`withdrawTo(assets)` SHALL be callable only by the vault and SHALL deliver at least `assets` of the vault asset to the vault in the same transaction, selling basket tokens through the configured swap path only as far as needed (idle balance first, then pro-rata or cheapest-first basket sales bounded by the strategy's slippage limit). If the full amount cannot be delivered within the slippage limit, the call SHALL revert rather than under-deliver. Adversary: an unwind that silently delivers less than requested, breaking the vault's balance-difference delivery check and stranding an exit mid-transaction; and an unbounded market sell that dumps the basket at any price, socializing slippage to remaining LPs.

#### Scenario: Idle balance covers the shortfall
- **WHEN** the requested assets are ≤ the strategy's idle vault-asset balance
- **THEN** the strategy transfers from idle balance without touching the basket

#### Scenario: Basket sale within slippage bound
- **WHEN** the request exceeds idle balance but the remainder can be raised selling basket tokens within the slippage limit
- **THEN** the strategy sells only what is needed and delivers at least the requested assets

#### Scenario: Unfillable request reverts
- **WHEN** the request cannot be met within the slippage limit
- **THEN** `withdrawTo` reverts and no partial delivery occurs

### Requirement: Lane A surface does not alter proposal lifecycle behavior

Adding position enumeration and instant liquidity SHALL NOT change the strategy's execute, settle, parameter-update, or rebalance behavior as observed by the governor and vault; settlement SHALL remain the sole terminal unwind path.

#### Scenario: Settle unchanged
- **WHEN** the governor settles the strategy after Lane A activity (partial unwinds) occurred
- **THEN** settle sells the remaining basket and pushes the remaining balance to the vault exactly as before
