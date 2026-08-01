# Instant Exit Fees Specification

## Purpose

Defines the two independent charges that apply when a depositor leaves through the
instant-exit lane instead of waiting for the settlement queue: crystallization of the
fees they already owe, so leaving early cannot shift their burden onto the depositors
who stay, and a separate early-exit penalty that compensates those remaining depositors
for the forced unwind.

## Requirements

### Requirement: An instant exit crystallizes the exiting shares' accrued fees

An instant exit SHALL compute the exiting shares' pro-rata share of accrued management
fee and their per-share performance fee above the high-water mark, and SHALL retain those
amounts in the fund rather than releasing them to the exiter. The retained amounts MUST
be excluded from the fund's reported total assets, so the remaining depositors' price per
share is unaffected by the retention.

#### Scenario: An instant exiter pays their accrued management fee at exit

- **WHEN** a depositor exits instantly partway through a proposal with management fee accrued
- **THEN** their proceeds are reduced by their pro-rata share of the accrual, and that
  amount is retained by the fund pending distribution

#### Scenario: An instant exiter above the mark pays performance fee at exit

- **WHEN** a depositor exits instantly at a price per share above the stored high-water mark
- **THEN** their proceeds are reduced by the per-share performance fee on the shares leaving

#### Scenario: An instant exiter below the mark pays no performance fee

- **WHEN** a depositor exits instantly at a price per share at or below the stored mark
- **THEN** no performance fee is crystallized, and the management-fee crystallization still applies

#### Scenario: Retention does not move the remaining holders' price per share

- **WHEN** an instant exit crystallizes fees into the fund
- **THEN** the price per share observed by the depositors who stay is the same as it would
  have been had the fees been transferred out at that moment

### Requirement: Exit timing is fee-neutral

A depositor who exits instantly mid-proposal SHALL bear the same fee burden as an
economically equivalent depositor who holds to settlement. Neither path MUST shift fee
burden onto the other.

#### Scenario: Instant exiter and hold-to-settle depositor bear equal burden

- **WHEN** two identical positions are opened, one exits instantly at a given moment and the
  other holds through settlement with no further fund movement
- **THEN** the total fees borne by each are equal up to rounding

#### Scenario: A queue exit pays through the settle price and owes no crystallization

- **WHEN** a depositor exits through the settlement queue
- **THEN** they claim at the post-distribution settle price and no separate crystallization
  is charged to them

### Requirement: Crystallized fees are paid to the correct recipients at the next settlement

Amounts crystallized on exit SHALL be distributed at the next settlement to the recipients
named by that proposal's recorded splits, through the same fail-open payment path as
ordinary fee distribution. The exit path itself MUST NOT resolve recipients or make
external calls to them.

#### Scenario: Crystallized amounts reach the split recipients at settle

- **WHEN** one or more instant exits crystallize fees during a proposal and that proposal settles
- **THEN** the crystallized management and performance amounts are distributed by the
  proposal's recorded management and performance splits

#### Scenario: A bricked recipient does not block the exit or the settlement

- **WHEN** a crystallized amount cannot be paid to its recipient at settlement
- **THEN** settlement completes, the other recipients are paid, and the exit that produced
  the amount was itself unaffected

### Requirement: Crystallized fees are not charged again at settlement

Settlement SHALL NOT charge a second time for fees already crystallized on exit. The
management fee charged at settlement MUST be the total accrued less the amount already
crystallized; the performance fee base MUST exclude shares that have already exited.

#### Scenario: The management fee at settle nets out crystallized amounts

- **WHEN** a proposal settles after instant exits crystallized part of its management accrual
- **THEN** the settlement charges only the remaining, uncrystallized portion

#### Scenario: Exited shares are absent from the performance-fee base

- **WHEN** shares are burned on instant exit and the proposal later settles above the mark
- **THEN** the performance-fee base covers only the shares still outstanding

### Requirement: A partial exit does not advance the high-water mark

Crystallizing a performance fee on exit SHALL NOT ratchet the stored high-water mark. The
mark MUST advance only at settlement.

#### Scenario: Remaining holders keep measuring from the same mark

- **WHEN** an instant exit crystallizes a performance fee above the mark
- **THEN** the stored mark is unchanged and the depositors who stay continue to be measured
  against it

### Requirement: An instant exit is charged a separate early-exit penalty

In addition to crystallization, an instant exit SHALL be charged an early-exit penalty at
a configurable rate bounded by a protocol maximum. The penalty SHALL accrue to the fund
for the benefit of remaining depositors and MUST NOT be routed to any fee recipient. It
applies to the portion of the exit that had to be sourced by pulling capital back from the
strategy, not to the portion the fund's idle balance could absorb.

#### Scenario: The penalty accrues to the fund, not to a fee recipient

- **WHEN** an instant exit incurs the early-exit penalty
- **THEN** the penalty amount stays in the fund and no fee recipient receives any part of it

#### Scenario: An exit served entirely from idle balance pays no penalty

- **WHEN** an instant exit is small enough to be served entirely from the fund's idle balance
- **THEN** no early-exit penalty is charged

#### Scenario: An exit that forces an unwind pays the penalty on the pulled portion

- **WHEN** an instant exit exceeds the idle balance and capital must be pulled from the strategy
- **THEN** the penalty is charged on the pulled portion only

#### Scenario: The penalty rate cannot exceed the protocol maximum

- **WHEN** an attempt is made to configure an early-exit penalty rate above the protocol maximum
- **THEN** the call reverts

#### Scenario: A queue exit never pays the penalty

- **WHEN** a depositor exits through the settlement queue
- **THEN** no early-exit penalty is charged, under any fund state

### Requirement: The two exit charges apply in a fixed order

Crystallization SHALL be applied first, to the exiting shares' value; the early-exit
penalty SHALL then be applied to the net remaining. The two are independent charges with
different destinations and MUST both apply to a qualifying instant exit.

#### Scenario: An instant exit above the mark bears both charges in order

- **WHEN** a depositor exits instantly above the high-water mark with management fee accrued
  and with capital pulled from the strategy
- **THEN** their accrued management and performance fees are crystallized to the fund for
  later distribution, the early-exit penalty is then applied to the net, and the remainder
  is released to them

### Requirement: Quoted proceeds match delivered proceeds

A preview of an instant exit's proceeds SHALL account for both charges, so that the amount
quoted is the amount delivered for the same fund state.

#### Scenario: The preview matches the executed exit

- **WHEN** an instant exit is previewed and then executed with no intervening state change
- **THEN** the delivered proceeds equal the previewed proceeds

### Requirement: Deposits are not charged a fee

The fund SHALL charge nothing on entry.

#### Scenario: A deposit incurs no fee

- **WHEN** a depositor deposits into the vault
- **THEN** the shares issued reflect the full deposited amount, less no fee
