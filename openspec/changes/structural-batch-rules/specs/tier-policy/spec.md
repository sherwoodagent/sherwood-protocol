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

## MODIFIED Requirements

### Requirement: Two demotion paths converging on one effect
Demotion SHALL delete the tier config (the key reverts to the tier-2 default), bar the target from reading that selector's tier off a class by setting the class-denied flag write-once (emitting `ClassMemberTierDenied` only on the first set; read via `isClassTierDenied`), leave the target's counterparty entry untouched (a per-selector conviction must not disarm a venue every vault shares; `setCounterpartyAllowed(x, false)` is the only revocation), and emit `TierDemoted`. Two callers reach it, and both SHALL revert `NotCertified` for a pair with neither an address nor a class certification:
- `demote(target, selector)` — owner-only revocation.
- `demoteByChallenge(target, selector)` — callable only by `authorizedDemoter` (reverts `NotAuthorizedDemoter` otherwise); the ChallengeGame's role, so the game can revoke a certification but never grant one.

Demotion SHALL touch nothing about batch reachability: the registry holds no callee axis, and the vault's ability to reclaim capital from a convicted strategy is a property of the vault's structural guard, not of registry state. The recovery path after a demotion is an ordinary `certify`, whose address entry wins ahead of both the denial flag and the class.

#### Scenario: Challenge-game demotion
- **WHEN** the address set as `authorizedDemoter` calls `demoteByChallenge` on a certified pair
- **THEN** the config is deleted, the class-denied flag is set, the target's counterparty entry (if any) is unchanged, and `TierDemoted` is emitted

#### Scenario: Unauthorized demoteByChallenge refused
- **WHEN** any other address calls `demoteByChallenge`
- **THEN** the call reverts `NotAuthorizedDemoter`

#### Scenario: Demotion leaves counterparty standing untouched
- **WHEN** a certified target that is also an allowed counterparty is demoted
- **THEN** `isCounterpartyAllowed(target)` still returns true and only an explicit owner `setCounterpartyAllowed(target, false)` revokes it

#### Scenario: A demoted class member does not fall back to the class
- **WHEN** a class-certified clone is demoted on one selector
- **THEN** `tierOf(clone, selector)` returns `(2, 10_000)` while sibling clones and the clone's other selectors keep the class tier

### Requirement: External read surface
The `ITierRegistry` interface consumed by the vault, the governor and the strategy templates SHALL expose exactly `tierOf(target, selector) → (tier, boundBps)`, `isCounterpartyAllowed(counterparty) → bool`, `classOf(target) → bytes32` and `strategyFactory() → address`. The demoter role and its setter are deliberately not part of this read-side interface.

#### Scenario: Governor-side consumption
- **WHEN** the governor prices a call's extractable value
- **THEN** it reads `tierOf` through `ITierRegistry` and gets the effective (post-lazy-demotion) tier and bound

#### Scenario: Template-side consumption
- **WHEN** a template binds a venue at init
- **THEN** it reads `isCounterpartyAllowed` through a length-checked raw staticcall, and a codeless registry, a reverting call or an answer that is not exactly one word counts as false
