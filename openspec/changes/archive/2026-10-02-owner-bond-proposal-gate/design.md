## Context

See proposal.md — Why. The constraints that shape the approach:

- `minOwnerStake == 0` is a documented open-onboarding sentinel. Under it,
  `bindOwnerStake` binds a slot with a real owner and a ZERO amount — a vault
  that never posted a bond and was never asked to.
- Both routes that empty a funded slot — `claimUnstakeOwner` and
  `slashOwnerBond` — `delete` the record rather than zeroing a field.
- `requiredOwnerBond` is governance-mutable (`setMinOwnerStake`) and there is no
  top-up path on a live vault: `bindOwnerStake` is reachable only from
  `createSyndicate`, once per vault at birth.
- `SyndicateGovernor` holds an `IGuardianRegistry` handle, not an sWOOD one.
  `GovernorEmergency` already reads `ownerStake` through it.
- `SyndicateGovernor` is layout-pinned; the gate must add no storage.

## Goals / Non-Goals

**Goals:**
- The grace period `claimUnstakeOwner` documents becomes a state the governor
  can read, on the normal lane and not only the emergency one.
- The gate fails closed for every way a slot can stop being collateral, and
  stays permissive for the one state that was never meant to be collateral.
- The gate is reversible, so an exploratory exit request does not strand a live
  vault's agents.

**Non-Goals:**
- Changing owner-bond sizing, the cooldown, or the slash paths.
- Adding a top-up path for a live vault's owner slot.
- Gating `approveCollaboration` or the vote itself (see Risks).

## Decisions

### D1 — The predicate is `owner != address(0) && unstakeRequestedAt == 0`

Two clauses, both load-bearing.

`s.owner != address(0)` is the SLOT-EXISTS test, and it is deliberately not
`stakedAmount != 0`. Under the `minOwnerStake == 0` sentinel a bound slot
legitimately holds a zero amount; keying on the amount would brick the proposal
lane of every open-onboarding vault at birth, which is not the state this
change closes. Because both emptying routes `delete` the record, they zero the
owner too and are caught by the existence test anyway. The route back to a
funded slot is `rotateOwner` -> `transferOwnerStakeSlot`, exactly as
`claimUnstakeOwner`'s natspec describes.

`s.unstakeRequestedAt == 0` closes the lane one step EARLIER than the claim. A
bond inside its exit cooldown is already committed to leaving and is not
collateral behind anything. The whole reason `claimUnstakeOwner` re-checks
`openProposalCount()` is that a gate which fires once can be walked around by
changing the state it measured; reading the request stamp here means there is no
window in which a proposal can be opened against collateral whose exit is
already in flight.

*Alternative rejected:* `ownerStake(vault) >= requiredOwnerBond(vault)`. Refused
for the same reason `GovernorEmergency.finalizeEmergencySettle` refuses that
comparison: the threshold is governance-mutable and there is no top-up path on a
live vault, so a raised `minOwnerStake` would permanently brick the proposal
lane of every vault correctly bonded under the old floor. Existence is the
property with no legitimate reading that turns a live vault off.

### D2 — Reversibility: `cancelUnstakeOwner`

Once `requestUnstakeOwner` closes the proposal lane, an owner who changes their
mind had no way back except claiming the bond — which leaves the lane shut — and
then a two-transaction `rotateOwner` -> `transferOwnerStakeSlot`. Without a
cancel, one exploratory request would strand a live vault's agents for the whole
cooldown. `cancelUnstakeOwner` mirrors `cancelUnstakeGuardian`: it clears
`unstakeRequestedAt` and `cooldownAtRequest`, so a later re-request buys the
full wait again rather than inheriting time already served.

*Consequence, deliberate:* a SLASHED slot cannot be cancelled back to life. If
the bond was slashed between the request and the cancel, `slashOwnerBond` has
deleted the record entirely, so `s.owner` is zero and `NoActiveStake` fires on
the first check — the same "nothing to restore" reasoning `cancelUnstakeGuardian`
spells out, reached one field earlier because the owner path deletes rather than
zeroes. A slashed vault's route back is `rotateOwner` ->
`transferOwnerStakeSlot`, not a cancel.

### D3 — The gate is re-asserted at execute, not only at propose

`propose` refuses an unbonded vault, but the bond that matters is the one live
WHEN CAPITAL MOVES, and the vote plus the review period sit between the two
points.

The reachable route between them is `slashOwnerBond`: the registry can empty an
owner-stake slot at any time, including while a proposal it never saw is
mid-flight, and it carries no open-proposal gate. The owner's OWN exit is not
that route — `requestUnstakeOwner` refuses while `openProposalCount() != 0`
(Draft onward) or a proposal is active, and once a request is in, `propose`
refuses too — so an owner cannot walk a proposal up to this gate. Checking at
the point of use closes the class rather than the instance, exactly as
`GovernorEmergency.finalizeEmergencySettle` re-asserts its own bond gate.

It is the dual of `claimUnstakeOwner`'s claim-time `openProposalCount()`
re-check: that one stops the bond leaving while a proposal is open, this one
stops a proposal executing once the bond is gone.

### D4 — Read through the registry handle

The governor holds an `IGuardianRegistry`, so the gate reads
`GuardianRegistry.ownerBondLive`, a passthrough to sWOOD — the same route
`GovernorEmergency` uses for `ownerStake`. No new handle, no new storage on a
layout-pinned contract.

*Consequence for deployment ordering:* the typed call means the upgrade order is
**sWOOD → GuardianRegistry → governor beacon**. Upgrading the beacon first makes
every `propose` and `executeProposal` revert bare, because the governor would
call a selector the live registry does not implement. Recorded as a ceremony
note on SHE-36.

## Risks / Trade-offs

- [A slashed vault consumes a vote and a review before execute refuses] →
  `approveCollaboration` and the vote path do not re-read the gate, so work can
  be spent on a proposal that will not execute. No capital risk: the refusal
  happens before any batch runs, and the proposal stays `Approved` and becomes
  executable again if the slot is re-funded inside the execution window.
- [The fizz harness can remove the propose→settle lifecycle from its own
  explored surface] → once a run lands `slashOwnerBond`, `ownerBondLive` has no
  producer unless a handler can restore the slot. The harness therefore needs a
  top-level restore handler (cancel an exiting request, or re-prepare and
  factory-bind a fresh stake), not only the slash selector.
- [A gate on the normal lane is a new way to brick a live vault] → mitigated by
  D1 (no governance-mutable threshold in the predicate) and D2 (the exit is
  reversible while it is in flight).
