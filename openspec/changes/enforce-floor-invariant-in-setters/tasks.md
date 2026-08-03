# Tasks — enforce-floor-invariant-in-setters

Build discipline (this machine): serialize solc — `while pgrep -x solc >/dev/null; do sleep 30; done` before every forge command; run forge in the FOREGROUND; never judge a build by a piped exit code. Format with a forge matching CI.

## 1. Contract changes

- [ ] 1.1 `src/interfaces/ITokenCourt.sol`: add `error FloorInvariantViolated();` beside `WindowInvariantViolated` (~line 179) with natspec naming the invariant `participationFloorBps < ageFloorBps` and both setters that enforce it; extend `setParticipationFloorBps`/`setStakedWood` natspec accordingly.
- [ ] 1.2 `src/TokenCourt.sol`: add the file-local `IStakedWoodAgeFloor { function ageFloorBps() external view returns (uint256); }` interface beside `IChallengeGameLedger` (design D1), with a comment mirroring the deploy script's rationale (`script/DeployTokenCourt.s.sol:19-22`).
- [ ] 1.3 `src/TokenCourt.sol` `setParticipationFloorBps` (204-208): after the existing `(0, 10_000]` bound, cache `address sw = stakedWood;` and when `sw != address(0)` revert `FloorInvariantViolated` if `newBps >= IStakedWoodAgeFloor(sw).ageFloorBps()` (design D2/D3). Natspec: mirror `setVoteWindow`'s vacuous-branch note; state the young-electorate rationale, the strict `<`, and that the sWOOD-side lever (`setAgeFloorBps` lowering) is deliberately NOT guarded here (design D5).
- [ ] 1.4 `src/TokenCourt.sol` `setStakedWood` (177-181): after the zero check, revert `FloorInvariantViolated` if `participationFloorBps >= IStakedWoodAgeFloor(newStakedWood).ageFloorBps()` — unconditional, every call validates (design D4). Natspec: name the compose-bypass this closes, referencing `setChallengeGame`'s precedent.
- [ ] 1.5 Confirm no edits touch `src/TokenCourt.sol:738`, 569-586, or 360-365 (sibling #96 regions) — `git diff` inspection.

## 2. Script comment

- [ ] 2.1 `script/DeployTokenCourt.s.sol` PRE-FLIGHT 4 comment (149-160): add a CORRECTED-style note (mirroring PRE-FLIGHT 3's at 120-137) that `TokenCourt.setParticipationFloorBps` / `setStakedWood` now enforce the invariant on-chain, and that this pre-flight still uniquely covers (a) a `StakedWood.setAgeFloorBps` lowering after deploy and (b) the pair's live values at first wiring (design D6). Check itself unchanged.

## 3. Test fixtures

- [ ] 3.1 `test/mocks/MockStakedWood.sol`: add `uint256 public ageFloorBps = 2_500;` with a `setAgeFloorBps(uint256)` setter, modeled as a plain settable slot with a natspec note in the style of the mock's `authorizedSlasher` (231-243) explaining that `TokenCourt`'s setters now read it back and a missing member would revert every wire/floor call in suites using this mock. Default 2_500 matches every real fixture (`StakedWood` InitParams in `TokenCourtEndToEnd.t.sol:178`, `SlashGasCeiling.t.sol:208`, `ChallengeEndToEnd.t.sol:202`, `DeployTokenCourtPreflight.t.sol:70`). NOTE: `ageFloorBps` is NOT an `IStakedWood` member — it sits with the mock's extra setters, not the interface surface.

## 4. New guard tests (`test/TokenCourt.t.sol`)

- [ ] 4.1 Guard rejects: wired court (setUp's mock, ageFloor 2_500) — `setParticipationFloorBps(2_500)` reverts `FloorInvariantViolated` (equality) and `setParticipationFloorBps(2_501)` reverts too (above).
- [ ] 4.2 Guard accepts: `setParticipationFloorBps(2_499)` succeeds, emits `ParticipationFloorBpsSet(1_000, 2_499)`, and `participationFloorBps()` reads back 2_499.
- [ ] 4.3 Vacuous branch: fresh `TokenCourt` with `stakedWood == address(0)` accepts `setParticipationFloorBps(9_999)` (only the `(0, 10_000]` bound applies); then `setStakedWood(mock with ageFloorBps 2_500)` reverts `FloorInvariantViolated` — proving the compose-bypass is closed at the wiring end (design D4).
- [ ] 4.4 `setStakedWood` rejects a sWOOD whose `ageFloorBps` equals the current floor (mock with `setAgeFloorBps(1_000)` vs default floor 1_000) and accepts one strictly above.
- [ ] 4.5 Behavioural end-to-end sanity: after lowering the mock's `ageFloorBps` (sWOOD-side lever, LEGAL — documents design D5's residual), `setParticipationFloorBps` at/above the new age floor now reverts, while the already-set floor keeps operating (no retroactive wedge).

## 5. Existing tests that pinned the unguarded behaviour

- [ ] 5.1 `test/TokenCourt.t.sol:263-272` (emit test): replace `makeAddr("newSwood")` with `address(new MockStakedWood())` (hoisted before `vm.prank` — argument-position call eats a one-shot prank) so the guarded `setStakedWood` and the following `setParticipationFloorBps(2_000)` both pass.
- [ ] 5.2 `test/deploy/DeployTokenCourtPreflight.t.sol:235-246`: re-target `test_wirePreflight_bites_whenParticipationFloorMeetsAgeFloor` to reach the violating state via `vm.prank(DEFAULT_SENDER); swood.setAgeFloorBps(1_000);` (floor 1_000 >= new age floor 1_000 — legal on sWOOD's own setter; the court's route now reverts), keeping the same `_runWireExpecting("PRE-FLIGHT: TokenCourt.participationFloorBps >= StakedWood.ageFloorBps.")` assertion. Update the test natspec: the pre-flight now covers the sWOOD-side lever the setters cannot.
- [ ] 5.3 Same file: add a companion test that the OLD route is dead — `court.setParticipationFloorBps(AGE_FLOOR_BPS)` (via `DEFAULT_SENDER`, the court's owner pre-handoff) reverts `FloorInvariantViolated`.

## 6. Deploy-path regression

- [ ] 6.1 Confirm `test/deploy/DeployTokenCourtPreflight.t.sol::test_deploy_configuresCourtButLeavesItInert` and `test_wire_defaultsWireSuccessfully` still pass unmodified — they drive the REAL `DeployTokenCourt` (which calls the now-guarded `setStakedWood` at `script/DeployTokenCourt.s.sol:74` against a real sWOOD with ageFloor 2_500 > default floor 1_000) and the REAL `WireTokenCourt`. These two passing IS the required "deploy path still works" regression; do not weaken them to make them pass.

## 7. Verification

- [ ] 7.1 Full suite: `forge test` (foreground, solc-serialized). Triage failures with `grep '\[FAIL' | sort | uniq -c` — never `sort -u`.
- [ ] 7.2 `forge fmt --check` with a CI-matching forge (CI checks `src/`, `test/`, `script/`).
- [ ] 7.3 Re-diff against origin/main to confirm blast radius matches the design's Impact list exactly (2 src files, 1 script comment, 1 mock, 2 test files, openspec/).
