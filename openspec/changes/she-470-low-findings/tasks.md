# Tasks

## 1. Vault and governor mirror (L-1, L-2, L-5)

- [x] 1.1 Buffer floor net of the queue reserve, skipped when `maxNetOutflow == 0`
- [x] 1.2 `CallValueNotAllowed(index)` in `_guardBatchCalls` and `_mirrorBatchLeg`
- [x] 1.3 `rotateOwnership` drains agents only on a change of owner
- [x] 1.4 Tests in `test/audit-she470/VaultBatchGuards.t.sol`, `RebondKeepsAgents.t.sol`; update the
      same-owner re-bond test that asserted the drain

## 2. Lifecycle (L-9)

- [x] 2.1 Paused branch of `_afterVote` expires past `executeBy`
- [x] 2.2 Test in `test/audit-she470/LifecyclePausedExpiry.t.sol`

## 3. Emergency block vote (L-8, L-7 natspec)

- [x] 3.1 `_governorReports` helper; `voteBlockEmergencySettle` requires `Executed`
- [x] 3.2 Correct `isEmergencyOpen` natspec
- [x] 3.3 Tests in `test/audit-she470/EmergencyVoteAfterSettle.t.sol`

## 4. Challenge re-arm (L-10)

- [x] 4.1 `file` seeds the baseline; `_rearmChallengeWindow` spends the latch only on extension
- [x] 4.2 Test in `test/challenge/ChallengeGame.t.sol`; existing asserts read the seeded baseline

## 5. Clone salt (L-3)

- [x] 5.1 Salt `keccak256(abi.encode(vault, msg.sender, salt))`; natspec
- [x] 5.2 Front-run test and predictor updates in `test/factory/StrategyFactory.t.sol`

## 6. Docs and specs

- [x] 6.1 Accepted-risk entries for L-4, L-6, L-7, L-11, L-12, L-13, L-14
- [x] 6.2 Natspec: performance-fee donation comment, `honestFilingBreaksEven`
- [x] 6.3 Spec deltas; `openspec validate she-470-low-findings` and `openspec validate --specs`
