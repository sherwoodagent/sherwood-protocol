## Purpose

Widen `ConcentratedLiquidityStrategy` with an unlevered mode so the CL LP
family is proposable when no template-compatible Morpho market has depth,
without altering one byte of levered behavior.

## ADDED Requirements

### Requirement: Two modes, decided at init, never blended
Initialization SHALL accept exactly two configurations: LEVERED
(`collateralAmount > 0`, `borrowAmount > 0`, `lpAmount == 0`, Morpho surface
bound and checked as today) and UNLEVERED (`collateralAmount == 0`,
`borrowAmount == 0`, `lpAmount > 0`, `morpho == address(0)` and
`marketParams` zero). Every other combination SHALL revert at init.

#### Scenario: Mixed configuration fails at the cheapest moment
- **WHEN** init receives a config with exactly one of
  `collateralAmount`/`borrowAmount` zero, or `lpAmount` set alongside a
  borrow, or a nonzero `morpho` in an unlevered config
- **THEN** initialization SHALL revert and no proposal carrying it reaches
  execution with capital

#### Scenario: Levered behavior is unchanged
- **WHEN** a levered configuration valid today is initialized and executed
- **THEN** every observable effect — pulls, collateral posting, borrow,
  mint, rerange, settle, events — SHALL be identical to the pre-change
  template

### Requirement: Unlevered execute pulls and mints, touching no Morpho
In unlevered mode `_execute` SHALL pull exactly `lpAmount` of vault asset
and fund the position mint from it directly. No Morpho call of any kind
SHALL occur in any code path of an unlevered clone — execute, rerange,
settle, sweep, views, or emergency paths.

#### Scenario: A zero-address Morpho is never called
- **WHEN** an unlevered clone runs its full lifecycle including settlement
  and residue collection
- **THEN** no call SHALL be made to `address(0)` or to any Morpho selector

#### Scenario: The existing venue guards still bind
- **WHEN** an unlevered clone executes
- **THEN** the TWAP-deviation gate, counterparty re-check, and pool-share
  cap SHALL apply exactly as in levered mode

### Requirement: Unlevered settlement delivers the position, not a repayment
Settlement of an unlevered clone SHALL unwind the position, convert holdings
to the vault asset via the bound adapter under the configured slippage
bounds, and push the balance to the vault, with the repay/withdraw stages
absent rather than attempted-and-tolerated.

#### Scenario: Quiet-window settle returns funding minus venue costs only
- **WHEN** an unlevered clone settles after a window with no reranges
- **THEN** the vault SHALL receive the position's full unwound value with no
  Morpho-related deduction, and residue machinery SHALL apply unchanged
