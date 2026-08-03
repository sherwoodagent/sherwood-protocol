## ADDED Requirements

### Requirement: Incoming-owner consent for owner-stake slot transfer
Binding a prepared owner stake to a vault through the slot-transfer path (the factory's owner-rotation flow) SHALL require the incoming owner's prior, vault-specific consent, recorded on sWOOD by the incoming owner themselves. Adversary: a current vault owner who "gifts" a vault to a victim to spend the victim's escrowed prepared stake — locking it behind the owner-unstake cooldown and exposing it to an emergency-review owner-bond slash — must be unable to do so without the victim's opt-in.

`approveOwnerStakeBinding(vault)` SHALL record `vault` as the single vault the caller consents to have their prepared stake bound to via slot transfer; it SHALL reject the zero vault. Calling it again SHALL overwrite the previous approval (at most one approved vault per address). `revokeOwnerStakeBinding()` SHALL clear the caller's approval. Both SHALL emit events naming the approver and the vault.

`transferOwnerStakeSlot(vault, newOwner)` SHALL revert with `BindingNotApproved` unless `newOwner`'s recorded approval equals exactly `vault`, in addition to its existing guards (factory-only caller, prior slot cleared, prepared stake present, unbound, and at or above the floor). A successful transfer SHALL consume the approval (clear it), so one consent authorizes at most one bind.

Consent SHALL be scoped to a single escrow lifetime and never replayable against a later one: the approval SHALL also be cleared by `cancelPreparedStake` and by a fresh `prepareOwnerStake`. An approval standing without a live prepared stake SHALL be inert — the transfer's existing prepared-stake guards still reject the bind.

The creation-time bind (`bindOwnerStake`, reached only from the factory's `createSyndicate`) SHALL NOT require an approval: the bound stake there belongs to the creator who initiated the call, so consent is structural.

#### Scenario: Non-consensual rotation cannot spend a third party's escrow (issue #98 trace)
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
