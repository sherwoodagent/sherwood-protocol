# Gate the normal proposal lane on a live owner bond (SHE-215)

## Why

`StakedWood.claimUnstakeOwner` has documented since it was written that after a
claim "the vault then enters grace-period state and new proposals cannot be
created until the slot is re-funded". Nothing enforced it. `grep gracePeriod
src/` returned that comment and nothing else: no state, no timer, no gate.
`_propose` gated on the vault address, `isAgent`, and the open-proposal lock and
read no owner bond at all; `executeProposal` gated on `Approved`, the active
proposal and the cooldown and read no owner bond either. The only two enforcers
of an owner bond anywhere in `src/` were `GovernorEmergency` and
`SyndicateFactory.rotateOwner`.

`isAgent` is `_agents[a].active` and is independent of the owner's stake. So an
owner who is also a registered agent could request their unstake in a quiet gap
(`requestUnstakeOwner` refuses only while a proposal is open), sit out the
cooldown, claim the bond (`claimUnstakeOwner`'s re-check also refuses only while
a proposal is open), and then propose AND execute a capital-moving strategy on a
vault with nothing slashable behind it. The deterrent for the entire normal lane
was gone, with only the emergency path still asking for collateral. Audit High,
SHE-215.

## What Changes

- `StakedWood.ownerBondLive(vault)` — a new view, `owner != address(0) &&
  unstakeRequestedAt == 0`. It IS the grace-period state the natspec promised,
  made readable.
- `GuardianRegistry.ownerBondLive(vault)` — passthrough to sWOOD, the route
  `SyndicateGovernor` already uses for `ownerStake`.
- `SyndicateGovernor._propose` and `SyndicateGovernor.executeProposal` refuse
  with a new `OwnerBondNotLive` error when the predicate is false. The gate is
  asserted on BOTH legs, not only at admission.
- `StakedWood.cancelUnstakeOwner(vault)` — new, mirrors `cancelUnstakeGuardian`.
  Without it the propose gate would be a one-way door for the whole cooldown.
- Interfaces: `IStakedWood`, `IGuardianRegistry`, `ISyndicateGovernor`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-governor`: propose and execute both require a live owner bond.
- `guardian-staking`: the owner-stake slot gains a liveness predicate and a
  cancel for a pending owner-bond exit.
- `deployment-docs`: the upgrade ordering for the new typed call.

## Impact

- `src/StakedWood.sol` — `ownerBondLive`, `cancelUnstakeOwner`,
  `OwnerUnstakeCancelled`.
- `src/GuardianRegistry.sol` — `ownerBondLive` passthrough.
- `src/SyndicateGovernor.sol` — two gate call sites.
- `src/interfaces/{IStakedWood,IGuardianRegistry,ISyndicateGovernor}.sol`.
- Every registry stand-in in `test/` that the governor reads through:
  `MockRegistryMinimal` gains `ownerBondLive` (defaulting `true`, pinned both
  ways), `MockStakedWood` keeps it as a documented `pure` constant because
  `IStakedWood` declares it.
- Tests: `test/audit-fixes/Governor_she215OwnerBondGate.t.sol`,
  `test/audit-fixes/StakedWood_she215OwnerBondLive.t.sol`, and the fizz
  handlers, which must keep a producer for the live state after a slash.
- No migration. On 46630 the current factory and sWOOD have emitted zero
  `GovernorDeployed` / `OwnerStakeBound` since deployment, and 8453 is a
  pre-sWOOD generation the governor beacon cannot reach.
