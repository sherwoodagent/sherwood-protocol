# instant-exit-fees — delta

## MODIFIED Requirements

### Requirement: An instant exit is charged a separate early-exit penalty

In addition to crystallization, an instant exit SHALL be charged an early-exit penalty at
a configurable rate bounded by a protocol maximum. The penalty SHALL accrue to the fund
for the benefit of remaining depositors and MUST NOT be routed to any fee recipient. It
SHALL apply to the whole exit at a flat rate, independent of how much of the exit the
fund's idle balance could absorb.

The penalty prices the spread between the mark an instant exit is paid against and what
the strategy's positions would actually fetch — a spread the Lane A availability gate
deliberately tolerates up to its divergence bound. That harm to the depositors who stay is
identical whether or not the exit happened to force a sale, so the charge does not depend
on the fund's idle balance. Adversary: idle balance is continuously replenished by fresh
instant deposits, so a balance-scoped charge would leave a penalty-free exit window that
grows with inflows — letting an arbitrageur size an exit to that window and harvest the
spread at no cost, funded by the very deposits that enlarged it.

Cost recovery for a forced unwind is a distinct concern; if charged at all it SHALL be a
separate surcharge on the pulled portion and SHALL NOT reduce the flat penalty above.

#### Scenario: The penalty accrues to the fund, not to a fee recipient

- **WHEN** an instant exit incurs the early-exit penalty
- **THEN** the penalty amount stays in the fund and no fee recipient receives any part of it

#### Scenario: An exit served entirely from idle balance pays the full penalty

- **WHEN** an instant exit is small enough to be served entirely from the fund's idle balance
- **THEN** the early-exit penalty is charged on the whole exit at the configured rate

#### Scenario: An exit that forces an unwind pays the same flat rate

- **WHEN** an instant exit exceeds the idle balance and capital must be pulled from the strategy
- **THEN** the penalty is charged on the whole exit at the same rate as a balance-served exit

#### Scenario: The penalty rate cannot exceed the protocol maximum

- **WHEN** an attempt is made to configure an early-exit penalty rate above the protocol maximum
- **THEN** the call reverts

#### Scenario: A queue exit never pays the penalty

- **WHEN** a depositor exits through the settlement queue
- **THEN** no early-exit penalty is charged, under any fund state
