# management-fee (delta)

One requirement modified (issue #54). The management fee itself survives untouched —
always-on, time-weighted, consumed at settlement, idle-gap-free, self-managing
exemption, fail-open payment. What changes is that the accrual base can no longer
move mid-proposal: deposits are locked while any proposal is open, and exits are
queue-only (escrowed outside the vault balance until after settlement), so the
mid-proposal base-change scenarios describe flows that can no longer occur. The
`consumeCrystallizedMgmt` netting at settlement is deleted with the
`instant-exit-fees` capability (see that delta); the settlement charge is the plain
annualized integral.

## MODIFIED Requirements

### Requirement: The management fee base is time-weighted over deployed capital

The fee owed SHALL be proportional to the integral of deployed capital over time —
the product of capital and the duration it was deployed — annualized at the
configured rate. Capital that was deployed for a shorter time MUST owe
proportionally less than the same capital deployed for the full proposal. Within a
single proposal the base is fixed at execution: deposits are locked while a proposal
is open and exits route through the settlement queue, so no flow can change the
deployed base mid-proposal.

#### Scenario: Half the duration owes half the fee

- **WHEN** one proposal deploys a given capital base for 30 days and an otherwise
  identical proposal deploys the same base for 15 days
- **THEN** the second proposal's management fee is half the first's

#### Scenario: Queued mid-proposal exits do not change the accrual base

- **WHEN** a holder requests a redemption through the queue while a proposal is live
- **THEN** the shares sit in queue escrow, the deployed base and its accrual are
  unchanged for the remainder of the proposal, and the exit is priced at settlement
