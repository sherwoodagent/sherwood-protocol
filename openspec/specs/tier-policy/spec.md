# Tier Policy Specification

## Purpose

Adapter-selector tier certification for the guardian economic-security model. A tier is a property of a `(target, selector)` pair, set at listing by governance and consumed at propose/execute time: tier 0 (closed-loop) and tier 1 (oracle-bounded discretion) carry a certified extractable bound in bps of notional; tier 2 (arbitrary calldata, full notional) is the default for anything uncertified. `TierRegistry` also carries the adapter allowlist that bounds where vault funds may be approved or sent inside governor batches — TWO axes since pashov finding #14, a funds axis (`isAdapterAllowed`) and a callee axis (`isCallableTarget`) that diverge on demotion.
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
Demotion SHALL delete the tier config (the key reverts to the tier-2 default), delete the target's adapter-allowlist entry (emitting `AdapterAllowedSet(target, false)` if and only if the entry was set), and emit `TierDemoted`. Two callers reach it:
- `demote(target, selector)` — owner-only revocation.
- `demoteByChallenge(target, selector)` — callable only by `authorizedDemoter` (reverts `NotAuthorizedDemoter` otherwise); the ChallengeGame's role, so the game can revoke a certification but never grant one.

The allowlist clear is DELIBERATELY over-broad: certification is keyed `(target, selector)` while the allowlist is keyed by bare `address`, so demoting ONE selector de-allowlists the WHOLE adapter. The adversary is an adapter that was just convicted in a challenge, or whose bytecode was just swapped under it, retaining the standing right to receive approvals and transfers of vault funds through a governor batch — tier 2 raises its coverage price but is a price, not a prohibition. For that adversary, de-allowlisting more than strictly necessary is the correct direction of error: the cost is one owner `setAdapterAllowed(adapter, true)` call to restore the surviving selectors' adapter; the alternative cost is vault funds approved to a convicted or mutated adapter. This over-breadth SHALL be recorded in the `_demote` natspec so it is not "fixed" back to per-selector.

#### Scenario: Challenge-game demotion
- **WHEN** the address set as `authorizedDemoter` calls `demoteByChallenge` on a certified pair
- **THEN** the config is deleted, the adapter's allowlist entry is cleared, and `TierDemoted` is emitted

#### Scenario: Unauthorized demoteByChallenge refused
- **WHEN** any other address calls `demoteByChallenge`
- **THEN** the call reverts `NotAuthorizedDemoter`

#### Scenario: Every demotion path clears the FUNDS axis and leaves the CALLEE axis
- **WHEN** an allowlisted adapter is demoted via owner `demote` or via `demoteByChallenge`
- **THEN** `isAdapterAllowed(adapter)` returns false and `AdapterAllowedSet(adapter, false)` was emitted, on both paths
- **AND** `isCallableTarget(adapter)` still returns true on both paths, provided the adapter's codehash has not drifted — the axes are specified separately below, and asserting only the first half of this scenario would let a regression that re-closes the callee axis pass

#### Scenario: Demoting a never-allowlisted target is silent on the allowlist channel
- **WHEN** a certified pair whose target was never allowlisted is demoted
- **THEN** the demotion proceeds normally and NO `AdapterAllowedSet` event is emitted (indexers see no phantom allowlist change)

#### Scenario: One selector's demotion de-allowlists the whole adapter (intended)
- **WHEN** an adapter certified for several selectors and allowlisted is demoted on exactly one selector
- **THEN** `isAdapterAllowed(adapter)` returns false even though the other selectors remain certified — the over-broad clear is the specified behavior, not a bug

### Requirement: The callee axis is separate from the funds axis and outlives a demotion
The registry SHALL expose `isCallableTarget(target)` answering exactly one question — "may the vault name this address as a callee inside a governor batch?" (`SyndicateVault._guardBatchCalls` PART 2a) — held SEPARATE from `isAdapterAllowed`, which answers "may this address RECEIVE vault-fund movements?" (PART 2b).

Both axes SHALL be granted together by an EXPLICIT owner decision (`setAdapterAllowed(a, true)` on the address path, `setClassAllowed(t, true)` on the class path) and SHALL diverge only on revocation:
- An EXPLICIT owner revocation (`setAdapterAllowed(a, false)`, `setClassAllowed(t, false)`) SHALL close BOTH axes. On the address path this SHALL bite for a CLASS member that has no address entry of its own, which requires a denial flag that demotion never writes (`_calleeRevoked`) — clearing an address-path grant that was never set would otherwise bite nothing and the class fallback would re-allow the member forever, and since anyone may permissionlessly deploy an ERC-1167 clone of a certified template to become a member, that would be a strict widening.
- A DEMOTION (`_demote`, `_demoteClass`, on all of their paths) SHALL close the funds axis and SHALL LEAVE THE CALLEE AXIS STANDING.

