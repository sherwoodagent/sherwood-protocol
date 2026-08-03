# venice-inference-strategy Specification

## Purpose
TBD - created by archiving change venice-inference-adapter-allowlist. Update Purpose after archive.
## Requirements
### Requirement: aeroRouter and sVVV must be allowlisted in the vault's tier registry

`VeniceInferenceStrategy._initialize` SHALL, before writing any state,
resolve the tier registry through the walk
`vault() → governor() → tierRegistry()` and revert
`AdapterNotAllowed(adapter, registry)` unless `isAdapterAllowed(adapter)`
returns true in the resolved registry, for BOTH:

- `aeroRouter_`, when `asset != vvv` (the only condition under which
  `aeroRouter` receives an ERC-20 approval).
- `sVVV_`, unconditionally (it always receives an approval and a `stake()`
  call in `_execute`).

This is the SAME registry `SyndicateVault._guardBatchCalls` consults: the
strategy's internal `forceApprove(aeroRouter, …)` / `forceApprove(sVVV, …)`
calls grant exactly the permission class the allowlist bounds, one frame
deeper than the batch guard can see.

Every hop of the walk SHALL be a raw staticcall hardened against hostile or
absent targets: a codeless target, a reverting call, a return shorter than
one word, or a returned word with dirty upper bits SHALL each resolve the hop
to "unset" rather than reverting. When the walk yields no registry, the check
SHALL be SKIPPED and initialization proceeds — this skip is deliberate and
bounded: it is exactly the condition under which the vault's own batch guard
disables itself, and no hop of the walk reads proposer input.

When the walk DOES resolve a registry, the requirement is hard and
fail-closed: a registry whose `isAdapterAllowed` reverts or returns malformed
data SHALL be treated as refusal (`AdapterNotAllowed`), never as a skip.

#### Scenario: Non-allowlisted aeroRouter refused at init
- **WHEN** a strategy clone is initialized with `asset != vvv` against a
  vault whose governor has a wired TierRegistry, with an `aeroRouter_` not on
  that registry's allowlist
- **THEN** initialization reverts `AdapterNotAllowed(aeroRouter, registry)`

#### Scenario: Non-allowlisted sVVV refused at init
- **WHEN** a strategy clone is initialized against a vault whose governor has
  a wired TierRegistry, with an `sVVV_` not on that registry's allowlist
- **THEN** initialization reverts `AdapterNotAllowed(sVVV, registry)`,
  regardless of whether `aeroRouter` is allowlisted or even used

#### Scenario: Both allowlisted — init succeeds unchanged
- **WHEN** both `aeroRouter_` and `sVVV_` are allowlisted (or `asset == vvv`
  so `aeroRouter` is never checked)
- **THEN** initialization proceeds exactly as before this change

#### Scenario: Unresolved registry walk skips the check
- **WHEN** the walk `vault() → governor() → tierRegistry()` yields no
  registry (codeless vault, no `governor()` surface, `governor() == 0`, no
  `tierRegistry()` getter, or `tierRegistry() == 0`)
- **THEN** initialization proceeds without reverting for either address

#### Scenario: Resolved-but-unreadable registry fails closed
- **WHEN** the walk resolves a registry address, but that registry's
  `isAdapterAllowed` call reverts or returns a malformed (non-32-byte)
  response
- **THEN** initialization reverts `AdapterNotAllowed(adapter, registry)`

