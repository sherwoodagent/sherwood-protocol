## MODIFIED Requirements

### Requirement: Coverage settlement returns over-reservations
`settleCoverage(governor, proposalId)` SHALL be permissionless and safe to skip. It SHALL revert `ReviewNotClosed` unless `executeBy` is set and `block.timestamp > executeBy` (strictly after — no overlap with the last executable instant), so no third party can collapse the quorum's reservation cushion while the proposal is still executable. It SHALL be re-runnable by design, and re-runnability — not a settled flag — SHALL be the idempotence mechanism: every pass re-derives the entire split from the unchanged per-approver pledges at the CURRENT price, never from a prior pass's bookings, so passes converge, a pass taken at a price trough is a stale number any later pass repairs, and no earlier pass can bind a later one. (The internal settled marker is write-only telemetry and SHALL NOT gate re-entry.) When the reserved total exceeds the priced need, it SHALL collapse each reservation to its pro-rata allocation, release the excess from each guardian's bucket, and assign the rounding residue to the first live holder ONLY in the over-subscribed branch (an under-covered cohort must not have phantom exposure invented for it). Each guardian's settlement basis — the value allocations and residue headroom are computed from — SHALL be `min(reservation, slashable bond)` on the execution-anchored basis when the proposal has executed (live basis when it never executed), so no booking is ever written up to a level the verdict slash cannot recover. When the coverage is unpriceable it SHALL return without settling (retry later); when under-subscribed or empty it SHALL mark settled with no changes. Settlement SHALL emit `CoverageSettled(reviewKey, reservedTotal, allocatedTotal)`.

Settlement SHALL NOT depend on an external keeper: the syndicate governor self-triggers `settleCoverage` best-effort at settlement finalization and after a successful proposer-bond reclaim (see the syndicate-governor capability, issue #33). The external permissionless call remains the universal backstop — for proposals the guarded triggers skip (settled at or before `executeBy` with no reclaimable bond) and for repairing any pass taken at a bad price.

#### Scenario: Settling before the execution window closes
- **WHEN** `settleCoverage` is called at or before `executeBy`, or before `executeBy` is set
- **THEN** the call reverts `ReviewNotClosed`

#### Scenario: Over-subscribed settlement
- **WHEN** settlement runs on a proposal whose reservations exceed its need and whose effective total exceeds its need
- **THEN** each approver's booking shrinks to its allocation, freed budget returns to the guardians' buckets immediately, the truncation residue lands on the first holder so the aggregate equals the need, and `CoverageSettled` is emitted

#### Scenario: Shrunken cohort settlement
- **WHEN** bonds have shrunk so the effective total is below the need, though raw reservations exceeded it
- **THEN** no residue is credited to anyone — the under-covered proposal stays under-covered

#### Scenario: Re-run settlement converges instead of compounding
- **WHEN** `settleCoverage` runs again on an already-settled proposal — whether by the governor's self-trigger, an external caller, or both in either order
- **THEN** the pass re-derives the whole split from the unchanged pledges at the current price; bookings may move in either direction, each bounded by the guardian's own pledge and the exposure-cap re-check, and no relief or exposure is ever applied twice

#### Scenario: Post-execution top-up cannot raise a booking
- **WHEN** an approver of an executed proposal tops up its stake and settlement (or a re-run of settlement) executes afterwards
- **THEN** that approver's rebooked coverage and residue headroom are computed from its stake as of the execution instant (clamped to live), so the top-up cannot lift any booking above what the verdict slash can reach
