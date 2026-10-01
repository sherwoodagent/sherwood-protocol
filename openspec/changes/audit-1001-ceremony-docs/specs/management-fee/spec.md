# management-fee (delta)

## RENAMED Requirements

- FROM: `### Requirement: The management fee base is time-weighted over deployed capital`
- TO: `### Requirement: The management fee base is the whole fund, time-weighted while a proposal is Executed`

## MODIFIED Requirements

### Requirement: The management fee base is the whole fund, time-weighted while a proposal is Executed

The fee owed SHALL be proportional to the integral of the base over time — the
product of the base and the duration the proposal was Executed — annualized at the
configured rate. The base is the WHOLE FUND's assets (`totalAssets()`), stamped at
execute, not the capital the proposal moves: a proposal that deploys nothing, or a
small fraction of the fund, accrues on the whole fund for as long as it stays
Executed. A proposal Executed for a shorter time MUST owe proportionally less than
the same fund Executed for the full proposal. Within a single proposal the base is
fixed at execution: deposits are locked while a proposal is open and exits route
through the settlement queue, so no flow can change the base mid-proposal.

#### Scenario: Half the duration owes half the fee

- **WHEN** one proposal deploys a given capital base for 30 days and an otherwise
  identical proposal deploys the same base for 15 days
- **THEN** the second proposal's management fee is half the first's

#### Scenario: Queued mid-proposal exits do not change the accrual base

- **WHEN** a holder requests a redemption through the queue while a proposal is live
- **THEN** the shares sit in queue escrow, the base and its accrual are
  unchanged for the remainder of the proposal, and the exit is priced at settlement

#### Scenario: A proposal that deploys nothing still accrues on the whole fund

- **WHEN** a proposal whose execute batch moves no capital is executed and later settles
- **THEN** its management fee is the whole fund's assets at execute times the time it was
  Executed, at the configured rate
