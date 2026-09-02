## Context

See proposal.md — Why. Constraints that shape the approach:

- After `declared-coverage-locks`, a guardian has exactly one figure per (proposal, guardian): the lock. It sits in an epoch bucket recorded in `RecordedExposure.epoch`, and `openExposure` sums every bucket that has not yet expired. Recycling is autonomous — no caller is needed for budget to come back.
- `freezeCoverage`/`unfreezeCoverage` already iterate the approver list to maintain a per-guardian frozen COUNT. `pinCoverageUntil` is already per-guardian. So every site that needs to move a lock already knows the lock.
- A challenge's `disputeTimeoutAtFiling` is pinned at filing and cannot be moved by the owner afterwards.
- The bucket scan is bounded to 16 buckets by `(challengeWindow + MAX_COVERAGE_HORIZON) / epochLength + 2 <= 16`, with `MAX_COVERAGE_HORIZON = 60 days`. `MAX_DISPUTE_TIMEOUT` is also 60 days, so a freeze target can reach the horizon's edge.
- Any approach that keeps a lock counted by adding a second, non-decaying accumulator to the capacity check has already been tried (on SHE-212) and rejected: it also keeps *unfrozen, expired* locks counted until someone retires them, which defeats autonomous recycling and broke the epoch-recycling tests.

## Goals / Non-Goals

**Goals:**
- A frozen or pinned lock counts against capacity for exactly as long as it is live — no earlier, no later than the mechanism can know.
- Zero change to `openExposure` and zero new state on the capacity path.
- Ordinary locks recycle exactly as before.

**Non-Goals:**
- Changing what freeze or pin *mean*, who may call them, or the frozen count that gates sWOOD unstake.
- Reworking the bucket model, the horizon, or the scan bound.
- Fixing SHE-212 or SHE-225 — both are resolved by `declared-coverage-locks`, which this change depends on.

## Decisions

### D1 — Re-bucket the lock; do not add an accumulator

Freeze, unfreeze and pin move the lock between buckets via one internal `_rebucket(key, guardian, targetEpoch)`: subtract from `_buckets[g][current]`, add to `_buckets[g][target]`, update `RecordedExposure.epoch`.

*Why:* The scan already answers "is this lock still live?" by bucket expiry. Moving the lock to the bucket that matches its true liability end makes the existing mechanism give the right answer, with no second source of truth to keep consistent and no new read for `recordApproval` to make. The freeze-count machinery stays exactly as it is.

*Alternative rejected:* `openExposure = bucketScan + frozenLockedWood[g]`. Needs a new per-guardian accumulator, double-counts any frozen lock whose bucket has *not yet* expired unless the scan learns to skip frozen locks (which reintroduces per-key iteration on the hot path), and does nothing for pins without a second accumulator. Strictly more moving parts for the same outcome.

*Alternative rejected:* non-decaying live-lock accumulator as the capacity basis. See Context — already tried, breaks recycling.

### D2 — Freeze target is the pinned worst-case end

