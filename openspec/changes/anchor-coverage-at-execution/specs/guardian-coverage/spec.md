## MODIFIED Requirements

### Requirement: Slashable bond valuation
The ledger SHALL value a guardian's slashable bond in USD (8-decimal price) as `ownStake(g) × woodPriceX8() / 1e8`. Only the guardian's own stake counts — there is no delegated-inbound term (delegation is out of scope for v1). The stake basis SHALL depend on whether the proposal being valued has executed:

- BEFORE execution (including the public `slashableBondUsd` view and approve-time budget sizing), `ownStake` is the guardian's LIVE stake, read from sWOOD's `guardianStake` — no verdict anchor exists yet, and any stake present at execution is reachable by the verdict slash.
- AFTER execution (`executedAt != 0` on the proposal), every per-proposal coverage read SHALL use the execution-anchored basis: `min(slashable stake at executedAt, live stake)` — exactly the basis the verdict slash recovers from — so stake added after the execution instant can never be counted as coverage for that proposal.

#### Scenario: Bond priced from own stake
- **WHEN** `slashableBondUsd(guardian)` is called for a guardian with staked WOOD
- **THEN** it returns the guardian's own live stake multiplied by the current haircut WOOD/USD price, with no delegated component

#### Scenario: Post-execution top-up is not coverage
- **WHEN** a guardian tops up its stake after the proposal it approved has executed, and a post-execution coverage read (allocation, liability, or settlement) values that guardian
- **THEN** the guardian is valued at its stake as of the execution instant (clamped to live), and the top-up moves none of the proposal's coverage figures

### Requirement: Allocation is pro-rata over the effective total
`allocatedUsd(governor, proposalId, guardian)` SHALL return the guardian's actual carried share: its `min(reservation, slashable bond)` scaled by `needUsd / effectiveTotal` when the proposal is over-subscribed (`effectiveTotal > needUsd`, rounding down), and the full `min(reservation, slashable bond)` otherwise — never scaled up to cover a shortfall. The slashable bond SHALL use the execution-anchored basis once the proposal has executed (and the live basis before), so the figure a challenger is charged against never exceeds what the conviction can take. The effective total SHALL be `Σ min(reservation_i, slashable bond_i)` on the same basis, so a guardian whose bond has gone cannot dilute the survivors' shares and a guardian who topped up after execution cannot inflate them. Allocations SHALL be computed lazily at read time, so a departing approver's share transfers to the remaining approvers on the next read and no settlement keeper is load-bearing. `allocatedUsd` SHALL revert on an unpriceable asset (deliberate asymmetry with `recordApproval`: sizing a slash off an unvouched price is the unsafe direction). `liabilityUsd` SHALL return `min(needUsd, effectiveTotal)` — the cohort's single-number actual liability, never the sum of reservations.

#### Scenario: Over-subscribed split
- **WHEN** two approvers each reserved the full coverage of a proposal whose need is $8,000
- **THEN** each is allocated $4,000, not the $8,000 reserved

#### Scenario: Challenger bond sizing
- **WHEN** an external caller (e.g. the challenge game) needs what a conviction can actually take
- **THEN** `liabilityUsd` returns `min(needUsd, effectiveTotal)` on the execution-anchored basis, so bonds are sized off what the verdict slash can reach, not off reservations or post-drain top-ups

#### Scenario: Accused cohort cannot price up its own prosecution
- **WHEN** approvers of an executed proposal top up their stakes before a challenge is filed
- **THEN** `liabilityUsd` — and therefore the challenger's filing bond sized from it — is unchanged by the top-ups

### Requirement: Coverage settlement returns over-reservations
`settleCoverage(governor, proposalId)` SHALL be permissionless and safe to skip. It SHALL revert `ReviewNotClosed` unless `executeBy` is set and `block.timestamp > executeBy` (strictly after — no overlap with the last executable instant), so no third party can collapse the quorum's reservation cushion while the proposal is still executable. It SHALL be idempotent via a settled flag. When the reserved total exceeds the priced need, it SHALL collapse each reservation to its pro-rata allocation, release the excess from each guardian's bucket, and assign the rounding residue to the first live holder ONLY in the over-subscribed branch (an under-covered cohort must not have phantom exposure invented for it). Each guardian's settlement basis — the value allocations and residue headroom are computed from — SHALL be `min(reservation, slashable bond)` on the execution-anchored basis when the proposal has executed (live basis when it never executed), so no booking is ever written up to a level the verdict slash cannot recover. When the coverage is unpriceable it SHALL return without settling (retry later); when under-subscribed or empty it SHALL mark settled with no changes. Settlement SHALL emit `CoverageSettled(reviewKey, reservedTotal, allocatedTotal)`.

#### Scenario: Settling before the execution window closes
- **WHEN** `settleCoverage` is called at or before `executeBy`, or before `executeBy` is set
- **THEN** the call reverts `ReviewNotClosed`

#### Scenario: Over-subscribed settlement
- **WHEN** settlement runs on a proposal whose reservations exceed its need and whose effective total exceeds its need
- **THEN** each approver's booking shrinks to its allocation, freed budget returns to the guardians' buckets immediately, the truncation residue lands on the first holder so the aggregate equals the need, and `CoverageSettled` is emitted

#### Scenario: Shrunken cohort settlement
- **WHEN** bonds have shrunk so the effective total is below the need, though raw reservations exceeded it
- **THEN** no residue is credited to anyone — the under-covered proposal stays under-covered

#### Scenario: Double settlement
- **WHEN** `settleCoverage` is called on an already-settled proposal
- **THEN** it returns without re-dividing the settled numbers

#### Scenario: Post-execution top-up cannot raise a booking
- **WHEN** an approver of an executed proposal tops up its stake and settlement (or a re-run of settlement) executes afterwards
- **THEN** that approver's rebooked coverage and residue headroom are computed from its stake as of the execution instant (clamped to live), so the top-up cannot lift any booking above what the verdict slash can reach
