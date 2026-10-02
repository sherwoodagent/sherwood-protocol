# Tier Policy Specification

## Purpose

Adapter-selector tier certification for the guardian economic-security model. A tier is a property of a `(target, selector)` pair, set at listing by governance and consumed at propose/execute time: tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) carry a certified extractable bound in bps of notional; tier 2 (arbitrary calldata, full notional) is the default for anything uncertified. `TierRegistry` also carries the counterparty allowlist — the venues a certified strategy template may bind inside its own code — which confers nothing to a governor batch, and a codehash-class axis (`certifyClass`) that certifies every factory clone of a template at once.
## Requirements
### Requirement: Tier semantics and the tier-2 default
The registry SHALL recognize exactly three tiers. Tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) are certified tiers whose extractable value is bounded to a certified `extractableBoundBps` (bps of notional). Tier 2 (`TIER_ARBITRARY = 2`, bound `FULL_NOTIONAL_BPS = 10_000`) is arbitrary calldata at full notional and SHALL be the default for any `(target, selector)` that has no live address certification and does not read a certified code class. `tierOf` SHALL look up, in order: the address entry (served only while the target's live codehash equals the certified codehash); then a per-address denial left by a prior demotion of that `(target, selector)`, which returns the tier-2 default; then the target's code class; then the tier-2 default. No on-chain tier ceiling exists: tier-2 exposure is admissible.

#### Scenario: Uncertified pair reads as tier 2
- **WHEN** `tierOf(target, selector)` is called for a pair with no address certification and whose target belongs to no certified class
- **THEN** it returns `(2, 10_000)` — full notional, no certified bound

#### Scenario: Certified pair reads its certified values
- **WHEN** `tierOf(target, selector)` is called for a pair certified at tier 0 or 1 whose target's live codehash still matches the certified codehash
- **THEN** it returns the certified `(tier, extractableBoundBps)`

#### Scenario: Address certification wins over class membership
- **WHEN** a target is both certified by address and a member of a certified class, and the two disagree
- **THEN** the address certification is returned — the class is a fallback consulted only when no live address entry exists

#### Scenario: A demoted member cannot fall back to its class
- **WHEN** a class member's `(target, selector)` has been demoted by `demote` or `demoteByChallenge`
- **THEN** `tierOf` returns `(2, 10_000)` for that pair even though its class is still certified; only a new address certification restores a bounded tier

### Requirement: Config keying
Tier configuration SHALL support two keying modes held in separate mappings. Address-keyed configuration SHALL be keyed by `keccak256(abi.encodePacked(target, selector))`, exposed as the pure function `key(address target, bytes4 selector)`. Class-keyed configuration SHALL be keyed by the class fingerprint and the selector, where the fingerprint is `keccak256(abi.encodePacked(cloneCodehash, classEpoch))`, `cloneCodehash` is the ERC-1167 runtime codehash derived from a template address (`cloneCodehashOf(template)`), and `classEpoch` advances when a re-certification finds the template's code changed, orphaning every config certified against the old code. Certification and demotion operate on whichever key the entry was created under; the two namespaces SHALL be independent and SHALL NOT alias.

#### Scenario: Same target, different selectors are independent
- **WHEN** two selectors on the same target are certified separately
- **THEN** each `(target, selector)` pair carries its own tier config; demoting one does not affect the other

#### Scenario: Same class, different selectors are independent
- **WHEN** two selectors on the same code class are certified separately
- **THEN** each `(class, selector)` pair carries its own tier config; demoting one does not affect the other

#### Scenario: Address and class keys never collide
- **WHEN** an address entry and a class entry exist whose raw key preimages could otherwise coincide
- **THEN** they remain distinct entries — the two keying modes occupy separate mappings and neither can be written through the other's entry point

### Requirement: Lazy fail-safe demotion on codehash mismatch
`tierOf` SHALL verify the target's live `EXTCODEHASH` against the codehash snapshotted at certification on every read, and SHALL report `(2, 10_000)` on mismatch without writing state. This catches same-address bytecode mutation (metamorphic CREATE2 + SELFDESTRUCT redeploys) on the first post-mutation read. It does NOT catch proxy implementation swaps — an EIP-1967/UUPS/transparent/beacon proxy's runtime bytecode is static across upgrades — so governance SHALL NOT certify proxied adapters at tier 0/1; proxies stay at the tier-2 default.

#### Scenario: Metamorphic redeploy is demoted lazily
- **WHEN** a certified target's bytecode changes at the same address after certification
- **THEN** the next `tierOf` read returns `(2, 10_000)` even though storage still holds the certification

#### Scenario: Proxy upgrade is invisible to the codehash check
- **WHEN** a certified target is a proxy whose implementation is swapped
- **THEN** `tierOf` keeps returning the certified tier (the proxy's codehash is unchanged) — which is why certification of proxied targets is a governance prohibition, not a code check

### Requirement: No demotion call is needed to revoke a drifted target
Every read SHALL re-verify the pinned codehash, so a target whose live code has
drifted — and every clone of a template whose code has drifted — SHALL read as
tier 2 with no call by anyone. The registry SHALL expose no permissionless
entry point that only persists what the reads already report.

#### Scenario: Drifted target reads as tier 2 without any call
- **WHEN** a certified target's live codehash no longer equals the codehash pinned at certification
- **THEN** `tierOf` returns `(2, 10_000)` and no owner or keeper transaction is required

### Requirement: Certification is owner-only with strict input guards
`certify(target, selector, tier, extractableBoundBps, expectedCodehash)` SHALL be owner-only, SHALL take effect in the same transaction, and SHALL revert: `InvalidTier` when `tier >= 2`; `BoundRequired` when `extractableBoundBps` is `0` or `>= 10_000`; `NotAContract` when the target's codehash is `bytes32(0)` or `keccak256("")` (a funded EOA hashes to the latter — both are rejected); `CodehashChanged` when the target's live `EXTCODEHASH` differs from `expectedCodehash`. On success it SHALL pin that codehash into the config and emit `TierCertified`.

`expectedCodehash` is the hash the owner reviewed off-chain. Reading the live codehash without comparing it would let the target's deployer land different bytecode between review and inclusion and have the registry pin a hash nobody reviewed.

#### Scenario: EOA target rejected
- **WHEN** the owner certifies an address with no deployed code (including a funded EOA)
- **THEN** the call reverts `NotAContract`

#### Scenario: Full-notional bound rejected
- **WHEN** the owner certifies with `extractableBoundBps = 10_000`
- **THEN** the call reverts `BoundRequired` — a full-notional "bound" is tier-2 economics and must not wear a tier-0/1 label

#### Scenario: Code that drifted since review is rejected
- **WHEN** the owner certifies a target whose live codehash no longer equals the reviewed `expectedCodehash`
- **THEN** the call reverts `CodehashChanged` and nothing is written

#### Scenario: Re-certification is a plain overwrite
- **WHEN** the owner certifies a key that is already certified
- **THEN** the new tier, bound and pinned codehash replace the old ones in the same transaction — correcting a bound or re-attesting an upgraded adapter needs no demotion first

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

### Requirement: Demoter role rotation is always safe, including to zero
`setAuthorizedDemoter(demoter)` SHALL be owner-only and SHALL accept `address(0)` — the unwire switch, revoking the challenge game's demotion role while a replacement is wired. The unwired state fails closed for future demotions (nothing can `demoteByChallenge`), and the ChallengeGame treats a failed demotion as best-effort (emitting `AdapterDemotionFailed` rather than reverting the verdict), so the role is safe to rotate at any time; owner `demote` is the remedy for any revocation a rotation lost. The setter emits `AuthorizedDemoterSet`.

#### Scenario: Unwiring the demoter mid-challenge does not brick a verdict
- **WHEN** the demoter role is cleared to zero while a challenge is live
- **THEN** the challenge still settles (the game's demotion attempt fails best-effort) and the owner can apply the lost demotion via `demote`

### Requirement: The counterparty allowlist is the only venue allowlist
The registry SHALL maintain exactly one owner-managed counterparty (venue) allowlist, `setCounterpartyAllowed(counterparty, allowed)` (emitting `CounterpartyAllowedSet`; read via `isCounterpartyAllowed(counterparty)`), answering one question: may a certified strategy template bind this address as a venue inside the template's own reviewed code. It SHALL confer nothing to a governor batch: the vault's batch guard does not read it. The grant SHALL snapshot the counterparty's effective codehash (normalizing `bytes32(0)` and `keccak256("")` to one "no code" value) and `isCounterpartyAllowed` SHALL return true only while the live effective codehash equals the snapshot — the same lazy self-heal as `tierOf`; a re-grant re-attests the current code. There SHALL be no class fallback, no implication from any other standing, and no certification action SHALL set or restore an entry. It is not the registry's only owner-managed axis: the token↔price-source attestation (`setPriceSourceForToken`) is a separate one, specified by the open change `codehash-class-certification`.

#### Scenario: Granting is owner-only
- **WHEN** a non-owner calls `setCounterpartyAllowed`
- **THEN** the call reverts (Ownable)

#### Scenario: Codehash drift closes the entry on the next read
- **WHEN** code is replaced at a listed counterparty after the grant
- **THEN** `isCounterpartyAllowed` returns false without any state write, until the owner re-grants

#### Scenario: A template binds only a listed venue
- **WHEN** a template's `initialize` names a venue whose `isCounterpartyAllowed` is false
- **THEN** the clone reverts at init with the template's own "not allowed" error naming the venue and the registry (`MorphoNotAllowed(morpho, registry)`, `AdapterNotAllowed(swapAdapter, registry)`, `PriceSourceNotAllowed(priceSource, registry)`, `CounterpartyNotAllowed(counterparty, registry)`)

### Requirement: External read surface
The `ITierRegistry` interface consumed by the vault, the governor and the strategy templates SHALL expose exactly `tierOf(target, selector) → (tier, boundBps)`, `isCounterpartyAllowed(counterparty) → bool`, `isMorphoMarketAllowed(marketId) → bool`, `classOf(target) → bytes32` and `strategyFactory() → address`. The demoter role and its setter are deliberately not part of this read-side interface.

#### Scenario: Governor-side consumption
- **WHEN** the governor prices a call's extractable value
- **THEN** it reads `tierOf` through `ITierRegistry` and gets the effective (post-lazy-demotion) tier and bound

#### Scenario: Template-side consumption
- **WHEN** a template binds a venue at init
- **THEN** it reads `isCounterpartyAllowed` through a length-checked raw staticcall, and a codeless registry, a reverting call or an answer that is not exactly one word counts as false

### Requirement: Ownership model
`TierRegistry` SHALL be `Ownable2Step`: ownership transfer requires the recipient to call `acceptOwnership`. The deploy ceremony leaves the registry owned by the deployer at birth (so initial certification can run before handoff), then starts the two-step transfer to the owner multisig.

#### Scenario: Handoff requires acceptance
- **WHEN** the deployer calls `transferOwnership(multisig)`
- **THEN** the deployer remains owner until the multisig calls `acceptOwnership()`

### Requirement: Governance certification discipline
Certification SHALL be treated as a governance judgment the code cannot check: governance SHALL NOT certify proxied adapters at tier 0/1 (the codehash guard cannot see implementation swaps), and SHALL NOT certify with a loose `extractableBoundBps` — an over-generous bound slides the economics continuously back toward the tier-2 result while looking safe. Coverage sizing consumes the bound directly (`requiredCoverage = maxCapital × Σ boundBps / 10_000`, tier-2 calls contributing full notional), so the bound is the real risk parameter.

#### Scenario: Loose bound distorts coverage
- **WHEN** a tier-0 certification carries a bound far above the adapter's true extractable value
- **THEN** every proposal touching it demands correspondingly inflated guardian coverage priced as if the leak were real — the certification is worse than refusing to certify

### Requirement: Morpho markets are allowlisted by market id

The registry SHALL keep an owner-managed allowlist of Morpho Blue market ids: `setMorphoMarketAllowed(id, allowed)` (`onlyOwner`, emitting `MorphoMarketAllowedSet(id, allowed)`) and the view `isMorphoMarketAllowed(id)`. The id is Morpho's `keccak256(abi.encode(loanToken, collateralToken, oracle, irm, lltv))`, so one grant attests all five parameters together. A strategy template that supplies to or borrows from a Morpho market SHALL admit the market only when its id is allowlisted, read fail-closed (a registry that cannot answer has not vouched), at init and again at execute (and, for the concentrated-liquidity template, at `rerange()`). Settle SHALL NOT be gated on it, so a de-listing never strands funds. Per-address counterparty grants for the oracle or collateral SHALL NOT admit a market.

Adversary: a proposer assembling a market from individually acceptable parts, such as a loan == collateral market priced by another token's oracle, a market with `irm == address(0)`, or a non-vetted `lltv`, to freeze or skim the vault's supply. Before granting, the owner SHALL read the market's five parameters from Morpho, recompute the id, and refuse a market whose `irm` is the zero address or whose oracle does not price its collateral in its loan token.

#### Scenario: Market built from allowlisted parts is refused
- **WHEN** a Morpho-supply or CL clone names a market whose oracle and collateral are allowed counterparties but whose id is not allowlisted
- **THEN** clone-init reverts `MorphoMarketNotAllowed(marketId, registry)`

#### Scenario: Allowlisted market initialises
- **WHEN** a clone names a market whose id is allowlisted and whose Morpho singleton (and, for the CL template, its other venue counterparties) are allowed counterparties
- **THEN** clone-init succeeds, with no oracle or collateral grant of its own

#### Scenario: De-listed after init
- **WHEN** the market id is de-listed between clone-init and `execute()`
- **THEN** `execute()` reverts `MorphoMarketNotAllowed` and no vault funds move; a de-listing after execute does not block `settle()`

#### Scenario: Allowlisting is owner-only
- **WHEN** a non-owner calls `setMorphoMarketAllowed`
- **THEN** the call reverts (Ownable)

### Requirement: Class certification attests a bound over all initializations

The registry SHALL support certifying a code class: a tier and `extractableBoundBps` attested for every factory-minted clone of a template, rather than for one deployed address. `certifyClass(template, selector, tier, extractableBoundBps, expectedTemplateCodehash)` SHALL be owner-only, SHALL refuse tier 2 (`InvalidTier`) and a bound of zero or at least full notional (`BoundRequired`), SHALL revert `NotAContract` for a codeless template and `CodehashChanged` when the template's live codehash differs from `expectedTemplateCodehash`, and SHALL record the template, its live codehash, the derived clone codehash, the tier and the bound, emitting `ClassCertified`.

Certifying a class asserts a strictly stronger claim than certifying an address: that the bound holds under **every** initialization of every clone, not merely for one deployment's stored configuration. Adversary: a template that accepts an external protocol address as initialization data and validates it by querying that same supplied address — a proposer supplies a contract that answers correctly and keeps the funds, so the certified bound holds for an honest clone and fails entirely for a hostile one, while both are class members.

#### Scenario: Class certification names a template
- **WHEN** the owner certifies a class for template `T` at tier 1 with a bound
- **THEN** the entry stores `T`, `T`'s live codehash, the derived clone codehash, the tier, and the bound

#### Scenario: Certifying a class for a codeless address
- **WHEN** the named template holds no code at certification time
- **THEN** the certification reverts `NotAContract` — there is no class to derive

### Requirement: Class membership is verified on every read

`tierOf` SHALL, when it reaches the class step, report a target's class entry only when ALL of these hold on the live chain state:

1. The target's `EXTCODEHASH` equals the clone codehash derived from a certified template.
2. That template's `EXTCODEHASH` still equals the codehash snapshotted at certification.
3. The registry's `strategyFactory` records that template as the target's `cloneTemplate`, read through a length-checked raw staticcall where any malformed answer resolves to no template. With `strategyFactory` unset, no target belongs to any class.

Condition 1 proves the target is a minimal-proxy clone of that template. Condition 2 is load-bearing: a clone's codehash embeds the template's **address**, not the template's **code**, so in-place mutation of the template changes every clone's behavior while leaving every clone's codehash identical. Adversary: a template whose bytecode is replaced at the same address after certification, silently re-pointing every existing and future clone at hostile code that the class still vouches for. Condition 3 limits the class to clones the protocol's factory minted.

The checks SHALL be read-side and SHALL NOT write state — the same lazy, ungriefable self-heal the address path uses. `classOf(target)` SHALL expose the resolved class (`bytes32(0)` for none). `setStrategyFactory(factory)` SHALL be owner-only and SHALL revert `InvalidStrategyFactory` unless `factory` holds code and answers `cloneTemplate(address(0))` with `address(0)`.

#### Scenario: Clone of a certified template
- **WHEN** `tierOf` is called on a factory-minted clone of a certified template, and the template's code is unchanged
- **THEN** it returns the class's certified `(tier, extractableBoundBps)` with no per-clone action ever having been taken

#### Scenario: Template mutated in place after certification
- **WHEN** the certified template's bytecode changes at the same address
- **THEN** every clone of it reads as `(2, 10_000)` on the very next read

#### Scenario: Look-alike contract that is not a clone
- **WHEN** a contract implements the same interface but is not a minimal-proxy clone of the certified template
- **THEN** its codehash does not match the derived class fingerprint and it reads as uncertified

#### Scenario: Clone created outside the factory
- **WHEN** an address clones a certified template directly rather than through the registry's `strategyFactory`
- **THEN** the factory holds no `cloneTemplate` record for it and it is not a class member

### Requirement: Only conformant templates may be class-certified

Governance SHALL class-certify a template only when every external address the template interacts with is either held immutable in the template's own bytecode or bound to the registry allowlist during initialization. A template that accepts an unbound external address as initialization data SHALL NOT be class-certified; it remains eligible for address-keyed certification of individual clones.

Governance SHALL NOT class-certify a template that is itself a proxy, for the same reason proxied adapters are barred from address certification: a proxy's runtime bytecode is static across implementation swaps, so the membership checks cannot observe the change.

#### Scenario: Template with an unbound init-supplied protocol address
- **WHEN** a template accepts a lending-protocol address as init data and validates it by querying that supplied address
- **THEN** it is ineligible for class certification — the certified bound would hold for honest initializations and fail for hostile ones

#### Scenario: Template binding every init-supplied address
- **WHEN** a template checks each init-supplied adapter and price source against the registry allowlist, and checks each price source against the token it is used to price, before storing either
- **THEN** it is eligible for class certification

#### Scenario: Template binding the price source but not the pairing
- **WHEN** a template allowlist-binds each price source but never checks that a slot's source describes that slot's token
- **THEN** it is NOT eligible for class certification — a valuable token paired with a cheap asset's allowlisted source derives its minimum-output floor from the wrong reference, so the bound holds for honest configurations and fails for hostile ones while every slippage check still passes

#### Scenario: Proxied template
- **WHEN** the named template is itself an upgradeable proxy
- **THEN** governance does not class-certify it — this is a governance prohibition, not a code check, exactly as for proxied adapters

### Requirement: Class-certifiable templates are cloned without per-instance bytecode

A template intended for class certification SHALL be instantiated only by clone mechanisms that produce byte-identical runtime code across instances (`Clones.clone`, `Clones.cloneDeterministic`). Clone-with-immutable-args variants, which write per-instance data into each clone's runtime bytecode, SHALL NOT be used for such templates.

The reason is structural rather than adversarial: per-instance bytecode gives every clone a distinct codehash, so the class dissolves into singletons and every clone silently falls back to the tier-2 default. The failure is quiet — proposals keep working, they just become expensive and size-capped again — which is why this is stated as a requirement rather than left to implementation taste.

#### Scenario: Clone carrying immutable args
- **WHEN** a clone is deployed with per-instance immutable arguments embedded in its bytecode
- **THEN** its codehash does not match the class fingerprint and it reads as uncertified, with no error raised anywhere

### Requirement: Token↔price-source attestation is a separate axis

The registry SHALL maintain an owner-managed attestation that a given price source prices a given token, set through `setPriceSourceForToken(token, priceSource, allowed)` (emitting `PriceSourceForTokenSet`) and read through `isPriceSourceForToken(token, priceSource)`. The price source SHALL be carried as `bytes32`; the shipped templates key it on the bare push-feed aggregator address widened to `bytes32`.

This is a distinct axis from the counterparty allowlist. The allowlist answers "may this price source be used at all"; this answers "…for THIS token". Adversary: a proposer who pairs a valuable basket token with a cheap asset's allowlisted feed, so the slot's minimum-output floor is derived from the wrong reference and value leaks on every swap while the configured slippage tolerance still reads as satisfied — the safety rail is measured against the wrong ruler.

The pairing SHALL be attested rather than derived: `AggregatorV3` exposes no on-chain link from a feed to the asset it prices, and Chainlink's Feed Registry is not deployed on Robinhood Chain, so no contract can compute this relationship.

#### Scenario: Mismatched pairing at initialization
- **WHEN** a Portfolio clone initializes a slot whose price source is allowlisted but not attested for that slot's token
- **THEN** initialization reverts `PriceSourceNotPairedWithToken(token, priceSource, registry)`

#### Scenario: Attestation is owner-only
- **WHEN** a non-owner calls `setPriceSourceForToken`
- **THEN** the call reverts

### Requirement: Class demotion

`demoteClass(template, selector)` (owner-only) and `demoteClassByChallenge(template, selector)` (only `authorizedDemoter`, else `NotAuthorizedDemoter`) SHALL delete the class's config for that selector, emit `ClassDemoted`, and revert `ClassNotCertified` when the class carries no certification for the selector. After a class demotion every member reads `(2, 10_000)` for that selector unless it holds its own live address certification. A later `certifyClass` for the same template and selector SHALL restore the class tier for every member.

#### Scenario: Demoting a class
- **WHEN** a class entry is demoted for a selector
- **THEN** every member clone without its own address certification reads as `(2, 10_000)` for that selector

#### Scenario: Re-certification restores the class
- **WHEN** a demoted class is later re-certified for the same selector
- **THEN** its member clones read the newly certified tier and bound

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

