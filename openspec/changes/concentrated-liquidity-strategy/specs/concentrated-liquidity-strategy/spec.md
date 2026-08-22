## Purpose

The concentrated-liquidity strategy template lets a syndicate deploy vault capital as a market-making position: liquidity provided over a bounded price range in one pool, with the second leg of the pair borrowed against stable collateral rather than bought. It exists so the vault stays denominated in its own asset while earning trading fees, and so a proposer's off-chain parameter choices are bounded on-chain by what the venue can actually absorb.

## ADDED Requirements

### Requirement: One-shot lifecycle with position custody

A clone SHALL move through Pending → Executed → Settled exactly once. `execute()` SHALL pull the vault asset, establish the borrow, and mint a liquidity position; `settle()` SHALL unwind whichever position is currently held, repay the borrow, and return the vault asset. The clone SHALL hold at most one liquidity position at any time — a rerange replaces it rather than adding to it — and SHALL hold custody of that position and any collateral receipt for the whole strategy period.

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

### Requirement: Initialization validates venue feasibility before capital moves

Initialization SHALL reject a configuration that cannot execute, so a typo'd or infeasible proposal fails at init rather than mid-batch with vault funds in flight. It SHALL verify, in this order:

1. The pool exists and one of its two tokens is the vault asset.
2. The lending market exists and its loan token is the vault asset.
3. The requested borrow does not exceed the market's currently lendable liquidity.
4. The resulting loan-to-value clears the market's own liquidation LTV by at least the configured buffer.
5. The position's notional does not exceed the configured maximum share of the pool's current liquidity.
6. The tick range is non-empty, correctly ordered, and aligned to the pool's tick spacing.

Adversary for (3) and (5): a proposer sizing a position against a venue that cannot absorb it — a borrow larger than the market can fund reverts the whole batch at execute, and a position that is a large share of pool liquidity dilutes its own fee income and makes its own exit the dominant flow, converting a market-making position into a forced seller.

Adversary for (4): a proposer initializing at a loan-to-value so close to liquidation that ordinary in-range price movement liquidates the collateral before settlement.

#### Scenario: Pool does not quote the vault asset
- **WHEN** initialization names a pool whose tokens are both different from the vault asset
- **THEN** initialization reverts — the position could not be unwound into the asset the vault redeems in

#### Scenario: Borrow exceeds lendable liquidity
- **WHEN** the requested borrow is greater than the market's lendable liquidity at init
- **THEN** initialization reverts rather than deferring the failure to execute

#### Scenario: Loan-to-value inside the liquidation buffer
- **WHEN** the target loan-to-value is above the market's liquidation LTV minus the configured buffer
- **THEN** initialization reverts

#### Scenario: Position exceeds the pool-share cap
- **WHEN** the position notional exceeds the configured share of the pool's current liquidity
- **THEN** initialization reverts

#### Scenario: Misaligned tick range
- **WHEN** the tick range is inverted, empty, or not a multiple of the pool's tick spacing
- **THEN** initialization reverts

### Requirement: Execution refuses a manipulated price

Before minting, `execute()` SHALL compare the pool's spot price against its time-weighted average over the configured window and SHALL revert when the deviation exceeds the configured bound. Adversary: an attacker who moves the pool's spot tick immediately before a scheduled execution so the position mints entirely into the leg they are about to sell back, extracting the difference from the vault at mint.

The TWAP read SHALL fail closed: if the pool cannot serve an observation over the configured window, `execute()` SHALL revert rather than fall back to spot.

#### Scenario: Spot outside the TWAP bound
- **WHEN** spot deviates from the window TWAP by more than the configured bound at execute time
- **THEN** `execute()` reverts and no capital is deployed

#### Scenario: Pool cannot serve the TWAP window
- **WHEN** the pool's observation cardinality is insufficient for the configured window
- **THEN** `execute()` reverts rather than minting against an unvalidated price

### Requirement: Only risk-reducing parameters are tunable after execution

Between execute and settle the proposer SHALL be able to update the settlement slippage floors and the settlement deadline, and nothing else. The pool, lending market, borrow amount, position size, and the whole rerange policy — half-width, trigger fraction, minimum interval, maximum rerange count — SHALL be immutable after initialization. Updates SHALL be rejected outside the Executed state.

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

### Requirement: Reranging is permissionless, fully determined, and bounded

The clone SHALL support reranging a live position, and the resulting range SHALL be fully determined by the approved policy and live chain state — the immutable half-width centered on the pool's current TWAP tick, snapped to tick spacing. No caller SHALL be able to choose, bias, or nominate the resulting range.

Because no discretion remains, `rerange()` SHALL be permissionless. It SHALL be admissible only when all of the following hold, and SHALL revert otherwise:

