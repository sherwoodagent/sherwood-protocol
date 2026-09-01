## MODIFIED Requirements

### Requirement: Challenger bond sized to the coverage the filing freezes
The bond SHALL be `coverageUsd * challengerBondBps / 10_000`, converted to WOOD at the ledger's composed haircut price `woodPriceX8()` (never the raw owner scalar). `coverageUsd` SHALL be the ledger's `liabilityUsd` for the proposal — the approvers' WOOD locks at live value, capped at the proposal's priced need — so that a cohort which over-subscribed the proposal cannot inflate the bond a challenger must post beyond what a conviction can actually recover for it; the adversary is an approver cohort locking surplus WOOD precisely to price challengers out. Filing SHALL fail closed: revert `NothingToFreeze` when the lock sum is zero, `WoodPriceUnset` when the composed price is zero (transient, protocol-wide), and `BondTooSmall` when the bond floors to zero (permanent, proposal-specific) — the two price failures MUST be distinct errors. The liability read SHALL NOT be wrapped so as to substitute an uncapped sum on failure: a stale WOOD feed makes filing wait, never makes the bond larger.

#### Scenario: Bond computed from capped coverage at the composed price
- **WHEN** the approvers' locks at live value exceed the proposal's need
- **THEN** the bond is priced against the need, at `challengerBondBps` (default 150, i.e. 1.5% — the main spec's "500" was stale against `ChallengeGame.sol`) of that value, converted at `woodPriceX8()`

#### Scenario: Under-subscribed proposal prices the bond off what is recoverable
- **WHEN** the approvers' locks at live value are below the proposal's need
- **THEN** the bond is priced against the lock value, not the need

#### Scenario: Unpriced WOOD blocks filing
- **WHEN** `exposureLedger.woodPriceX8()` returns zero
- **THEN** `file` reverts `WoodPriceUnset`

#### Scenario: Zero-coverage proposal cannot be challenged
- **WHEN** every approver lock for the proposal has been released (sums to zero)
- **THEN** `file` reverts `NothingToFreeze`
