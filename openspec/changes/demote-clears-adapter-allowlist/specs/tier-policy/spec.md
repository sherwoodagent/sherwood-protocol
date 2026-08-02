## MODIFIED Requirements

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
