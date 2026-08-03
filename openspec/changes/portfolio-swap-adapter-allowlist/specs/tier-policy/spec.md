# tier-policy (delta)

One MODIFIED requirement: the adapter allowlist gains a second consumer
(`PortfolioStrategy._initialize`), so the requirement that scoped it to
governor batches is updated to name both. TierRegistry code is unchanged by
this change — storage, surface, events, and the one-way demotion coupling are
all exactly as specified today.

## MODIFIED Requirements

### Requirement: Adapter allowlist is a separate axis from tiers

The registry SHALL maintain an owner-managed allowlist of adapter addresses
(`setAdapterAllowed(adapter, allowed)`, emitting `AdapterAllowedSet`; read via
`isAdapterAllowed(adapter)`). Tiers PRICE extractable value for coverage; the
allowlist bounds WHERE vault funds may be approved or sent at all. It is
consumed at two enforcement points, both gating the same permission class:

1. `SyndicateVault._guardBatchCalls` — the spender/recipient of value-moving
   ERC20 calls (approve / increaseAllowance / transfer / transferFrom-out)
   inside governor batches.
2. `PortfolioStrategy._initialize` — the proposer-supplied swap adapter that
   the strategy will later `forceApprove` vault capital to from inside its own
   frame, one hop outside the batch calldata the vault guard inspects. The
   strategy resolves the registry through
   `vault() → governor() → tierRegistry()` and refuses a non-allowlisted
   adapter at initialization (see the portfolio-strategy capability for the
   walk and degrade semantics).

The coupling between the two axes SHALL be exactly one-way and fail-closed:
demotion clears the allowlist entry (see "Three demotion paths converging on
one effect"), but NO certification action ever sets or restores it. In
particular, re-certifying a previously demoted (target, selector) SHALL NOT
re-allowlist the target — `certify` would otherwise silently re-grant a
payment permission as a side effect of a pricing action, and the adversary is
a submitter who gets a certification through and thereby re-opens the funds
path without the owner ever deciding to. Restoring the allowlist after a
demotion is always an explicit owner `setAdapterAllowed(adapter, true)` call.
Because demotion clears the entry, a demoted adapter is simultaneously refused
by BOTH consumers: existing batches cannot fund it and new strategies cannot
bind to it, with no additional wiring.

#### Scenario: Disallowed adapter as ERC20 spender
- **WHEN** a governor batch contains an ERC20 approval whose spender is not on
  the allowlist
- **THEN** the vault's batch guard rejects it regardless of the target's tier

#### Scenario: Disallowed adapter as a strategy's swap adapter
- **WHEN** a PortfolioStrategy clone is initialized on a wired stack with a
  swap adapter not on the allowlist
- **THEN** initialization reverts `AdapterNotAllowed` — the strategy-side
  consumer enforces the same allowlist the batch guard does

#### Scenario: Allowlisting is owner-only
- **WHEN** a non-owner calls `setAdapterAllowed`
- **THEN** the call reverts (Ownable)

#### Scenario: Re-certification does not restore the allowlist
- **WHEN** a demoted adapter (allowlist auto-cleared) is later re-certified via
  `certify`
- **THEN** `isAdapterAllowed(adapter)` still returns false until the owner
  explicitly calls `setAdapterAllowed(adapter, true)`

#### Scenario: Owner recovery after an over-broad clear
- **WHEN** the owner calls `setAdapterAllowed(adapter, true)` after a demotion
  cleared the adapter's entry
- **THEN** `isAdapterAllowed(adapter)` returns true again and governor batches
  may fund the adapter as before
