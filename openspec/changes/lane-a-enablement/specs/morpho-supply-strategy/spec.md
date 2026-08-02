# morpho-supply-strategy — delta

## Purpose

A minimal Lane-A-capable strategy: supplies the vault asset to a single Morpho Blue lending market and its companion pricing adapter values the supply position with pure view accounting. Serves as the proof-of-life for the whole instant lane — priceable without oracles, liquid up to the market's idle liquidity.

## ADDED Requirements

### Requirement: Single-market supply lifecycle

The strategy SHALL supply the vault asset to exactly one Morpho Blue market fixed at initialization, whose loan asset SHALL equal the vault asset (validated at initialization; mismatch reverts). Execute SHALL pull the approved amount from the vault and supply it; settle SHALL withdraw the full supply position and push the entire resulting balance back to the vault. Adversary: a market/asset mismatch that supplies vault funds into a market whose loan asset the vault cannot redeem.

#### Scenario: Execute supplies to the market
- **WHEN** the governor batch executes the strategy with an approved amount
- **THEN** the full amount is supplied to the configured Morpho market for the strategy's account

#### Scenario: Settle unwinds fully
- **WHEN** the governor settles the strategy
- **THEN** the strategy withdraws its entire supply position (interest included) and transfers all held vault asset to the vault

### Requirement: View-only valuation via market accounting

The companion pricing adapter SHALL value the supply position by converting the strategy's supply shares to assets using the market's on-chain accounting state in a view context, and SHALL return `ok = false` (never revert) when the venue is not the configured Morpho contract, the position decodes to a different market than expected, or the share→asset conversion cannot be computed. No external price oracle SHALL be involved. Adversary: a strategy pointing the adapter at a spoofed market or venue contract to fabricate supply value.

#### Scenario: Supply position valued from market state
- **WHEN** the router values the strategy's supply position
- **THEN** the value equals the strategy's supply shares converted to assets at the market's current share price, in vault-asset units

#### Scenario: Wrong venue fails closed
- **WHEN** a position names a venue other than the canonical Morpho contract
- **THEN** the adapter returns `(0, false)`

### Requirement: Instant liquidity bounded by market liquidity

`availableLiquidity()` SHALL return the lesser of the strategy's redeemable supply value and the market's currently available (unborrowed) liquidity. `withdrawTo(assets)` SHALL be vault-only and SHALL withdraw exactly the requested assets from the market to the vault in the same transaction, reverting if the market cannot deliver. Adversary: a highly utilized market where advertised instant liquidity exceeds what Morpho can actually pay out, causing under-delivery against the vault's balance-difference check.

#### Scenario: Utilization caps advertised liquidity
- **WHEN** the market's unborrowed liquidity is less than the strategy's supply value
- **THEN** `availableLiquidity()` reports the market's unborrowed liquidity

#### Scenario: Withdraw within market liquidity
- **WHEN** the vault requests assets ≤ `availableLiquidity()`
- **THEN** the strategy delivers at least the requested assets to the vault in the same transaction

### Requirement: Position enumeration

While holding a supply position, `positions()` SHALL return exactly one position identifying the Morpho venue and the configured market; with no supply outstanding it SHALL return an empty set.

#### Scenario: Active supply enumerates one position
- **WHEN** the strategy has a nonzero supply balance
- **THEN** `positions()` returns exactly one Morpho supply position for the configured market
