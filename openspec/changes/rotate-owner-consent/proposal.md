# Consent-gated owner-stake binding on rotateOwner

GitHub issue: #98 — "rotateOwner binds a third party's escrowed stake without their consent" (pre-existing on `main`; surfaced by the Pashov `solidity-auditor` panel, access-control lens).

## Why

`SyndicateFactory.rotateOwner(vault, newOwner)` authorizes only `msg.sender` (current vault owner or original creator, `SyndicateFactory.sol:720`); `newOwner` is validated solely against `address(0)` (`:715`). But the call is not a mere title assignment — it invokes `StakedWood.transferOwnerStakeSlot(vault, newOwner)` (`SyndicateFactory.sol:733` → `StakedWood.sol:1032`), which **spends `newOwner`'s escrowed prepared stake**: it sets `_ownerStakes[vault] = {p.amount, owner: newOwner}` and marks `_prepared[newOwner].bound = true` with no consent check on `newOwner`.

Verified attack (all guards traced in this worktree): Mallory owns any vault whose bond slot is empty (`ownerStake(V) == 0` — free at the documented `minOwnerStake == 0` open-onboarding floor, or obtainable via her own unstake cycle) and has no open proposals. Alice calls `prepareOwnerStake(50_000e18)` intending to open her own vault. Mallory calls `rotateOwner(V, alice)`; every guard passes. Alice's stake is now bound to V: `cancelPreparedStake()` reverts `PreparedStakeNotFound` (`StakedWood.sol:897`), her own `createSyndicate` reverts (`canCreateVault` false via `bound`, `StakedWood.sol:1070-1072` → `SyndicateFactory.sol:307`), and recovery requires a full `requestUnstakeOwner` → cooldown (1–30 days) → `claimUnstakeOwner` cycle on a vault she never chose, during which the bond is exposed to `GuardianRegistry._resolveEmergency` → `slashOwnerBond(V)` full burn (`GuardianRegistry.sol:891-894`).

## What Changes

- `StakedWood` gains an explicit opt-in: `approveOwnerStakeBinding(address vault)` (and `revokeOwnerStakeBinding()`), callable by the prospective owner, recording the single vault their prepared stake may be bound to via slot transfer.
- `StakedWood.transferOwnerStakeSlot(vault, newOwner)` SHALL revert (new error `BindingNotApproved`) unless `newOwner` has approved exactly `vault`. The approval is consumed on successful bind.
- Stale-consent hygiene: the approval is cleared on successful bind, on `cancelPreparedStake`, and on a fresh `prepareOwnerStake` — an approval given for one escrow lifetime can never be replayed against a later one.
- `SyndicateFactory.rotateOwner` keeps its exact signature and single-call semantics; it now additionally requires prior consent from `newOwner` (enforced at the sWOOD spend site). **BREAKING (behavioral only)**: a `rotateOwner` call whose `newOwner` has not pre-approved the vault now reverts. No ABI change; no deploy script calls `rotateOwner` (verified — zero hits under `script/`).
- `createSyndicate` → `bindOwnerStake` is untouched: there the bound stake belongs to `msg.sender` of `createSyndicate`, so consent is structural.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `guardian-staking`: new requirement — the owner-stake slot transfer SHALL require the incoming owner's prior vault-specific approval; approvals are single-use and cleared across the prepared-stake lifecycle.
- `syndicate-governor`: the "Factory lifecycle-gated administration" requirement's `rotateOwner` clause gains the incoming-owner-consent precondition and its failure scenario.

## Impact

- `src/StakedWood.sol` — new approval mapping + `approveOwnerStakeBinding` / `revokeOwnerStakeBinding`, consent check in `transferOwnerStakeSlot`, approval clearing in `cancelPreparedStake` / `prepareOwnerStake`, new error + events.
- `src/interfaces/IStakedWood.sol` — new function declarations.
- `src/SyndicateFactory.sol` — natspec only (document the new precondition; no code change).
- `test/factory/OwnerStakeAtCreation.t.sol`, `test/audit-fixes/SyndicateFactory_rotateOwner_proposalGuard.t.sol` — existing rotation happy paths must add the newOwner approval step.
- `test/StakedWood.t.sol` (or a new `test/audit-fixes/` file) — negative test reproducing the issue's exact 4-step trace, plus approval-lifecycle tests.
- No deploy-script changes; no storage-layout risk to existing mappings (append-only state).
