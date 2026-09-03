## MODIFIED Requirements

### Requirement: Coverage freeze pins release and exit
`freezeCoverage` and `unfreezeCoverage` SHALL be callable only by the owner-set `coverageFreezer` (the challenge game). A freeze SHALL pin exactly one proposal's committed coverage — never the guardians' whole stake or other approvals — blocking `releaseApproval` for that proposal and incrementing a per-guardian frozen-commitment COUNT for every listed approver with a live lock. `hasFrozenCoverage(guardian)` SHALL report whether any frozen proposal names the guardian, and sWOOD gates the unstake claim on it, so bucket expiry (pure wall-clock) cannot let accused collateral walk out mid-challenge. A freeze SHALL ALSO re-bucket every listed approver's lock so that it keeps counting against that guardian's capacity for as long as the challenge can be live — the second adversary the wall clock enables is not the accused walking out but the accused *locking again* on budget the expired bucket wrongly reports as free, and `hasFrozenCoverage` does nothing for that. Freeze and unfreeze SHALL be idempotent (counters move only when the flag flips), and unfreeze SHALL clear exactly the per-guardian marks its freeze set and return each lock to ordinary decay.

#### Scenario: Freeze by non-freezer
- **WHEN** any address other than `coverageFreezer` calls `freezeCoverage` or `unfreezeCoverage`
- **THEN** the call reverts `NotCoverageFreezer`

#### Scenario: Accused guardian cannot exit
- **WHEN** a proposal naming a guardian is frozen and the guardian's epoch buckets have aged out
- **THEN** `hasFrozenCoverage(guardian)` is true and the sWOOD unstake claim is refused until the challenge resolves and unfreezes

#### Scenario: Accused guardian cannot re-lock the frozen budget
- **WHEN** a proposal naming a guardian is frozen, enough wall-clock time passes that the lock's original bucket would have expired, and the guardian approves another proposal
- **THEN** the frozen lock still counts in `openExposure`, so the new lock is clamped to the budget genuinely free and never overlaps the frozen one

#### Scenario: Repeated freeze
- **WHEN** `freezeCoverage` is called twice for the same proposal
- **THEN** the per-guardian counters do not drift, no lock moves a second time, and the second call only re-emits the event

## ADDED Requirements

### Requirement: Frozen and pinned locks are re-bucketed to their true liability end
The ledger SHALL keep each lock in the epoch bucket that matches how long the lock is actually live, moving it when a freeze, an unfreeze, or a pin changes that answer, so that the existing bucket scan counts it for exactly that long without any second accumulator or any additional read on the capacity path. On freeze, each listed approver's lock SHALL move to the bucket containing the challenge's pinned worst-case end (`filedAt + disputeTimeoutAtFiling`, passed by the freezer), never earlier than the bucket it occupies. On unfreeze, each lock SHALL move to the LATEST of the bucket containing the current time, the bucket it was booked into, and the bucket of any standing pin on it — so ordinary decay resumes, the lock still covers one further `challengeWindow`, and a challenge resolved before settlement can never leave the settlement drain uncovered. A move SHALL update the lock's recorded epoch, and release and retirement SHALL unwind the lock from that recorded (current) epoch — never from a recomputed booking-time epoch — so a moved lock leaves neither a phantom in its new bucket nor a negative in its old one. A re-bucket target beyond the coverage horizon SHALL be clamped to the horizon's edge, because a bucket outside the bounded scan is invisible to it — the exact un-counting this requirement exists to prevent. Moving a lock to the bucket it already occupies SHALL be a no-op. The adversary throughout is a guardian who has been accused, or whose lock is pinned, and who uses the wall-clock expiry of the original bucket to have that lock stop counting while it remains slashable.

#### Scenario: Freeze extends the lock to the challenge's worst-case end
- **WHEN** a challenge is filed against a proposal whose approvers' locks sit in a bucket that expires before `filedAt + disputeTimeoutAtFiling`
- **THEN** each lock is moved to the bucket containing that end, and `openExposure` for each approver is unchanged at the moment of the move

#### Scenario: Unfreeze resumes ordinary decay
- **WHEN** the challenge terminates and coverage is unfrozen after the lock's booked bucket has become the current one or has passed
- **THEN** each lock is moved to the bucket containing the current time, so it expires at that bucket's end plus `challengeWindow` — the same guarantee a freshly booked lock has

#### Scenario: Unfreeze before settlement keeps the settlement bucket
- **WHEN** a challenge is filed and resolved before the proposal settles, while the lock's booked bucket is still ahead of the current one
- **THEN** the unfreeze returns the lock to its booked bucket, not the current one, so the budget stays held until the settlement drain can no longer be challenged

#### Scenario: Freeze never moves a lock earlier
- **WHEN** a challenge's worst-case end falls in a bucket earlier than the one the lock already occupies
- **THEN** the lock stays where it is

#### Scenario: Retire after a move unwinds the right bucket
- **WHEN** a lock has been re-bucketed by a freeze and later unfrozen, and its retirement window has elapsed
- **THEN** `retireApproval` subtracts the lock from the bucket it currently occupies, and every bucket the lock ever visited sums to zero for that lock

#### Scenario: Target beyond the horizon is clamped
- **WHEN** a freeze's worst-case end lies beyond `now + MAX_COVERAGE_HORIZON`
- **THEN** the lock is moved to the last bucket inside the horizon rather than to a bucket the scan cannot see, and `hasFrozenCoverage` continues to block exit regardless

#### Scenario: Re-bucketing composes
- **WHEN** the same lock is frozen, unfrozen, then pinned, then retired
- **THEN** each step reads the lock's current epoch, the intermediate bucket sums are consistent after every step, and the final retirement leaves the guardian's buckets at their pre-lock values

### Requirement: Pinning a lock extends its bucket to the pin's expiry
`pinCoverageUntil(governor, proposalId, guardian, until)` SHALL be callable only by the owner-set `coverageFreezer`, SHALL raise the lock's pin deadline monotonically (a shorter `until` than the current pin is a no-op), and SHALL move the lock to the bucket containing `until` whenever that bucket is later than the one the lock currently occupies — never earlier — clamped to the coverage horizon. A pinned lock SHALL count against the guardian's capacity until at least `until`, and `retireApproval` SHALL refuse it with `CoveragePinnedActive` until then. There is no unpin: pin expiry is time-based, which is exactly why the bucket mechanism — itself time-based — is the right enforcer. The adversary is a guardian whose proposal was ruled inconclusive and pinned pending re-challenge, who would otherwise see the pinned lock fall out of `openExposure` on the original bucket's clock and re-lock that budget elsewhere.

#### Scenario: Pin by non-freezer
- **WHEN** any address other than `coverageFreezer` calls `pinCoverageUntil`
- **THEN** the call reverts `NotCoverageFreezer`

#### Scenario: Pin extends capacity accounting
- **WHEN** a lock is pinned to an `until` beyond its current bucket's expiry and the original expiry passes
- **THEN** the lock still counts in `openExposure` until the bucket containing `until` expires

#### Scenario: Shorter pin does not move the lock earlier
- **WHEN** `pinCoverageUntil` is called with an `until` earlier than the lock's current bucket expiry
- **THEN** the pin deadline is unchanged, the lock stays in its current bucket, and the call is a no-op beyond the event

#### Scenario: Retire refused while pinned
- **WHEN** `retireApproval` is called for a lock whose `until` has not yet passed
- **THEN** the call reverts `CoveragePinnedActive`