The reason demotion is asymmetric: revoking the right to be PAID must not revoke the vault's ability to RECLAIM. Demotion is reachable permissionlessly — `ChallengeGame.file` only requires the `(target, selector)` pair to appear in the executed proposal's calldata, and every execute batch names `(clone, execute())` — so a single bit answering both questions let anyone revoke the vault's ability to CALL the strategy clone HOLDING its capital: `settleProposal`, `unstick` and `finalizeEmergencySettle` all reverted `DisallowedBatchCallee`, the proposal pinned in `Executed`, `redemptionsLocked()` stayed true, and every LP exit shut until the registry multisig re-granted standing.

The callee axis SHALL retain the grant-time codehash equality check on the address path, so a bytecode swap under an allowlisted address closes it exactly as it closes the funds axis. A clone's runtime is immutable, so this never strands the case the split exists to rescue.

This asymmetry SHALL be recorded in the `_demote`, `_demoteClass` and `isCallableTarget` natspec, and pinned by test, so it is not "fixed" into clearing both — a demotion that deliberately does NOT clear a flag reads as an omission rather than a decision, and is therefore more vulnerable to a well-meaning correction than the over-breadth above.

SCOPE, stated so it is not over-read: the callee axis confers no right to receive ERC-20 fund movements, which PART 2b gates on `isAdapterAllowed` over its enumerated spender/recipient selectors. It is NOT a guarantee about native `value`, which no part of the guard inspects — a `value`-bearing call with fewer than 4 calldata bytes passes PART 2b unexamined on any callable target. The vault holds no native balance by design (no `receive()`/`fallback()`), so this is a stated residual rather than a funded path.

#### Scenario: Demotion leaves an address-path target callable so its capital can be reclaimed
- **WHEN** an allowlisted target holding vault capital is demoted via `demoteByChallenge`
- **THEN** `isAdapterAllowed` returns false, `isCallableTarget` returns true, and a governor batch naming that target executes — recovering the capital

#### Scenario: Demotion leaves a CLASS member callable
- **WHEN** a certified, class-allowed template is demoted via `demoteClassByChallenge`
- **THEN** `isCallableTarget(clone)` still returns true for a clone of that template, whose only standing was ever the class path

#### Scenario: A demoted target still cannot receive vault funds
- **WHEN** a governor batch tries to `transfer` or `approve` vault funds to a demoted target
- **THEN** the call reverts `DisallowedTransferTarget` — restoring callability SHALL NOT restore fundability

#### Scenario: Explicit owner revocation closes the callee axis too
- **WHEN** the owner calls `setAdapterAllowed(target, false)`
- **THEN** `isCallableTarget(target)` returns false and a governor batch naming it reverts `DisallowedBatchCallee`

#### Scenario: Explicit owner revocation closes the callee axis for a class member with no address entry
- **WHEN** the owner calls `setAdapterAllowed(clone, false)` for a clone whose only standing is class membership
- **THEN** `isCallableTarget(clone)` returns false — the revocation bites through the class fallback, not merely on an address entry that was never set

#### Scenario: A codehash swap closes the callee axis
- **WHEN** code is replaced at an allowlisted address after the grant
- **THEN** `isCallableTarget` returns false without any state write, on the same read that closes `isAdapterAllowed`

#### Scenario: A counterparty grant does not open the callee axis
- **WHEN** an address holds only `setCounterpartyAllowed` standing
- **THEN** `isCallableTarget` returns false — the WEAK grant implies neither axis of the strong one

### Requirement: Demoter role rotation is always safe, including to zero
`setAuthorizedDemoter(demoter)` SHALL be owner-only and SHALL accept `address(0)` — the unwire switch, revoking the challenge game's demotion role while a replacement is wired. The unwired state fails closed for future demotions (nothing can `demoteByChallenge`), and the ChallengeGame treats a failed demotion as best-effort (emitting `AdapterDemotionFailed` rather than reverting the verdict), so the role is safe to rotate at any time; owner `demote` is the remedy for any revocation a rotation lost. The setter emits `AuthorizedDemoterSet`.

