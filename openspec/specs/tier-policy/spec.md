# Tier Policy Specification

## Purpose

Adapter-selector tier certification for the guardian economic-security model. A tier is a property of a `(target, selector)` pair, set at listing by governance and consumed at propose/execute time: tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) carry a certified extractable bound in bps of notional; tier 2 (arbitrary calldata, full notional) is the default for anything uncertified. `TierRegistry` also carries the adapter allowlist that bounds where vault funds may be approved or sent inside governor batches, and the submitter-bond machinery that makes a tier certification a bonded claim.

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
Tier configuration SHALL be keyed by `keccak256(abi.encodePacked(target, selector))`, exposed as the pure function `key(address target, bytes4 selector)`. Certification, bonds, and demotion all operate on this key.

#### Scenario: Same target, different selectors are independent
- **WHEN** two selectors on the same target are certified separately
- **THEN** each `(target, selector)` pair carries its own tier config and its own bond; demoting one does not affect the other

### Requirement: Lazy fail-safe demotion on codehash mismatch
`tierOf` SHALL verify the target's live `EXTCODEHASH` against the codehash snapshotted at certification on every read, and SHALL report `(2, 10_000)` on mismatch without writing state. This catches same-address bytecode mutation (metamorphic CREATE2 + SELFDESTRUCT redeploys) on the first post-mutation read. It does NOT catch proxy implementation swaps — an EIP-1967/UUPS/transparent/beacon proxy's runtime bytecode is static across upgrades — so governance SHALL NOT certify proxied adapters at tier 0/1; proxies stay at the tier-2 default.

#### Scenario: Metamorphic redeploy is demoted lazily
- **WHEN** a certified target's bytecode changes at the same address after certification
- **THEN** the next `tierOf` read returns `(2, 10_000)` even though storage still holds the certification

