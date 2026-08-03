# Enforce `participationFloorBps < ageFloorBps` in TokenCourt's setters

## Why

Issue #84: the project's own asserted launch-math invariant `participationFloorBps < ageFloorBps` (spec §5, PRE-FLIGHT 4 of `WireTokenCourt`) is enforced **only** in a deploy script. On-chain, `TokenCourt.setParticipationFloorBps` accepts any value in `(0, 10_000]` (`src/TokenCourt.sol:204-208`), so after wiring, the court's owner can move the floor to or above `StakedWood.ageFloorBps` in one legal-looking transaction. Against a young electorate (all stake inside `maturationPeriod`), turnout is summed in AGED weight while the floor's base is RAW stake, so a floor at or above the age floor becomes unclearable and every case lands `Inconclusive` — silent, permanent liveness damage to the court's only decision path. The severity is narrower than the issue's headline: mature stake votes at par regardless of `ageFloorBps`, so this is a launch-window / young-electorate hazard — but it is the protocol's own invariant going unenforced where it can be enforced.

The repo owner approved the issue's recommended **option 1 + 3**: enforce the invariant on-chain in the court's setter, keep off-chain monitoring for the side the court cannot guard. That decision is settled; this change implements it.

## What Changes

- `TokenCourt.setParticipationFloorBps` additionally requires `newBps < IStakedWood(stakedWood).ageFloorBps()` whenever `stakedWood` is wired (non-zero), reverting a new `FloorInvariantViolated` error otherwise. Vacuous while unwired — mirroring `setVoteWindow`'s live cross-contract check (`src/TokenCourt.sol:190-201`).
- `TokenCourt.setStakedWood` additionally validates the same invariant against the NEW sWOOD's `ageFloorBps()` unconditionally — closing the compose-bypass the codebase itself documents for the window invariant (`src/TokenCourt.sol:139-149`): a floor raised while unwired must not then be wired to an electorate whose age floor it meets or exceeds.
- A minimal local `IStakedWoodAgeFloor`-style read (one view function) since `IStakedWood` deliberately does not declare `ageFloorBps` — same pattern as the file's existing `IChallengeGameLedger` (`src/TokenCourt.sol:14-16`) and the deploy script's own local interface (`script/DeployTokenCourt.s.sol:23-25`).
- `StakedWood.setAgeFloorBps` is **deliberately untouched**: sWOOD is the base-layer custodian consumed by registry, governor, factory, and court; it holds no pointer to TokenCourt and gaining one would invert the dependency direction. Lowering `ageFloorBps` to or below the court's floor remains possible and is covered by off-chain monitoring (option 3) plus the wire-time pre-flight.
- `WireTokenCourt` PRE-FLIGHT 4 is **kept** (see design.md): it still catches states the setters cannot, foremost a `setAgeFloorBps` lowering between deploy and wire. Its comment gains a correction note in the style of PRE-FLIGHT 3's.
- Tests: guard rejects an invalid floor (wired), accepts a valid one, vacuous branch while unwired, setStakedWood-side rejection, and the deploy-path regression. `MockStakedWood` gains a settable `ageFloorBps` slot; two existing tests that relied on the unguarded behaviour are updated.

**BREAKING** (behavioral, no ABI break): `setParticipationFloorBps(x)` with `x >= ageFloorBps` and `setStakedWood(sw)` with `sw.ageFloorBps() <= participationFloorBps` now revert; `setStakedWood` now performs a view read on its target, so a target without `ageFloorBps()` (e.g. an EOA) is refused — previously any non-zero address was accepted.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `token-court`: the **Owner surface** requirement's `setParticipationFloorBps` and `setStakedWood` bullets gain the floor-invariant validation, and a new **Cross-contract floor invariant** requirement is added, mirroring the existing **Cross-contract window invariant** requirement's two-setter shape (vacuous-while-unwired on the parameter setter; unconditional on the wiring setter).

## Impact

- `src/TokenCourt.sol` — the two setters + one local interface + natspec.
- `src/interfaces/ITokenCourt.sol` — new `FloorInvariantViolated` error (naming mirrors `WindowInvariantViolated`), natspec on `setParticipationFloorBps`/`setStakedWood`.
- `script/DeployTokenCourt.s.sol` — PRE-FLIGHT 4 comment update only (check kept).
- `test/mocks/MockStakedWood.sol` — settable `ageFloorBps` slot (precedent: the mock's `authorizedSlasher` slot, added for the same reason when `ChallengeGame.setStakedWood` grew its read-back).
- `test/TokenCourt.t.sol` — new guard tests; two existing tests updated (`file:line` inventory in design.md).
- `test/deploy/DeployTokenCourtPreflight.t.sol` — PRE-FLIGHT 4 test re-targeted to break the invariant from the sWOOD side (the side the setters cannot guard), which is exactly what the pre-flight still covers.
- No change to `StakedWood.sol`, no change to `finalize`/`_participationFloor` (the sibling #96 fix touches `src/TokenCourt.sol:738` and natspec at 569-586/360-365 — this change stays clear of all three regions).
- Open PRs: #104 (`feat/lane-a-enablement`) has zero file overlap; #88 (`spec/wood-twap-ceiling`) touches `test/TokenCourtEndToEnd.t.sol`, which this change does not modify.
