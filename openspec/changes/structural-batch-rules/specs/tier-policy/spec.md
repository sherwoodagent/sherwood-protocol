## ADDED Requirements

### Requirement: Permissionless strategy registration

`StrategyFactory.registerStrategy(strategy)` SHALL be callable by any address with no fee. It SHALL revert `NotAStrategy(strategy)` when `strategy` has no code or when any of `IStrategy`'s `vault()`, `proposer()` and `executed()` does not answer exactly one word; otherwise it SHALL record `registeredStrategy[strategy] = true` and `registeredCodehash[strategy] = strategy.codehash` and emit `StrategyRegistered(strategy, codehash)`. `isRegisteredStrategy(strategy)` SHALL return true iff the strategy is recorded and its current codehash equals the recorded one. `cloneAndInit` and `cloneAndInitDeterministic` SHALL register the clone they mint. Registration SHALL NOT require `vault()` to equal any particular vault. Registration is a shape, not a certification: a registered strategy prices at tier 2 until certified through the existing certification paths.

#### Scenario: Anyone registers a conformant strategy
- **WHEN** an arbitrary address calls `registerStrategy` with a contract answering the three getters
- **THEN** the call succeeds, `StrategyRegistered` is emitted and `isRegisteredStrategy` is true

#### Scenario: Non-strategies cannot register
- **WHEN** `registerStrategy` is called with the withdrawal queue, an ERC-20, the vault, an EOA or a contract with no functions
- **THEN** the call reverts `NotAStrategy(strategy)`

#### Scenario: A code change de-registers
- **WHEN** a registered strategy's code changes
- **THEN** `isRegisteredStrategy` is false until it is registered again (which requires the new code to conform)

#### Scenario: Minted clones are registered
- **WHEN** `cloneAndInit` or `cloneAndInitDeterministic` mints a clone
- **THEN** `isRegisteredStrategy(clone)` is true and the template itself is not registered by that act

### Requirement: The counterparty allowlist is the only address axis
The registry SHALL maintain exactly one owner-managed address allowlist, `setCounterpartyAllowed(counterparty, allowed)` (emitting `CounterpartyAllowedSet`; read via `isCounterpartyAllowed(counterparty)`), answering one question: may a certified strategy template bind this address as a venue — a lending market, a position manager, a swap adapter, a price feed, a collateral or volatile-leg token — inside the template's own reviewed code. It SHALL confer nothing to a governor batch: the vault's batch guard does not read it, and a proposal may call any address with or without an entry here. The grant SHALL snapshot the counterparty's effective codehash and `isCounterpartyAllowed` SHALL return true only while the live effective codehash equals the snapshot (the same lazy self-heal as `tierOf`); a re-grant re-attests the current code. There SHALL be no class fallback and no implication from any other standing.

#### Scenario: A template binds only a listed venue
- **WHEN** a template's `initialize` names a venue whose `isCounterpartyAllowed` is false
- **THEN** the clone reverts at init with the template's own "not allowed" error naming the venue and the registry

#### Scenario: A batch needs no counterparty entry
- **WHEN** a governor batch approves and calls an address with no counterparty entry
- **THEN** the vault's guard admits it; the entry is irrelevant to batch admission

#### Scenario: Codehash drift closes the entry on the next read
- **WHEN** code is replaced at a listed counterparty after the grant
- **THEN** `isCounterpartyAllowed` returns false without any state write

## MODIFIED Requirements

### Requirement: Three demotion paths converging on one effect
Demotion SHALL delete the tier config (the key reverts to the tier-2 default), cancel any pending certification for the key, start the bond release timelock exactly once (`releasableAt = block.timestamp + bondReleaseDelay`, emitting `SubmitterBondReleaseStarted`, only if a bond exists and is not already releasing), bar the target from reading that selector's tier off a class (`ClassMemberTierDenied`), delete the target's counterparty entry (emitting `CounterpartyAllowedSet(target, false)` if and only if it was set), and emit `TierDemoted`. Three callers reach it:
- `demote(target, selector)` — owner-only revocation.
- `demoteByChallenge(target, selector)` — callable only by `authorizedDemoter` (reverts `NotAuthorizedDemoter` otherwise); the ChallengeGame's role, so the game can revoke a certification but never grant one.
- `poke` — permissionless, gated on codehash mismatch (above).

Demotion SHALL touch nothing about batch reachability: there is no callee axis, and the vault's ability to reclaim capital from a convicted strategy is a property of the vault's structural guard, not of registry state.

#### Scenario: Challenge-game demotion
- **WHEN** the address set as `authorizedDemoter` calls `demoteByChallenge` on a certified pair
- **THEN** the config is deleted, the bond release timelock starts, the target's counterparty entry (if any) is cleared, and `TierDemoted` is emitted

#### Scenario: Unauthorized demoteByChallenge refused
- **WHEN** any other address calls `demoteByChallenge`
- **THEN** the call reverts `NotAuthorizedDemoter`

#### Scenario: Double demotion does not restart the timelock
- **WHEN** a key whose bond is already pending release is demoted again (e.g. owner `demote` after a challenge demotion)
- **THEN** `releasableAt` is unchanged — the timelock starts once

#### Scenario: A demoted strategy is still reachable by a settlement batch
- **WHEN** a strategy clone holding vault capital is demoted via `demoteByChallenge`
- **THEN** a governor batch naming `clone.settle()` executes — the demotion changed the price of the next proposal, not the vault's reach

### Requirement: External read surface
The `ITierRegistry` interface consumed by the vault, the governor and the strategy templates SHALL expose exactly `tierOf(target, selector) → (tier, boundBps)`, `isCounterpartyAllowed(counterparty) → bool`, `classOf(target) → bytes32` and `strategyFactory() → address`. The demoter role and its setter are deliberately not part of this read-side interface.

#### Scenario: Governor-side consumption
- **WHEN** the governor prices a call's extractable value
- **THEN** it reads `tierOf` through `ITierRegistry` and gets the effective (post-lazy-demotion) tier and bound

#### Scenario: Template-side consumption
- **WHEN** a template binds a venue at init
- **THEN** it reads `isCounterpartyAllowed` through a length-checked raw staticcall and treats an unreadable answer as false

## REMOVED Requirements

### Requirement: The callee axis is separate from the funds axis and outlives a demotion
**Reason**: The vault no longer asks the registry whether a target may be called. Every target that is not a privileged protocol contract is callable, so the asymmetry this requirement protected (reclaiming from a demoted clone) holds by construction.
**Migration**: `setCallable`, `setClassCallable`, `isCallableTarget`, `_calleeAllowed`, `_calleeRevoked`, `_classCalleeAllowed`, `CalleeAllowedSet`, `ClassCalleeAllowedSet` are deleted. Nothing replaces them.

### Requirement: Adapter allowlist is a separate axis from tiers
**Reason**: The vault no longer decodes spenders or recipients, so there is nothing for an adapter allowlist to gate. Template venue binding, its only surviving consumer, moves to the counterparty axis.
**Migration**: `setAdapterAllowed`, `isAdapterAllowed`, `setClassAllowed`, `isClassAllowed`, `isClassAllowDenied`, `_adapterAllowed`, `_adapterAllowedCodehash`, `_classAllowed`, `_classAllowDenied`, `AdapterAllowedSet`, `ClassAllowedSet`, `ClassMemberAllowDenied` are deleted. Any address previously granted for a template binding is re-granted with `setCounterpartyAllowed`.
