# Tasks: fix-bond-reclaim-deadline

## 1. Governor gate

- [x] 1.1 In `src/SyndicateGovernor.sol` `reclaimProposerBond` (currently :573), inside the existing `executedAt != 0` block and after the freeze check (:601), add gate 3 per design D2-D5: resolve `address freezer = IExposureLedger(ledger).coverageFreezer();` and, when `freezer != address(0)`, revert `ChallengeWindowOpen` unless `block.timestamp > max(executedAt + IChallengeGame(freezer).challengeWindow(), IChallengeGame(freezer).challengeableUntil(keccak256(abi.encode(address(this), proposalId))))`. Strict `>`, matching `file`'s `<=` admissibility (ChallengeGame.sol:605). Add the `IChallengeGame` import.
- [x] 1.2 Replace the "Known gap" natspec paragraph (:564-567) with the gate's rationale per design D6 (adversary: proposer racing an `Inconclusive` re-arm; cross-reference `ChallengeGame._refundAll` and `file`'s deadline max; document the zero-freezer skip and why it cannot strand bonds).

## 2. Reproduction and regression tests

- [x] 2.1 Reproduction of the issue #94 timeline (extend `test/ChallengeEndToEnd.t.sol`, which already drives execute → file → dispute → refer → Inconclusive): execute at T0; file at T0+13d; complete pool and refer by T0+19d; miss the participation floor so `rule` lands `Inconclusive` at ~T0+24d (freeze released, `challengeableUntil` re-armed to ruling+14d). Assert `reclaimProposerBond` now reverts `ChallengeWindowOpen` at every probe inside (ruling, challengeableUntil] — before the fix it succeeded there. Use `vm.getBlockTimestamp()`, never a cached `block.timestamp` local across `vm.warp` (repo guardrail), and forward-only warps.
- [x] 2.2 Reclaim-then-convict closure: in the same fixture, file an honest challenge inside the re-armed window (e.g. ruling+6d), drive it to conviction (silence path), and assert `forfeitBond` SUCCEEDS — `ProposerBondForfeited` emitted with the prosecutor fee paid to the challenger and the remainder burned, and NOT `ProposerBondForfeitureFailed`. Then assert the proposer's reclaim reverts (`NoBondToReclaim` after forfeiture).
- [x] 2.3 Boundary test: warp to exactly `challengeableUntil` — reclaim reverts, `file` still accepts; warp +1s — reclaim succeeds, `file` reverts `WindowClosed`. Two fixtures at the same timestamps if backward warps would otherwise be needed (forge 1.7.1 guardrail).
- [x] 2.4 Regression — unchallenged proposal reclaims on schedule: executed proposal, no filing ever, warp to `executedAt + challengeWindow`; assert reclaim succeeds exactly as before the change (extend `test/GovernorCoverageGates.t.sol` where the existing reclaim-timing tests live). Also assert the pre-window revert still fires.
- [x] 2.5 Regression — unset freezer skips gate 3: fixture with a wired `ExposureLedger` whose `coverageFreezer` is zero (or rotated to zero after draining freezes); executed proposal past the ledger window reclaims successfully. Companion negative: freezer set to an address that reverts on `challengeableUntil` → reclaim reverts (fail closed).
- [x] 2.6 Divergence test for design D2: lower the ledger's `challengeWindow` below the game's (ledger owner `setChallengeWindow`, respecting its floor) after execution; assert reclaim still waits for `executedAt + game.challengeWindow` even with `challengeableUntil` zero.

## 3. Suite sweep and verification

- [x] 3.1 Run the full suite (`forge test`, foreground, serialized against other solc runs per the 16 GB guardrail) and triage with `sort | uniq -c` (never `sort -u`). Any suite whose reclaim path now hits the new gate should be inspected for whether it was silently relying on the bug.
- [x] 3.2 Confirm no mock ledger used in reclaim paths lacks `coverageFreezer()` (all three covering suites — `GovernorCoverageGates`, `ChallengeEndToEnd`, `CoverageEndToEnd` — wire the real `ExposureLedger`, so this is expected to be a no-op; fix any straggler by returning `address(0)`).
- [x] 3.3 `forge fmt` with a CI-matching forge; `forge build` size check is moot for Robinhood (98,304-byte ceiling) but record the governor's new size in the PR description.
- [x] 3.4 `openspec validate fix-bond-reclaim-deadline` passes; update the `challenge-game` main spec via archive flow at merge time, not by hand now.
