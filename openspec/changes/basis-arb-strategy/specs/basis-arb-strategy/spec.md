## Purpose

A pair-agnostic strategy template that harvests the price gap between two
on-chain routes for the same asset pair, executing buy-cheap / sell-rich
atomically and ending every trade flat in the vault asset — so the vault's
exposure between transactions is custody of its own asset, never an open
directional position.

## ADDED Requirements

### Requirement: Every poke ends flat in the vault asset
A `pokeArb` call SHALL execute all legs of both routes within one
transaction and SHALL end with the clone holding no more than dust of any
non-asset token. A leg failure SHALL revert the entire poke; there SHALL be
no code path that leaves partial inventory on the clone in a successful
transaction.

The template's whole risk story rests here: if the clone never holds a
non-asset position across transactions, its `undeliveredValue` is its asset
balance and every existing residue mechanism applies unchanged.

#### Scenario: A failing final leg unwinds the whole poke
- **WHEN** the last leg of a poke reverts (slippage, liquidity, a hook)
- **THEN** the entire poke SHALL revert and the clone's balances SHALL be
  exactly what they were before the call

#### Scenario: No open position between pokes
- **WHEN** any successful poke completes
- **THEN** the clone's non-asset token balances SHALL each be ≤ dust

### Requirement: The contract verifies the basis; callers are untrusted
`pokeArb` SHALL be callable by anyone. The contract SHALL recompute the
two-route basis from pool state in the same transaction and SHALL revert
unless (a) the basis exceeds the configured `minBasisBps`, (b) the basis
exceeds the LIVE sum of all leg fees plus a configured margin, and (c) the
realized output is at least the input plus `minProfitBps`.

Fee reads SHALL be live per poke for any leg whose fee is dynamic (a v4
hook can change its fee at will), so a fee hike between configuration and
execution converts into a revert rather than a guaranteed-loss fill.

#### Scenario: A thin basis reverts, whoever calls
- **WHEN** `pokeArb` is called while the recomputed basis is at or below
  the live fee sum plus margin
- **THEN** the call SHALL revert and no swap SHALL have executed

#### Scenario: A dynamic-fee hike fails closed
- **WHEN** a v4 leg's hook raises its lpFee such that the configured
  `minBasisBps` no longer clears the live fee sum
- **THEN** a poke profitable under the old fee SHALL revert

#### Scenario: A hostile poker cannot close at a loss
- **WHEN** a caller supplies a `minOut` that would permit an unprofitable
  fill
- **THEN** the contract's own `minProfitBps` check SHALL still revert the
  poke

### Requirement: Routes are validated at initialization
`init` SHALL verify that both routes begin and end at the vault asset, that
consecutive legs share their connecting token, and that each leg's declared
tokens match the pool's actual `token0/token1` (v3) or currencies (v4).
A mis-wired route SHALL fail at init, before any capital moves.

#### Scenario: A broken chain fails at init
- **WHEN** `init` receives routes whose legs do not chain end-to-end from
  the vault asset back to the vault asset
- **THEN** initialization SHALL revert and the proposal carrying it SHALL
  never reach execution with capital

### Requirement: Settlement delivers, residue stays recoverable
`_settle` SHALL push the clone's full asset balance to the vault. `sweep`
SHALL remain the post-settlement recovery path for any token a lying ERC-20
strands on the clone, conforming to the vault-only sweep convention and the
vault's `collectResidue` machinery unchanged.

#### Scenario: Settle after a quiet window
- **WHEN** a window elapses with zero successful pokes
- **THEN** settlement SHALL deliver the original funding in full, minus
  nothing
