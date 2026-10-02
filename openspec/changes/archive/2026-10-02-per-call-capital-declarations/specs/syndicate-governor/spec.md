# syndicate-governor (delta)

## MODIFIED Requirements

### Requirement: Risk tiering and proposer bond at propose
At propose time the governor SHALL resolve the proposal's tier and required coverage through the tier registry: tier = MAX tier across execute AND settlement calls (the aggregate the execute-time regression guard compares against); coverage = the per-call sum `Σ cap_i × boundBps_i / 10_000` across BOTH execute and settlement calls, where each call's contribution is its OWN declared cap times its certified bound (tier-0/1) or times 10_000 (tier-2/uncertified). Coverage SHALL be linear in the cap vector (scaling every cap by a factor scales coverage by the same factor, modulo floor rounding downward) — the property the execute-time proportional sizing consumes. A tier registry is always wired: the governor's `initialize` and `setTierRegistry` refuse a codeless registry (`TierRegistryNotWired`). `requiredCoverage == 0` is reachable when every declared cap is zero; such a proposal consumes no coverage and passes the execute-time quorum gate on its existing `requiredCoverage != 0` key, because it declares zero asset-extractable value and the per-call meter enforces exactly that declaration. When an exposure ledger is wired, propose SHALL additionally enforce the ledger's covered-TVL cap and coverage-horizon gates against the per-call-sum coverage (fail-closed, failing on the proposer; the collaborative path uses the worst-case deadline `now + collaborationWindow + votingPeriod + reviewPeriod + executionWindow`), and when a bond escrow is also wired and the ledger-priced risk-scaled WOOD proposer bond (priced from the per-call-sum coverage) is non-zero SHALL require the escrow to point at the same ledger (`LedgerEscrowMismatch`) and lock the bond in the escrow, recording the amount, the escrow address, AND the exposure-ledger address on the proposal before the external lock call. The recorded ledger is the one the reclaim gates read for the life of the bond — re-pointing the governor's live ledger slot afterwards MUST NOT change which ledger gates an already-locked bond.

#### Scenario: Coverage is the per-call sum, not full notional per call
- **GIVEN** a wired registry, `maxCapital` of 10,000,000, and a batch of a tier-0 call (100 bps bound) capped at 8,000,000, a tier-1 call (500 bps) capped at 1,900,000, and a tier-2 call capped at 100,000
- **WHEN** the proposal is created
- **THEN** `requiredCoverage` SHALL be 80,000 + 95,000 + 100,000 = 275,000 — not the 10,000,000+ the proposal-wide formula would have priced — and the risk-scaled proposer bond SHALL be priced from that per-call sum

#### Scenario: Unwired registries keep the safe default
- **WHEN** no exposure ledger is wired (a tier registry cannot be unwired)
- **THEN** the covered-TVL, coverage-horizon and bond gates SHALL be skipped, and tier and coverage are still priced through the tier registry

#### Scenario: All-zero caps price zero coverage
- **GIVEN** a wired registry and a proposal whose every cap is zero
- **WHEN** the proposal is created and later executed
- **THEN** `requiredCoverage` SHALL be 0, the approve-quorum gate SHALL be skipped on its `requiredCoverage != 0` key, and the per-call meter SHALL revert any call that moves any vault asset out of custody

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
