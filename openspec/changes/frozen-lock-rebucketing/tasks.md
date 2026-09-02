## 1. Reproduce first

- [ ] 1.1 Write the SHE-213 reproduction against the lock model: guardian locks on A, A is frozen, warp past A's original bucket expiry, guardian approves B — assert (pre-fix) that B's lock overlaps A's. This is the red test; it must fail before §2 and pass after.
- [ ] 1.2 Add the pin variant: lock on A, pin to `until` beyond bucket expiry, warp past the original expiry, approve B — assert the same overlap pre-fix.

## 2. The re-bucket primitive

- [ ] 2.1 Add `_rebucket(bytes32 key, address guardian, uint256 targetEpoch)`: no-op on equal epochs; subtract the lock from `_buckets[g][current]`, add to `_buckets[g][target]`, write `RecordedExposure.epoch = target`. Clamp `targetEpoch` to `(now + MAX_COVERAGE_HORIZON) / epochLength` before moving (design D5); state the adversary in natspec.
- [ ] 2.2 Make `_unwindApproval` (used by release and retire) subtract from `RecordedExposure.epoch` as currently recorded — verify it does not recompute the booking-time epoch anywhere (design D6). Pin with the "retire after a move" scenario test.

## 3. Call sites

- [ ] 3.1 `freezeCoverage`: inside the existing approver loop, `_rebucket` each live lock to the epoch containing `filedAt + disputeTimeoutAtFiling`. Decide the source of that value (parameter from the freezer vs. read-back through the narrow freezer interface) and document why; keep idempotence — a second freeze must not move locks again.
- [ ] 3.2 `unfreezeCoverage`: inside the existing loop, `_rebucket` each lock to the epoch containing `block.timestamp` (design D3).
- [ ] 3.3 `pinCoverageUntil`: after raising the pin deadline, `_rebucket` to the epoch containing `until` only when later than the current epoch (design D4, monotonic).
- [ ] 3.4 Update `IExposureLedger` natspec for all three; the freezer-facing interface gains the timeout parameter only if 3.1 chose the parameter route.

## 4. Tests

- [ ] 4.1 The two reproductions from §1 now pass (B's lock is clamped to genuinely free budget).
- [ ] 4.2 Freeze moves the lock and leaves `openExposure` unchanged at the instant of the move.
- [ ] 4.3 Unfreeze re-books to the current bucket; assert expiry lands at `currentBucketEnd + challengeWindow`.
- [ ] 4.4 Horizon clamp: freeze with `disputeTimeoutAtFiling` at its 60-day maximum; assert the lock lands in the last in-horizon bucket and `hasFrozenCoverage` still blocks the unstake claim.
- [ ] 4.5 Composition: freeze → unfreeze → pin → retire on one lock; after each step assert bucket sums are consistent and after retirement the guardian's buckets equal their pre-lock values.
- [ ] 4.6 Shorter pin is a no-op: lock stays in its bucket, deadline unchanged.
- [ ] 4.7 Mutation-verify: (a) remove the `_rebucket` call from `freezeCoverage` and confirm 1.1 fails; (b) make `_unwindApproval` recompute the booking epoch and confirm 4.5 fails with a bucket residue.
- [ ] 4.8 Full non-fork suite green; `forge fmt --check` clean under the CI-pinned forge; `script/exposure-ledger-layout.golden.json` diffs ZERO (no new storage).

## 5. Docs and tracking

- [ ] 5.1 `docs/guardian-network.md`: one paragraph on why frozen and pinned locks keep counting against capacity, and the horizon-clamp residual.
- [ ] 5.2 Linear: resolve SHE-213 linking this change; confirm it is recorded as blocked-by `declared-coverage-locks` until that lands.
