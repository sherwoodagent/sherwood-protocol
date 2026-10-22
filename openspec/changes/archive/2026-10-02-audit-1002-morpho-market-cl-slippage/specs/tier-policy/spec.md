## ADDED Requirements

### Requirement: Morpho markets are allowlisted by market id

The registry SHALL keep an owner-managed allowlist of Morpho Blue market ids: `setMorphoMarketAllowed(id, allowed)` (`onlyOwner`, emitting `MorphoMarketAllowedSet(id, allowed)`) and the view `isMorphoMarketAllowed(id)`. The id is Morpho's `keccak256(abi.encode(loanToken, collateralToken, oracle, irm, lltv))`, so one grant attests all five parameters together. A strategy template that supplies to or borrows from a Morpho market SHALL admit the market only when its id is allowlisted, read fail-closed (a registry that cannot answer has not vouched), at init and again at execute (and, for the concentrated-liquidity template, at `rerange()`). Settle SHALL NOT be gated on it, so a de-listing never strands funds. Per-address counterparty grants for the oracle or collateral SHALL NOT admit a market.

Adversary: a proposer assembling a market from individually acceptable parts, such as a loan == collateral market priced by another token's oracle, a market with `irm == address(0)`, or a non-vetted `lltv`, to freeze or skim the vault's supply. Before granting, the owner SHALL read the market's five parameters from Morpho, recompute the id, and refuse a market whose `irm` is the zero address or whose oracle does not price its collateral in its loan token.

#### Scenario: Market built from allowlisted parts is refused
- **WHEN** a Morpho-supply or CL clone names a market whose oracle and collateral are allowed counterparties but whose id is not allowlisted
- **THEN** clone-init reverts `MorphoMarketNotAllowed(marketId, registry)`

#### Scenario: Allowlisted market initialises
- **WHEN** a clone names a market whose id is allowlisted and whose Morpho singleton (and, for the CL template, its other venue counterparties) are allowed counterparties
- **THEN** clone-init succeeds, with no oracle or collateral grant of its own

#### Scenario: De-listed after init
- **WHEN** the market id is de-listed between clone-init and `execute()`
- **THEN** `execute()` reverts `MorphoMarketNotAllowed` and no vault funds move; a de-listing after execute does not block `settle()`

#### Scenario: Allowlisting is owner-only
- **WHEN** a non-owner calls `setMorphoMarketAllowed`
- **THEN** the call reverts (Ownable)
