# Tier Policy Specification

## Purpose

Adapter-selector tier certification for the guardian economic-security model. A tier is a property of a `(target, selector)` pair, set at listing by governance and consumed at propose/execute time: tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) carry a certified extractable bound in bps of notional; tier 2 (arbitrary calldata, full notional) is the default for anything uncertified. `TierRegistry` also carries the counterparty allowlist — the venues a certified strategy template may bind inside its own code — which confers nothing to a governor batch, and a codehash-class axis (`certifyClass`) that certifies every factory clone of a template at once.
## Requirements
### Requirement: Tier semantics and the tier-2 default
The registry SHALL recognize exactly three tiers. Tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) are certified tiers whose extractable value is bounded to a certified `extractableBoundBps` (bps of notional). Tier 2 (`TIER_ARBITRARY = 2`, bound `FULL_NOTIONAL_BPS = 10_000`) is arbitrary calldata at full notional and SHALL be the default for any uncertified `(target, selector)`. No on-chain tier ceiling exists: tier-2 exposure is admissible (the ADR 2026-07-27 tier-2 refusal was reversed 2026-07-31; the guardian ROE gap at tier 2 is closed by off-chain team token incentives, not by refusing the tier).

#### Scenario: Uncertified pair reads as tier 2
- **WHEN** `tierOf(target, selector)` is called for a pair with no certification
- **THEN** it returns `(2, 10_000)` — full notional, no certified bound

#### Scenario: Certified pair reads its certified values
- **WHEN** `tierOf(target, selector)` is called for a pair certified at tier 0 or 1 whose target's live codehash still matches the certified codehash
- **THEN** it returns the certified `(tier, extractableBoundBps)`

### Requirement: Config keying
Tier configuration SHALL be keyed by `keccak256(abi.encodePacked(target, selector))`, exposed as the pure function `key(address target, bytes4 selector)`. Certification and demotion both operate on this key.

#### Scenario: Same target, different selectors are independent
- **WHEN** two selectors on the same target are certified separately
- **THEN** each `(target, selector)` pair carries its own tier config; demoting one does not affect the other

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
The `ITierRegistry` interface consumed by the vault, the governor and the strategy templates SHALL expose exactly `tierOf(target, selector) → (tier, boundBps)`, `isCounterpartyAllowed(counterparty) → bool`, `classOf(target) → bytes32` and `strategyFactory() → address`. The demoter role and its setter are deliberately not part of this read-side interface.

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

