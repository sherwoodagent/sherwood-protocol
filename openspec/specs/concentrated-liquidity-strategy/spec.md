# concentrated-liquidity-strategy Specification

## Purpose
The concentrated-liquidity strategy template lets a syndicate deploy vault capital as a market-making position: liquidity provided over a bounded price range in one Uniswap V3 pool that quotes the vault asset, funded by vault asset posted as Morpho collateral plus vault asset borrowed against it, with part of that capital swapped into the pool's other token before the mint. It exists so a proposer's off-chain parameter choices are bounded on-chain by what the venue can actually absorb.
## Requirements
### Requirement: One-shot lifecycle with position custody

A clone SHALL move through Pending → Executed → Settled exactly once. `execute()` SHALL pull `collateralAmount` of the vault asset, post it as Morpho collateral (depositing it into the ERC-4626 wrapper first when the market's collateral is a wrapper), borrow `borrowAmount` of the vault asset, and mint a liquidity position; `settle()` SHALL unwind whichever position is currently held, repay the borrow, and return the vault asset. The clone SHALL hold at most one liquidity position at any time — a rerange replaces it rather than adding to it — and SHALL hold custody of that position and any collateral receipt for the whole strategy period.

The vault SHALL be the only caller of `execute()` and `settle()`. Adversary: a registered agent who gets any unrelated proposal executed and targets a pre-deployed clone's `execute()` from that batch, flipping the one-shot ratchet and permanently bricking the clone's own later proposal. `execute()` SHALL therefore additionally require that the governor's active proposal declares this clone as its strategy, and SHALL revert `NotActiveProposalStrategy` otherwise.

#### Scenario: Execute from a foreign proposal's batch
- **WHEN** `execute()` is reached from a batch whose active proposal declares a different strategy address
- **THEN** the call reverts `NotActiveProposalStrategy` and the clone remains in Pending, executable by its own proposal later

#### Scenario: Second execute on the same clone
- **WHEN** `execute()` is called on a clone already in Executed
- **THEN** the call reverts and no second position is minted

#### Scenario: Settle before execute
- **WHEN** `settle()` is called while the clone is Pending
- **THEN** the call reverts `NotExecuted` — there is no position to unwind

### Requirement: Initialization validates venue feasibility before capital moves

Initialization SHALL reject a configuration that cannot execute, so a typo'd or infeasible proposal fails at init rather than mid-batch with vault funds in flight. It SHALL first resolve the vault's tier registry (`TierRegistryUnresolved` when it cannot) and require the swap adapter, the position manager, the Morpho singleton and the Uniswap factory to be allowed counterparties (`CounterpartyNotAllowed(counterparty, registry)`). It SHALL then verify:

1. The pool was created by the named factory (`getPool(token0, token1, fee) == pool`), the position manager's own `factory()` is that factory (`PoolNotFromFactory`), and one of the pool's two tokens is the vault asset (`PoolAssetMismatch`). The pool's other token SHALL be an allowed counterparty.
2. The lending market lends the vault asset (`LoanAssetMismatch`), its id is allowlisted (`MorphoMarketNotAllowed(marketId, registry)`), it exists on Morpho (`MarketNotCreated`), and its collateral is the vault asset or an ERC-4626 wrapper of it, never the pool's other token (`CollateralAssetMismatch`).
3. The requested borrow does not exceed the market's currently lendable liquidity (`BorrowExceedsLiquidity`).
4. The resulting loan-to-value, with the collateral valued through the wrapper's own conversion, sits at least `MIN_LLTV_BUFFER_BPS` (500 bp) below the market's liquidation LTV (`LtvInsideLiquidationBuffer`, also when the LLTV itself is below 500 bp).
5. The declared `expectedLiquidity` does not exceed `MAX_POOL_SHARE_BPS` (10%) of the pool's current in-range liquidity (`PositionExceedsPoolShareCap`). `execute()` SHALL re-check the liquidity actually minted against the pool's liquidity read before the mint.
6. The tick range is non-empty, correctly ordered, and aligned to the pool's tick spacing (`InvalidTickRange`). A range outside the tick domain is not refused at init; it reverts inside the position manager's mint at `execute()`, atomically.

Adversary for (3) and (5): a proposer sizing a position against a venue that cannot absorb it — a borrow larger than the market can fund reverts the whole batch at execute, and a position that is a large share of pool liquidity dilutes its own fee income and makes its own exit the dominant flow, converting a market-making position into a forced seller.

Adversary for (4): a proposer initializing at a loan-to-value so close to liquidation that ordinary price movement liquidates the collateral before settlement.

#### Scenario: Pool does not quote the vault asset
- **WHEN** initialization names a pool whose tokens are both different from the vault asset
- **THEN** initialization reverts `PoolAssetMismatch` — the position could not be unwound into the asset the vault redeems in

#### Scenario: Borrow exceeds lendable liquidity
- **WHEN** the requested borrow is greater than the market's lendable liquidity at init
- **THEN** initialization reverts `BorrowExceedsLiquidity` rather than deferring the failure to execute

#### Scenario: Loan-to-value inside the liquidation buffer
- **WHEN** the target loan-to-value is above the market's liquidation LTV minus 500 bp
- **THEN** initialization reverts `LtvInsideLiquidationBuffer`

#### Scenario: Position exceeds the pool-share cap
- **WHEN** the declared liquidity exceeds 10% of the pool's current liquidity
- **THEN** initialization reverts `PositionExceedsPoolShareCap`

#### Scenario: Misaligned tick range
- **WHEN** the tick range is inverted, empty, or not a multiple of the pool's tick spacing
- **THEN** initialization reverts `InvalidTickRange`

### Requirement: Execution refuses a manipulated price

`execute()` SHALL first re-check that every counterparty and the market id are still allowed, and before minting SHALL compare the pool's spot tick against its time-weighted average tick over `twapWindow` (at least `MIN_TWAP_WINDOW`, 300 s) and SHALL revert `SpotOutsideTwapBound` when they differ by more than `maxTwapDeviationBps`. Despite its name, that bound is compared in TICKS (N ticks is a price move of 1.0001^N − 1) and is capped at `MAX_TWAP_DEVIATION_BPS` (1,000). Adversary: an attacker who moves the pool's spot tick immediately before a scheduled execution so the position mints entirely into the leg they are about to sell back, extracting the difference from the vault at mint.

The TWAP read SHALL fail closed: if the pool's observation cardinality is below 2 or `observe` fails, `execute()` SHALL revert `TwapUnavailable` rather than fall back to spot.

#### Scenario: Spot outside the TWAP bound
- **WHEN** spot deviates from the window TWAP by more than the configured bound at execute time
- **THEN** `execute()` reverts `SpotOutsideTwapBound` and no capital is deployed

#### Scenario: Pool cannot serve the TWAP window
- **WHEN** the pool's observation cardinality is insufficient for the configured window
- **THEN** `execute()` reverts `TwapUnavailable` rather than minting against an unvalidated price

### Requirement: Only risk-reducing parameters are tunable after execution

Between execute and settle the proposer SHALL be able to update the settlement deadline, and nothing else. `updateParams` SHALL decode exactly `(settleSlippageBps, settleDeadline)`; it SHALL be callable only by the proposer while still a registered agent (`NotProposer`, `ProposerNoLongerAgent`) and only in the Executed state. The settlement slippage floor SHALL be at least `MIN_SETTLE_SLIPPAGE_BPS` (50 bp) at initialization and SHALL NOT change after it: an update naming a slippage above `MAX_SLIPPAGE_BPS` (1,000) SHALL revert `InvalidBound`, an update naming any other non-zero slippage than the stored value SHALL revert `ImmutableParam`, and zero keeps the stored value. Lowering it is not risk-reducing: a floor tighter than the settle swap's own impact reverts every settle route and leaves the position on the clone. Every accepted update SHALL overwrite `settleDeadline`. The pool, lending market, borrow amount, position size, and the whole rerange policy — half-width, trigger fraction, minimum interval, maximum rerange count, rerange slippage and swap fraction — SHALL be immutable after initialization, because no update field can express them.

The active tick range SHALL NOT be settable through a parameter update. It changes only through the deterministic rerange path below.

Adversary: a proposer who, having had a position approved by voters and guardians, mutates it after approval into a materially different position the review never covered — including by re-centering the band repeatedly until it sits somewhere the review would not have approved.

#### Scenario: Proposer tries to retune slippage before settling
- **WHEN** the proposer submits a settlement slippage floor other than the stored one while the clone is Executed
- **THEN** the update reverts `ImmutableParam` and settlement uses the reviewed floor

#### Scenario: Proposer retunes the deadline
- **WHEN** the proposer updates the settlement deadline while the clone is Executed
- **THEN** the update applies

#### Scenario: Settlement slippage below the floor at init
- **WHEN** a clone is initialized with a settlement slippage below `MIN_SETTLE_SLIPPAGE_BPS`
- **THEN** initialization reverts `InvalidBound`

#### Scenario: Non-proposer update
- **WHEN** any address other than the proposer submits a parameter update
- **THEN** the update reverts `NotProposer`

### Requirement: Reranging is permissionless, fully determined, and bounded

The clone SHALL support reranging a live position, and the resulting range SHALL be fully determined by the approved policy and live chain state — the immutable half-width centered on the pool's current TWAP tick, snapped to tick spacing and clamped to the tick domain. No caller SHALL be able to choose, bias, or nominate the resulting range.

Because no discretion remains, `rerange()` SHALL be permissionless. It SHALL check, in this order, and revert on the first that fails:

1. The clone is in the Executed state (`NotExecutedForRerange`).
2. Every counterparty and the market id are still allowed.
3. At least the approved minimum interval has elapsed since execute or the previous rerange (`RerangeTooSoon`).
4. The rerange count is below the approved maximum (`RerangeCapReached`); the maximum is at most `MAX_RERANGE_LIMIT` (20).
5. The spot-vs-TWAP deviation is within the same bound `execute()` enforces.
6. The TWAP tick has travelled from the active range's midpoint at least the approved trigger fraction of the half-range, and at least one tick spacing whatever the fraction computes to (`RerangeTriggerNotReached`).
7. The derived range differs from the active range (`RerangeTriggerNotReached`). Together with (6) this makes a second rerange in the same transaction always revert, including when the derived range is clamped at the tick-domain edge.

A rerange SHALL burn the existing position, collect accrued fees, swap toward the policy's target split with the swap floored at the rerange slippage, and mint a fresh position over the new range from every balance the clone then holds. It SHALL NOT touch the borrow or the collateral, and SHALL increment the rerange count.

Adversary: a caller who reranges repeatedly within the permitted window to bleed the position through swap cost and realized divergence loss, or who times a permitted rerange to follow an unfavorable tick move. Conditions (3), (4) and (6) bound this: the worst case is `maxReranges × (swap cost + slippage floor)`, a figure a voter can evaluate before approving the proposal. Timing choice inside the window is bounded, not eliminated — this is an accepted residual, not a solved problem.

Once the maximum rerange count is reached the position SHALL remain in its last range until settlement rather than becoming unsettleable.

#### Scenario: Rerange at the trigger
- **WHEN** the TWAP has travelled the trigger fraction of the active half-range, the interval has elapsed, and the count is below the maximum
- **THEN** any caller may rerange, and the new range is the approved half-width centered on the current TWAP tick, snapped to tick spacing

#### Scenario: Two callers, one range
- **WHEN** two different addresses call `rerange()` in the same conditions
- **THEN** both would produce the identical range — the caller's identity is not an input

#### Scenario: Rerange before the trigger
- **WHEN** the TWAP is still inside the trigger fraction of the range
- **THEN** the call reverts `RerangeTriggerNotReached`

#### Scenario: Second rerange in the same transaction
- **WHEN** a rerange has just succeeded and any caller calls `rerange()` again in the same transaction, with the TWAP unaligned to the tick spacing or the derived range clamped at the tick-domain edge
- **THEN** the call reverts `RerangeTriggerNotReached`

#### Scenario: Zero-travel rerange from a narrow initial band
- **WHEN** the initial range is narrower than the policy's half-width and the TWAP has travelled less than one tick spacing from its midpoint
- **THEN** the call reverts `RerangeTriggerNotReached`

#### Scenario: Rerange inside the minimum interval
- **WHEN** the minimum interval has not elapsed since the previous rerange
- **THEN** the call reverts `RerangeTooSoon`, regardless of where price sits

#### Scenario: Rerange past the cap
- **WHEN** the rerange count has reached the approved maximum
- **THEN** the call reverts `RerangeCapReached` and the position stays in its last range, still settleable

#### Scenario: Rerange during price manipulation
- **WHEN** spot deviates from the TWAP by more than the configured bound
- **THEN** the call reverts `SpotOutsideTwapBound` — a rerange cannot be used as a manipulated re-mint that `execute()` would have refused

#### Scenario: Rerange leaves the borrow untouched
- **WHEN** a rerange completes
- **THEN** outstanding debt and posted collateral are unchanged

### Requirement: Settlement unwinds before repaying, and never leaves a borrow against an unwound leg

`settle()` SHALL burn the liquidity position and collect all accrued fees, swap the clone's whole other-token balance into the vault asset — requiring spot within the TWAP bound and flooring the output at the pool-anchored price less the settlement slippage — then repay the borrow, then withdraw the collateral and redeem any wrapper, then push the clone's entire vault-asset balance to the vault, including any balance that arrived outside the position. When the vault asset held is below the debt, settlement SHALL deleverage in up to `MAX_DELEVERAGE_PASSES` (32) passes: each repays what is held and withdraws only collateral that keeps the residual debt healthy at the market oracle price.

Adversary: an ordering that withdraws collateral first, leaving an outstanding borrow collateralized by nothing and the position exposed to liquidation during its own settlement.

#### Scenario: Full settlement
- **WHEN** the position can be fully burned and the borrow fully repaid
- **THEN** the clone ends with zero liquidity, zero debt, zero collateral, and the vault receives the entire proceeds

#### Scenario: Fees accrued in both tokens
- **WHEN** the position accrued fees in the non-vault-asset token
- **THEN** settlement converts them subject to the settlement slippage floor and includes them in the amount returned to the vault

### Requirement: Settlement is all-or-revert, with a vault-only token rescue

`settle()` SHALL either leave the clone holding none of the vault asset, the other token, or a non-asset collateral token, or revert with nothing changed. It SHALL revert `ProceedsBelowDebt(held, owed)` when deleveraging cannot raise the debt, `CollateralNotFreeable(owed, collateral)` when no collateral can be freed while debt remains, and `StrategyHoldsTokens(token, amount)` when any of those balances remains after the pushes. There is no partial settlement and no sweep. A clone whose settlement cannot complete stays Executed, and the vault can recover any token it holds through `rescueTo(token)`, which pushes the clone's whole balance of that token to the vault, in any lifecycle state, reachable only through a vault batch, with no price read.

#### Scenario: Borrow not fully repayable at settle
- **WHEN** the unwound position and the freeable collateral yield less than the outstanding debt
- **THEN** `settle()` reverts `ProceedsBelowDebt` and the clone stays Executed

#### Scenario: Leftover balance refused
- **WHEN** a balance of the vault asset, the other token, or a non-asset collateral token remains on the clone after settlement's pushes
- **THEN** `settle()` reverts `StrategyHoldsTokens`

#### Scenario: Token rescued by a later batch
- **WHEN** a governor batch calls `rescueTo(token)` on the clone
- **THEN** the clone's whole balance of `token` moves to the vault; any caller other than the vault is refused

