# guardian-staking (delta)

## ADDED Requirements

### Requirement: Owner-bond liveness predicate
`StakedWood` SHALL expose `ownerBondLive(address vault)` returning true iff the vault's owner-stake slot is bound and not exiting — `owner != address(0) && unstakeRequestedAt == 0`. The first clause SHALL test slot EXISTENCE and NOT `stakedAmount != 0`, because the documented `minOwnerStake == 0` open-onboarding sentinel binds a slot with a real owner and a zero amount; both routes that empty a funded slot (`claimUnstakeOwner`, `slashOwnerBond`) `delete` the record and so zero the owner as well. The predicate SHALL NOT compare against `requiredOwnerBond`: that threshold is governance-mutable and there is no top-up path on a live vault, so a raised floor would permanently brick every vault correctly bonded under the old one. `GuardianRegistry` SHALL expose the same view as a passthrough, since consumers hold a registry handle rather than an sWOOD one.

#### Scenario: A freshly bound slot is live
- **WHEN** the factory binds a prepared owner stake to a vault
- **THEN** `ownerBondLive(vault)` SHALL return true

#### Scenario: An exit in flight is not a live bond
- **WHEN** the owner calls `requestUnstakeOwner` and the cooldown has not yet elapsed
- **THEN** `ownerBondLive(vault)` SHALL return false, even though the WOOD is still escrowed and `ownerStake(vault)` is unchanged

#### Scenario: An emptied slot is not a live bond
- **WHEN** the slot is emptied by `claimUnstakeOwner` or by `slashOwnerBond`
- **THEN** `ownerBondLive(vault)` SHALL return false, because both delete the record

#### Scenario: A zero-bond onboarding vault stays live
- **GIVEN** `minOwnerStake == 0` and the factory bound a slot with a real owner and a zero amount
- **THEN** `ownerBondLive(vault)` SHALL return true, so the vault that was never asked for a bond keeps its proposal lane

#### Scenario: The registry passthrough is not its own opinion
- **WHEN** the sWOOD predicate changes for a vault
- **THEN** `GuardianRegistry.ownerBondLive(vault)` SHALL report the same value across that change

### Requirement: Owner unstake cancel
`StakedWood` SHALL expose `cancelUnstakeOwner(address vault)`, callable only by the recorded owner of a slot with a non-zero `stakedAmount` and a pending request, clearing `unstakeRequestedAt` and `cooldownAtRequest` and emitting `OwnerUnstakeCancelled`. Without it, one exploratory `requestUnstakeOwner` would shut a live vault's proposal lane for the whole cooldown with no way back short of claiming the bond and running a two-transaction `rotateOwner` -> `transferOwnerStakeSlot`. Clearing `cooldownAtRequest` alongside the stamp SHALL mean a later re-request buys the full wait again rather than inheriting time already served. A slot already emptied by `slashOwnerBond` SHALL NOT be recoverable through this path.

#### Scenario: Cancel restores the live bond
- **WHEN** the recorded owner cancels a pending owner-bond unstake request
- **THEN** `ownerBondLive(vault)` SHALL return true again and the escrowed WOOD SHALL be unchanged

#### Scenario: Cancel then re-request restarts the cooldown
- **WHEN** an owner cancels a request one second short of the cooldown and immediately re-requests
- **THEN** `claimUnstakeOwner` SHALL revert with `CooldownNotElapsed` until a FULL fresh cooldown has elapsed

#### Scenario: Only the recorded owner, only against a real request
- **WHEN** a stranger calls `cancelUnstakeOwner`, or the recorded owner calls it with no request pending
- **THEN** the call SHALL revert with `NoActiveStake` or `UnstakeNotRequested` respectively

#### Scenario: A slashed slot cannot be cancelled back to life
- **GIVEN** the bond was slashed after the unstake request was made
- **WHEN** the former owner calls `cancelUnstakeOwner`
- **THEN** the call SHALL revert with `NoActiveStake`, because `slashOwnerBond` deleted the record
