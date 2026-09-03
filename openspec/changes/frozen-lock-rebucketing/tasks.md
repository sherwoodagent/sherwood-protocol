## 1. Reproduce first

- [x] 1.1 Write the SHE-213 reproduction against the lock model: guardian locks on A, A is frozen, warp past A's original bucket expiry, guardian approves B — assert (pre-fix) that B's lock overlaps A's. This is the red test; it must fail before §2 and pass after. (`test_freezeCoverage_frozenLockCannotBeRelockedAfterItsBucketAgesOut`; red confirmed: `openExposure` read 0 while frozen.)
- [x] 1.2 Add the pin variant: lock on A, pin to `until` beyond bucket expiry, warp past the original expiry, approve B — assert the same overlap pre-fix. (`test_pinCoverageUntil_pinnedLockCannotBeRelockedAfterItsBucketAgesOut`; red confirmed.)

## 2. The re-bucket primitive

- [x] 2.1 Add `_rebucket(bytes32 key, address guardian, uint256 targetEpoch)`: no-op on equal epochs; subtract the lock from `_buckets[g][current]`, add to `_buckets[g][target]`, write `RecordedExposure.epoch = target`. Clamp `targetEpoch` to `(now + MAX_COVERAGE_HORIZON) / epochLength` before moving (design D5); state the adversary in natspec. (Struct is `LockRecord`; clamp lives in `_horizonClampedEpochOf`, applied by every caller; raise-only wrapper `_rebucketNoEarlier` for freeze and pin.)
- [x] 2.2 Make `_unwindApproval` (used by release and retire) subtract from `RecordedExposure.epoch` as currently recorded — verify it does not recompute the booking-time epoch anywhere (design D6). Pin with the "retire after a move" scenario test. (`test_rebucketing_composesAcrossFreezeUnfreezePinAndRetire`; `bookedEpoch` added to the record as the unfreeze floor — see design.md Implementation notes.)

## 3. Call sites

- [x] 3.1 `freezeCoverage`: inside the existing approver loop, `_rebucket` each live lock to the epoch containing `filedAt + disputeTimeoutAtFiling`. Decide the source of that value (parameter from the freezer vs. read-back through the narrow freezer interface) and document why; keep idempotence — a second freeze must not move locks again. (PARAMETER route: `freezeCoverage(governor, proposalId, liveUntil)`; `ChallengeGame.file` passes `block.timestamp + disputeTimeout` on EVERY filing, and the ledger re-buckets raise-only on every call while the flag/counters flip once — review round 1 M-1. No ledger-to-freezer call.)
- [x] 3.2 `unfreezeCoverage`: inside the existing loop, `_rebucket` each lock to the epoch containing `block.timestamp` (design D3). (REFINED TWICE: target is `max(bookedEpoch, epochOf(standing pin))`. D3 as written would expire a lock before settlement when a challenge resolves early; the `currentEpoch()` floor first added was redundant for safety and over-held capacity/exit after acquittal — review round 1 M-2. See design.md Implementation notes.)
- [x] 3.3 `pinCoverageUntil`: after raising the pin deadline, `_rebucket` to the epoch containing `until` only when later than the current epoch (design D4, monotonic).
- [x] 3.4 Update `IExposureLedger` natspec for all three; the freezer-facing interface gains the timeout parameter only if 3.1 chose the parameter route. (Signature changed; `ExposureRebucketed` event added; three test-side ledger stand-ins patched in the same commit.)

## 4. Tests

- [x] 4.1 The two reproductions from §1 now pass (B's lock is clamped to genuinely free budget).
- [x] 4.2 Freeze moves the lock and leaves `openExposure` unchanged at the instant of the move. (`test_freezeCoverage_movesTheLockWithoutChangingOpenExposureAtTheInstant`, plus `_repeatRaisesTheTargetAndNeverLowersIt`, `_neverMovesTheLockEarlier`; game level: `ChallengeEndToEnd.test_secondFiling_keepsTheLockCountedPastTheFirstFreezesBucket`.)
- [x] 4.3 Unfreeze re-books to the current bucket; assert expiry lands at `currentBucketEnd + challengeWindow`. (`test_unfreezeCoverage_returnsTheLockToOrdinaryDecay`, `_lateUnfreezeReturnsToTheBookedBucketAndFreesADeadLock`; the pre-settlement floor is `_neverDropsTheLockBeneathTheBucketCoveringSettlement`; the pin floor is `_neverDropsTheLockBeneathAStandingPin`. There is no current-bucket floor — see design.md.)
- [x] 4.4 Horizon clamp: freeze with `disputeTimeoutAtFiling` at its 60-day maximum; assert the lock lands in the last in-horizon bucket and `hasFrozenCoverage` still blocks the unstake claim. (`test_freezeCoverage_targetBeyondTheHorizonIsClampedToItsEdge`; at exactly 60 d the target IS the edge, so the test drives a 200-day value through the clamp.)
- [x] 4.5 Composition: freeze → unfreeze → pin → retire on one lock; after each step assert bucket sums are consistent and after retirement the guardian's buckets equal their pre-lock values. (`test_rebucketing_composesAcrossFreezeUnfreezePinAndRetire`, reading buckets through `ExposureLedgerHarness.bucketOf`.)
- [x] 4.6 Shorter pin is a no-op: lock stays in its bucket, deadline unchanged. (`test_pinCoverageUntil_shorterPinDoesNotMoveTheLockEarlier` — the deadline IS still recorded, as before; only the bucket is untouched.)
- [x] 4.7 Mutation-verify: (a) remove the `_rebucket` call from `freezeCoverage` and confirm 1.1 fails; (b) make `_unwindApproval` recompute the booking epoch and confirm 4.5 fails with a bucket residue. ((a) killed 1.1 + 7 others incl. the game-level two-filing test; (b) killed 4.5 and `ChallengeEndToEnd.test_badFaithArc_*` with arithmetic underflow; (c) reverting the game to first-filing-only freezing killed the two-filing game test.)
- [x] 4.9 `MAX_DISPUTE_TIMEOUT <= MAX_COVERAGE_HORIZON` pinned by a test reading both constants (`ChallengeEndToEnd.test_constants_disputeTimeoutCeilingFitsTheCoverageHorizon`).
- [x] 4.8 Full non-fork suite green; `forge fmt --check` clean under the CI-pinned forge; `script/exposure-ledger-layout.golden.json` diffs ZERO (no new storage). (No such golden exists — the ledger is not proxy-upgraded and is not in `check-layout-goldens.sh`; the gate was run and passes for the five contracts it covers. `LockRecord` gained `bookedEpoch` inside the same slot.)

## 5. Docs and tracking

- [x] 5.1 `docs/guardian-network.md`: one paragraph on why frozen and pinned locks keep counting against capacity, and the horizon-clamp residual.
- [ ] 5.2 Linear: resolve SHE-213 linking this change; confirm it is recorded as blocked-by `declared-coverage-locks` until that lands. (Left for the PR author: resolve on merge. Also file the follow-up for the unresolved-filing residual and the review's M-3 economics note.)
