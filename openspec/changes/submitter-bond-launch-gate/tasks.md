# Tasks

- [ ] 1. `src/TierRegistry.sol`: add a `@dev` natspec block above
  `submitterBondWood`'s declaration stating the three-part gate (guard-bypass
  slash exists and can reach `_bonds`; a disputed slash is enforceable via a
  seated court, per #25; third-party submission volume exists) and that
  enabling a non-zero value before all three hold buys an unenforceable
  warranty.
- [ ] 2. `script/Deploy.s.sol`: after `TierRegistry` deployment, add
  `require(TierRegistry(d.tierRegistry).submitterBondWood() == 0, "submitter bond must stay 0 at launch - see issue #40");`
  (or equivalent `assert`) — pins that the script never enables it.
- [ ] 3. New pinning test (e.g. `test/TierRegistry.t.sol` or a small new file)
  asserting `certify` with `submitterBondWood == 0` locks nothing (`_bonds`
  entry stays empty / `totalBondedWood` unchanged) and emits no
  `SubmitterBondLocked`.
- [ ] 4. `forge build`, `forge test --match-path` the touched/new test files,
  full non-fork suite, `forge fmt --check src/ test/ script/`, `openspec
  validate submitter-bond-launch-gate --strict`.
- [ ] 5. Commit, push, PR against `main`, reference issue #40.
