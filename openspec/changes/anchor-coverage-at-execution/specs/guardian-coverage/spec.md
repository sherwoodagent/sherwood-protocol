## MODIFIED Requirements

### Requirement: Slashable bond valuation
The ledger SHALL value a guardian's slashable bond in USD (8-decimal price) as `ownStake(g) × woodPriceX8() / 1e8`. Only the guardian's own stake counts — there is no delegated-inbound term. The stake basis SHALL depend on the read:

- The public `slashableBondUsd` view and the free-budget cap in `recordApproval` read the guardian's LIVE stake (`swood.guardianStake`).
- Every per-proposal read that values a lock — the approval slot floor and the execute-time quorum (anchored at the current block), and after execution `coverageUsdOf`, `liabilityUsd` / `unsharedLiabilityUsd` and `slashBpsFor` (anchored at `executedAt`) — SHALL use `swood.slashableStakeAt(g, anchor)`, the basis the verdict slash recovers from, so stake added at or after the anchor instant is never counted as coverage for that proposal.

#### Scenario: Bond priced from own stake
- **WHEN** `slashableBondUsd(guardian)` is called for a guardian with staked WOOD
- **THEN** it returns the guardian's own live stake multiplied by the current haircut WOOD/USD price, with no delegated component

#### Scenario: Post-execution top-up is not coverage
- **WHEN** a guardian tops up its stake after the proposal it approved has executed, and a post-execution coverage read (coverage, liability, or slash rate) values that guardian
- **THEN** the guardian is valued at its stake as of the execution instant (clamped to live), and the top-up moves none of the proposal's coverage figures
