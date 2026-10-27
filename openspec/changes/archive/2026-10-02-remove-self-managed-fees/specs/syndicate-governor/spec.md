# syndicate-governor (delta)

## ADDED Requirements

### Requirement: Fee distribution charges every proposal
Every settlement path (`settleProposal`, `unstick`, `finalizeEmergencySettle`) SHALL charge both fee legs, in order; no strategy self-report can exempt a proposal from either. (1) Management fee = `assetSeconds × managementFeeBps / (10_000 × 365 days)`, where `assetSeconds` is the vault's accrual from execute to settle (consumed and reset at settlement) and `managementFeeBps` is the vault's rate, fixed at vault initialization; it is split by the snapshotted management split into protocol, guardian and agent shares, the agent taking the remainder. (2) Performance fee = `base × performanceFeeBps / 10_000`, where `base = min(aboveHighWaterMark(), max(pnl, 0))`, read after the management fee has left the vault, and the propose-time `performanceFeeBps` is re-clamped to the live `maxPerformanceFeeBps` (emitting `FeeClamped` when the clamp fires); it is split by the snapshotted performance split into protocol, guardian, vault-owner and agent shares, the agent taking the remainder. The high-water mark SHALL be ratcheted after every settlement whether or not a fee was charged. A protocol or guardian share whose snapshotted recipient is `address(0)` SHALL fold into the agent's share. The agent's share of either leg SHALL be split across co-proposers by their `splitBps` with the remainder to the lead proposer; a co-proposer who is no longer a registered agent at settlement forfeits its share, which stays in the vault and is not paid to the lead. `GuardianFeeAccrued` SHALL be emitted for a guardian share only when its transfer delivers. Any individual fee transfer that reverts (e.g. a blacklisted recipient) SHALL be escrowed against `(vault, recipient, token)` instead of reverting settlement, emitting `FeeTransferFailed`, with the escrowed amount capped at the vault's `spendableFee` (`FeeEscrowCapped` when the cap binds). Recipients pull escrowed amounts later via `claimUnclaimedFees`, which SHALL be `nonReentrant`, SHALL revert `VaultProposalActive` while the claimed vault has an executing proposal, SHALL zero the escrow slot before transferring, and SHALL only pay from the vault that owes it.

#### Scenario: Settlement never bricks on a bad recipient
- **WHEN** a fee recipient's transfer reverts during settlement
- **THEN** the amount SHALL be recorded in the unclaimed-fees escrow, the rest of the waterfall SHALL continue, and the proposal SHALL still reach `Settled`

#### Scenario: Guardian fee attribution only on delivery
- **WHEN** the guardian-fee transfer escrows instead of delivering
- **THEN** `GuardianFeeAccrued` SHALL NOT be emitted (preventing the off-chain airdrop bot from double-paying)

#### Scenario: Inactive co-proposer forfeits
- **WHEN** a co-proposer is no longer a registered agent at settlement
- **THEN** their share SHALL stay in the vault, the lead SHALL receive only its own share, and the co-proposer distribution SHALL never pay out more than the agent fee

#### Scenario: No self-report skips a fee leg
- **WHEN** a proposal settles, whatever its strategy reports about itself
- **THEN** the management fee is charged, the performance fee is computed from the high-water mark and the realized P&L, and the mark is ratcheted

#### Scenario: Ordinary escrow claim unaffected
- **WHEN** an escrowed recipient calls `claimUnclaimedFees` directly while the vault has no executing proposal
- **THEN** the call succeeds, zeroes the escrow slot, and transfers the amount

## REMOVED Requirements

### Requirement: Fee distribution waterfall
**Reason**: It described a gross-profit protocol/guardian fee, a management fee on remaining net paid to the vault owner, and a strategy-declared `selfManagesFees` opt-out that skipped every fee. None of these exist: every settlement charges a time-weighted management fee and a high-water-mark performance fee, each split by the propose-time snapshot, and no strategy can opt out.
**Migration**: Replaced by "Fee distribution charges every proposal".
