## MODIFIED Requirements

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