On freeze, the target bucket is the one containing `filedAt + disputeTimeoutAtFiling` (the challenge's pinned timeout). The ledger receives it from the freezer or reads it back through the freezer's narrow interface.

*Why:* That is the latest instant the challenge can still be live. Counting the lock until then is conservative — never unsafe — and the pinned value cannot be moved by the owner after filing, so the target cannot be gamed by a parameter change.

*Alternative rejected:* target the current epoch + `challengeWindow`. Too short — a disputed challenge routinely outlives that.

### D3 — Unfreeze re-books to the current bucket

On unfreeze, the lock moves to the bucket containing `block.timestamp`, so it expires at `currentBucketEnd + challengeWindow`.

*Why:* The challenge is over; the lock should now decay like any other, but it must still cover the post-challenge window in which a fresh filing is possible. Booking into the current bucket gives exactly one more `challengeWindow` of coverage from now, which is the same guarantee an ordinary lock has.

### D4 — Pin re-books to the bucket of `pinnedUntil`

`pinCoverageUntil(key, guardian, until)` moves the lock to the bucket containing `until` when that is later than the lock's current bucket; it never moves a lock earlier.

*Why:* A pin means "may not retire before `until`". Booking the lock into `until`'s bucket makes the bucket mechanism enforce the pin, and there is no unpin event to hook because pin expiry is already time-based. Monotonic-raise matches the pin's existing semantics.

### D5 — Clamp the target to the coverage horizon

Any target epoch beyond `(now + MAX_COVERAGE_HORIZON) / epochLength` is clamped to that edge.

*Why:* The scan is bounded to 16 buckets; a target past the horizon would be invisible to it — silently *un*counting the lock, the exact failure this change fixes. Clamping keeps the lock inside the scan. For freeze this is conservative-then-corrected: if a challenge genuinely outlives the horizon (rare — needs `disputeTimeout` at its 60-day max), the lock stops counting at the horizon edge, but unfreeze re-books it anyway and `hasFrozenCoverage` still blocks exit throughout. The residual is bounded to the tail beyond the horizon and only under a maximal timeout; recorded as a risk rather than solved with a wider scan, which would cost every read.

### D6 — Release and retire unwind from the current bucket

`_unwindApproval` subtracts the lock from `_buckets[g][RecordedExposure.epoch]` — the field re-bucketing keeps current — never from a recomputed booking-time epoch.

*Why:* Otherwise a moved lock would be subtracted from the wrong bucket, leaving a phantom in the target bucket and a negative in the source. This is the one place the change has a correctness dependency outside the three call sites, so it gets its own scenario and test.

## Risks / Trade-offs

- [Freeze target beyond the horizon stops counting early] → Clamped to the horizon edge; exit still blocked by `hasFrozenCoverage`; unfreeze re-books. Bounded to a maximal-timeout tail. Documented in-source with the adversary named.
- [Re-bucketing a lock a second time (re-freeze after unfreeze, or pin then freeze)] → `_rebucket` is idempotent on equal epochs and always reads the *current* epoch from the record, so sequences compose; pinned with a test that freezes, unfreezes, pins and retires the same lock.
- [Gas on freeze/unfreeze] → One extra SLOAD/SSTORE pair per approver on a path that already loops over approvers. Bounded by cohort size, which is already bounded.
- [`RecordedExposure.epoch` becomes mutable] → It was already per-lock state; only its write sites grow. No layout change.

## Implementation notes (post-`declared-coverage-locks`, PR #293)

Recorded at implementation time; each is a deviation from the decisions above, with the reason.

- **D3 is refined: unfreeze floors at the BOOKED bucket and at any standing pin.** `ChallengeGame.file` requires only `executedAt != 0`, so a challenge can be filed and resolved *before* settlement (`executedAt + strategyDuration`) while the lock sits in the bucket containing `executeBy + strategyDuration`. Moving it to the bucket containing `block.timestamp` then would expire it before the settlement drain can be challenged — the pre-ADR `currentEpoch()` hole SHE-231 pins as closed. Unfreeze therefore targets `max(currentEpoch(), bookedEpoch, epochOf(_pinnedUntil[key][g]))`. When the unfreeze happens after settlement (the case D3 reasoned about) this is exactly D3's answer.
- **The lock record carries its booking epoch.** `LockRecord{uint192 wood; uint64 epoch}` became `{uint128 wood; uint64 bookedEpoch; uint64 epoch}` — still one slot. `epoch` is the current bucket (mutable, what `_unwindApproval` subtracts from); `bookedEpoch` is the floor above. `wood` at uint128 is not a real bound (sWOOD stake is uint128; WOOD supply ~1e27) and the store still fails loudly rather than truncating. The ledger is not proxy-upgradeable and has no layout golden (`script/exposure-ledger-layout.golden.json` in tasks.md never existed), so "layout diffs zero" is vacuous here; the struct change is stated in the commit.
- **Freeze is raise-only.** D2 did not say; the spec scenario conditions on the bucket expiring before the target. A lock whose settlement lies past the dispute clock stays where it is.
- **Freeze target arrives as a parameter.** `freezeCoverage(governor, proposalId, liveUntil)`; `ChallengeGame.file` passes `block.timestamp + disputeTimeout`, the same value it pins as `disputeTimeoutAtFiling` in that transaction. No read-back: the ledger makes no call into the freezer on this path.
- **The ledger never reverts on capacity.** SHE-213's "the second approval is refused" is a zero lock (`recordApproval` returns rather than revert when `open >= cap`, so the Approve vote still lands); the reproduction asserts `lockOf(B) == 0`.
- **Residual not in D5: a second concurrent filing.** The game refcounts, so only the first filing's `liveUntil` reaches the ledger; a later concurrent filing's dispute clock ends later by at most the filing gap. `hasFrozenCoverage` blocks exit throughout; the capacity tail beyond the first target's bucket expiry is uncounted. Bounded by the challenge-window slack and bucket rounding; would need the game to re-freeze or pin on each concurrent filing to close, which is out of this change's scope.

## Migration Plan

Ships with the fresh guardian-economics deployment alongside `declared-coverage-locks`. No live state to migrate. Sequenced strictly after that change so the re-bucketed quantity is the lock.
