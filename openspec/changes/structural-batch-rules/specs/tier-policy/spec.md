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

### Requirement: External read surface
The `ITierRegistry` interface consumed by the vault, the governor and the strategy templates SHALL expose exactly `tierOf(target, selector) → (tier, boundBps)`, `isCounterpartyAllowed(counterparty) → bool`, `isMorphoMarketAllowed(marketId) → bool`, `classOf(target) → bytes32` and `strategyFactory() → address`. The demoter role and its setter are deliberately not part of this read-side interface.

#### Scenario: Governor-side consumption
- **WHEN** the governor prices a call's extractable value
- **THEN** it reads `tierOf` through `ITierRegistry` and gets the effective (post-lazy-demotion) tier and bound

#### Scenario: Template-side consumption
- **WHEN** a template binds a venue at init
- **THEN** it reads `isCounterpartyAllowed` through a length-checked raw staticcall, and a codeless registry, a reverting call or an answer that is not exactly one word counts as false