#### Scenario: Proxy upgrade is invisible to the codehash check
- **WHEN** a certified target is a proxy whose implementation is swapped
- **THEN** `tierOf` keeps returning the certified tier (the proxy's codehash is unchanged) — which is why certification of proxied targets is a governance prohibition, not a code check

### Requirement: Permissionless persistence of a lazy demotion
`poke(target, selector)` SHALL be callable by anyone. It SHALL revert `NotCertified` when no certification exists and `CodehashMatches` when the live codehash still matches; otherwise it SHALL persist the demotion (delete the config, start the bond release timelock, emit `TierDemoted`) so indexers observe what `tierOf` already reports.

#### Scenario: Anyone persists a codehash-mismatch demotion
- **WHEN** any caller invokes `poke` on a certified pair whose target codehash no longer matches
- **THEN** the config is deleted, `TierDemoted` is emitted, and any active bond enters its release timelock

#### Scenario: Poke on a healthy certification reverts
- **WHEN** `poke` is called while the live codehash matches the certified hash
- **THEN** the call reverts `CodehashMatches` and the certification is untouched

### Requirement: Certification is owner-only with strict input guards
`certify(target, selector, tier, extractableBoundBps, submitter)` SHALL be owner-only and SHALL revert: `InvalidTier` when `tier >= 2`; `BoundRequired` when `extractableBoundBps` is `0` or `>= 10_000`; `NotAContract` when the target's codehash is `bytes32(0)` or `keccak256("")` (a funded EOA hashes to the latter — both are rejected). On success it SHALL snapshot the target's `EXTCODEHASH` into the config and emit `TierCertified`.

#### Scenario: EOA target rejected
- **WHEN** the owner certifies an address with no deployed code (including a funded EOA)
- **THEN** the call reverts `NotAContract`

#### Scenario: Full-notional bound rejected
- **WHEN** the owner certifies with `extractableBoundBps = 10_000`
- **THEN** the call reverts `BoundRequired` — a full-notional "bound" is tier-2 economics and must not wear a tier-0/1 label

### Requirement: Submitter bond pulled at certification when configured
When `submitterBondWood` is non-zero, `certify` SHALL revert `ZeroAddressSubmitter` for `submitter == address(0)`, record a `SubmitterBond{submitter, amount, releasableAt: 0}` for the key, add the amount to `totalBondedWood`, pull `submitterBondWood` WOOD from the submitter via `safeTransferFrom`, and emit `SubmitterBondLocked`. When `submitterBondWood` is zero, certification SHALL proceed with no bond (the Plan A no-bond passthrough for the governance-assigned initial adapter set).

#### Scenario: Bonded certification locks WOOD
- **WHEN** `submitterBondWood` is non-zero and the owner certifies with a submitter that has approved the registry
- **THEN** the bond transfers into the registry, `totalBondedWood` increases by the bond amount, and `SubmitterBondLocked` is emitted

#### Scenario: Zero-config bond skips the pull
- **WHEN** `submitterBondWood` is 0
- **THEN** `certify` records the tier config without touching WOOD or the bonds mapping

### Requirement: A key with any existing bond cannot be re-certified
`certify` SHALL revert while ANY bond exists for the key: `BondActive` when the bond is held under a live certification (`releasableAt == 0`), `BondPendingRelease` when a demoted bond is in its release timelock. Replacing a bonded certification requires demote → release timelock → claim → fresh certify; during that whole window the key reads as tier 2. This applies to benign edits too (correcting a bound typo, re-certifying after a legitimate adapter upgrade) — deliberate, so no path ever swaps a certification out from under a live bond or strands a submitter's WOOD.

#### Scenario: Re-certify over an active bond refused
- **WHEN** the owner calls `certify` on a key whose bond is still held under a live certification
- **THEN** the call reverts `BondActive`

#### Scenario: Re-certify during the release timelock refused
- **WHEN** the owner calls `certify` on a demoted key whose bond has not yet been claimed
- **THEN** the call reverts `BondPendingRelease`

### Requirement: Bond configuration setters and their guards
The owner SHALL configure the bond system through three setters, each emitting `SubmitterBondConfigSet`:
- `setWood(wood_)` SHALL revert `BondsOutstanding` while `totalBondedWood != 0` (outstanding bonds are denominated in the old token; a swap would strand them), and SHALL revert `BondConfigUnset` when clearing the token to `address(0)` while `submitterBondWood` is still non-zero.
- `setSubmitterBondWood(amount)` SHALL revert `BondConfigUnset` when setting a non-zero amount while no WOOD token is set, and `BondTooLarge` above `type(uint96).max` (making the `uint96` narrowing in `certify` provably lossless). Zero disables the bond requirement.
- `setBondReleaseDelay(delay)` SHALL revert `InvalidDelay` outside `[MIN_BOND_RELEASE_DELAY = 1 days, MAX_BOND_RELEASE_DELAY = 365 days]`. The floor preserves the guard-bypass slash window (a demoted bond must stay claimable-not-yet-claimed long enough for the slash machinery to act); the ceiling bounds governance error. The default delay is 14 days.

#### Scenario: Token swap with bonds outstanding refused
- **WHEN** the owner calls `setWood` while any bond (active or pending release) is held
- **THEN** the call reverts `BondsOutstanding`; the operator must drain all bonds (demote → timelock → claim) first

#### Scenario: Delay outside bounds refused
- **WHEN** the owner sets a bond release delay below 1 day or above 365 days
- **THEN** the call reverts `InvalidDelay`

### Requirement: Three demotion paths converging on one effect
Demotion SHALL delete the tier config (the key reverts to the tier-2 default), start the bond release timelock exactly once (`releasableAt = block.timestamp + bondReleaseDelay`, emitting `SubmitterBondReleaseStarted`, only if a bond exists and is not already releasing), delete the target's adapter-allowlist entry (emitting `AdapterAllowedSet(target, false)` if and only if the entry was set), and emit `TierDemoted`. Three callers reach it:
- `demote(target, selector)` — owner-only revocation.
- `demoteByChallenge(target, selector)` — callable only by `authorizedDemoter` (reverts `NotAuthorizedDemoter` otherwise); the ChallengeGame's role, so the game can revoke a certification but never grant one.
- `poke` — permissionless, gated on codehash mismatch (above).

The allowlist clear is DELIBERATELY over-broad: certification is keyed `(target, selector)` while the allowlist is keyed by bare `address`, so demoting ONE selector de-allowlists the WHOLE adapter. The adversary is an adapter that was just convicted in a challenge, or whose bytecode was just swapped under it (the `poke` trigger), retaining the standing right to receive approvals and transfers of vault funds through a governor batch — tier 2 raises its coverage price but is a price, not a prohibition. For that adversary, de-allowlisting more than strictly necessary is the correct direction of error: the cost is one owner `setAdapterAllowed(adapter, true)` call to restore the surviving selectors' adapter; the alternative cost is vault funds approved to a convicted or mutated adapter. This over-breadth SHALL be recorded in the `_demote` natspec so it is not "fixed" back to per-selector.

#### Scenario: Challenge-game demotion
- **WHEN** the address set as `authorizedDemoter` calls `demoteByChallenge` on a certified pair
- **THEN** the config is deleted, the bond release timelock starts, the adapter's allowlist entry is cleared, and `TierDemoted` is emitted

#### Scenario: Unauthorized demoteByChallenge refused
- **WHEN** any other address calls `demoteByChallenge`
- **THEN** the call reverts `NotAuthorizedDemoter`

#### Scenario: Double demotion does not restart the timelock
- **WHEN** a key whose bond is already pending release is demoted again (e.g. owner `demote` after a challenge demotion)
- **THEN** `releasableAt` is unchanged — the timelock starts once

#### Scenario: Every demotion path clears the allowlist
- **WHEN** an allowlisted adapter is demoted via owner `demote`, via `demoteByChallenge`, or via permissionless `poke` after a codehash change
- **THEN** `isAdapterAllowed(adapter)` returns false and `AdapterAllowedSet(adapter, false)` was emitted, on each of the three paths

#### Scenario: Demoting a never-allowlisted target is silent on the allowlist channel
- **WHEN** a certified pair whose target was never allowlisted is demoted
- **THEN** the demotion proceeds normally and NO `AdapterAllowedSet` event is emitted (indexers see no phantom allowlist change)

#### Scenario: One selector's demotion de-allowlists the whole adapter (intended)
- **WHEN** an adapter certified for several selectors and allowlisted is demoted on exactly one selector
- **THEN** `isAdapterAllowed(adapter)` returns false even though the other selectors remain certified — the over-broad clear is the specified behavior, not a bug

### Requirement: Demoter role rotation is always safe, including to zero
`setAuthorizedDemoter(demoter)` SHALL be owner-only and SHALL accept `address(0)` — the unwire switch, revoking the challenge game's demotion role while a replacement is wired. The unwired state fails closed for future demotions (nothing can `demoteByChallenge`), and the ChallengeGame treats a failed demotion as best-effort (emitting `AdapterDemotionFailed` rather than reverting the verdict), so the role is safe to rotate at any time; owner `demote` is the remedy for any revocation a rotation lost. The setter emits `AuthorizedDemoterSet`.

#### Scenario: Unwiring the demoter mid-challenge does not brick a verdict
- **WHEN** the demoter role is cleared to zero while a challenge is live
- **THEN** the challenge still settles (the game's demotion attempt fails best-effort) and the owner can apply the lost demotion via `demote`

### Requirement: Permissionless bond claim after the release timelock
`claimSubmitterBond(target, selector)` SHALL be callable by anyone, SHALL revert `BondNotReleasable` while `releasableAt` is zero or in the future, and on success SHALL delete the bond, decrement `totalBondedWood`, and transfer the bond amount to the RECORDED submitter (never the caller). Permissionless because the payout address is fixed — a caller gate would protect nothing and would let a lost-key submitter permanently retire a key (since `certify` blocks while any bond exists). `SubmitterBondClaimed` is emitted.

#### Scenario: Claim before the timelock elapses refused
- **WHEN** `claimSubmitterBond` is called before `releasableAt`
- **THEN** the call reverts `BondNotReleasable`

#### Scenario: Third-party claim pays the submitter
- **WHEN** an unrelated address claims a releasable bond
- **THEN** the WOOD transfers to the recorded submitter and the key becomes certifiable again

### Requirement: Bond introspection
`bondOf(target, selector)` SHALL return the full `SubmitterBond` record (submitter, amount, releasableAt) — a zeroed struct when no bond exists. The slash contract and UIs need `releasableAt` to time the challenge window.

#### Scenario: Reading a pending-release bond
- **WHEN** `bondOf` is called on a demoted key
- **THEN** the returned struct carries the recorded submitter, the bonded amount, and the non-zero `releasableAt`

### Requirement: Registry WOOD balance invariant
The registry SHALL maintain `wood.balanceOf(address(this)) == totalBondedWood` — every WOOD in the registry is an accounted bond (active or pending release), and every accounted bond is backed.

#### Scenario: Invariant across the bond lifecycle
- **WHEN** bonds are locked at certify, demoted, and claimed
- **THEN** at every step the registry's WOOD balance equals `totalBondedWood`

### Requirement: Adapter allowlist is a separate axis from tiers
The registry SHALL maintain an owner-managed allowlist of adapter addresses (`setAdapterAllowed(adapter, allowed)`, emitting `AdapterAllowedSet`; read via `isAdapterAllowed(adapter)`). Tiers PRICE extractable value for coverage; the allowlist bounds WHERE vault funds may be approved or sent at all — it gates the spender/recipient of value-moving ERC20 calls (approve / increaseAllowance / transfer / transferFrom-out) inside governor batches (consumed by `SyndicateVault._guardBatchCalls`).

The coupling between the two axes SHALL be exactly one-way and fail-closed: demotion clears the allowlist entry (see "Three demotion paths converging on one effect"), but NO certification action ever sets or restores it. In particular, re-certifying a previously demoted (target, selector) SHALL NOT re-allowlist the target — `certify` would otherwise silently re-grant a payment permission as a side effect of a pricing action, and the adversary is a submitter who gets a certification through and thereby re-opens the funds path without the owner ever deciding to. Restoring the allowlist after a demotion is always an explicit owner `setAdapterAllowed(adapter, true)` call.

#### Scenario: Disallowed adapter as ERC20 spender
- **WHEN** a governor batch contains an ERC20 approval whose spender is not on the allowlist
- **THEN** the vault's batch guard rejects it regardless of the target's tier

#### Scenario: Allowlisting is owner-only
- **WHEN** a non-owner calls `setAdapterAllowed`
- **THEN** the call reverts (Ownable)

#### Scenario: Re-certification does not restore the allowlist
- **WHEN** a demoted adapter (allowlist auto-cleared) is later re-certified via `certify`
- **THEN** `isAdapterAllowed(adapter)` still returns false until the owner explicitly calls `setAdapterAllowed(adapter, true)`

#### Scenario: Owner recovery after an over-broad clear
- **WHEN** the owner calls `setAdapterAllowed(adapter, true)` after a demotion cleared the adapter's entry
- **THEN** `isAdapterAllowed(adapter)` returns true again and governor batches may fund the adapter as before

### Requirement: External read surface
The `ITierRegistry` interface consumed by the vault SHALL expose exactly the two reads `tierOf(target, selector) → (tier, boundBps)` and `isAdapterAllowed(adapter) → bool`. The demoter role and its setter are deliberately not part of this read-side interface.

#### Scenario: Vault-side consumption
- **WHEN** the vault or governor prices a call's extractable value
- **THEN** it reads `tierOf` through `ITierRegistry` and gets the effective (post-lazy-demotion) tier and bound

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
