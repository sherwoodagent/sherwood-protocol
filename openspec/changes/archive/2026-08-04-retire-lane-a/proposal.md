# Retire Lane A from v1 by deleting it

## Why

Lane A — mid-proposal instant entry/exit at router-priced live NAV — is being deferred
to V2 (issue #54). The repo owner has decided to DELETE it from v1 rather than
neutralize it, for one reason: keeping ~1,600+ lines of confirmed-dead code out of the
upcoming security audit. The decision is final and rests on two facts:

1. **`laneA` is structurally unreachable when no proposal is active.** `_laneState()`
   early-returns on `locked == false` (`SyndicateVault.sol:891-895`), so Lane A only
   ever fires mid-proposal. Exits outside a proposal are already instant against idle
   float via `_availableFloat()`, and mid-proposal exits fall back to the async Lane B
   queue, which exists and works.
2. **No `SyndicateVault` proxy is live** (owner-confirmed). Vault storage-layout
   compatibility is therefore NOT a constraint: fields are deleted outright, not
   replaced with same-slot placeholders.

The single most important invariant of this change: **deleting Lane A must not change
either surviving behaviour** — (a) exits outside a proposal remain instant against
idle float net of the queue reserve, and (b) mid-proposal LP flow routes to the Lane B
queue. Both are proven line-by-line in design.md ("Behaviour-preservation proof") and
pinned by the kept/added tests in tasks.md.

## What Changes

- **Delete `src/pricing/PriceRouter.sol`** (190 lines) and its interface file
  `src/interfaces/IPriceRouter.sol` (the `Position` struct, `IPriceAdapter`, and
  `IPriceRouter` — nothing survives; see design.md Q1).
- **`SyndicateVault.sol`**: delete `_laneState`, `_isLaneALocked` + `_laneALockPid`,
  `_laneBOnly`, `_strategyLiquidity`, `_pullFromStrategy`, `_getPriceRouter`, the
  Lane A branch of `_deposit`, the live-NAV term in `totalAssets`, the Lane-A-lock
  checks in `_update` and `requestRedeem`, and the whole exit-fee crystallization
  system: `instantExitFeeBps` / `MAX_INSTANT_EXIT_FEE_BPS` / `setInstantExitFeeBps`,
  `_exitPenalty`, `_exitFees` / `_exitFeesAt`, `_governorPerformanceCap`,
  `_crystallizedMgmt` / `_crystallizedPerf` + their views + `consumeCrystallized*`,
  the `previewRedeem` / `previewWithdraw` overrides and `previewExitFees`, and the
  Lane-A-only `_interimNetFlow` accumulator + `interimNetFlow()` view (the last two
  are additions to the original blast-radius analysis — see design.md "Errata").
- **`ISyndicateVault.sol`**: remove the matching functions, events
  (`ExitFeesCrystallized`, `InstantExitFeeUpdated`) and errors (`SharesLocked`,
  `InstantExitFeeTooHigh`, `UnwindShortfall`).
- **`SyndicateGovernor.sol`**: remove the `interimNetFlow()` term from settlement PnL
  and the two `consumeCrystallized*` releases in `_chargeManagementFee` /
  `_chargePerformanceFee`. No other governor code reads the deleted surface.
- **`IStrategy.sol` / `BaseStrategy.sol`**: remove `positions()`,
  `availableLiquidity()`, and `withdrawTo()` (and `OnDemandExitUnsupported`). All
  three have zero non-Lane-A consumers, so `Position` is deleted, not relocated
  (design.md Q1).
- **`SyndicateFactory.sol`**: `priceRouter` storage becomes a private deprecated
  placeholder (slot 7 must stay — the factory IS deployed and layout-golden-pinned);
  `setPriceRouter` + `PriceRouterUpdated` are removed;
  `ISyndicateFactory.priceRouter()` is removed. Factory layout golden regenerated in
  the same step (design.md Q2).
- **Scripts**: PriceRouter deploy/wire/validate/log blocks removed from
  `script/robinhood-mainnet/Deploy.s.sol` and `script/robinhood-testnet/DeployV2.s.sol`;
  stale `DeployPriceRouter` line removed from `script/deploy-vnet.sh` (design.md Q7).
- **Tests**: 7 files deleted outright, 4 files edited (definitive per-file list with
  test names in design.md Q6 — the prior analysis's claim that
  `test/fees/MgmtFeeAccrual.t.sol` is a full delete was WRONG; it covers the
  surviving management-fee spec and is kept with 4 Lane-A tests removed).
- **NOT deleted**: `src/pricing/WoodTwapOracle.sol` + `IWoodTwapOracle.sol`. They are
  independent of Lane A — wired exclusively into `ExposureLedger` for the WOOD/USD
  guardian-bond feed (import at `ExposureLedger.sol:6`, storage `:217`, consult
  `:526-533`, setter `:663`), with **zero** references to `PriceRouter`,
  `IPriceRouter`, `Position`, or `laneA` (verified by grep over both files). Any
  future "delete the pricing folder" instinct must stop here.

## Impact

- Affected specs: `syndicate-vault` (3 requirements removed, 5 modified, 1 added),
  `epoch-nav` (4 PriceRouter requirements removed; all ExposureLedger/WOOD-feed
  requirements untouched), `instant-exit-fees` (capability retired — all 8
  requirements removed; the one general requirement, "Deposits are not charged a
  fee", moves to `syndicate-vault`), `management-fee` (1 requirement modified:
  mid-proposal base-change scenarios removed), `deployment-docs` (2 requirements
  modified).
- Affected code: `src/SyndicateVault.sol` (~300 lines), `src/SyndicateGovernor.sol`,
  `src/SyndicateFactory.sol`, `src/interfaces/{ISyndicateVault,ISyndicateFactory,
  IStrategy,IPriceRouter}.sol`, `src/strategies/BaseStrategy.sol`,
  `src/pricing/PriceRouter.sol` (deleted), `script/` (3 files),
  `test/` (7 deletions, 4 edits, ~2,200 lines removed),
  `script/syndicate-factory-layout.golden.json` (regenerated).
- **No live-contract migration**: no vault proxy exists; the deployed factories
  (Base 8453 legacy, Robinhood testnet 46630 — see design.md "Deployment reality")
  keep slot 7 occupied and upgrade cleanly. Robinhood mainnet (4663) has no
  deployment yet.
- Interaction with #147 (`fix/issue-147-swap-adapter-allowlist`, lands FIRST): no
  conflict — this change does not touch `PortfolioStrategy.sol` at all (design.md Q8).
- Related: #148 (no storage-layout pin for `SyndicateVault`) is filed separately.
  This deletion is only safe BECAUSE no vault is live; once #148's pin exists, this
  class of change becomes mechanically verifiable rather than argued.
