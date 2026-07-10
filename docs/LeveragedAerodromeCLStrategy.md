# LeveragedAerodromeCLStrategy — spec & integration guide

A net-short leveraged Aerodrome Slipstream CL strategy with **strategy-serviced custody**:
users deposit and withdraw at the **strategy contract** directly (not the vault, not the
withdrawal queue), while holding standard vault ERC-20 shares.

This document serves two audiences:

- **Auditors** — architecture, storage, authorization, valuation, invariants, and known
  risks (first half, through *Audit focus areas*).
- **Frontend / backend integrators** — deposits, the three withdrawal entrypoints, state
  reads, events, and errors (second half, from *Integration overview*). Integrators only
  ever interact with the strategy contract.

Source: `src/strategies/LeveragedAerodromeCLStrategy.sol` + `LeveragedAeroManager.sol` +
`LeveragedAeroValuation.sol` + `LeveragedAeroFees.sol`. File references are relative to
the repo root and pinned to the code this document ships with — the code is authoritative
where any external description disagrees. Protocol-wide docs: https://docs.sherwood.sh/

## Architecture

The strategy is a **net-short leveraged Aerodrome Slipstream CL** position with a **strategy-serviced custody** deposit/redeem model. It ships as four contracts, split to fit the EIP-170 24,576-byte code cap:

| Contract | Path | Role | Kind |
|---|---|---|---|
| `LeveragedAerodromeCLStrategy` | `src/strategies/LeveragedAerodromeCLStrategy.sol` | Thin entrypoints + `nav()` + init + ERC-7201 `Layout`; owns everything that touches `vault()` / shares / fees | ERC-1167 clone |
| `LeveragedAeroManager` | `src/strategies/LeveragedAeroManager.sol` | All venue logic (supply/borrow/mint/stake/unwind/repay/swap), delegatecalled by the strategy | deployed `library` |
| `LeveragedAeroValuation` | `src/strategies/LeveragedAeroValuation.sol` | Oracle net-equity NAV; fail-closed | deployed `library` |
| `LeveragedAeroFees` | `src/strategies/LeveragedAeroFees.sol` | Streaming mgmt + HWM performance fee math (`pure`) | deployed `library` |

**Delegatecall / storage-corruption constraint.** `LeveragedAeroManager`'s `public` functions compile to `DELEGATECALL` from the clone, so `address(this)` and `_layout()` resolve to the clone. This requires the diamond-storage triplet to be **byte-identical** across strategy and manager:

- `Layout` struct — `src/strategies/LeveragedAerodromeCLStrategy.sol:172` vs `src/strategies/LeveragedAeroManager.sol:103` (also `RedeemRequest` at `:163` / `:94`).
- `STORAGE_SLOT = 0x405ae0b1…844900` — `src/strategies/LeveragedAerodromeCLStrategy.sol:220` vs `src/strategies/LeveragedAeroManager.sol:151` (identical literal, both flagged CORRUPTION-CRITICAL).
- `_layout()` assembly accessor — `:223` vs `:154`.

Any field reorder/insert in one file without the other silently reads/writes wrong slots. This is the single most important invariant to preserve; there is no compile-time cross-file check.

**Relationship to the vault (bypasses Lane A/B entirely).** Ordinary strategies return capital only at settle; this one custodies deposits/redeems itself for the position's indefinite life. It mints/burns vault shares directly through two vault hooks, moving **no assets** vault-side and computing **no price** vault-side:

```
                 depositor / redeemer
                        │  USDC / shares (approve→transferFrom)
                        ▼
        ┌───────────────────────────────────┐
        │  LeveragedAerodromeCLStrategy      │   nav() = oracle net-equity (fail-closed)
        │  (ERC-1167 clone, ERC-7201 Layout) │   fees crystallize here
        └───────────────────────────────────┘
          │ strategyMint/strategyBurn │ DELEGATECALL (shared slot)
          ▼ (supply only, no assets)  ▼
   ┌──────────────┐        ┌─────────────────────┐
   │ SyndicateVault│        │ LeveragedAeroManager │──► Moonwell (mUSDC collat,
   │  onlyActive-  │        │  (venue library)     │     borrow cbBTC+WETH)
   │  Strategy gate│        └─────────────────────┘──► Slipstream CL pool + AERO gauge
   └──────────────┘
```

`vault.totalAssets()` reads ~float-only during the (indefinite) proposal — Lane A is OFF (this `kind` is unregistered in the PriceRouter). Integrators must read `strategy.nav()`, never `previewRedeem` on the vault. The vault resolves its per-vault governor via `factory.governorOf(vault)` (no singleton governor).

## Position & venue flow

On-venue lifecycle (`_execute` → `LeveragedAeroManager.executeImpl`, `src/strategies/LeveragedAeroManager.sol:165`):
supply all strategy USDC to Moonwell mUSDC → `enterMarkets` → borrow cbBTC+WETH 50/50-by-USD at `targetLtvBps` → wrap native ETH → mint a Slipstream CL position on the borrowed legs → stake the NFT in the AERO gauge → `_assertHealthy`. CL pair is **cbBTC/WETH**; USDC is Moonwell collateral, not a pool leg. The short is the Moonwell debt; the LP re-adds long; net-short delta is an operator promise bounded by the LTV/health caps — **not asserted on-chain** (`docs spec §9`).

| Entrypoint | Strategy site | Caller | Gate |
|---|---|---|---|
| `execute()` | `BaseStrategy.execute` → `_execute` `:515` | vault (batch) | `onlyVault`, state `Pending` |
| `deposit(assets,minShares)` | `:705` | anyone (whitelisted depositor, enforced vault-side) | `nonReentrant`, state `Executed` |
| `deployIdle(amount,minLiq)` | `:727` | proposer | `onlyProposer`, `Executed` |
| `compound(minUsdcOut,minLiq)` | `:746` | proposer | `onlyProposer`, `Executed` |
| `rerange(minLiq0,minLiq1)` | `:776` | proposer | `onlyProposer`, `Executed` |
| `adjustLeverage(targetLtv,minLiq,minOut)` | `:792` | proposer | `onlyProposer`, `Executed`, `target≤maxLtv` |
| `deleverage(minOut)` | `:808` | **anyone** | `nonReentrant`, `Executed` only |
| `redeem(shares,minAssetsOut)` | `:828` | share owner (fast path) | `nonReentrant`, `Executed` |
| `requestRedeem` / `fulfillRedeem` / `cancelRedeem` / `emergencyRedeem` | `:955/:976/:991/:1008` | see Roles table | mixed |
| `settle()` | `BaseStrategy.settle` → `_settle` `:526` | vault (batch) | `onlyVault`, state `Executed` |
| `rescueToVault(token)` | `:1082` | proposer OR vault owner | `nonReentrant`, non-position token only |

