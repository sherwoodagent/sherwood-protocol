# token-court delta — enforce the floor invariant in the setters (issue #84)

## MODIFIED Requirements

### Requirement: Owner surface

All configuration setters SHALL be `onlyOwner` under plain `Ownable2Step` (two-step transfer; non-upgradeable), bounded, and event-emitting:

- `setChallengeGame(newGame)`: rejects the zero address, and validates the cross-contract window invariant against the NEW game unconditionally (see the window-invariant requirement). Emits `ChallengeGameSet`.
- `setStakedWood(newStakedWood)`: rejects the zero address, and validates the cross-contract floor invariant against the NEW sWOOD unconditionally (see the floor-invariant requirement). Emits `StakedWoodSet`.
- `setVoteWindow(newWindow)`: requires `0 < newWindow <= MAX_VOTE_WINDOW` (14 days), and validates the window invariant against the live game when one is wired. Emits `VoteWindowSet`.
- `setParticipationFloorBps(newBps)`: requires `0 < newBps <= 10_000`, and validates the floor invariant against the live sWOOD when one is wired. Emits `ParticipationFloorBpsSet`.

Re-wiring and window changes SHALL govern future referrals only: a case already `Voting` or `Resolved` keeps its pinned `game`, `snapshotTs`, and `voteWindowAtReferral`, so no owner action redirects a live case's `finalize` to a different game or moves a live case's clock or electorate.

#### Scenario: Live case immune to re-wiring

- **WHEN** the owner calls `setChallengeGame` or `setVoteWindow` while a case is in `Voting`
- **THEN** that case keeps the `game` and `voteWindowAtReferral` pinned at its referral; only cases referred afterward see the new values

#### Scenario: Non-owner refused

- **WHEN** any address other than the owner calls a setter
- **THEN** the call reverts with the `Ownable` unauthorized error

#### Scenario: Bounded parameters

- **WHEN** `setVoteWindow` is called with 0 or a value above 14 days, or `setParticipationFloorBps` with 0 or a value above 10,000
- **THEN** the call reverts `InvalidParameter`

## ADDED Requirements

### Requirement: Cross-contract floor invariant

The court SHALL enforce `participationFloorBps < ageFloorBps` against the electorate contract's LIVE `ageFloorBps()` on both of its own setters that can break it: `setParticipationFloorBps` (when an electorate contract is wired; vacuous while unwired — there is no age floor to compare against yet) and `setStakedWood` (always, against the NEW electorate contract — closing the compose-bypass where a floor raised while unwired is then wired to an electorate whose age floor it meets or exceeds). Violations SHALL revert `FloorInvariantViolated`.

The comparison SHALL be strict. Turnout is summed in aged vote weight, whose per-account factor is bounded below by `ageFloorBps/10_000`, while the floor's base is raw stake — so a fully young electorate voting completely produces turnout no less than `ageFloorBps/10_000` of the base, and the raw-turnout fraction required to clear the floor is `participationFloorBps / ageFloorBps`. At equality that fraction is 100% — every un-accused staked wei must vote, at exactly age zero, for `turnout >= floor` to hold — which is participation the system cannot assume; above it the fraction exceeds 100% and the floor is arithmetically unclearable for an all-young electorate. Equality therefore violates the invariant, exactly as the deploy pre-flight (`floorBps < ageFloorBps`) already asserts.

The read SHALL fail closed: if the wired electorate contract does not expose `ageFloorBps()` (or the read reverts), the setter reverts rather than skipping the check — a floor change against an electorate whose age floor cannot be read is refused, matching how `setVoteWindow` bubbles a revert from the wired game's clock reads.

The court SHALL NOT impose the reciprocal guard on the electorate contract: `StakedWood.setAgeFloorBps` remains free to lower `ageFloorBps` to or below the court's live floor. The dependency direction is deliberate — the court reads the staking layer, the staking layer does not know the court — so the invariant's other side is an accepted, monitored residual (see the deploy pre-flight requirement in `deployment-docs` and the off-chain monitoring commitment of issue #84 option 3).

#### Scenario: Floor raised to meet or exceed the wired age floor

- **WHEN** the owner calls `setParticipationFloorBps` with a value greater than or equal to the wired sWOOD's live `ageFloorBps()`
- **THEN** the call reverts `FloorInvariantViolated`

#### Scenario: Floor strictly below the age floor accepted

- **WHEN** the owner calls `setParticipationFloorBps` with a value in `(0, 10_000]` strictly below the wired sWOOD's live `ageFloorBps()`
- **THEN** the call succeeds, emits `ParticipationFloorBpsSet`, and the new floor is live for the next `finalize`

#### Scenario: Vacuous while no electorate is wired

- **WHEN** the owner calls `setParticipationFloorBps` on a court whose `stakedWood` is the zero address
- **THEN** only the `(0, 10_000]` bound applies and the call succeeds — there is no age floor to compare against yet; the invariant is instead checked when `setStakedWood` later wires one

#### Scenario: Wiring an electorate the current floor cannot clear

- **WHEN** the owner calls `setStakedWood` with a sWOOD whose `ageFloorBps()` is less than or equal to the court's current `participationFloorBps`
- **THEN** the call reverts `FloorInvariantViolated` — the invariant is checked on every wiring call, with no vacuous branch

#### Scenario: Electorate that cannot report an age floor refused

- **WHEN** the owner calls `setStakedWood` with a non-zero address that does not implement `ageFloorBps()`
- **THEN** the call reverts — the guard fails closed rather than wiring an electorate whose age floor cannot be read

#### Scenario: Age floor lowered on the staking side is NOT guarded here

- **WHEN** the sWOOD owner calls `StakedWood.setAgeFloorBps` with a value at or below the court's live `participationFloorBps`
- **THEN** the call succeeds on sWOOD and the invariant is broken until monitoring or governance restores it — the court's guard covers only the court's own two levers; this residual is accepted and monitored off-chain
