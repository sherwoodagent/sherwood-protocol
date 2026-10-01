# Tasks

## 1. Ceremony (V1-05)

- [x] 1.1 `DeployAll` run 2 pushes wiring into every lagging governor after Plan B, before the handoff.
- [x] 1.2 `_validateAll` (Complete) and `verify-robinhood.sh` assert per-governor wiring.
- [x] 1.3 Runbook step, including the open-proposal case.
- [x] 1.4 Regression test `test/audit-fixes/Deploy_ceremonyGapVault.t.sol`.

## 2. ETH/USD bound (V1-06)

- [x] 2.1 `ETH_USD_MAX_AGE = ETH_USD_HEARTBEAT + 2 hours`; feed pre-flight requires `> ETH_USD_HEARTBEAT`.
- [x] 2.2 Regression test `test/audit-fixes/WoodPoolFeed_ethUsdMaxAge.t.sol`; pre-flight test in `test/deploy/DeployWoodPoolFeed.t.sol`.

## 3. Documentation (V1-08, V1-09, V1-10, V1-11, V2-04)

- [x] 3.1 `docs/coverage.md` lock retention and containment qualifier; `ExposureLedger.setKNumerator` natspec.
- [x] 3.2 `docs/guardian-network.md` sibling referral; `docs/deployment-runbook.md` liquidity holders and feed recovery.
- [x] 3.3 `docs/fees.md` and the management-fee spec: whole-fund base.
