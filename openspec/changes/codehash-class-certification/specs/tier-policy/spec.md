## MODIFIED Requirements

### Requirement: Tier semantics and the tier-2 default
The registry SHALL recognize exactly three tiers. Tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) are certified tiers whose extractable value is bounded to a certified `extractableBoundBps` (bps of notional). Tier 2 (`TIER_ARBITRARY = 2`, bound `FULL_NOTIONAL_BPS = 10_000`) is arbitrary calldata at full notional and SHALL be the default for any `(target, selector)` that is neither certified by address nor a member of a certified code class. No on-chain tier ceiling exists: tier-2 exposure is admissible (the ADR 2026-07-27 tier-2 refusal was reversed 2026-07-31; the guardian ROE gap at tier 2 is closed by off-chain team token incentives, not by refusing the tier).

#### Scenario: Uncertified pair reads as tier 2
- **WHEN** `tierOf(target, selector)` is called for a pair with no address certification and whose target belongs to no certified class
- **THEN** it returns `(2, 10_000)` — full notional, no certified bound

#### Scenario: Certified pair reads its certified values
- **WHEN** `tierOf(target, selector)` is called for a pair certified at tier 0 or 1 whose target's live codehash still matches the certified codehash
- **THEN** it returns the certified `(tier, extractableBoundBps)`

#### Scenario: Address certification wins over class membership
- **WHEN** a target is both certified by address and a member of a certified class, and the two disagree
- **THEN** the address certification is returned — the class is a fallback consulted only when no address entry exists

### Requirement: Config keying
Tier configuration SHALL support two keying modes. Address-keyed configuration SHALL be keyed by `keccak256(abi.encodePacked(target, selector))`, exposed as the pure function `key(address target, bytes4 selector)`. Class-keyed configuration SHALL be keyed by `keccak256(abi.encodePacked(cloneCodehash, selector))`, where `cloneCodehash` is the ERC-1167 runtime codehash derived from a template address. Certification, bonds, and demotion all operate on whichever key the entry was created under; the two namespaces SHALL be independent and SHALL NOT alias.

#### Scenario: Same target, different selectors are independent
- **WHEN** two selectors on the same target are certified separately
- **THEN** each `(target, selector)` pair carries its own tier config and its own bond; demoting one does not affect the other

#### Scenario: Same class, different selectors are independent
- **WHEN** two selectors on the same code class are certified separately
- **THEN** each `(class, selector)` pair carries its own tier config and its own bond; demoting one does not affect the other

#### Scenario: Address and class keys never collide
- **WHEN** an address entry and a class entry exist whose raw key preimages could otherwise coincide
- **THEN** they remain distinct entries — the two keying modes occupy separate namespaces and neither can be written through the other's entry point

## ADDED Requirements

### Requirement: Class certification attests a bound over all initializations

The registry SHALL support certifying a code class: a tier and `extractableBoundBps` attested for every address whose runtime code matches the class, rather than for one deployed address. A class SHALL be certified by naming a template address; the registry SHALL derive the class fingerprint as the ERC-1167 runtime codehash of a minimal proxy pointing at that template, and SHALL snapshot the template's own live codehash at certification.

Certifying a class asserts a strictly stronger claim than certifying an address: that the bound holds under **every** initialization of every clone, not merely for one deployment's stored configuration. Adversary: a template that accepts an external protocol address as initialization data and validates it by querying that same supplied address — a proposer supplies a contract that answers correctly and keeps the funds, so the certified bound holds for an honest clone and fails entirely for a hostile one, while both are class members.

#### Scenario: Class certification names a template
- **WHEN** the owner certifies a class for template `T` at tier 1 with a bound
- **THEN** the entry stores `T`, `T`'s live codehash, the derived clone codehash, the tier, and the bound

#### Scenario: Certifying a class for a codeless address
- **WHEN** the named template holds no code at certification time
- **THEN** the certification reverts — there is no class to derive

### Requirement: Class membership is verified at two levels on every read

`tierOf` and `isAdapterAllowed` SHALL, when no address-keyed entry resolves, report a target's class entry only when BOTH hold on the live chain state:

1. The target's `EXTCODEHASH` equals the clone codehash derived from the certified template.
2. The certified template's `EXTCODEHASH` still equals the codehash snapshotted at certification.

