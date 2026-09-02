## MODIFIED Requirements

### Requirement: Settlement and P&L
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` under the same `maxCapital` cap as execution, then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot minus the vault's interim LP net flow (deposits/withdrawals during the strategy are principal, not performance); state SHALL move to `Settled`, the active-proposal marker cleared, and the open count decremented before external fee transfers; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV.

After finalization completes (state `Settled`, fees distributed or escrowed, vault notified, `ProposalSettled` emitted), the governor SHALL make a best-effort self-trigger of the exposure ledger's `settleCoverage(governor, proposalId)` so cohort capacity relief no longer depends on an external caller (issue #33). The trigger SHALL:
- resolve the ledger pinned-first — the exposure ledger recorded on the proposal at bond-lock time, falling back to the live ledger slot only for a proposal that recorded none — and skip silently when both are unset (no ledger means no coverage was ever booked);
- be attempted ONLY when `block.timestamp > executeBy`, mirroring the ledger's own `ReviewNotClosed` gate; at or before `executeBy` (e.g. a proposer self-settle inside a long execution window — settlement is NOT reliably past the execution deadline) the trigger SHALL be skipped silently, with no call and no event, because the revert is deterministic and the bond-reclaim trigger retries later;
- never revert the settlement: a revert in the triggered call SHALL be caught bare and surfaced as `CoverageSettleFailed(proposalId, ledger)` (both fields indexed — the house best-effort pattern established by `AdapterDemotionFailed`), leaving the reservation over-booked exactly as before the trigger existed, repairable by the permissionless external `settleCoverage`;
- be the LAST operation of finalization, so a gas-starved triggered call leaves no meaningful work unfunded behind it;
- carry no gas floor (deliberate contrast with the challenge-settle path's `DEMOTION_GAS`): a caller who starves the trigger achieves only the pre-change status quo — over-reserved, the conservative direction — visibly and permissionlessly repairably, so gas-dialling selects no safety outcome here.

The self-trigger SHALL apply to every settlement entrypoint that finalizes: `settleProposal`, `unstick`, and `finalizeEmergencySettle`.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: Interim LP flow excluded from P&L
- **WHEN** depositors add or remove principal while a strategy is live
- **THEN** the settlement P&L SHALL exclude that interim net flow, so fees are charged only on strategy performance

#### Scenario: Post-deadline settlement collapses the cohort's reservations
- **WHEN** a proposal with a wired exposure ledger settles at a time strictly after `executeBy`
- **THEN** the governor SHALL call the ledger's `settleCoverage` in the same transaction, so each approver's reservation collapses to its pro-rata allocation without any external keeper

#### Scenario: Early settlement skips the trigger silently
- **WHEN** settlement finalizes at or before `executeBy` (proposer self-settle, or a strategy shorter than the remaining execution window)
- **THEN** the governor SHALL NOT attempt the ledger call and SHALL NOT emit `CoverageSettleFailed` — the reservations remain until the bond-reclaim trigger or an external `settleCoverage` call

#### Scenario: Ledger failure never bricks settlement
- **WHEN** the triggered `settleCoverage` reverts (e.g. the WOOD price feed is down)
- **THEN** the proposal SHALL still reach `Settled` with all fees processed, and the governor SHALL emit `CoverageSettleFailed(proposalId, ledger)` instead of reverting

#### Scenario: Independent external settle already ran
- **WHEN** any caller invoked the permissionless `settleCoverage` before the governor's self-trigger fires
- **THEN** the trigger's pass SHALL re-derive the same pledge-based split (the ledger's re-runnable contract) and no reservation is double-released or double-applied

### Requirement: Risk tiering and proposer bond at propose
At propose time the governor SHALL resolve the proposal's tier and required coverage through the tier registry: tier = MAX tier across execute calls; coverage = `maxCapital × Σ boundBps / 10_000` summed per-call across BOTH execute and settlement calls, where a certified tier-0/1 call contributes its certified bound and a tier-2/uncertified call contributes 10_000 (full notional). With no tier registry wired, every proposal SHALL resolve to tier 2 / full-notional coverage (the safe default). When an exposure ledger is wired, propose SHALL additionally enforce the ledger's covered-TVL cap and coverage-horizon gates (fail-closed, failing on the proposer; the collaborative path uses the worst-case deadline `now + collaborationWindow + votingPeriod + reviewPeriod + executionWindow`), and when a bond escrow is also wired SHALL lock the ledger-priced risk-scaled WOOD proposer bond in the escrow, recording the amount, the escrow address, AND the exposure-ledger address on the proposal before the external lock call. The recorded ledger is the one the reclaim gates read for the life of the bond — re-pointing the governor's live ledger slot afterwards MUST NOT change which ledger gates an already-locked bond (adversary: a vault owner colluding with the proposer re-points at a permissive ledger after settlement, when the open-proposal guard no longer holds, to detach the reclaim gates from a live challenge).

After a successful bond release, `reclaimProposerBond` SHALL make the same guarded best-effort `settleCoverage` self-trigger as settlement finalization (same pinned-first ledger resolution, same `block.timestamp > executeBy` guard, same bare catch emitting `CoverageSettleFailed`, placed after the release as the last operation). This is the backstop that is provably past `executeBy` for every executed proposal: the Settled-proposal reclaim gate waits `executedAt + challengeWindow` on the pinned ledger, that ledger enforces `challengeWindow >= reviewPeriod + 7 days`, and `executeBy − executedAt` is strictly less than the execution window, itself capped at 7 days — so reservations a pre-`executeBy` settlement could not collapse are collapsed here, by the one caller (the proposer) with a standing economic motive. For an `Expired` proposal the state itself implies the deadline has passed. The trigger SHALL NOT run on the forfeiture-acknowledge path (a conviction already reprices the cohort through the slash machinery) and SHALL NOT block or delay the bond release when it fails.

#### Scenario: Unwired registries keep the safe default
- **WHEN** no tier registry is wired
- **THEN** every proposal SHALL be tier 2 with `requiredCoverage == maxCapital`, and with no exposure ledger wired the covered-TVL and bond gates SHALL be skipped

#### Scenario: Bond reclaim is terminal-only and permissionless
- **WHEN** any caller invokes `reclaimProposerBond` on a proposal in a terminal state (Rejected, Expired, Cancelled, or Settled) with a nonzero recorded bond
- **THEN** the governor SHALL zero the recorded bond and release it from the escrow recorded on the proposal at lock time (never the live escrow slot), paying the proposer, with the executed-proposal challenge gates evaluated against the ledger recorded on the proposal at lock time (never the live ledger slot); a second call SHALL revert with `NoBondToReclaim`
- **AND** a call while the proposal is non-terminal SHALL revert with `ProposalNotTerminal`

#### Scenario: Forfeited bond reclaim is an acknowledged no-op
- **WHEN** any caller invokes `reclaimProposerBond` on a terminal proposal whose recorded bond is nonzero but whose recorded escrow no longer holds a bond for it (a conviction forfeited it)
- **THEN** the governor SHALL zero the recorded bond, emit `ProposerBondForfeitureAcknowledged(proposalId, amount)`, and return without transferring — never reverting indefinitely and never leaving the recorded amount stale; a second call SHALL revert with `NoBondToReclaim`

#### Scenario: Forfeiture is never a lifecycle outcome
- **WHEN** a proposal is rejected by veto, blocked by guardians, expired, or cancelled
- **THEN** the proposer bond SHALL be returnable in full — forfeiture is exclusively a passed-challenge outcome outside this capability

#### Scenario: Bond reclaim backstops an early settlement
- **WHEN** a proposal settled before `executeBy` (so the settlement-time trigger skipped) and the proposer later reclaims the bond after the challenge-window gates pass
- **THEN** the reclaim SHALL trigger `settleCoverage` — the gate arithmetic guarantees this point is strictly after `executeBy` — and the cohort's reservations collapse to their allocations

#### Scenario: Trigger failure never blocks the bond
- **WHEN** the reclaim-time `settleCoverage` trigger reverts
- **THEN** the bond SHALL already have been released to the proposer, and the governor SHALL emit `CoverageSettleFailed(proposalId, ledger)` instead of reverting
