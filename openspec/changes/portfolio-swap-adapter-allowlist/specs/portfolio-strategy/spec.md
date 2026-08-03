# portfolio-strategy (delta)

New capability spec. PortfolioStrategy predates the openspec tree; this delta
adds only the two requirements introduced by this change (swap-adapter
provenance and the slippage floor). It is not a retrofit of the whole contract.

## ADDED Requirements

### Requirement: The proposer-supplied swap adapter must be allowlisted in the vault's tier registry

`PortfolioStrategy._initialize` SHALL, before writing any state, resolve the
tier registry through the walk `vault() → governor() → tierRegistry()` and
revert `AdapterNotAllowed(swapAdapter, registry)` unless
`isAdapterAllowed(swapAdapter_)` returns true in the resolved registry. This is
the SAME registry `SyndicateVault._guardBatchCalls` consults: the strategy's
internal `forceApprove(swapAdapter, …)` calls grant exactly the permission
class the allowlist bounds ("where vault funds may be approved or sent"), one
frame deeper than the batch guard can see.

Every hop of the walk SHALL be a raw staticcall hardened against hostile or
absent targets: a codeless target, a reverting call, a return shorter than one
word, or a returned word with dirty upper bits SHALL each resolve the hop to
"unset" rather than reverting. When the walk yields no registry — codeless
vault, no `governor()` surface, `governor() == 0`, no `tierRegistry()` getter,
or `tierRegistry() == 0` — the check SHALL be SKIPPED and initialization
proceeds. This skip is deliberate and bounded: it is exactly the condition
under which the vault's own batch guard disables itself (a batch could already
approve funds to any address), and no hop of the walk reads proposer input, so
a proposer cannot force the skip — the walk starts at `vault()`, which is
BaseStrategy state fixed before `_initialize` runs.

When the walk DOES resolve a registry, the requirement is hard and
fail-closed: a registry whose `isAdapterAllowed` reverts or returns malformed
data SHALL be treated as refusal (`AdapterNotAllowed`), never as a skip — a
registry that cannot vouch for the adapter has not vouched for it.

#### Scenario: Non-allowlisted adapter refused at init
- **WHEN** a strategy clone is initialized against a vault whose governor has
  a wired TierRegistry, with a `swapAdapter_` not on that registry's allowlist
- **THEN** initialization reverts `AdapterNotAllowed(swapAdapter, registry)`
  before any strategy state is written

#### Scenario: Allowlisted adapter accepted
- **WHEN** the same stack initializes a clone whose `swapAdapter_` the registry
  owner has allowlisted via `setAdapterAllowed(adapter, true)`
- **THEN** initialization succeeds and the adapter is bound

#### Scenario: Unresolved walk skips the check
- **WHEN** a clone is initialized against a codeless vault address, or a vault
  whose governor lacks a `tierRegistry()` getter, or a governor whose
  `tierRegistry()` returns zero
- **THEN** initialization proceeds without consulting any allowlist — the same
  degrade the vault's batch guard documents for an unwired registry

#### Scenario: Resolved but unreadable registry fails closed
- **WHEN** the walk resolves a nonzero, code-bearing registry whose
  `isAdapterAllowed(adapter)` reverts or returns malformed data
- **THEN** initialization reverts `AdapterNotAllowed` — unreadable is refusal,
  not a skip

### Requirement: The swap adapter binding is immutable after initialization and checked only there

`swapAdapter` SHALL be written exactly once, in `_initialize`; no
parameter-update or any other path may change it (`_updateParams` accepts only
weights, slippage, and route data, and routes are frozen post-execute).
`_execute` and `_settle` SHALL NOT re-check the allowlist: a demotion that
clears the adapter's allowlist entry after a strategy initialized MUST NOT add
a revert path to that strategy's settlement — with vault capital held as
basket tokens, a settle-time re-check would convert a registry state change
into stranded LP funds recoverable only through the emergency path. The
init-time check certifies provenance at binding time; later registry changes
are handled by governance (veto/guardian review before execute, demotion
machinery and the emergency path after).

#### Scenario: Demotion after init does not brick settlement
- **WHEN** a strategy initialized with an allowlisted adapter has executed, and
  the adapter's allowlist entry is subsequently cleared by a demotion
- **THEN** `settle()` still runs to completion — the strategy performs no
  allowlist read after initialization

### Requirement: Swap slippage tolerance is floored at MIN_SLIPPAGE_BPS

The contract SHALL expose `MIN_SLIPPAGE_BPS = 50` and enforce
`MIN_SLIPPAGE_BPS <= maxSlippageBps <= MAX_SLIPPAGE_CEILING_BPS` both at
`_initialize` (reverting `InvalidSlippage` otherwise; the previous
`maxSlippageBps_ == 0` rejection is subsumed by the floor) and on every
nonzero `newMaxSlippageBps` in `_updateParams`, where it combines with the
existing tighten-only rule: an update SHALL revert `InvalidSlippage` when the
new value exceeds the current one OR sits below the floor. The
`newMaxSlippageBps == 0` sentinel SHALL retain its "keep current value"
meaning and SHALL NOT be evaluated against the floor. Rationale: the tolerance
doubles as the tolerance applied to oracle-anchored `minOut` floors in
`rebalanceDelta`, so a value below the venue fee makes those swaps
structurally unfillable, and the tighten-only rule would make that state
irreversible for the strategy's lifetime.

#### Scenario: Init below the floor refused
- **WHEN** a clone is initialized with `maxSlippageBps_` of 49 or less
  (including 0)
- **THEN** initialization reverts `InvalidSlippage`

#### Scenario: Tighten below the floor refused
- **WHEN** the proposer calls `updateParams` on an executed strategy with a
  nonzero `newMaxSlippageBps` below `MIN_SLIPPAGE_BPS`
- **THEN** the call reverts `InvalidSlippage` and the stored tolerance is
  unchanged

#### Scenario: Zero sentinel still means keep-current
- **WHEN** the proposer calls `updateParams` with `newMaxSlippageBps == 0`
  alongside a valid weights update
- **THEN** the weights update applies and `maxSlippageBps` is unchanged — the
  sentinel is not floor-checked

#### Scenario: The floor bottoms out without trapping
- **WHEN** a strategy initialized at exactly `MIN_SLIPPAGE_BPS` submits an
  update re-asserting `MIN_SLIPPAGE_BPS`
- **THEN** the update succeeds (equality passes the tighten-only rule); any
  strictly lower value is refused