Level 1 proves the target is a minimal-proxy clone of that template. Level 2 is load-bearing and cannot be dropped: a clone's codehash embeds the template's **address**, not the template's **code**, so in-place mutation of the template changes every clone's behavior while leaving every clone's codehash identical. Adversary: a template whose bytecode is replaced at the same address (metamorphic CREATE2 + SELFDESTRUCT redeploy) after certification, silently re-pointing every existing and future clone at hostile code that the class still vouches for.

Both checks SHALL be read-side and SHALL NOT write state — the same lazy, ungriefable self-heal the address path uses.

#### Scenario: Clone of a certified template
- **WHEN** `tierOf` is called on a minimal-proxy clone of a certified template, and the template's code is unchanged
- **THEN** it returns the class's certified `(tier, extractableBoundBps)` with no per-clone action ever having been taken

#### Scenario: Template mutated in place after certification
- **WHEN** the certified template's bytecode changes at the same address
- **THEN** every clone of it reads as `(2, 10_000)` on the very next read, and `isAdapterAllowed` returns false for every clone

#### Scenario: Look-alike contract that is not a clone
- **WHEN** a contract implements the same interface but is not a minimal-proxy clone of the certified template
- **THEN** its codehash does not match the derived class fingerprint and it reads as uncertified

#### Scenario: Clone created outside the factory
- **WHEN** an address clones a certified template directly rather than through `StrategyFactory`
- **THEN** the clone is a class member — membership is proven from bytecode, not from factory provenance. This is a deliberate loosening of `StrategyFactory._authClone`: the clone is inert until a proposal names it, and that proposal still passes vote and guardian review, so no capability is granted that a registered agent did not already have

### Requirement: Only conformant templates may be class-certified

Governance SHALL class-certify a template only when every external address the template interacts with is either held immutable in the template's own bytecode or bound to the registry allowlist during initialization. A template that accepts an unbound external address as initialization data SHALL NOT be class-certified; it remains eligible for address-keyed certification of individual clones.

Governance SHALL NOT class-certify a template that is itself a proxy, for the same reason proxied adapters are barred from address certification: a proxy's runtime bytecode is static across implementation swaps, so neither level of the membership check can observe the change.

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

The registry SHALL maintain an owner-managed attestation that a given price source prices a given token, set through `setPriceSourceForToken(token, priceSource, allowed)` and read through `isPriceSourceForToken(token, priceSource)`. The price source SHALL be carried as `bytes32` so one attestation namespace serves both a push-feed aggregator address and a Data Streams feed id, and callers SHALL strip any packed metadata (such as a per-slot staleness bound) before looking up, so one attestation covers an aggregator regardless of the staleness bound a proposer chose.

This is a distinct axis from the adapter allowlist. The allowlist answers "may this price source be used at all"; this answers "…for THIS token". Adversary: a proposer who pairs a valuable basket token with a cheap asset's allowlisted feed, so the slot's minimum-output floor is derived from the wrong reference and value leaks on every rebalance while the configured slippage tolerance still reads as satisfied — the safety rail is measured against the wrong ruler.

The pairing SHALL be attested rather than derived: `AggregatorV3` exposes no on-chain link from a feed to the asset it prices, and Chainlink's Feed Registry is not deployed on Robinhood Chain, so no contract can compute this relationship.

#### Scenario: Mismatched pairing at initialization
- **WHEN** a template initializes a slot whose price source is allowlisted but not attested for that slot's token
- **THEN** initialization reverts

#### Scenario: One attestation covers every staleness variant
- **WHEN** two slots name the same push aggregator with different packed max-age values
- **THEN** both resolve to the same attestation — the lookup key is the bare aggregator address

#### Scenario: Attestation is owner-only
- **WHEN** a non-owner calls `setPriceSourceForToken`
- **THEN** the call reverts

### Requirement: Class demotion mirrors address demotion

The demotion paths and the permissionless persistence path SHALL apply to class entries with the same effect and the same one-way coupling as address entries: demoting a class clears the class's allowlist standing, and no certification action ever sets or restores it. Restoring a demoted class SHALL require an explicit owner allowlist grant for that class.

Adversary: a submitter who gets a class re-certified and thereby silently re-opens the funds path for every clone of that template at once — the blast radius of the address-path version of this hazard, multiplied by every clone in existence.

#### Scenario: Demoting a class
- **WHEN** a class entry is demoted
- **THEN** every member clone reads as `(2, 10_000)` and `isAdapterAllowed` returns false for all of them

#### Scenario: Re-certification does not restore class allowlist standing
- **WHEN** a demoted class is later re-certified
- **THEN** its clones remain disallowed until the owner explicitly re-grants the class's allowlist entry
