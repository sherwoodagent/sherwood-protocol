## Purpose

Widen `ConcentratedLiquidityStrategy` with an unlevered mode so the CL LP
family is proposable without a Morpho borrow leg — independent of the depth
of the single template-compatible market on 4663 — without altering one byte
of levered behavior.

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

## MODIFIED Requirements

These three requirements are stated in `changes/concentrated-liquidity-strategy`
(never archived, so they are the repo's only normative CL statements) in terms
that assume a borrow. Restated so they hold for both modes; the levered reading
is unchanged word for word.

### Requirement: One-shot lifecycle with position custody

A clone SHALL move through Pending → Executed → Settled exactly once. `execute()` SHALL pull the vault asset, establish the borrow WHEN LEVERED, and mint a liquidity position; `settle()` SHALL unwind whichever position is currently held, repay the borrow WHEN LEVERED, and return the vault asset. An unlevered clone SHALL pull `lpAmount` and SHALL reach no lending market on any path. The clone SHALL hold at most one liquidity position at any time — a rerange replaces it rather than adding to it — and SHALL hold custody of that position and any collateral receipt for the whole strategy period.

The vault SHALL be the only caller of `execute()` and `settle()`. Adversary: a registered agent who gets any unrelated proposal executed and targets a pre-deployed clone's `execute()` from that batch, flipping the one-shot ratchet and permanently bricking the clone's own later proposal. `execute()` SHALL therefore additionally require that the governor's active proposal declares this clone as its strategy, and SHALL revert otherwise.

#### Scenario: Execute from a foreign proposal's batch
- **WHEN** `execute()` is reached from a batch whose active proposal declares a different strategy address
- **THEN** the call reverts and the clone remains in Pending, executable by its own proposal later

#### Scenario: Second execute on the same clone
- **WHEN** `execute()` is called on a clone already in Executed
- **THEN** the call reverts and no second position is minted

#### Scenario: Settle before execute
- **WHEN** `settle()` is called while the clone is Pending
- **THEN** the call reverts — there is no position to unwind

#### Scenario: Unlevered execute
- **WHEN** an unlevered clone executes
- **THEN** it pulls exactly `lpAmount`, mints a position, and posts no collateral and no borrow

### Requirement: Only risk-reducing parameters are tunable after execution

Between execute and settle the proposer SHALL be able to update the settlement slippage floors and the settlement deadline, and nothing else. The pool, lending market, borrow amount, unlevered funding amount, position size, and the whole rerange policy — half-width, trigger fraction, minimum interval, maximum rerange count — SHALL be immutable after initialization. The clone's MODE SHALL likewise be immutable: it is derived from the `morpho` address bound at init and SHALL NOT be settable. Updates SHALL be rejected outside the Executed state.

The active tick range SHALL NOT be settable through a parameter update. It changes only through the deterministic rerange path below.

Adversary: a proposer who, having had a position approved by voters and guardians, mutates it after approval into a materially different position the review never covered — including by re-centering the band repeatedly until it sits somewhere the review would not have approved.

#### Scenario: Proposer retunes slippage before settling
- **WHEN** the proposer updates the settlement slippage floor while the clone is Executed
- **THEN** the update applies and settlement uses the new floor

#### Scenario: Proposer attempts to move the range
- **WHEN** the proposer submits a parameter update changing the tick range, the pool, or any rerange-policy field
- **THEN** the update reverts

#### Scenario: Non-proposer update
- **WHEN** any address other than the proposer submits a parameter update
- **THEN** the update reverts

### Requirement: Settlement unwinds before repaying, and never leaves a borrow against an unwound leg

`settle()` SHALL burn the liquidity position and collect all accrued fees before repaying the borrow, and SHALL repay the borrow before withdrawing collateral. An unlevered clone has neither, so it SHALL skip the repay and withdraw legs entirely rather than reaching a lending market that was never configured. In both modes `settle()` SHALL then push the clone's entire vault-asset balance to the vault, including any balance that arrived outside the position.

Adversary: an ordering that withdraws collateral first, leaving an outstanding borrow collateralized by nothing and the position exposed to liquidation during its own settlement.

#### Scenario: Full settlement
- **WHEN** the position can be fully burned and the borrow fully repaid
- **THEN** the clone ends with zero liquidity, zero debt, zero collateral, and the vault receives the entire proceeds

#### Scenario: Fees accrued in both tokens
- **WHEN** the position accrued fees in the non-vault-asset token
- **THEN** settlement converts them subject to the tunable slippage floor and includes them in the amount returned to the vault

#### Scenario: Unlevered settlement
- **WHEN** an unlevered clone settles
- **THEN** it burns the position, converts the volatile leg, pushes everything home, and touches no lending market
