## MODIFIED Requirements

### Requirement: Review-path slash (registry-only)
`slashGuardians(reviewKey, openedAt, approvers, slashBps)` SHALL be callable only by the wired guardian registry (revert `NotRegistry` otherwise). For each approver it SHALL burn `slashBps` (bps of 10,000) of the approver's slash basis — the greater of the liability and votable checkpoints at `openedAt`, clamped to live stake (a concurrent slash may already have reduced it). The rate supplied for each approver SHALL be computed by the registry as `clamp(ceil(lockBps × severity / 10_000), minSlashBps, maxSlashBps)`, where `lockBps` is the approver's WOOD lock for the review over that same basis (the ledger's `slashBpsForAt` at the review-open instant, see the guardian-coverage capability) and `severity` is the review's deterministic severity — so the amount burned is `min(lock, basis) × severity / 10_000` unless the envelope binds, never a fraction of the whole bond chosen independently of the lock. The envelope `[minSlashBps, maxSlashBps]` SHALL be the one SNAPSHOTTED AT REVIEW OPEN — never the live values — so `minSlashBps` is the floor a guardian cannot declare their way under, while the owner cannot raise what an already-decided review costs between open and resolve. The staking contract SHALL NOT apply the live envelope in either direction: not the live floor (the owner could raise what a decided review costs) and not the live ceiling (the owner could zero `maxSlashBps` between open and resolve and nullify the burn). Its only cap SHALL be the arithmetic saturation at 10,000 bps, a constant no role controls. The adversary of both rules is the sWOOD owner — the same multisig that owns the registry — changing the envelope after a review has opened to punish, or to spare, a specific cohort against the terms they voted under. A rate whose lock-times-severity product is zero SHALL be passed as zero, never as the raw lock rate. With no exposure ledger wired the registry passes all-zero rates and nothing is slashed. Age discounts voting power, not liability: the slash basis is raw staked amount, never age-discounted. For a still-active approver the slash decrements `totalGuardianStake` and re-checkpoints votable stake; for an unstake-requested approver the aggregate was already decremented at request time, and a slash to zero clears the request stamp so no ghost guardian survives. The liability trace re-checkpoints on both branches. `GuardianSlashed(reviewKey, approver, ownSlash, delegatedSlash)` SHALL be emitted only when a non-zero amount was slashed; `delegatedSlash` is always 0 (parameter retained for ABI compatibility). The aggregate total-stake checkpoint is pushed once after the loop and the total is burned in a single transfer. The severity is a quadratic ramp of block-side decisiveness bounded to the at-open envelope. The adversary is a guardian who backed a bad proposal with a small lock while holding a large bond: they lose the lock scaled by severity, and never less than `minSlashBps` of the basis.

#### Scenario: Non-registry caller
- **WHEN** any address other than the wired registry calls `slashGuardians`
- **THEN** the call reverts `NotRegistry`

#### Scenario: Slash sized at review open, clamped to live
- **WHEN** an approver's checkpointed stake at `openedAt` exceeds its live stake at slash time
- **THEN** the slash is computed on the live (smaller) amount

#### Scenario: Burn tracks the lock, not the bond
- **WHEN** an approver whose basis is 2,000 WOOD locked 500 WOOD on the reviewed proposal, the review's severity is 10,000 bps, and the envelope does not bind
- **THEN** 500 WOOD is burned and 1,500 WOOD remains staked, covering the approver's other locks

#### Scenario: Envelope floors a small lock
- **WHEN** an approver's lock-and-severity rate is below the `minSlashBps` snapshotted at review open
- **THEN** the burn is that at-open `minSlashBps` of the basis, not the smaller lock

#### Scenario: Owner cannot raise the floor on a decided review
- **WHEN** the owner raises `minSlashBps` after a review has opened and before it resolves Blocked
- **THEN** the approvers are floored at the value in force at open; the raise applies only to reviews opened afterwards

#### Scenario: Fully slashed guardian mid-request
- **WHEN** an unstake-requested approver is slashed to zero stake
- **THEN** its `unstakeRequestedAt` stamp is cleared, so a later `cancelUnstakeGuardian` cannot resurrect it

#### Scenario: Slashed WOOD burns
- **WHEN** `slashGuardians` slashes a non-zero total
- **THEN** the total is transferred to the dead burn address in one transfer

## ADDED Requirements

### Requirement: The incoming owner consents to an owner-stake slot transfer
Binding a prepared owner stake to a vault through the slot-transfer path (the factory's owner-rotation flow) SHALL require the incoming owner's prior, vault-specific consent, recorded on sWOOD by the incoming owner themselves. Adversary: a current vault owner who "gifts" a vault to a victim to spend the victim's escrowed prepared stake — locking it behind the owner-unstake cooldown and exposing it to an emergency-review owner-bond slash — must be unable to do so without the victim's opt-in.

`approveOwnerStakeBinding(vault)` SHALL record `vault` as the single vault the caller consents to have their prepared stake bound to via slot transfer; it SHALL reject the zero vault. Calling it again SHALL overwrite the previous approval (at most one approved vault per address). `revokeOwnerStakeBinding()` SHALL clear the caller's approval. Both SHALL emit events naming the approver and the vault.

`transferOwnerStakeSlot(vault, newOwner)` SHALL revert with `BindingNotApproved` unless `newOwner`'s recorded approval equals exactly `vault`, in addition to its existing guards (factory-only caller, prior slot cleared, prepared stake present, unbound, and at or above the floor). A successful transfer SHALL consume the approval (clear it), so one consent authorizes at most one bind.

Consent SHALL be scoped to a single escrow lifetime and never replayable against a later one: the approval SHALL also be cleared by `cancelPreparedStake` and by a fresh `prepareOwnerStake`. An approval standing without a live prepared stake SHALL be inert — the transfer's existing prepared-stake guards still reject the bind.

The creation-time bind (`bindOwnerStake`, reached only from the factory's `createSyndicate`) SHALL NOT require an approval: the bound stake there belongs to the creator who initiated the call, so consent is structural.

#### Scenario: Non-consensual rotation cannot spend a third party's escrow
- **WHEN** Alice has a prepared, unbound stake at or above the floor and has never called `approveOwnerStakeBinding`, and the owner of a vault with an empty bond slot and no open proposals attempts the factory owner-rotation naming Alice as the new owner
- **THEN** the slot transfer SHALL revert with `BindingNotApproved`, Alice's prepared stake SHALL remain unbound, `cancelPreparedStake` SHALL still refund it, and Alice's own vault creation SHALL remain possible

#### Scenario: Consented rotation binds and consumes the approval
- **WHEN** the incoming owner has called `approveOwnerStakeBinding(vault)` and the factory rotation for that vault executes
- **THEN** the prepared stake SHALL bind to the vault under the incoming owner's name and the approval SHALL be cleared, so a second slot transfer naming the same incoming owner reverts (`BindingNotApproved` or the prepared-stake guards)

#### Scenario: Approval is vault-specific
- **WHEN** the incoming owner approved vault A and the factory rotation targets vault B
- **THEN** the slot transfer SHALL revert with `BindingNotApproved`

#### Scenario: Revocation restores the safe state
- **WHEN** an incoming owner approves a vault and then calls `revokeOwnerStakeBinding()` before the rotation lands
- **THEN** a subsequent slot transfer naming them SHALL revert with `BindingNotApproved`

#### Scenario: Stale approval does not survive the escrow lifecycle
- **WHEN** an address approves a vault, then cancels its prepared stake (or prepares a fresh stake after the prior one was bound)
- **THEN** the approval SHALL be cleared, and a slot transfer against the new escrow SHALL revert with `BindingNotApproved` until a fresh approval is given

## REMOVED Requirements

### Requirement: Incoming-owner consent for owner-stake slot transfer
**Reason**: A scenario title carried an issue reference.
**Migration**: Restated unchanged as "The incoming owner consents to an owner-stake slot transfer".
