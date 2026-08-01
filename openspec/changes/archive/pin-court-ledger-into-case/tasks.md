# Tasks

- [x] 1. Interface: add `address ledger` to `ITokenCourt.Case` (adjacent to
  `game`, with the "written once in refer" comment); update natspec.
- [x] 2. `TokenCourt.refer`: hoist the single
  `IChallengeGameLedger(game).exposureLedger()` read into a local, store it in
  `c.ledger`, pass it to `_recordAccused`.
- [x] 3. `TokenCourt._recordAccused`: replace the `game` parameter with
  `address ledger`; delete the internal ledger lookup; body otherwise
  unchanged.
- [x] 4. Natspec: document the residual file→refer re-point window on
  `refer`/`_recordAccused` per the spec delta.
- [x] 5. Tests (failing-first where feasible): `test_ledgerPinnedAtRefer`,
  `test_repointAfterReferDoesNotDisturbCase`,
  `test_ledgerAndWeightPinnedTogether`. Reuse/extend existing TokenCourt test
  fixtures and mocks.
- [x] 6. Full gate: `forge build`, `forge test` (non-fork set), `forge fmt`
  (CI-matching forge), confirm no storage-layout golden files reference
  TokenCourt (it is non-upgradeable; no golden pin expected).
  Result: build clean; 1539 passed / 0 failed / 1 skipped across 105 suites;
  `forge fmt --check` clean. Goldens pin only SyndicateGovernor,
  SyndicateFactory, GuardianRegistry, StakedWood — TokenCourt absent, as
  expected.
- [x] 7. Commit on `fix/issue-69-pin-court-ledger`, push, open PR titled
  `fix(court): pin the exposure ledger into Case at refer (#69)` linking
  issue #69; PR body documents the residual window + follow-up decision.
  Opened as #78, STACKED ON #61 (`fix/pr56-review-findings`) rather than
  `main`: #61 rewrites `TokenCourt.sol` (floor lookback, `coverageFreezer`
  check on `setExposureLedger`) and #69 is its explicit follow-up. Retarget
  to `main` once #61 merges.
