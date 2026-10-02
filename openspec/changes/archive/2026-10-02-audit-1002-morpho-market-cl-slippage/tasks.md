## 1. Morpho market id allowlist (FP-02)

- [x] 1.1 `TierRegistry`: appended mapping, `setMorphoMarketAllowed` (owner, event), `isMorphoMarketAllowed`; view on `ITierRegistry`.
- [x] 1.2 `MorphoSupplyStrategy`: market-id check at init and execute replaces the oracle and collateral counterparty checks; `MorphoMarketNotAllowed`.
- [x] 1.3 `ConcentratedLiquidityStrategy`: same for the Morpho leg at init and in `_requireCounterpartiesStillAllowed`.
- [x] 1.4 Registry mocks answer `isMorphoMarketAllowed`; real-registry fixtures grant the market id.
- [x] 1.5 Regression test `test/audit-fixes/MorphoMarket_marketIdAllowlist.t.sol`; `MorphoMarket_v104OracleBinding.t.sol` changed direction.
- [x] 1.6 `docs/deployment-runbook.md` Safe step and `docs/adapter-onboarding-checklist.md`.

## 2. CL settle slippage (FP-06)

- [x] 2.1 `MIN_SETTLE_SLIPPAGE_BPS = 50` at init; `_updateParams` reverts `ImmutableParam` for any change.
- [x] 2.2 Regression test `test/audit-fixes/CLStrategy_settleSlippageImmutable.t.sol`; ratchet tests changed direction.

## 3. Specs

- [x] 3.1 `audit-1001-containment` deployment-docs requirement and `concentrated-liquidity-strategy` tunables requirement amended in place.