#### Scenario: Unwiring the demoter mid-challenge does not brick a verdict
- **WHEN** the demoter role is cleared to zero while a challenge is live
- **THEN** the challenge still settles (the game's demotion attempt fails best-effort) and the owner can apply the lost demotion via `demote`

### Requirement: Adapter allowlist is a separate axis from tiers
The registry SHALL maintain an owner-managed allowlist of adapter addresses (`setAdapterAllowed(adapter, allowed)`, emitting `AdapterAllowedSet`; read via `isAdapterAllowed(adapter)`). Tiers PRICE extractable value for coverage; the allowlist bounds WHERE vault funds may be approved or sent at all — it gates the spender/recipient of value-moving ERC20 calls (approve / increaseAllowance / transfer / transferFrom-out) inside governor batches (consumed by `SyndicateVault._guardBatchCalls`).

THE ALLOWLIST SHALL BE CODEHASH-BOUND. `setAdapterAllowed(adapter, true)` SHALL snapshot the adapter's effective codehash into a dedicated per-address mapping at grant time, where the effective codehash normalizes both `bytes32(0)` (non-existent account) and `keccak256("")` (existing account with no code) to `bytes32(0)` — "no code" is one value, so merely funding a codeless allowlisted address cannot be used as a griefing donation that closes the vault's funds path. Every grant (re)writes the snapshot: an idempotent re-grant is the owner's re-attestation of the adapter's CURRENT code (the recovery ceremony after a verified legitimate upgrade). `setAdapterAllowed(adapter, false)` and the demotion paths do not touch the snapshot; a snapshot under a cleared flag is inert and is overwritten by the next grant.

`isAdapterAllowed(adapter)` SHALL remain a `view` and SHALL return `true` only when the allowlist flag is set AND the adapter's live effective codehash equals the grant-time snapshot — a lazy, read-side self-heal mirroring `tierOf`: no state write in the hot path, nothing to grief, and no dependence on any demotion call. The adversary: an allowlisted adapter whose bytecode is swapped at the same address (metamorphic CREATE2 + SELFDESTRUCT redeploy), or a codeless allowlisted address at which code later appears (counterfactual CREATE2), otherwise retains standing permission to appear as spender/recipient of vault-fund movements in governor batches until the owner happens to revoke the grant; the read-side check is the ONLY automatic protection there. The codehash binding does NOT cover proxy implementation swaps (a proxy's runtime bytecode is static across upgrades) — allowlisting proxied adapters carries the same governance-discipline caveat as certifying them.

The coupling between the two axes SHALL be exactly one-way and fail-closed: demotion clears the allowlist entry (see "Three demotion paths converging on one effect"), but NO certification action ever sets or restores it. In particular, re-certifying a previously demoted (target, selector) SHALL NOT re-allowlist the target — `certify` would otherwise silently re-grant a payment permission as a side effect of a pricing action, and the adversary is a submitter who gets a certification through and thereby re-opens the funds path without the owner ever deciding to. Restoring the allowlist after a demotion is always an explicit owner `setAdapterAllowed(adapter, true)` call. The grant-time codehash snapshot SHALL likewise remain dedicated to the allowlist axis: certification-path changes MUST NOT repurpose it for their own audit trails — certification tier and transfer permission are structurally different axes with different keying and lifecycles.

#### Scenario: Disallowed adapter as ERC20 spender
- **WHEN** a governor batch contains an ERC20 approval whose spender is not on the allowlist
- **THEN** the vault's batch guard rejects it regardless of the target's tier

#### Scenario: Allowlisting is owner-only
- **WHEN** a non-owner calls `setAdapterAllowed`
- **THEN** the call reverts (Ownable)

#### Scenario: Metamorphic redeploy closes the funds path on the next read
- **WHEN** an allowlisted adapter's bytecode changes at the same address after the grant, and nobody has called `demote` or `setAdapterAllowed`
- **THEN** `isAdapterAllowed(adapter)` returns false on the very next read — a governor batch approving or transferring vault funds to the adapter reverts in the vault's batch guard even though the allowlist storage still holds `true`

#### Scenario: Selfdestructed adapter fails closed
- **WHEN** an adapter that had code at grant time later has no code (selfdestructed, not yet redeployed)
- **THEN** `isAdapterAllowed(adapter)` returns false; only batch calls directing value at that adapter revert (the gate is per-recipient), and recovery is one owner re-grant after verifying any redeployed code

#### Scenario: Codeless payout address stays allowed while codeless
- **WHEN** an address with no code is allowlisted and later merely receives a native-balance donation (non-existent account becomes existing-codeless)
- **THEN** `isAdapterAllowed` still returns true — the normalized "no code" snapshot matches the normalized live state; a 1-wei donation cannot grief the funds path closed

#### Scenario: Code appearing at a codeless allowlisted address fails closed
- **WHEN** code is deployed to an address that was allowlisted while it had no code
- **THEN** `isAdapterAllowed` returns false until the owner re-attests the deployed code with a fresh `setAdapterAllowed(adapter, true)`

#### Scenario: Re-grant re-attests the current code
- **WHEN** the owner calls `setAdapterAllowed(adapter, true)` after a verified legitimate bytecode change at the adapter's address
- **THEN** the snapshot is refreshed to the adapter's current effective codehash and `isAdapterAllowed(adapter)` returns true again

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

