# tier-policy (delta)

<!-- Change: fix-adapter-allowlist-selfheal (issue #137). Modifies the
     allowlist requirement only: the allowlist becomes codehash-bound with a
     lazy read-side self-heal mirroring tierOf. The demotion requirement
     ("Three demotion paths converging on one effect") is NOT modified —
     _demote is untouched by this change. -->

## MODIFIED Requirements

### Requirement: Adapter allowlist is a separate axis from tiers
The registry SHALL maintain an owner-managed allowlist of adapter addresses (`setAdapterAllowed(adapter, allowed)`, emitting `AdapterAllowedSet`; read via `isAdapterAllowed(adapter)`). Tiers PRICE extractable value for coverage; the allowlist bounds WHERE vault funds may be approved or sent at all — it gates the spender/recipient of value-moving ERC20 calls (approve / increaseAllowance / transfer / transferFrom-out) inside governor batches (consumed by `SyndicateVault._guardBatchCalls`).

THE ALLOWLIST SHALL BE CODEHASH-BOUND. `setAdapterAllowed(adapter, true)` SHALL snapshot the adapter's effective codehash into a dedicated per-address mapping at grant time, where the effective codehash normalizes both `bytes32(0)` (non-existent account) and `keccak256("")` (existing account with no code) to `bytes32(0)` — "no code" is one value, so merely funding a codeless allowlisted address cannot be used as a griefing donation that closes the vault's funds path. Every grant (re)writes the snapshot: an idempotent re-grant is the owner's re-attestation of the adapter's CURRENT code (the recovery ceremony after a verified legitimate upgrade). `setAdapterAllowed(adapter, false)` and the demotion paths do not touch the snapshot; a snapshot under a cleared flag is inert and is overwritten by the next grant.

`isAdapterAllowed(adapter)` SHALL remain a `view` and SHALL return `true` only when the allowlist flag is set AND the adapter's live effective codehash equals the grant-time snapshot — a lazy, read-side self-heal mirroring `tierOf`: no state write in the hot path, nothing to grief, and no dependence on `poke` ever being called. The adversary: an allowlisted adapter whose bytecode is swapped at the same address (metamorphic CREATE2 + SELFDESTRUCT redeploy), or a codeless allowlisted address at which code later appears (counterfactual CREATE2), otherwise retains standing permission to appear as spender/recipient of vault-fund movements in governor batches until someone happens to persist a demotion — and for an allowlisted-but-uncertified adapter `poke` reverts `NotCertified`, so no permissionless persistence path exists at all; the read-side check is the ONLY automatic protection there. The codehash binding does NOT cover proxy implementation swaps (a proxy's runtime bytecode is static across upgrades) — allowlisting proxied adapters carries the same governance-discipline caveat as certifying them.

The coupling between the two axes SHALL be exactly one-way and fail-closed: demotion clears the allowlist entry (see "Three demotion paths converging on one effect"), but NO certification action ever sets or restores it. In particular, re-certifying a previously demoted (target, selector) SHALL NOT re-allowlist the target — `certify` would otherwise silently re-grant a payment permission as a side effect of a pricing action, and the adversary is a submitter who gets a certification through and thereby re-opens the funds path without the owner ever deciding to. Restoring the allowlist after a demotion is always an explicit owner `setAdapterAllowed(adapter, true)` call. The grant-time codehash snapshot SHALL likewise remain dedicated to the allowlist axis: certification-path changes (e.g. a future `certify` timelock) MUST NOT repurpose it for their own audit trails — certification tier and transfer permission are structurally different axes with different keying and lifecycles.

#### Scenario: Disallowed adapter as ERC20 spender
- **WHEN** a governor batch contains an ERC20 approval whose spender is not on the allowlist
- **THEN** the vault's batch guard rejects it regardless of the target's tier

#### Scenario: Allowlisting is owner-only
- **WHEN** a non-owner calls `setAdapterAllowed`
- **THEN** the call reverts (Ownable)

#### Scenario: Metamorphic redeploy closes the funds path on the next read
- **WHEN** an allowlisted adapter's bytecode changes at the same address after the grant, and nobody has called `poke`, `demote`, or `setAdapterAllowed`
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
