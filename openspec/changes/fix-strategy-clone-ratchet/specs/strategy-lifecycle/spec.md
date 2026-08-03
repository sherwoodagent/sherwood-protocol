# strategy-lifecycle (delta)

New capability spec. `BaseStrategy` predates the openspec tree; this delta
adds only the requirements introduced by this change (proposal-bound
execution, plus the one-shot ratchet invariant it defends and the deliberate
settlement posture). It is not a retrofit of the whole contract.

## ADDED Requirements

### Requirement: Strategy clone execution is bound to the clone's owning proposal

`BaseStrategy.execute()` SHALL, after the existing `onlyVault` caller check
and before any state write, verify that this clone is the declared strategy
of the vault's currently-active proposal, and revert
`NotActiveProposalStrategy()` otherwise. The binding SHALL be resolved
through the existing seams — `vault() → governor()` and the governor's
`IProposalStatus` views (`getActiveProposal()`, `strategyOf(proposalId)`) —
never through new storage on the clone, a clone registry, or a restated copy
of the governor's proposal state.

ADVERSARY: governor batches execute via delegatecall in the vault, so every
sub-call of every proposal's batch reaches its target with
`msg.sender == vault`. Without this check, any registered agent who gets any
proposal executed can include `clone.execute()` against a clone pre-deployed
for a different, later proposal, permanently flipping its one-shot
`Pending → Executed` ratchet and bricking the later proposal with
`AlreadyExecuted` before it is voted on (issue #150; PoC verified 2026-08-03
post-#118). The privileged-batch-target denylist deliberately exempts
strategy entrypoints as the legitimate batch surface, so this check is the
sole enforcement of proposal identity at the clone.

The check SHALL be fail-closed: it consumes typed external calls with no
capability probe, no try/catch, and no degrade-open path. A clone whose vault
or governor cannot answer the binding views SHALL refuse to execute. This is
the deliberate inversion of the propose-time target validation's degrade-open
posture: that check has an authoritative guard behind it; this check IS the
enforcement, and a refused execute is recoverable (redeploy) where a flipped
ratchet is not.

#### Scenario: Unrelated proposal's batch cannot flip a foreign clone's ratchet

- **GIVEN** a strategy clone pre-deployed via `StrategyFactory` for a future proposal
- **WHEN** a different proposal — one whose declared strategy is not this clone — executes a batch containing a call to this clone's `execute()`
- **THEN** the call SHALL revert `NotActiveProposalStrategy()`, the whole batch (and therefore that proposal's `executeProposal`) SHALL fail, and the clone's ratchet SHALL remain `Pending`
- **AND** the later proposal that declares this clone SHALL subsequently execute it normally

#### Scenario: Owning proposal executes its declared clone

- **WHEN** `executeProposal` runs the batch of the proposal whose stored `strategy` equals the clone (the governor sets the active-proposal id before the batch runs)
- **THEN** the binding check SHALL pass and the ratchet SHALL flip `Pending → Executed` exactly once
- **AND** a second `execute()` call in the same or a later batch SHALL still revert `AlreadyExecuted` — the one-shot ratchet semantics are unchanged for the owner

#### Scenario: No active proposal means no execution

- **WHEN** the vault calls `execute()` on a clone while the governor reports no active proposal (id 0)
- **THEN** the call SHALL revert `NotActiveProposalStrategy()` (the zero id resolves to strategy `address(0)`, which never equals a clone)

#### Scenario: Unresolvable binding fails closed

- **WHEN** the clone's vault does not expose `governor()`, or the resolved governor does not expose the `IProposalStatus` views, or any hop of the walk reverts
- **THEN** `execute()` SHALL revert rather than skip the check — a clone that cannot verify which proposal is driving it SHALL NOT deploy capital

### Requirement: Settlement is transitively protected and deliberately open for orphan recovery

`BaseStrategy.settle()` SHALL NOT carry the active-proposal binding check.
Its protection against the same adversary is transitive and SHALL be
preserved by construction: `settle()` requires `_state == Executed`, which —
given the execution binding above — only the owning proposal's batch can
set; and while that proposal is open, the governor's single-open-proposal
invariant prevents any other proposal's batch from existing. The unguarded
`settle()` is load-bearing for recovery: a clone orphaned in `Executed`
(its proposal settled through owner-supplied emergency calls that bypassed
it) SHALL remain settleable by a later proposal's batch, returning its held
funds to the vault. Any future change adding a proposal-binding check to
`settle()` MUST first account for orphaned-clone fund recovery.

#### Scenario: Orphaned clone remains settleable

- **GIVEN** a clone in `Executed` whose owning proposal reached a terminal state via an emergency settlement that did not call the clone
- **WHEN** a later proposal's batch calls the clone's `settle()`
- **THEN** the call SHALL succeed, the clone SHALL push its held balances back to the vault, and the ratchet SHALL reach `Settled`

#### Scenario: Foreign settle before execution is impossible

- **WHEN** any batch calls `settle()` on a clone still in `Pending`
- **THEN** the call SHALL revert `NotExecuted` — the execution binding upstream means no foreign batch can first move the clone to `Executed` to open this path
