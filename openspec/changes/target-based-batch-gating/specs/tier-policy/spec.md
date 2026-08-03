# tier-policy (delta)

## MODIFIED Requirements

### Requirement: Adapter allowlist is a separate axis from tiers

The registry SHALL maintain an owner-managed allowlist of adapter addresses (`setAdapterAllowed(adapter, allowed)`, emitting `AdapterAllowedSet`; read via `isAdapterAllowed(adapter)`). Tiers PRICE extractable value for coverage; the allowlist bounds WHERE the vault's identity and funds may travel at all. It is consumed by `SyndicateVault._guardBatchCalls` in two roles, both answering through the SAME predicate (one implementation, two consumers — a second allowlist would drift):

1. **Spender/recipient gate (existing role):** it gates the spender/recipient of value-moving ERC-20-family calls (approve / increaseAllowance / transfer / transferFrom-out and the alternate-signature families) inside governor batches.
2. **Batch callee gate (issue #166, Option B):** it gates the `target` of EVERY governor-batch sub-call other than the vault's underlying `asset()`, regardless of selector — an entry now means "may be reached by a governor batch carrying `msg.sender == vault` at all, and hence may receive vault funds under selectors the guard cannot enumerate". Under selector-blindness these two consents are the same consent: any callable target must be assumed able to receive an approval or transfer under an unenumerated selector, so the registry SHALL NOT attempt to distinguish "callable" from "fund-destination".

GOVERNANCE DISCIPLINE FOR THE CALLEE ROLE: because the value-moving-selector guard beneath the callee gate only understands ERC-20-family calldata shapes, exotic-asset contracts — ERC-721, ERC-1155, ERC-777, LP-position NFTs, and kin — MUST NOT be allowlisted as batch callees. Batches reach such positions only through allowlisted strategy adapters, never by direct calldata against the asset contract; allowlisting an exotic-asset contract would re-open, for that one contract, exactly the operator/approval gap (issue #18) the callee gate closes by default posture. This is the same class of documented operator invariant as the existing proxy-discipline rule for certification.

THE ALLOWLIST SHALL BE CODEHASH-BOUND. `setAdapterAllowed(adapter, true)` SHALL snapshot the adapter's effective codehash into a dedicated per-address mapping at grant time, where the effective codehash normalizes both `bytes32(0)` (non-existent account) and `keccak256("")` (existing account with no code) to `bytes32(0)` — "no code" is one value, so merely funding a codeless allowlisted address cannot be used as a griefing donation that closes the vault's funds path. Every grant (re)writes the snapshot: an idempotent re-grant is the owner's re-attestation of the adapter's CURRENT code (the recovery ceremony after a verified legitimate upgrade). `setAdapterAllowed(adapter, false)` and the demotion paths do not touch the snapshot; a snapshot under a cleared flag is inert and is overwritten by the next grant.

`isAdapterAllowed(adapter)` SHALL remain a `view` and SHALL return `true` only when the allowlist flag is set AND the adapter's live effective codehash equals the grant-time snapshot — a lazy, read-side self-heal mirroring `tierOf`: no state write in the hot path, nothing to grief, and no dependence on `poke` ever being called. The adversary: an allowlisted adapter whose bytecode is swapped at the same address (metamorphic CREATE2 + SELFDESTRUCT redeploy), or a codeless allowlisted address at which code later appears (counterfactual CREATE2), otherwise retains standing permission to appear as spender/recipient of vault-fund movements — and, since issue #166, to be CALLED by governor batches at all — until someone happens to persist a demotion; and for an allowlisted-but-uncertified adapter `poke` reverts `NotCertified`, so no permissionless persistence path exists at all; the read-side check is the ONLY automatic protection there. The codehash binding does NOT cover proxy implementation swaps (a proxy's runtime bytecode is static across upgrades) — allowlisting proxied adapters carries the same governance-discipline caveat as certifying them, and that caveat now covers callability too.

The coupling between the two axes SHALL be exactly one-way and fail-closed: demotion clears the allowlist entry (see "Three demotion paths converging on one effect"), but NO certification action ever sets or restores it. In particular, re-certifying a previously demoted (target, selector) SHALL NOT re-allowlist the target — `certify` would otherwise silently re-grant a payment permission as a side effect of a pricing action, and the adversary is a submitter who gets a certification through and thereby re-opens the funds path without the owner ever deciding to. Restoring the allowlist after a demotion is always an explicit owner `setAdapterAllowed(adapter, true)` call. The grant-time codehash snapshot SHALL likewise remain dedicated to the allowlist axis: certification-path changes (e.g. a future `certify` timelock) MUST NOT repurpose it for their own audit trails — certification tier and transfer permission are structurally different axes with different keying and lifecycles.

#### Scenario: Disallowed adapter as ERC20 spender

- **WHEN** a governor batch contains an ERC20 approval whose spender is not on the allowlist
- **THEN** the vault's batch guard rejects it regardless of the target's tier

#### Scenario: Unlisted callee is rejected regardless of selector

- **WHEN** a governor batch contains a call to a target that is neither the vault's `asset()` nor on the allowlist, whatever its selector or calldata (including empty calldata with native value)
- **THEN** the vault's batch guard rejects it with `DisallowedBatchCallee(target)` — tier pricing is not an implicit callability grant

#### Scenario: Allowlisting is owner-only

- **WHEN** a non-owner calls `setAdapterAllowed`
- **THEN** the call reverts (Ownable)

#### Scenario: Metamorphic redeploy closes the funds path on the next read

- **WHEN** an allowlisted adapter's bytecode changes at the same address after the grant, and nobody has called `poke`, `demote`, or `setAdapterAllowed`
- **THEN** `isAdapterAllowed(adapter)` returns false on the very next read — a governor batch approving or transferring vault funds to the adapter, or merely naming it as a call target, reverts in the vault's batch guard even though the allowlist storage still holds `true`

#### Scenario: Demotion severs callability along with fund-destination standing

- **WHEN** any demotion path (`demote`, `demoteByChallenge`, `poke`) clears an adapter's allowlist entry
- **THEN** subsequent governor batches can neither direct value-moving calls at the adapter nor call it as a batch target until the owner explicitly re-grants `setAdapterAllowed(adapter, true)`

#### Scenario: Selfdestructed adapter fails closed

- **WHEN** an adapter that had code at grant time later has no code (selfdestructed, not yet redeployed)
- **THEN** `isAdapterAllowed(adapter)` returns false; batch calls directing value at that adapter or naming it as a target revert (the gate is per-address), and recovery is one owner re-grant after verifying any redeployed code

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
- **THEN** `isAdapterAllowed(adapter)` returns true again and governor batches may fund and call the adapter as before