There is **no `execute`-time flat-book bypass**: `nav()` reads the `tokenId==0` idle-USDC branch pre-deploy/post-settle (`:452`) and the oracle branch while a position is open.

## Storage layout

State lives in one **ERC-7201 namespaced** struct `Layout` at `STORAGE_SLOT` (`keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~0xff`), NOT sequential storage. Sequential slots hold only `BaseStrategy` fields (`_hcSelf`@0, `_vault`, `_proposer`, `_state`, `_initialized`; `src/strategies/BaseStrategy.sol:50-54`); the hashed diamond slot cannot collide with them.

- `Layout` groups: valuation config (token/venue/feed addresses + oracle params), venue addresses, risk params (`targetLtvBps`/`maxLtvBps`/`minHealthBps`/`maxSlippageBps`/`usdcCollateralFactorBps`), position state (`tokenId`/`posTickLower`/`posTickUpper`), fee params+state (`hwmPerShare`/`lastFeeAccrualTimestamp`/`protocolFeeOwed`), the appended `aeroUsdFeed`, and the trailing async-redeem queue (`nextRedeemRequestId` + `mapping(id⇒RedeemRequest) redeemRequests`). `src/strategies/LeveragedAerodromeCLStrategy.sol:172-217`.
- New fields are **append-only** (comments mark the L9 `aeroUsdFeed` and the queue as later appends) — required both for the manager byte-identity and because a nested mapping bars struct-return (hence the separate `LayoutView` mirror at `:233`, exposed via `layout()` `:276`).

**Instance creation.** Instances are **ERC-1167 clones**, not UUPS proxies — there is no upgrade path for a live strategy. Deploy: `StrategyFactory.cloneAndInit(template, vault, proposer, data)` → `Clones.clone(template)` → `initialize(vault, proposer, data)` (`src/StrategyFactory.sol:127`). Guards: template must be on the owner allowlist (`approvedTemplate`, `:59`/`:102`), `vault` registered, and `proposer == msg.sender` (`ProposerMustBeSender`, `:133`). `initialize` is one-shot (`BaseStrategy.sol:87`); the template itself is locked in its constructor (`:64`). `_initialize` (`:335`) validates and persists `InitParams` — the audit-relevant checks:

| Check | Site | Enforces |
|---|---|---|
| `usdc == vault.asset()` + 6 decimals | `:361-362` | unit-of-account = vault asset; `SHARES_VIRTUAL_OFFSET=1e6` hardcodes 6dp |
| `maxLtvBps < Moonwell CF` | `:367` | leverage cap below the collateral factor |
| `minHealthBps × maxLtvBps < 1e8` | `:371` | deleverage trigger LTV strictly above `maxLtvBps` (no grief-deleverage band, L4) |
| oracle-param bounds | `:379-383` | `maxDelay∈(0,7d]`, `grace≤1d`, `twapWindow∈(0,1d]`, `calmTicks∈(0,5000]`, `slippage∈(0,1000]` — a misconfig can't disable a guard |
| `aeroUsdFeed.decimals()==8` | `:357` | L9 floor scaling assumption |
| fee ceilings | `:388-389` | perf ≤ 1500 bps (`FeeConstants.MAX_PERFORMANCE_FEE_BPS`), mgmt ≤ 500 bps |

**Proposal setup (genesis).** The strategy lives inside one **indefinite** governor proposal, but the
per-vault governor ships with `maxStrategyDuration = 30 days` (factory default). Before `propose`, the
**vault owner must call `governor.setMaxStrategyDuration(3650 days)`** — the `ABSOLUTE_MAX_STRATEGY_DURATION`
ceiling; `onlyVaultOwner`, frozen once a proposal is open — or the long-lived `strategyDuration` fails
bounds validation. The proposal then clears the standard **24h voting window** (`MIN_VOTING_PERIOD`, a hard
floor) plus the guardian-review window before `execute()`. The governor is **per-vault** — resolve it via
`factory.governorOf(vault)`.

## Roles & authorization matrix

`proposer` = the agent that cloned/initialized the strategy (`BaseStrategy._proposer`). `owner` = the vault owner (`Ownable(vault).owner()`).

| Function | vault | governor | proposer | vault owner | anyone | State/pause gate | Auth site |
|---|:---:|:---:|:---:|:---:|:---:|---|---|
| `execute()` / `settle()` | ✅ | | | | | `onlyVault` + state | `BaseStrategy.sol:107/114` |
| `deposit` | | | | | ✅¹ | `Executed`; vault re-checks whitelist+pause | `:705`, hook `:921` |
| `deployIdle` | | | ✅ | | | `onlyProposer`,`Executed` | `:727` |
| `compound` | | | ✅ | | | `onlyProposer`,`Executed` | `:746` |
| `rerange` | | | ✅ | | | `onlyProposer`,`Executed` | `:776` |
| `adjustLeverage` | | | ✅ | | | `onlyProposer`,`Executed` | `:792` |
| `deleverage` | | | | | ✅ | `Executed` only (health-gated in impl) | `:808` |
| `redeem` (fast) | | | | | ✅¹ | `Executed`,`nonReentrant` | `:828` |
| `requestRedeem` | | | | | ✅¹ | `Executed` | `:955` |
| `fulfillRedeem` | | | ✅ | | | `onlyProposer`,`Executed` | `:976` |
| `cancelRedeem` | | | | | request owner only | any state | `:991` |
| `emergencyRedeem` | | | | | request owner only | `Executed`, after `FULFILL_WINDOW` | `:1008` |
| `rescueToVault` | | | ✅ | ✅ | | `NotProposerOrOwner`; non-position token | `:1082` |
| `updateParams` | | | (no-op) | | | `_updateParams` empty | `:1094` |
| `strategyMint(to,shares)` (vault) | | | | | active strategy | `onlyActiveStrategy` + `whenNotPaused` + depositor whitelist | `SyndicateVault.sol:921` |
| `strategyBurn(shares)` (vault) | | | | | active strategy | `onlyActiveStrategy`, **NOT** `whenNotPaused` | `SyndicateVault.sol:936` |

¹ `deposit`/`redeem`/`requestRedeem` are open to any caller, but `deposit`+`strategyMint` re-enforce the vault depositor whitelist (`_requireApprovedDepositor`, `SyndicateVault.sol:922`); a closed vault stays closed through the strategy.

