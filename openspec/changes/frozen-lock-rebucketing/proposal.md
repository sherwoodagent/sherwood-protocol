## Why

A guardian's lock is booked into an epoch bucket that expires on a wall clock, at `bucketEnd + challengeWindow`. A freeze (a challenge was filed) or a pin keeps that lock alive and unretirable past the bucket's expiry — but `openExposure` stops counting it the moment the bucket ages out. The guardian's free budget then over-reports, and they can lock again on top of a lock they are still fully on the hook for (SHE-213, audit Medium). The existing freeze requirement already guards the sWOOD *unstake* claim against exactly this wall-clock gap; the *capacity* check was never given the same protection.

This is orthogonal to `declared-coverage-locks` (which removes the cohort cap and the collapse) and survives it unchanged, because that change deliberately keeps the epoch buckets and their wall-clock decay.

## What Changes

- **Freeze, unfreeze and pin re-bucket the lock** instead of leaving it in the bucket it was booked into. A frozen lock moves to the bucket covering the challenge's worst-case end; an unfrozen lock moves back to the current bucket so ordinary decay resumes; a pinned lock moves to the bucket covering `pinnedUntil`. The capacity scan is untouched — it already sums every unexpired bucket, so a re-bucketed lock is counted for as long as it is live with no new accumulator and no second read on the capacity path.
- Release and retirement unwind the lock from its **current** bucket, not the one it was originally booked into.
- Re-bucket targets are clamped to the coverage horizon so the bounded bucket scan is never exceeded; unfreeze re-books anyway, so the clamp is conservative rather than lossy.
- `pinCoverageUntil` gains a spec-level requirement for the first time (it exists in code but not in the main spec).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `guardian-coverage`: the freeze requirement gains the re-bucketing obligation and the capacity-side adversary it was missing; a re-bucketing requirement is added covering freeze, unfreeze, pin and the current-bucket unwind; the pin path is specified.

## Impact

- `src/ExposureLedger.sol` — one internal `_rebucket(key, guardian, targetEpoch)` helper; call sites in `freezeCoverage`, `unfreezeCoverage`, `pinCoverageUntil`; `_unwindApproval` reads the lock's current epoch. `RecordedExposure.epoch` becomes mutable state rather than a booking-time constant. No new storage: the per-lock epoch field already exists. Layout golden diffs ZERO.
- `src/ChallengeGame.sol` — no change; it already passes the pinned `disputeTimeoutAtFiling` the ledger needs to compute the freeze target, or the ledger reads it back.
- Tests: freeze-then-age-out-then-relock (the SHE-213 reproduction, must now be refused); unfreeze resumes decay; pin extends to `pinnedUntil`; horizon clamp; release/retire from a moved bucket.
- Depends on `declared-coverage-locks` landing first: the thing being moved is the lock, and the tests assert against the lock model.
- Linear: SHE-213 resolved.
