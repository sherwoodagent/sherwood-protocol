# deployment-docs (delta)

## ADDED Requirement: Accepted oracle risks are stated in the deploy runbook

The deploy runbook documentation SHALL contain an "Accepted v1 oracle risks"
section stating, in the operator's line of sight rather than only in source
natspec:

#### Scenario: reviewer reads the runbook

- **WHEN** a reviewer or deploy operator reads the runbook end to end
- **THEN** they encounter (1) the aggregator min/max clamping risk with its
  anti-conservative direction (clamped price understates `coverageUsd`, so
  `requireApproveQuorum` under-collateralizes exactly during a collapse), and
  (2) the absence of a sequencer-uptime feed on Robinhood 4663 and why the
  usual staleness gate therefore cannot exist,
- **AND** each names the affected read paths (`coverageUsd`, `woodPriceX8`)
  and states these are accepted-for-v1, not open defects.

#### Scenario: operator wires a Chainlink WOOD feed

- **WHEN** the operator reads the section on feed wiring
- **THEN** they find the maintenance note: `woodUsdPriceX8` remains
  load-bearing after a feed is wired (stale feed falls back to it silently);
  abandoning the manual number silently misvalues every bond.
