## ADDED Requirements

### Requirement: Each Morpho market's oracle and collateral are counterparty-allowlisted before its proposal

Morpho Blue market creation is permissionless for any oracle and collateral token, so the market a strategy clone names is only as sound as the oracle that prices it. `ConcentratedLiquidityStrategy._initialize` SHALL bind `marketParams.oracle` through `isCounterpartyAllowed` and re-check it at `execute()` and `rerange()`. `MorphoSupplyStrategy._initialize` SHALL bind `marketParams.oracle`, and `marketParams.collateralToken` unless it equals the vault asset, and re-check both at `execute()`. A no-collateral market (`oracle == address(0)`) SHALL be refused like any other unlisted oracle.

This is a PER-PROPOSAL obligation, not a ceremony step: the market is chosen per clone, so no deploy script can assert it. The registry owner SHALL call `setCounterpartyAllowed(<oracle>, true)` (and, for the supply strategy, `setCounterpartyAllowed(<collateral>, true)`) for each market a proposal is expected to use, before clone-init. Settle paths are NOT gated on it, so a demotion cannot strand the funds it is meant to protect.

#### Scenario: Proposal naming an unvouched oracle
- **WHEN** a CL or Morpho-supply clone names a market whose oracle is not counterparty-allowlisted
- **THEN** clone-init reverts `CounterpartyNotAllowed(oracle, registry)`

#### Scenario: Supply market with an unvouched collateral
- **WHEN** a Morpho-supply clone names a market whose collateral token is neither the vault asset nor counterparty-allowlisted
- **THEN** clone-init reverts `CounterpartyNotAllowed(collateralToken, registry)`

#### Scenario: Oracle demoted after init
- **WHEN** the oracle is demoted between clone-init and `execute()`
- **THEN** `execute()` reverts `CounterpartyNotAllowed(oracle, registry)` and no vault funds move
