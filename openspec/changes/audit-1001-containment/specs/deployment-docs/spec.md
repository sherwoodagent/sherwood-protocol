## ADDED Requirements

### Requirement: Each Morpho market is allowlisted by id before its proposal

Morpho Blue market creation is permissionless for any oracle, collateral token, irm and lltv, so the market a strategy clone names is only as sound as all five of its parameters together. `ConcentratedLiquidityStrategy._initialize` and `MorphoSupplyStrategy._initialize` SHALL require the market id (`MarketParamsLib.id` over all five fields) to be allowlisted through `isMorphoMarketAllowed`, read fail-closed, and SHALL re-check it at `execute()` (and, for CL, at `rerange()`). Separate counterparty grants for the oracle or the collateral token SHALL NOT admit a market (amended by `audit-1002-morpho-market-cl-slippage`, FP-02; this requirement originally bound the oracle and collateral as separate counterparties).

This is a PER-PROPOSAL obligation, not a ceremony step: the market is chosen per clone, so no deploy script can assert it. The registry owner SHALL call `setMorphoMarketAllowed(<marketId>, true)` for each market a proposal is expected to use, before clone-init, after reading the market's five parameters from Morpho and refusing a market whose `irm` is the zero address or whose oracle does not price its collateral. For the known 4663 USDG market the call is `setMorphoMarketAllowed(0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114, true)`. Settle paths are NOT gated on it, so a demotion cannot strand the funds it is meant to protect.

#### Scenario: Proposal naming a market that is not allowlisted
- **WHEN** a CL or Morpho-supply clone names a market whose id is not allowlisted, even if its oracle and collateral are allowed counterparties
- **THEN** clone-init reverts `MorphoMarketNotAllowed(marketId, registry)`

#### Scenario: Allowlisted market needs no part grants
- **WHEN** a clone names an allowlisted market whose oracle and collateral hold no counterparty grant
- **THEN** clone-init succeeds

#### Scenario: Market demoted after init
- **WHEN** the market id is de-listed between clone-init and `execute()`
- **THEN** `execute()` reverts `MorphoMarketNotAllowed(marketId, registry)` and no vault funds move
