# Tasks

- [ ] 1. Recon: read `test/ExposureLedger.t.sol` (esp.
  `_wireUnderCoveredEpochZeroApprovers` and every multi-approver fixture);
  read `requireApproveQuorum` + `recordApproval` early exits in
  `src/ExposureLedger.sol`.
- [ ] 2. Write the hazard comment block per the spec delta.
- [ ] 3. Build the shared helper (+ count assertion) modeled on
  `_wireUnderCoveredEpochZeroApprovers`.
- [ ] 4. Migrate qualifying fixtures; tag deliberate early-exit fixtures with
  `// EARLY-EXIT INTENDED:`; do not weaken any assertion.
- [ ] 5. Gate: `forge test --match-path test/ExposureLedger.t.sol` green;
  full non-fork suite green; `forge fmt --check src test script`.
- [ ] 6. Commit on `test/fixture-hazard-docs`, push, open PR
  `test: name the ExposureLedger early-exit fixture hazards + shared helper (#71)`
  — body "Closes #71". Do NOT merge.