1. The clone is in the Executed state.
2. The current price has reached or passed the approved trigger fraction of the active range's boundary.
3. At least the approved minimum interval has elapsed since execute or the previous rerange.
4. The rerange count is below the approved maximum.
5. The spot-vs-TWAP deviation is within the same bound `execute()` enforces.

A rerange SHALL burn the existing position, collect accrued fees, and mint a fresh position over the new range subject to the approved slippage floor. It SHALL NOT change the borrow, the collateral, or the position's notional, and SHALL increment the rerange count.

Adversary: a caller who reranges repeatedly within the permitted window to bleed the position through swap cost and realized divergence loss, or who times a permitted rerange to follow an unfavorable tick move. Conditions (2)–(4) bound this: the worst case is `maxReranges × (swap cost + slippage floor)`, a figure a voter can evaluate before approving the proposal. Timing choice inside the window is bounded, not eliminated — this is an accepted residual, not a solved problem.

Once the maximum rerange count is reached the position SHALL remain in its last range until settlement rather than becoming unsettleable.

#### Scenario: Rerange at the trigger
- **WHEN** price reaches the trigger fraction of the active range boundary, the interval has elapsed, and the count is below the maximum
- **THEN** any caller may rerange, and the new range is the approved half-width centered on the current TWAP tick, snapped to tick spacing

#### Scenario: Two callers, one range
- **WHEN** two different addresses call `rerange()` in the same conditions
- **THEN** both would produce the identical range — the caller's identity is not an input

#### Scenario: Rerange before the trigger
- **WHEN** price is still inside the trigger fraction of the range
- **THEN** the call reverts

#### Scenario: Rerange inside the minimum interval
- **WHEN** the minimum interval has not elapsed since the previous rerange
- **THEN** the call reverts, regardless of where price sits

#### Scenario: Rerange past the cap
- **WHEN** the rerange count has reached the approved maximum
- **THEN** the call reverts and the position stays in its last range, still settleable

#### Scenario: Rerange during price manipulation
- **WHEN** spot deviates from the TWAP by more than the configured bound
- **THEN** the call reverts — a rerange cannot be used as a manipulated re-mint that `execute()` would have refused

#### Scenario: Rerange leaves the borrow untouched
- **WHEN** a rerange completes
- **THEN** outstanding debt and posted collateral are unchanged, and only the LP position's range differs

### Requirement: Settlement unwinds before repaying, and never leaves a borrow against an unwound leg

`settle()` SHALL burn the liquidity position and collect all accrued fees before repaying the borrow, and SHALL repay the borrow before withdrawing collateral. It SHALL then push the clone's entire vault-asset balance to the vault, including any balance that arrived outside the position.

Adversary: an ordering that withdraws collateral first, leaving an outstanding borrow collateralized by nothing and the position exposed to liquidation during its own settlement.

#### Scenario: Full settlement
- **WHEN** the position can be fully burned and the borrow fully repaid
- **THEN** the clone ends with zero liquidity, zero debt, zero collateral, and the vault receives the entire proceeds

#### Scenario: Fees accrued in both tokens
- **WHEN** the position accrued fees in the non-vault-asset token
- **THEN** settlement converts them subject to the tunable slippage floor and includes them in the amount returned to the vault

### Requirement: Settlement takes the deliverable maximum and leaves a recoverable residue

When the borrow cannot be repaid in full or the collateral cannot be withdrawn in full within one call, `settle()` SHALL take the deliverable maximum, SHALL emit an incomplete-settlement event naming the remaining debt and collateral, and SHALL NOT revert. The residue SHALL remain recoverable through a permissionless post-settlement sweep that moves value in one direction only — out of the clone and into the vault.

Adversary: a settlement that reverts on any shortfall hands whoever can create that shortfall a veto over the vault's whole settlement path, freezing redemptions vault-wide for as long as they sustain it. The residue is deliberately booked as a loss on this proposal and returned untaxed later: a proposer who parks the vault in a venue that cannot pay out at settlement wears the mark, which is strictly better than the vault freezing.

#### Scenario: Borrow not fully repayable at settle
- **WHEN** the unwound position yields less than the outstanding debt
- **THEN** settlement repays what it can, emits the incomplete-settlement event, and completes without reverting

#### Scenario: Sweep after conditions recover
- **WHEN** anyone calls the sweep after settlement and the residue is now deliverable
- **THEN** the residue is returned to the vault and the sweep is safe to call again with nothing to move

#### Scenario: Sweep before settlement
- **WHEN** the sweep is called while the clone is Pending or Executed
- **THEN** it reverts — before settlement the position is unwound by settlement itself
