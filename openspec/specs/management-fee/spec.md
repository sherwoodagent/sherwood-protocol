# Management Fee Specification

## Purpose

Defines the always-on management fee: a time-weighted charge on the whole fund's assets
while a proposal is Executed (not only the capital it deploys) that
is owed whether the fund made money, lost money, or went nowhere, so that the parties
doing continuous work — the agent managing the book and the guardian network reviewing
every proposal — are funded in flat months.
## Requirements
### Requirement: The management fee is charged on every settlement regardless of profit or loss

A settlement SHALL charge the management fee whether the proposal's realized profit is
positive, zero, or negative. The management fee MUST NOT be gated on profit.

#### Scenario: A flat proposal still pays the management fee

- **WHEN** a proposal settles with realized profit of exactly zero
- **THEN** the management fee accrued over that proposal is charged and distributed to
  the recipients named by the proposal's recorded management split

#### Scenario: A losing proposal still pays the management fee

- **WHEN** a proposal settles with negative realized profit
- **THEN** the management fee accrued over that proposal is charged, and no performance
  fee is charged

#### Scenario: A profitable proposal pays the management fee before any performance fee

- **WHEN** a proposal settles with positive realized profit above the high-water mark
- **THEN** the management fee is charged first and the performance fee is computed
  against assets already reduced by it

### Requirement: Accrual is consumed and reset at settlement

Settlement SHALL charge the outstanding accrual and reset it, so no portion of the base
is charged twice across consecutive proposals.

#### Scenario: Two consecutive proposals do not double-charge the first proposal's accrual

- **WHEN** a proposal settles and charges its management fee, and a second proposal is
  then executed and settled
- **THEN** the second settlement charges only accrual generated after the first settlement

### Requirement: Capital idle between proposals accrues no management fee

Accrual SHALL begin when capital is deployed for a proposal and stop at settlement.
Capital sitting in the vault between proposals MUST accrue nothing. This is accepted
behaviour, not a defect: between proposals there is no proposal, hence no recorded
recipients to pay, nobody managing the money, and nothing for guardians to review —
and redemptions are unlocked so depositors may leave freely.

#### Scenario: The gap between two proposals generates no fee

- **WHEN** a proposal settles, a cooldown period elapses with capital idle in the vault,
  and a new proposal is then executed
- **THEN** the second proposal's management fee covers only its own deployment period and
  nothing from the idle gap

#### Scenario: A dormant fund charges nothing

- **WHEN** an agent stops proposing entirely while depositors remain in the vault
- **THEN** no management fee accrues for as long as no proposal is live

### Requirement: A recipient that cannot receive payment does not block settlement

If a management-fee recipient reverts or otherwise cannot be paid, settlement SHALL
continue and the remaining recipients SHALL still be paid, using the same fail-open
escrow behaviour the protocol already applies to fee payment.

#### Scenario: One bricked recipient does not brick the settlement

- **WHEN** the guardian-network recipient reverts on receipt during a settlement
- **THEN** the settlement completes, the agent and protocol shares are paid, and the
  unpayable share is escrowed or recorded rather than reverting the transaction

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

- **WHEN** one proposal stays Executed for 30 days on a given fund and an otherwise
  identical proposal stays Executed for 15 days on the same fund
- **THEN** the second proposal's management fee is half the first's

#### Scenario: Queued mid-proposal exits do not change the accrual base

- **WHEN** a holder requests a redemption through the queue while a proposal is live
- **THEN** the shares sit in queue escrow, the base and its accrual are
  unchanged for the remainder of the proposal, and the exit is priced at settlement

#### Scenario: A proposal that deploys nothing still accrues on the whole fund

- **WHEN** a proposal whose execute batch moves no capital is executed and later settles
- **THEN** its management fee is the whole fund's assets at execute times the time it was
  Executed, at the configured rate

### Requirement: No proposal is exempt from either fee

Every settlement SHALL charge the management fee and compute the performance fee the same way, whatever the proposal's strategy reports about itself. No strategy can opt out of either leg.

#### Scenario: Every proposal pays management

- **WHEN** any proposal settles
- **THEN** the management fee is charged and distributed by the recorded management split, and the performance fee is computed from the high-water mark and the realized profit

