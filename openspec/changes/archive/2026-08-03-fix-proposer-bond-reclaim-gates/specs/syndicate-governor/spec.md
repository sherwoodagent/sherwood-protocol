# syndicate-governor (delta)

<!-- Change: fix-proposer-bond-reclaim-gates (issues #116, #117). The propose-time
     recording gains the ledger address (the pin the reclaim gates read), and the
     reclaim scenario set gains the forfeited-bond acknowledged outcome. The full
     gate mechanics live in the challenge-game capability ("Proposer bond lock,
     release, and forfeiture"); this requirement owns what propose RECORDS. -->

## MODIFIED Requirements

### Requirement: Risk tiering and proposer bond at propose
At propose time the governor SHALL resolve the proposal's tier and required coverage through the tier registry: tier = MAX tier across execute calls; coverage = `maxCapital × Σ boundBps / 10_000` summed per-call across BOTH execute and settlement calls, where a certified tier-0/1 call contributes its certified bound and a tier-2/uncertified call contributes 10_000 (full notional). With no tier registry wired, every proposal SHALL resolve to tier 2 / full-notional coverage (the safe default). When an exposure ledger is wired, propose SHALL additionally enforce the ledger's covered-TVL cap and coverage-horizon gates (fail-closed, failing on the proposer; the collaborative path uses the worst-case deadline `now + collaborationWindow + votingPeriod + reviewPeriod + executionWindow`), and when a bond escrow is also wired SHALL lock the ledger-priced risk-scaled WOOD proposer bond in the escrow, recording the amount, the escrow address, AND the exposure-ledger address on the proposal before the external lock call. The recorded ledger is the one the reclaim gates read for the life of the bond — re-pointing the governor's live ledger slot afterwards MUST NOT change which ledger gates an already-locked bond (adversary: a vault owner colluding with the proposer re-points at a permissive ledger after settlement, when the open-proposal guard no longer holds, to detach the reclaim gates from a live challenge).

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