**Vault-hook trust boundary.** The only thing standing between the two share hooks and arbitrary supply inflation is `onlyActiveStrategy` — `msg.sender == _activeStrategy()` (`SyndicateVault.sol:397`), which reads the active proposal's `strategy` field through the governor (`:484`). There is **no codehash pin** on the strategy (deliberate — the strategy is a governance-approved, guardian-reviewed clone; `docs spec §4/§13`). `strategyMint` mirrors `_deposit`'s guards (whitelist + `whenNotPaused`) and deliberately **omits** the Lane-A `_laneALockPid` (G1) stamp and `DepositsLocked` gate (stamping G1 would brick the strategy's own redeem — `_update` reverts `SharesLocked` and the lock never lifts under an indefinite proposal). `strategyBurn` is **deliberately not** `whenNotPaused`, so per-user exits proceed during a pause; governance settlement (`executeGovernorBatch`) still carries `whenNotPaused` and IS blocked by a pause.

## Valuation & fees

**`nav()`** (`src/strategies/LeveragedAerodromeCLStrategy.sol:449`) returns USDC (6dp), **net of `protocolFeeOwed`** (`:462-463`, floored at 0, never reverts on owed>gross):
- Flat book (`tokenId==0`): face value of strategy-held idle USDC only. **Vault float is excluded** (M2 deposit/redeem symmetry — the strategy never pays out float).
- Active position: `LeveragedAeroValuation.netEquityUsdc` (`:460`), which is fail-closed.

**`netEquityUsdc`** (`src/strategies/LeveragedAeroValuation.sol:107`): `NAV = idleStrategy + collateral + clLegs + idleLegs − debt`.
- **Calm-gate runs first** (`:113`, impl `:296`): reverts `CalmGateBreached` if `|spotTick − twapTick|` over `twapWindow` exceeds `calmDeviationTicks`. Deposit fails closed if the pool is being shoved.
- CL legs split at an **oracle-implied `sqrtP`** derived from the two Chainlink prices (`oracleSqrtPriceX96`, `:170`) — **not** the pool `slot0` tick, so the mint mark cannot be tick-shoved. Debt and idle-legs price on the same Chainlink basis, so the whole net-short book nets on one oracle.
- `collateral` = `mUSDC.balanceOf × exchangeRateStored / 1e18`; `debt` = `borrowBalanceStored(cbBTC/WETH) × price`. Both use Moonwell **last-accrued view** values (`nav()` is `view`) — bounded, conservative-leaning staleness (over-states NAV ⇒ fewer shares ⇒ protects stayers).
- `idleLegs` prices any out-of-position cbBTC/WETH (e.g. a `rerange` remainder) so a recenter is NAV-neutral.
- `assets ≤ debt ⇒ NonPositiveEquity` revert (`:141`); a manipulated price can only **deny** a deposit.

**Oracle hardening** (`src/libraries/ChainlinkReader.sol:14`): L2 sequencer up (`:19-20`), grace elapsed with `startedAt==0`/future-timestamp guards (`:27`), positive answer, `answeredInRound≥roundId`, `startedAt≠0`, `age≤maxDelay` (`:33-39`). Every consumer additionally asserts `decimals()==8` (`LeveragedAeroValuation.sol:256`, `LeveragedAeroManager.sol:921`) ⇒ `FeedDecimalsMismatch`.

**AERO compound floor (L9).** `compound` swaps claimed AERO→USDC through the Aerodrome v2 volatile pool. The manager derives `floor = mulDiv(aeroBal, AERO/USD_8dp, 1e20) × (1 − maxSlippageBps/1e4)` from a hardened AERO/USD read and **post-checks the measured fill** (`src/strategies/LeveragedAeroManager.sol:368-381`, `usdcOut < floor ⇒ BelowOracleFloor`). Effective bound = `max(minUsdcOut, floor)`; a stale AERO feed fail-closes (harvest deferred).

**`selfManagesFees() == true`** (`:505`). The governor skips `_distributeFees` **entirely** for this proposal (protocol + guardian + agent + management), so the strategy self-collects. Consequence: the **protocol** fee is collected strategy-side — its rate is read live from `ProtocolConfig` (via `vault.factory().protocolConfig()`, `_protocolFeeBps()` `:638` / `_protocolFeeRecipient()` `:644`), NOT from the governor.
- **Management** (streaming) + **performance** (HWM per-share) crystallize by **minting fee-shares** to `feeRecipient` via `strategyMint` (`_crystallizeFees`, `:553`; math in `LeveragedAeroFees.crystallize`, `src/strategies/LeveragedAeroFees.sol:199`). HWM seeds on first cycle (no phantom fee, `:140`); crystallize is on the **pre-action** NAV, before USDC is pulled (phantom-fee fix).
- **Protocol slice** — the rate comes live from `ProtocolConfig` (`_protocolFeeBps()` `:638`), taken off the **gross gain above HWM first** (`LeveragedAeroFees.sol:153`), accrued as a USDC liability `protocolFeeOwed` (never minted as shares — treasury must receive USDC), and **netted out of `nav()`**. HWM still advances to the gross peak (no double-charge). Discharged where USDC flows: `compound` skim (`:755`), `_settle` (`:533`), and the async redeem skim `_dischargeRedeemSkim` (`:1061`). The fast-path `redeem` takes **no** skim — `nav()` is already net, so pricing at `f×navNet` preserves stayers (a skim would double-charge).
- Crystallize is **best-effort** on user-exit paths (`_crystallizeBestEffort`, `:666`): a fee-mint revert (paused vault / de-whitelisted recipient) or the near-unreachable `ProtocolConfig` read (`_protocolFeeBps`/`_protocolFeeRecipient`) rolls back **only** the crystallize (HWM + timestamp + owed together) and emits `FeeCrystallizeDeferred`; the exit proceeds. `compound`/`_settle` read `ProtocolConfig` **un-try'd** and hard-revert on the same failure (asymmetry is intentional).

## Invariants

Properties an auditor should try to break (invariant suite: `test/invariants/LeveragedAeroCL.invariant.t.sol`, handler `test/invariants/handlers/LeveragedAeroCLHandler.sol`):

1. **Stayer per-share NAV non-decreasing** across random deposit/redeem/rerange/compound/adjust/deleverage/shove — `invariant_redeemConservation` (`:103`; arbiter is the no-calm-gate oracle NAV, so pool shoves can't mask a leak). Proportional redeem is proven exactly stayer-neutral: `navAfter == (1−f)·navBefore` (removes fraction `f` of *every* leg; `redeemUnwindImpl`, `LeveragedAeroManager.sol:214`; proof `LeveragedAeroCL.redeem.fork.t.sol::test_redeem_partialUnderIL_afterRerange_noStayerSkim` + unit twin `test_anchor_conservation_postRerangePartialRedeemUnderIL`). The stayers' `(1−f)` share of any pre-existing idle leg is reserved before the residual sweep (`_stayerLeg` `:903`, budget caps in `_redeemRepayFromCollected` `:999`).
2. **Health ≥ `minHealthBps` / LTV ≤ `maxLtvBps` after every position op** — `invariant_health` (`:109`); enforced by `_assertHealthy` (`LeveragedAeroManager.sol:1096`: LTV check `:1120`, Moonwell `getAccountLiquidity` shortfall belt `:1124`) at the tail of execute/deployIdle/compound/rerange/adjustLeverage; plus `fastRedeemImpl`'s pre-withdraw LTV gate (`:312-316`).
3. **`totalSupply` conserved across mint/burn** — `invariant_totalSupplyConserved` (`:115`). Every `strategyMint` (deposit + fee) has a matching `strategyBurn` on exit; supply changes only via the hooks.
4. **No exfil** — `invariant_noExfil` (`:137`): the strategy only ever pays `vault()` or a redeeming user. `rescueToVault` target is hardcoded to `vault()` (`:1090`), never caller-supplied, and reverts `CannotRescuePositionToken` for usdc/cbBTC/weth/mTokens/AERO (`:1089`).
5. **`redeem` never over-pays.** Fast path pays `mulDiv(shares, navNet, supply)` rounded **down** (`:846`); `assetsOut==0 ⇒ ZeroAssetsOut` (`:851`) blocks burn-for-zero. Async path pays the gross proportional unwind minus the pro-rata protocol skim, min-out enforced (`:1039-1043`).
6. **`protocolFeeOwed` monotonic until discharged.** Increases only in `_crystallizeFees` (`:583`); decreases only at the three discharge points paying USDC out (`:538`, `:759`, `:1070`). If `protocolFeeRecipient == 0`, discharge is skipped and the liability persists (`nav()` stays net) until a recipient exists.
7. **`emergencyRedeem` deadman** requires `msg.sender == request.owner` and `block.timestamp > requestedAt + FULFILL_WINDOW` (2 days) with `!settled` (`:1011-1013`); `settled` is a single-shot double-spend guard set on fulfill/cancel/emergency.
8. **`deleverage` monotone recovery.** Reverts `HealthyNoDeleverage` when debt==0 or health ≥ min (`LeveragedAeroManager.sol:475/478`); on success asserts health **strictly improved** and Moonwell shortfall cleared/reduced (`:490-494`).
9. **No phantom fee**: crystallize on pre-deposit NAV ⇒ zero perf fee on idle USDC that just landed (`LeveragedAeroFees` seed/ordering `:136-169`; deposit ordering `:705-721`).
10. **Deposit share-inflation guard**: `navNet==0 && supply>0 ⇒ NavUnpriceable` (`:717`); first deposit (`supply==0`) legitimately allowed.

## Audit focus areas & known risks

- **Delegatecall layout drift** — the top structural risk. `Layout`/`STORAGE_SLOT`/`_layout()`/`RedeemRequest` byte-identity across `LeveragedAerodromeCLStrategy.sol` and `LeveragedAeroManager.sol` is enforced only by discipline/comments. **Coverage gap:** no test byte-compares the two layouts or asserts non-corruption after a manager delegatecall — the offline harnesses only exercise the shared slot indirectly. Verify field-by-field on any change.
- **Deposit-side oracle-lag MEV (accepted, beta).** The oracle-`sqrtP` basis defeats tick-shove mints, but a depositor front-running a pending Chainlink update can skim up to the feed deviation threshold (mint at stale-low NAV, redeem proportionally after). Bounded by `maxDelay` + calm-gate + un-shoveable basis. Mainnet hardening (entry/exit fee or short cooldown) deferred; the vault Lane-A G1 lock is deliberately NOT used (would brick redeem).
- **Oracle manipulation surface generally.** `nav()` prices deposits and the fast `redeem`; a wrong sign/decimal/overflow mis-mints. Focus: `oracleSqrtPriceX96` low-bound guard and the "high bound is unreachable because `mulDiv` overflow-reverts first" argument (`LeveragedAeroValuation.sol:170-183`); the calm-gate TWAP rounding (`:307-309`); `_usdcValue` decimal scaling (`:274-284`). The load-bearing shove-immunity contrast is `LeveragedAeroValuation.fork.t.sol::test_a_tickShove_oracleNavInvariant_naiveNavMoves` (oracle NAV ≤0.5% vs naive-slot0 NAV >2% under the same shove).
- **LTV-gate bypass attempts.** Fast `redeem` predicts post-withdraw LTV on pre-withdraw prices against the collateral-funded remainder only (`fastRedeemImpl` `:308-316`), with `_assertHealthy` as belt. `deleverage` is permissionless and repays only to `minHealthBps × 1.05` (a recovery op, not the full max-LTV gate) — an adverse move can leave LTV above max legitimately.
- **Donation / inflation on strategy-side mint.** `nav()` excludes vault float (M2) but **counts** strategy-held idle USDC and out-of-position legs (`:456`, valuation `:135-136`); consider direct-donation griefs to the strategy address inflating `nav()` and the share price for a pending depositor. `NavUnpriceable` guards the `navNet==0` inflation case only.
- **IL-shortfall handling on full redeem.** A 100%-of-supply exit with zero idle sizes one oracle-priced collateral→debt swap (`redeemUnwindImpl` full branch `:238-255`, `_settleShortfall`); fail-safe (no stayers to harm) but the lone oracle dependency on the otherwise oracle-free proportional path. Partial redeems cap IL cover at the redeemer's own budget so they can never spend stayer idle (`:263-270`).
- **`deleverage` oracle-staleness residual (accepted, §13).** Reads Chainlink → a stale our-feed fail-closes; Moonwell liquidation uses Moonwell's own oracle, so a window where our feed is stale but Moonwell's is fresh is an accepted early-warning gap.
- **`compound` reward swap** routes through a hardcoded Aerodrome v2 router/factory (`LeveragedAeroManager.sol:85-87`); the L9 floor is the honesty-independent guard. A deferred follow-up (AERO/USD min-out passed to the router too) is noted non-blocking.
- **`selfManagesFees()` trust (accepted, beta).** Snapshotted at propose (closes TOCTOU) but `propose` has no on-chain strategy allowlist — a strategy returning `true` to dodge governor fees is stopped only by guardian review + owner veto. For this template it's `pure→true` and self-collects protocol fee. Hardening (governor self-fee registry) deferred.
- **Deferred crystallize = fee-shifting, not fee-delaying (accepted, §13 r5-3).** On a fee-mint revert the whole crystallize rolls back; exits during the window escape their share of pending fees (borne by fee recipient + window depositors, stayers neutral). Trigger is owner-controlled (pause / de-whitelist recipient) — a trusted-owner misconfig leak, not permissionless theft. `FeeCrystallizeDeferred` is the signal.
- **Pending AERO not in NAV (accepted).** Depositing while emissions are unclaimed slightly under-prices the deposit (dilutes stayers by pro-rata pending AERO). Operator mitigates by `compound`-before-open.
- **Governance blast radius (acknowledged).** `ABSOLUTE_MAX_STRATEGY_DURATION` is a governor `public constant` (3650 days, `src/GovernorParameters.sol:39`) shared by every per-vault governor (they share one implementation behind `GovernorBeacon`). Each vault's owner sets *that vault's* `maxStrategyDuration` (default 30 days) up to this ceiling; a multi-year value keeps that vault's owner emergency exits dormant for the position's life. Per-vault duration cap is the deferred mainnet hardening.
- **Rescue dormancy.** `vault.rescueERC20/721/Eth` revert while `redemptionsLocked()` (forever true under the indefinite proposal); tokens sent directly to the **vault** address are recoverable only by settling or a vault UUPS upgrade. `strategy.rescueToVault` covers stray tokens sent to the **strategy**.

---

## Integration overview

`LeveragedAerodromeCLStrategy` is a **strategy-serviced-custody** vault strategy. Integrators talk to the
**strategy contract**, not to the vault's `deposit`/`redeem` or the withdrawal queue.

Mental model:

- **Users hold vault ERC-20 shares** (12 dp for a 6 dp USDC asset). The strategy never issues its own
  token — it mints/burns *vault* shares on your behalf via `vault.strategyMint` / `vault.strategyBurn`
  (`src/SyndicateVault.sol:921`, `:936`). Your on-chain balance is `vault.balanceOf(user)`.
- **Deposits are priced at oracle net-equity NAV** (`nav()`, USDC 6 dp), fail-closed: a stale feed or a
  shoved pool *denies* the deposit, it can never mint cheap shares (`src/strategies/LeveragedAeroValuation.sol`).
- **Exits have three entrypoints** picked by size / oracle-liveness / proposer-liveness (below).
- The strategy runs under an **indefinite governance proposal** — the vault stays "locked" forever, so the
  vault's own `deposit`/`redeem`/`withdraw` and the withdrawal queue are **unavailable** (`maxRedeem == 0`
  while locked; Lane A is off for this strategy `kind`). `vault.totalAssets()` reflects **vault float only**
  (≈ 0) — do NOT use it or `vault.previewRedeem`. Read `strategy.nav()` + `vault.totalSupply()` instead.

```
DEPOSIT
  user --approve USDC--> strategy
  user --deposit(assets,minShares)--> strategy
     strategy: crystallize fees → nav() price → pull USDC (idle) → vault.strategyMint(user, shares)
  user receives VAULT shares (12dp).  USDC sits idle until proposer calls deployIdle().

EXIT A — fast redeem (everyday, oracle-priced, LTV-gated)
  user --approve shares--> strategy --redeem(shares,minOut)-->
     price shares×nav/supply → fund from the redeemer's f×idle share then Moonwell collateral for the remainder (NO LP touch, NO debt repay)
     → if post-withdraw LTV > maxLtv: revert FastRedeemExceedsLtv → route user to EXIT B
     → else pay USDC + vault.strategyBurn(shares)

EXIT B — async request → proposer fulfill (oracle-FREE proportional unwind)
  user --approve shares--> strategy --requestRedeem(shares,minOut)--> id   (shares escrowed, NO price freeze)
  backend deleverages (adjustLeverage) then proposer --fulfillRedeem(id)--> pays owner + burns
  (user may --cancelRedeem(id)--> to reclaim escrowed shares any time before settle)

EXIT C — emergency deadman (oracle-free, trustless)
  user --requestRedeem--> id ; wait FULFILL_WINDOW (2 days) ; user --emergencyRedeem(id,minOut)--> self-serve
```

---

## Deposits

```solidity
function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares);
```
`src/strategies/LeveragedAerodromeCLStrategy.sol:705`

| Param | Unit | Meaning |
|---|---|---|
| `assets` | USDC, **6 dp** | USDC to deposit. |
| `minShares` | vault shares, 12 dp | Slippage floor; reverts `InsufficientShares` if the mint would be below it. |
| → `shares` | vault shares, 12 dp | Minted to `msg.sender`. |

**Asset / decimals** — asset is USDC, 6 dp. Enforced at init: `asset() == usdc` and `usdc.decimals() == 6`
(`:361-362`). Share offset is `1e6` matching the vault's `_decimalsOffset()`.

**Approvals** — `usdc.approve(strategy, assets)` (or Permit2). USDC is pulled with `safeTransferFrom`.

**Preconditions**
- Strategy `state() == Executed` else `NotExecuted` (`:706`).
- Oracle must price: `nav()` runs the full fail-closed valuation. Any staleness / sequencer-down /
  calm-gate breach / non-positive-equity **reverts the deposit**.
- Vault gates re-checked inside `strategyMint` (`:921`): `whenNotPaused` (else `EnforcedPause`) and the
  depositor whitelist `_requireApprovedDepositor(to)` (else `NotApprovedDepositor`). A closed-deposit vault
  stays closed through the strategy.

**Share pricing** — `shares = mulDiv(assets, totalSupply + 1e6, navNet + 1)`, rounds **down**
(`:718`). `navNet` = pre-deposit `nav()` minus the fresh protocol-fee slice the crystallize accrued; fees
are crystallized on the *pre-deposit* NAV first (phantom-fee guard). First deposit (`supply == 0`) is allowed
at `navNet == 0`; a `navNet == 0` with `supply > 0` reverts `NavUnpriceable` (worthless book, holders present).

**Voting power (self-delegation)** — on a depositor's **first** mint `strategyMint` auto-delegates them to
themselves (`if (delegates(to) == 0) _delegate(to, to)`, `SyndicateVault.sol` `strategyMint` body), so a
deposit silently activates the holder's vault ERC20Votes voting power. Subsequent mints don't re-delegate;
a holder who has already delegated elsewhere is left as-is.

**Events** — no strategy-specific deposit event. The mint emits ERC-20 `Transfer(address(0), user, shares)`
from the **vault**. A perf/mgmt fee mint (if any) emits a second `Transfer(0, feeRecipient, feeShares)`; a
deferred crystallize emits `FeeCrystallizeDeferred(0, navPre)`.

**Reverts**

| Selector | Cause |
|---|---|
| `NotExecuted` | strategy not in `Executed` state |
| `NavUnpriceable` | `navNet == 0` while `supply > 0` |
| `InsufficientShares` | `shares < minShares` |
| `NotApprovedDepositor` | recipient not whitelisted (closed vault) |
| `EnforcedPause` | vault paused |
| `NonPositiveEquity` / `CalmGateBreached` / `StaleOracle` / `SequencerDown` / `GracePeriodNotOver` / `FeedDecimalsMismatch` | oracle fail-closed inside `nav()` |

**viem**
```ts
await walletClient.writeContract({ address: usdc, abi: erc20Abi, functionName: 'approve', args: [strategy, assets] });
const { result: shares } = await publicClient.simulateContract({
  address: strategy, abi: stratAbi, functionName: 'deposit',
  args: [assets, minShares], account });
await walletClient.writeContract({ address: strategy, abi: stratAbi, functionName: 'deposit', args: [assets, minShares], account });
```
**cast**
```bash
cast send $USDC "approve(address,uint256)" $STRATEGY 1000000000 --private-key $PK
cast send $STRATEGY "deposit(uint256,uint256)" 1000000000 0 --private-key $PK   # 1000 USDC, minShares=0
```

---

## Withdrawals — three entrypoints

### A. Fast `redeem` (oracle-priced, LTV-gated)

```solidity
function redeem(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 assetsOut);
```
`src/strategies/LeveragedAerodromeCLStrategy.sol:828`

The everyday exit. Pays `shares × navNet / supply` (rounds down), funded from **the redeemer's proportional
`f×idle` share of idle USDC first (`f = shares/supply`), then Moonwell mUSDC collateral for the remainder —
no LP touch, no debt repay** (`fastRedeemImpl`, manager `:298`). Only `f×idle` is drawable, NOT the whole
idle balance — the stayers' `(1−f)×idle` is reserved, mirroring the proportional async path. Requires
`vault.approve(strategy, shares)` (shares pulled via `safeTransferFrom`, then `strategyBurn`).

**Oracle-dependent, fail-closed** — `nav()` reverts on a down oracle; the caller then routes to `requestRedeem`.

**LTV gate** — because collateral shrinks while debt is unchanged, the withdraw *raises* LTV. The manager
predicts post-withdraw LTV on pre-withdraw prices; if it breaches `maxLtvBps` it reverts
`FastRedeemExceedsLtv(ltvBps, maxLtvBps)` (`:315`). This means "collateral can't fund this size without a
deleverage" → **route the user to `requestRedeem`**. A belt `_assertHealthy()` runs after. Only if the
redeemer's `f×idle` share alone covers the payout are collateral + the LTV gate skipped; because that share
is a small fraction of idle, even a modestly-sized redeem usually reaches collateral and the LTV gate.

**Fees** — none skimmed on this path: `nav()` is already net of `protocolFeeOwed`, so pricing at `navNet`
provably preserves stayers' per-share. A pending mgmt/perf crystallize still mints fee-shares first.

**Reverts**: `NotExecuted`, `InsufficientAssetsOut` (`assetsOut < minAssetsOut`), `ZeroAssetsOut` (payout
floors to 0 — dust shares or `navNet == 0`; shares are NOT burned), `FastRedeemExceedsLtv`, `UnhealthyPosition`
(belt), oracle fail-closed reverts, ERC-20 revert if unapproved.

**Events**: on the vault, **two** ERC-20 transfers — `Transfer(user, strategy, shares)` (the `safeTransferFrom`
pull) then `Transfer(strategy, 0, shares)` (the `strategyBurn`; the burn's `from` is the **strategy**, which
holds the pulled shares, **never** the user). There is **no** `Transfer(user → 0)` and — on the fast path — **no
strategy-side event at all**; only these two vault Transfers. Optional `FeeCrystallizeDeferred(1, navPre)`.

**Preview first** (`:899`):
```solidity
function previewRedeem(uint256 shares) external view returns (uint256 assetsOut, bool fastOk);
```
`fastOk == false` → the fast path would revert; pre-route to `requestRedeem`. `fastOk` is **advisory** — the
manager's on-chain LTV gate is authoritative. Returns `(0, false)` when the oracle is down or payout floors to 0.

### B. Async `requestRedeem` → proposer `fulfillRedeem` (oracle-free)

```solidity
function requestRedeem(uint256 shares, uint256 minAssetsOut) external nonReentrant returns (uint256 id);      // :955
function fulfillRedeem(uint256 id) external onlyProposer nonReentrant;                                          // :976
function cancelRedeem(uint256 id) external nonReentrant;                                                        // :991
```

**Who calls what** — the *user* calls `requestRedeem` (escrows shares in the strategy NOW; requires
`vault.approve`). The **proposer/backend** deleverages (`adjustLeverage`) so the unwind's IL self-funds, then
calls `fulfillRedeem(id)` which pays `request.owner`. `fulfillRedeem` is **not** owner/user-callable — that
would resurrect the demoted oracle-free path.

**Pricing (oracle-free)** — `_proportionalRedeem` removes exactly fraction `f = shares/supply` of *every*
leg (idle USDC, CL liquidity, each debt, collateral), so the output equals `f × NAV` without computing an
oracle price (`redeemUnwindImpl`, manager `:214`). **No price is frozen at request time** — escrowed shares
keep bearing PnL until fulfill, so `cancelRedeem` is not a free look-back option. Stayers keep `(1−f)` of
every leg under any price move.

**Cancel** — request owner only, callable in **any** strategy state; returns the escrowed shares. Reverts
`NotRequestOwner` / `RequestSettled`. A request outstanding at proposal settle stays cancellable so the owner
can exit normally.

**Latency model** — fulfillment is a backend action (minutes typically). There is no on-chain deadline for
the proposer; the user's trustless fallback is `emergencyRedeem` after `FULFILL_WINDOW` (2 days).

**Detecting fulfillment (backend)** — index these strategy events:
- `RedeemRequested(id, owner, shares)` — on `requestRedeem`.
- `RedeemFulfilled(id, owner, assetsOut)` — request paid; `assetsOut` USDC sent to `owner`, shares burned.
- `RedeemCancelled(id, owner, shares)` — escrow returned.
Poll `strategy.redeemRequest(id).settled` for terminal state.

**Reverts**: `requestRedeem` → `NotExecuted`, ERC-20 if unapproved. `fulfillRedeem` → `NotProposer`,
`NotExecuted`, `RequestSettled`, `ZeroAssetsOut` (payout nets to 0 — escrow left intact, recover via
`cancelRedeem`), `InsufficientAssetsOut`.

### C. `emergencyRedeem` (deadman, trustless)

```solidity
function emergencyRedeem(uint256 id, uint256 minAssetsOut) external nonReentrant returns (uint256 assetsOut); // :1008
```

The request **owner** may self-fulfill via the same oracle-free proportional unwind once
`block.timestamp > requestedAt + FULFILL_WINDOW`. **`FULFILL_WINDOW = 2 days`** (verified constant,
`:90`). Covers the only truly stuck case (oracle down **and** backend dead); a live backend resolves via
normal `fulfillRedeem` even with the oracle down. `minAssetsOut` is a **fresh** arg (the stored one may be
stale after 2 days).

**Frontend** — surface an "Emergency withdraw" affordance only when a user has an unsettled request older
than 2 days. Before the window: `FulfillWindowOpen`.

**Reverts**: `NotExecuted`, `NotRequestOwner`, `RequestSettled`, `FulfillWindowOpen`, `ZeroAssetsOut`,
`InsufficientAssetsOut`. Emits `RedeemEmergency(id, owner, assetsOut)`.

### Decision table — user wants out → which path

| Condition | Path |
|---|---|
| Oracle live, size small enough that post-withdraw LTV ≤ `maxLtvBps` (`previewRedeem.fastOk == true`) | **A** `redeem` (instant) |
| `previewRedeem.fastOk == false` (large size / would breach LTV) or `redeem` reverted `FastRedeemExceedsLtv` | **B** `requestRedeem` → proposer `fulfillRedeem` |
| Oracle down / `nav()` reverts | **B** `requestRedeem` (oracle-free) |
| Request open > 2 days, proposer not fulfilling (dead backend) | **C** `emergencyRedeem` |
| Changed mind before fulfillment | `cancelRedeem` |

---

## Reading state (frontend data needs)

| View | Signature | Units | Notes / cadence |
|---|---|---|---|
| NAV | `nav() → uint256` (`:449`) | USDC 6 dp | Net of `protocolFeeOwed`. Reverts (fail-closed) when oracle down / calm-gate breached. Wrap in try/catch off-chain. Refresh per block / on-demand. |
| Share price | derive: `nav() / vault.totalSupply()` | USDC 6 dp per 12 dp share | **Use `strategy.nav()` + `vault.totalSupply()`, NOT `vault.totalAssets()`/`vault.previewRedeem`** — the vault is locked, `totalAssets()` is float-only (≈0). The strategy is the sole backer of the shares (vault float excluded from NAV, distributed to all shares only at settle, which never happens under the indefinite proposal). |
| Redeem quote | `previewRedeem(shares) → (assetsOut, fastOk)` (`:899`) | USDC 6 dp, bool | Mirrors executed `redeem` incl. pending fee. `(0,false)` when unpriceable. Apply small slippage tolerance for `minAssetsOut` (mgmt fee accrues with `dt`). |
| LTV / health basis | `previewCollateralDebt() → (collateralUsdc, debtUsdc)` (`:940`) | USDC 6 dp | **Self-only** (`OnlySelf` guard) — used internally by `previewRedeem`; NOT frontend-callable. To show LTV/health, read Moonwell markets directly, or use `previewRedeem(shares).fastOk` as the routing signal. Risk caps live in `layout().maxLtvBps` / `.minHealthBps`. |
| Pending request | `redeemRequest(id) → RedeemRequest{owner, shares, minAssetsOut, requestedAt, settled}` (`:317`) | — | `requestedAt` (uint40) + 2 days = emergency-eligible time. `nextRedeemRequestId` = next id via `layout()`. |
| Fee params / risk / config | `layout() → LayoutView` (`:276`) | mixed | `managementFeeBps`, `performanceFeeBps` (bps), `feeRecipient`, `hwmPerShare` (1e18 WAD), `protocolFeeOwed` (USDC 6 dp), `targetLtvBps`/`maxLtvBps`/`minHealthBps`/`maxSlippageBps` (bps), token/venue/feed addresses. One call. |
| Paused | `vault.paused() → bool` | — | Deposits blocked when true; exits still work (burn not pause-gated). |
| Whitelist | `vault.isApprovedDepositor(addr)` / `vault.openDeposits()` | — | Gate the deposit UI. |
| Lifecycle | `state() → {Pending,Executed,Settled}` (`BaseStrategy:142`) | enum | Deposit/redeem require `Executed`. |
| Protocol-fee liability | `layout().protocolFeeOwed` | USDC 6 dp | Already subtracted inside `nav()`; discharged in redeem/compound/settle. |

---

## Events & indexing

| Event | Source | Topics (indexed) | Emitted when | Index to reconcile balances? |
|---|---|---|---|---|
| `Transfer(from, to, value)` | **vault** ERC-20 | from, to | `strategyMint` (from `0`) on deposit + fee mint; every user exit emits **two** — `Transfer(user, strategy, shares)` (the share pull) then `Transfer(strategy, 0, shares)` (`strategyBurn`), so the burn's `from` is the **strategy**, never the user | **Yes — authoritative for user share balances.** Deposits/burns have no strategy-specific event; the fast path fires **only** these two vault Transfers (no strategy event). |
| `RedeemRequested(id, owner, shares)` | strategy `:93` | id, owner | `requestRedeem` | Yes — open async requests / escrow. |
| `RedeemFulfilled(id, owner, assetsOut)` | strategy `:94` | id, owner | `fulfillRedeem` | Yes — request paid + shares burned. |
| `RedeemCancelled(id, owner, shares)` | strategy `:95` | id, owner | `cancelRedeem` | Yes — escrow returned. |
| `RedeemEmergency(id, owner, assetsOut)` | strategy `:96` | id, owner | `emergencyRedeem` | Yes — deadman exit paid. |
| `FeeCrystallizeDeferred(op, navPre)` | strategy `:103` | (none) | best-effort crystallize reverted (`op`: 0 deposit, 1 fast redeem, 2 fulfill/emergency) | Monitoring only — fee deferred, op proceeded. |

Reconciliation: a deposit is a vault `Transfer(0, user, shares)` with **no** matching strategy event — pair
it with the strategy `deposit` call trace or just trust the vault `Transfer`. Every exit burns via
`strategyBurn`, so the burn is always `Transfer(strategy, 0, shares)` — an indexer keyed on `Transfer(from=user,
to=0)` will **miss every redeem** (the burn's `from` is the strategy, not the user). Key on `Transfer(from=user,
to=strategy)` (the share pull) or `Transfer(from=strategy, to=0)` (the burn) instead. Async exits **also** fire
a strategy `Redeem*` event (on fulfill/emergency), but the fast `redeem` fires **no** strategy event — only the
two vault Transfers.

---

## Errors

| Selector | Path | When | Client handling |
|---|---|---|---|
| `NotExecuted` | all | strategy not `Executed` (or settled) | Hide deposit/redeem UI until `state()==Executed`. |
| `NavUnpriceable` | deposit | `navNet==0` with holders present | Rare (worthless book) — surface "temporarily unpriceable". |
| `InsufficientShares` | deposit | mint < `minShares` | Loosen slippage / re-quote. |
| `NotApprovedDepositor` | deposit (vault) | recipient not whitelisted | Gate UI on `isApprovedDepositor`/`openDeposits`. |
| `EnforcedPause` | deposit (vault) | vault paused | Disable deposits; keep exits enabled. |
| `StaleOracle` / `SequencerDown` / `GracePeriodNotOver` (`src/libraries/ChainlinkReader.sol:10-12`) | deposit, fast redeem | Chainlink stale / L2 sequencer down / grace window | Route redeems to `requestRedeem`; block deposits until feeds recover. |
| `CalmGateBreached` | deposit, fast redeem | pool spot vs TWAP deviated | Transient — retry shortly / route to async. |
| `NonPositiveEquity` | deposit, fast redeem | book underwater (assets ≤ debt) | Block deposit; async exit still works. |
| `FeedDecimalsMismatch` / `OracleSqrtPriceOutOfRange` / `InvalidConfig` | deposit, fast redeem | misconfigured/degenerate feed | Ops issue — surface generic error. |
| `InsufficientAssetsOut` | all redeems | payout < `minAssetsOut` | Loosen slippage / re-quote via `previewRedeem`. |
| `ZeroAssetsOut` | all redeems | payout floors to 0 (dust / owed ≥ book) | Shares NOT burned; increase size or `cancelRedeem`. |
| `FastRedeemExceedsLtv(ltvBps, maxLtvBps)` | fast redeem | post-withdraw LTV > cap | **Route to `requestRedeem`.** |
| `UnhealthyPosition(ltvBps, limitBps)` | fast redeem (belt) | health assert after withdraw | Route to async. |
| `NotProposer` | `fulfillRedeem` | non-proposer called | Backend/proposer only. |
| `RequestSettled` | fulfill/cancel/emergency | request already terminal | Refresh `redeemRequest(id).settled`. |
| `NotRequestOwner` | cancel/emergency | caller ≠ request owner | Only the request owner may cancel/emergency. |
| `FulfillWindowOpen` | emergency | before `requestedAt + 2 days` | Show countdown; hide until eligible. |

---

## Gotchas

- **Burn works during pause, deposit does not.** `strategyMint` is `whenNotPaused` (deposits + fee mints
  blocked on pause); `strategyBurn` is deliberately **not** pause-gated so per-user exits proceed during an
  incident (`src/SyndicateVault.sol:921`, `:936`). Governance settlement still respects pause.
- **Do not read `vault.totalAssets()` / `vault.previewRedeem`.** The vault is permanently locked under the
  indefinite proposal; Lane A is off for `kind = keccak256("LEVERAGED_AERO_CL")`, so `totalAssets()` is
  vault-float-only (≈ 0) and `maxRedeem == 0`. Use `strategy.nav()` + `vault.totalSupply()`.
- **Do not read `vault.maxDeposit` / `vault.maxMint` either.** Both report `type(uint256).max` while the vault
  is locked (active proposal) or the caller isn't whitelisted — only `paused()` makes them return 0 (a
  deliberate EIP-170 trade-off from Sherlock run #2 #12; adding the lock/whitelist checks busts the code cap,
  `src/SyndicateVault.sol:691`). A 4626-generic frontend that gates on `maxDeposit > 0` would wrongly show
  deposits open; poll the vault's own governor — resolve it via `factory.governorOf(vault)`, then call the
  no-arg `governor.getActiveProposal()` — plus `vault.isApprovedDepositor(addr)` instead (and
  route deposits through `strategy.deposit`, never `vault.deposit`).
- **Oracle staleness reverts deposits and the fast redeem.** Both call `nav()` fail-closed. Always offer
  `requestRedeem` (oracle-free) as the fallback and try/catch `nav()`/`previewRedeem` off-chain.
- **LTV gate routing.** `redeem` is collateral-funded and *raises* LTV; large exits revert
  `FastRedeemExceedsLtv`. Check `previewRedeem(shares).fastOk` before offering the instant path.
- **Two ERC-20 revert dialects + two distinct approvals.** Deposit and redeem approve *different* tokens to
  the strategy: `usdc.approve(strategy, assets)` for a deposit (USDC → strategy) and `vault.approve(strategy,
  shares)` for any redeem (vault-shares → strategy) — one approval never covers the other. The two tokens
  also revert in **different dialects**: the fork USDC (FiatToken) reverts with **string** errors
  (`"ERC20: transfer amount exceeds allowance"`) while the vault-share ERC-20 is OZ v5 and reverts with
  **custom** errors (`ERC20InsufficientAllowance(spender, allowance, needed)`). A client that only decodes
  one style will mis-surface a missing approval on the other leg — decode both.
- **Rounding favors stayers.** `deposit` shares and `redeem` payout both round **down** (`mulDiv`), so a
  round-trip in one block returns slightly less than deposited.
- **Fee-share dilution is visible between deposit and redeem — and crystallizes inside your own tx.** Mgmt
  fee streams with `dt` and a perf fee mints fee-shares on gains above the HWM — `vault.totalSupply()` grows
  without a matching deposit, so a user's implied per-share value drifts down between actions even with no NAV
  change. The crystallize fires the fee-mint **inside the same tx** as your deposit/redeem, on the **pre-action**
  NAV (before your USDC is pulled / your shares priced), so client-side share math from a **pre-tx**
  `totalSupply` is off by that pending fee mint — read the mint from the tx's own `Transfer(0, feeRecipient,
  feeShares)` log, or quote with `previewRedeem` (it simulates the pending crystallize) and keep a slippage
  cushion on `minAssetsOut`. Note also that a `compound`'s **own** realized gain is charged into
  `protocolFeeOwed` only by the **next** crystallizing op (deposit/redeem/compound), not within the `compound`
  itself — so a single `compound` can leave `protocolFeeOwed` unchanged until a trailing crystallize.
- **Async request does NOT freeze a price.** Escrowed shares keep bearing PnL until `fulfillRedeem`; the
  payout is whatever `f × NAV` is at fulfill time, not at request time. `cancelRedeem` returns the same shares.
- **`ZeroAssetsOut` does not burn.** A dust-share or underwater redeem reverts without consuming shares —
  the user still owns them; recover an async escrow with `cancelRedeem`.
- **Genesis vs. strategy depositors are priced identically.** Whether shares were minted at vault genesis or
  via `strategy.deposit`, all are backed by the same `nav()/supply` — no separate accounting.
- **Fee caps** (init-enforced): management ≤ 500 bps/yr, performance ≤ 1500 bps
  (`FeeConstants.MAX_PERFORMANCE_FEE_BPS`). The protocol fee **rate** is read live from the protocol-wide
  `ProtocolConfig` (resolved via `vault.factory().protocolConfig()`; `_protocolFeeBps()` `:638`, cap
  `MAX_PROTOCOL_FEE_BPS = 1000` / 10%), and the accrued fee sits as the `protocolFeeOwed` USDC liability
  netted out of `nav()`.
