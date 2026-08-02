# erc20-spot-pricing — delta

## Purpose

Defines the first production pricing adapter: values plain ERC-20 spot positions (tokenized stocks and similar) held by a strategy, using Chainlink push feeds, so the PriceRouter can open Lane A over spot baskets. Fail-closed: any doubt about quantity, price, or freshness makes the position instant-ineligible.

## ADDED Requirements

### Requirement: Venue-read quantity, never self-reported

The adapter SHALL derive position quantity exclusively by reading the token balance of the holder at the venue token contract (`balanceOf(holder)` where `venue` is the ERC-20 token). The adapter SHALL NOT accept any quantity, balance, or value figure supplied by the strategy or embedded in the position's `ref`. Adversary: a malicious or buggy strategy inflating its reported holdings to overstate live NAV and let exiters drain the vault at a fictitious mark.

#### Scenario: Quantity comes from the token contract
- **WHEN** the adapter values a position whose venue is an ERC-20 token
- **THEN** the quantity used is exactly the venue token's `balanceOf(holder)` at call time

### Requirement: Governance-registered feeds, not position-chosen

The adapter SHALL price the quantity using the Chainlink push feed (AggregatorV3) mapped to the venue token in an adapter-owned, governance-maintained token→feed registry, converting the result into the vault-asset units the PriceRouter aggregates and honoring both token and feed decimals. The feed and its maximum acceptable price age SHALL come from the registry alone — the position's `ref` SHALL NOT be able to select or override the feed. A venue token with no registry entry SHALL value as `(0, false)`. The adapter SHALL return `ok = false` when the feed answer is non-positive, the round is incomplete, or the price is older than the registered age bound. Adversary: a malicious strategy pricing token X's real balance with token Y's (higher) feed to inflate live NAV; and a stale or broken feed letting instant exits execute at a price the market has moved away from, at remaining LPs' expense.

#### Scenario: Fresh price values the position
- **WHEN** the venue token has a registered feed reporting a positive price within the registered age bound
- **THEN** the adapter returns `(quantity × price scaled to vault-asset units, ok = true)`

#### Scenario: Unregistered token fails closed
- **WHEN** a position's venue token has no registry entry
- **THEN** the adapter returns `(0, false)`

#### Scenario: Stale price fails closed
- **WHEN** the feed's latest update is older than the position's age bound
- **THEN** the adapter returns `(0, false)` and the router degrades the strategy to Lane B

#### Scenario: Broken feed fails closed
- **WHEN** the feed reverts, reports a non-positive answer, or reports an unanswered round
- **THEN** the adapter returns `(0, false)` without reverting

### Requirement: Malformed positions are instant-ineligible, never a revert

For any position the adapter cannot interpret — zero venue, unparseable `ref`, feed decimals outside supported range, or a venue that is not a readable ERC-20 — the adapter SHALL return `(0, false)` rather than revert, so `SyndicateVault.totalAssets()` can never be bricked by a bad position. Adversary: a strategy publishing a poisoned position to make NAV reads revert and freeze exits.

#### Scenario: Unparseable ref
- **WHEN** a position's `ref` does not decode to a valid feed locator
- **THEN** the adapter returns `(0, false)`

### Requirement: Per-token instant cap in the adapter registry

The registry entry for each token SHALL carry a per-token cap in vault-asset units; a position whose computed value exceeds its token's cap SHALL value as `(0, false)`. Rationale: the router's `instantCap` is per-kind, so heterogeneous pool depths (e.g. NVDA ~$100k-safe vs TSLA ~$7.5k-safe) cannot be expressed there without collapsing every token to the smallest cap. Adversary: an instant exit sized beyond the token's real DEX depth, unwinding at a slippage the instant-exit fee cannot cover and socializing the gap to remaining LPs.

#### Scenario: Over-cap position fails closed
- **WHEN** a position's computed value exceeds the registered per-token cap
- **THEN** the adapter returns `(0, false)` and the strategy degrades to Lane B

### Requirement: Oracle-vs-pool divergence gate

The registry entry for each token SHALL carry a reference DEX pool and a maximum divergence in bps; when set, the adapter SHALL compare the feed price against the pool's current spot price and return `(0, false)` when they diverge beyond the bound. Adversary: a held/stale oracle mark (e.g. the 24/5 equity feed's weekend hold-last-price regime, or a deviation-threshold lag) sitting above the live pool price, letting an exiter be paid an oracle mark the vault cannot realize — measured basis of ~40bps exists at rest and the instant-exit fee ceiling (200bps) cannot cover a stale-mark regime, so marks diverging >100bps from executable price must close Lane A rather than misprice it.

#### Scenario: Divergent oracle fails closed
- **WHEN** the feed price and the reference pool spot diverge beyond the registered bound
- **THEN** the adapter returns `(0, false)`

### Requirement: View-only valuation

Valuation SHALL be a view operation with no state changes, token transfers, or external calls beyond reading the venue token and the price feed.

#### Scenario: Valuation has no side effects
- **WHEN** the router values an ERC20 spot position
- **THEN** no state on the adapter, venue, or holder changes
