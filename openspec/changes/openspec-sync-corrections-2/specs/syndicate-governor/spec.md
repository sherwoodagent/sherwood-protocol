## MODIFIED Requirements

### Requirement: Execution safety guards
`executeProposal` SHALL be permissionless but SHALL only run when the resolved state is `Approved` (`ProposalNotApproved`), no other proposal is actively executing (`StrategyAlreadyActive`), and the vault's owner bond is still live (`OwnerBondNotLive`). The settle cooldown is enforced at `propose`, and since `cooldownPeriod` is frozen while a proposal is open it cannot be the first gate to fail at execute. Before executing it SHALL: snapshot the vault's asset balance as the capital snapshot and its price per share as the settle-price anchor; mark the proposal `Executed` and set `executedAt` before the execute batch (the owner-bond, asset-balance and price-per-share reads come first); start the vault's management-fee accrual; re-resolve tier and coverage from the stored calls of both legs and revert with `TierRegressed` if the live tier exceeds the propose-time `envelopeTier`, or `CoverageRegressed` if the live coverage exceeds the propose-time `requiredCoverage`; revert `MaxCapitalCeilingRegressed` if `maxCapital` now exceeds `totalAssets() * maxCapitalBps / 10_000`; and, when an exposure ledger is wired and `requiredCoverage != 0`, at every tier, measure the bond-encumbered approve coverage via `requireApproveQuorum` — which reverts on no covering approver (fail-closed: no identified, slashable approver means no execution) and otherwise returns `(coverageRaisedUsd, requiredCoverageUsd)`, from which the governor derives and stores the proposal's `effectiveMaxCapital` per the coverage-proportional effective capital requirement. The opening batch SHALL run via the vault's `executeGovernorBatch` with the (scaled) execute caps under the proposal's `effectiveMaxCapital` net-outflow cap (equal to `maxCapital` whenever coverage was full or the gate did not run). All execute/settle/cancel entrypoints SHALL be protected by a shared reentrancy lock.

#### Scenario: Cooldown between strategies
- **WHEN** `propose` is called before the cooldown deadline stamped at the last terminal event (`terminalAt + cooldownPeriod` as of that event; nothing ever settled: no cooldown)
- **THEN** the call SHALL revert with `CooldownNotElapsed`, giving depositors an exit window between strategies

#### Scenario: Stale certification blocks execution
- **WHEN** an adapter used by the proposal's calls was demoted or re-certified with a higher extractable bound after propose, so the live tier or coverage exceeds the propose-time snapshot
- **THEN** `executeProposal` SHALL revert (`TierRegressed` / `CoverageRegressed`), and the proposal SHALL remain `Approved` until `executeBy` expires it

#### Scenario: Missing approve quorum blocks execution
- **WHEN** an exposure ledger is wired and a coverage-consuming proposal has no covering approve coverage booked (empty approver set, or every contribution zero)
- **THEN** `executeProposal` SHALL revert `InsufficientApproveCoverage`, leaving the proposal `Approved` until `executeBy` expires it; no approval can be added after `reviewEnd`

#### Scenario: Partial approve coverage sizes execution instead of blocking it
- **WHEN** the same proposal reaches execute with a nonzero approve coverage below `requiredCoverageUsd`
- **THEN** execution SHALL proceed at the coverage-proportional `effectiveMaxCapital` instead of reverting

#### Scenario: Only one live strategy
- **WHEN** `executeProposal` is called while another proposal is in the Executed window
- **THEN** the call SHALL revert with `StrategyAlreadyActive`

### Requirement: Fee distribution charges every proposal
Every settlement path (`settleProposal`, `unstick`, `finalizeEmergencySettle`) SHALL charge both fee legs, in order; no strategy self-report can exempt a proposal from either. (1) Management fee = `assetSeconds × managementFeeBps / (10_000 × 365 days)`, where `assetSeconds` is the vault's accrual from execute to settle (consumed and reset at settlement) and `managementFeeBps` is the vault's rate, fixed at vault initialization; it is split by the snapshotted management split into protocol, guardian and agent shares, the agent taking the remainder. (2) Performance fee = `base × performanceFeeBps / 10_000`, where `base = min(aboveHighWaterMark(), max(pnl, 0))`, read after the management fee has left the vault, and the propose-time `performanceFeeBps` is re-clamped to the live `maxPerformanceFeeBps` (emitting `FeeClamped` when the clamp fires); it is split by the snapshotted performance split into protocol, guardian, vault-owner and agent shares, the agent taking the remainder. The high-water mark SHALL be ratcheted after every settlement whether or not a fee was charged. If a snapshotted split did not sum to 10_000, the management fee would be zero (after the accrual is consumed) and the performance fee zero with the mark still ratcheted; `ProtocolConfig`'s constructor and setters (`InvalidMgmtSplit`, `InvalidPerfSplit`) make such a split unreachable. A protocol or guardian share whose snapshotted recipient is `address(0)` SHALL fold into the agent's share. The agent's share of either leg SHALL be split across co-proposers by their `splitBps` with the remainder to the lead proposer; a co-proposer who is no longer a registered agent at settlement forfeits its share, which stays in the vault and is not paid to the lead. `GuardianFeeAccrued` SHALL be emitted for a guardian share only when its transfer delivers. Any individual fee transfer that reverts (e.g. a blacklisted recipient) SHALL be escrowed against `(vault, recipient, token)` instead of reverting settlement, emitting `FeeTransferFailed`, with the escrowed amount capped at the vault's `spendableFee` (`FeeEscrowCapped` when the cap binds). Recipients pull escrowed amounts later via `claimUnclaimedFees`, which SHALL be `nonReentrant`, SHALL revert `VaultProposalActive` while the claimed vault has an executing proposal, SHALL zero the escrow slot before transferring, and SHALL only pay from the vault that owes it.

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
