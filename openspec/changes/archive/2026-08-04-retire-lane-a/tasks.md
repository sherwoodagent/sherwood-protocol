# Tasks

> **Applied and archived 2026-08-04.** Sections 0-7 (the code deletion) landed
> across earlier PRs; this branch closed section 8.1, the spec sync, which had
> been left outstanding — `openspec/specs/` still described Lane A months after
> the code was gone. Every code-side box below was checked against the tree's
> END STATE, not by replaying the steps: the seven Lane-A test files are absent,
> the four do-not-delete suites and both `WoodTwapOracle` files are present, the
> two new behaviour-preservation tests from 3.4 exist, `IPriceRouter`/
> `PriceRouter` are deleted, and the dead-symbol sweep leaves only comment-only
> notes that document the retirement. Task 8.2's warning that stacked PRs get no
> CI no longer holds — `.github/workflows/ci.yml` has since dropped the
> `branches: [main]` filter from its `pull_request` trigger.

**Ordering is load-bearing. The tree MUST compile after every numbered section**
(src + test + script — forge builds all three), because the implementer works
against a contended build lock where a mid-way break is expensive. The order below
is dependency-driven; do not reorder:

- **`src/interfaces/IPriceRouter.sol` CANNOT be deleted first.** It declares the
  `Position` struct that `IStrategy.sol:4` and `BaseStrategy.sol:5` import for the
  `positions()` hook every strategy inherits. Design Q1 resolved this by deleting
  the hooks rather than relocating `Position` — but the hooks can only go after
  the vault stops calling `availableLiquidity()`/`withdrawTo()` (section 2), and
  the file itself can only go once nothing imports it (section 5, last).
- Test REMOVALS are compile-safe at any point (nothing imports a test file), so
  all test surgery on to-be-deleted surface happens FIRST (section 1) — after it,
  no test references the vault/strategy surface that sections 2-3 delete.
- The vault, its interface, and the governor are mutually referential
  (`SyndicateVault is ISyndicateVault`; the governor calls `interimNetFlow()` and
  `consumeCrystallized*` through the interface), so section 2 is ONE atomic step
  across three files. It cannot be split and still compile.
- Storage is free: no vault and no governor proxy is deployed (owner-confirmed;
  design "Deployment reality"), so vault fields are deleted outright — no
  same-slot placeholders. The ONLY layout constraint is factory slot 7 (the
  factory IS deployed and golden-pinned): deprecate in place, never vacate (Q2).

## 0. Preliminaries

- [x] 0.1 Rebase this branch onto `main` AFTER #147
      (`fix/issue-147-swap-adapter-allowlist`) merges. Then re-run the design-Q8
      guard: `grep -n "positions\|availableLiquidity\|withdrawTo\|Position" src/strategies/PortfolioStrategy.sol`
      must return no hook overrides and no `Position` import. If #147 added any,
      STOP and re-run the Q1 consumer enumeration before proceeding.
- [x] 0.2 Build discipline for every forge invocation in this file: foreground
      only with a generous timeout (never background-and-wait), serialized behind
      the shared lock (`while pgrep -x forge >/dev/null; do sleep 30; done`, or a
      PID-stamped `mkdir` lock with a cleanup trap), and never judge a build by a
      piped exit code. Three build/test checkpoints are marked below (1.5, 2.8,
      7.1) plus the golden regen (4.4); avoid extra builds between them — the
      section ordering guarantees compilability without probing.

## 1. Test pre-surgery (removals only — compile-safe before any src change)

- [x] 1.1 Delete the 7 Lane-A-only test files whole (design Q6 table):
      `test/SyndicateVault.LaneA.t.sol`,
      `test/pricing/PriceRouter.t.sol`,
      `test/invariants/InstantLiquidityInvariants.t.sol`,
      `test/invariants/handlers/InstantLiquidityHandler.sol` (imported only by the
      invariant suite deleted alongside it),
      `test/fees/CrystallizeOnExit.t.sol`,
      `test/fees/InstantExitFee.t.sol`,
      `test/audit-fixes/Vault_withdrawLaneStateConsistency.t.sol` (its inline mock
      implements `withdrawTo` — goes with the file).
- [x] 1.2 `test/SyndicateVault.InstantLiquidity.t.sol` is MIXED — do NOT delete
      the file. Delete exactly the 13 Lane-A tests named in design Q6
      (`test_baseStrategy_*`, `test_maxWithdraw_includesStrategyLiquidity`,
      `test_withdraw_pullsShortfallFromStrategy`, `test_withdraw_floatOnly_noStrategyCall`,
      `test_withdraw_revertsOnUnderDelivery`,
      `test_maxWithdraw_zeroStrategyCapacity_whenLaneAOff`,
      `test_maxWithdraw_floatOnly_whenStrategyHasNoLiquidity`,
      `test_interimNetFlow_*` ×4, `test_settlementPnl_excludesLaneAFlows`) plus the
      `MockRouter` contract and the `priceRouter()` mockCall arming. KEEP the 10
      general `minBufferBps` / idle-float / `governorBatch` tests listed in Q6 —
      they pin the surviving instant-liquidity behaviour.
- [x] 1.3 `test/fees/MgmtFeeAccrual.t.sol` is KEPT (the prior blast-radius
      analysis's "full delete" was wrong — design Errata 4). Delete only the 4
      Lane-A tests (`test_capitalAddedMidProposalIsChargedOnlyForItsTime`,
      `test_aLateDepositorIsNotChargedForTimeBeforeTheDeposit`,
      `test_capitalWithdrawnMidProposalStopsAccruing`,
      `test_liveStrategyValueCountsTowardTheBase`); drop `MockAccrualRouter` and
      the `priceRouter()` mockCall; rename `_executeWithLaneA` → `_executeProposal`
      (locked + `startManagementAccrual`, no router arming). The 9 kept tests must
      still pass unmodified — they cover the surviving `management-fee` spec.
- [x] 1.4 `test/audit-fixes/Vault_batchQueueTargets.t.sol`: in
      `test_adapterOnlyVaultEntrypointsStayReachable`, drop only the
      `withdrawTo`/`OnDemandExitUnsupported` probe leg (`:307-315`); the
      `execute()` and `settle()` legs fully prove the denylist property (Q1).
- [x] 1.5 Do-NOT-delete guard, then checkpoint. Confirm untouched:
      `test/pricing/WoodTwapOracle.t.sol` (WOOD/USD guardian-bond feed — NOT Lane
      A), `test/SyndicateVault.AsyncRedeem.t.sol`, `test/fees/HighWaterMark.t.sol`,
      `test/fees/FeeDistribution.t.sol`. Checkpoint (build 1): run the four edited
      suites (`forge test --match-path` on InstantLiquidity, MgmtFeeAccrual,
      batchQueueTargets, AsyncRedeem) — all green BEFORE any src change, proving
      the kept tests never depended on the deleted harness pieces.

## 2. Vault core — SyndicateVault + ISyndicateVault + SyndicateGovernor (ONE atomic step)

- [x] 2.1 `src/SyndicateVault.sol` — delete: the `IPriceRouter` import,
      `_laneState`, `_getPriceRouter`, `_isLaneALocked` + `_laneALockPid`,
      `_laneBOnly`, `_strategyLiquidity`, `_pullFromStrategy`, the Lane A branch
      of `_deposit` (incl. the `_interimNetFlow +=` block), `_interimNetFlow` +
      `interimNetFlow()` + its `onProposalSettled` reset, the Lane-A-lock checks
      in `_update` and `requestRedeem`, and the whole crystallization system:
      `instantExitFeeBps` / `MAX_INSTANT_EXIT_FEE_BPS` / `setInstantExitFeeBps`,
      `_exitPenalty`, `_exitFees` / `_exitFeesAt`, `_governorPerformanceCap`
      (orphaned helper — Errata 2), `_crystallizedMgmt` / `_crystallizedPerf` +
      views + `consumeCrystallizedMgmt` / `consumeCrystallizedPerf`, the
      `previewRedeem` / `previewWithdraw` overrides and `previewExitFees`.
- [x] 2.2 Replacements (exact shapes in design Q3/Q4):
      `maxWithdraw`/`maxRedeem` non-queue branch → `if (redemptionsLocked()) return 0;`
      (queue bypass stays ABOVE it; `GovernorNotSet` fail-closed surface
      preserved); instant capacity → `_availableFloat()` alone; `_withdraw`
      shortfall branch → `if (assets + reserve > float) revert QueueReserveBreached();`
      (same error surface as the deleted `_pullFromStrategy` path); delete the
      `_laneState()`/`pricePerShare()` hoist, the crystallization block, and the
      unreachable post-withdraw `redemptionsLocked()` block; `totalAssets()` →
      idle balance minus `reservedQueueAssets()`, floored at zero (live-NAV and
      crystallized-fee terms gone; `_pricingSupply()` pairing and
      `_stampMgmtBase()` try/catch untouched).
- [x] 2.3 KEEP (consumed by the surviving settlement fee path — design
      "Crystallization reachability" KEEP list): `agentFeeBps()`,
      `pricePerShare()`, `managementAssetSeconds()`, `aboveHighWaterMark()`,
      `ratchetHighWaterMark()`, `_accrueManagementFee()`,
      `_initHighWaterMarkIfUnset()`, the `_mgmtAssetSeconds`/`_mgmtBase`/
      `_mgmtLastUpdate` trio, and `minHoldingPeriod`/`lastDepositAt`
      (future cooldown on the general path — out of scope).
- [x] 2.4 `src/interfaces/ISyndicateVault.sol` — remove the matching functions,
      events (`ExitFeesCrystallized`, `InstantExitFeeUpdated`) and errors
      (`SharesLocked`, `InstantExitFeeTooHigh`, `UnwindShortfall`).
      `QueueReserveBreached` STAYS (still thrown by `_withdraw`).
- [x] 2.5 `src/SyndicateGovernor.sol` — exactly three sites (design Q5):
      drop the `interimNetFlow()` subtraction in `_finishSettlement`
      (`pnl = int256(balanceAdjusted) - int256(snapshot);`); delete the
      `consumeCrystallizedMgmt()` netting block in `_chargeManagementFee`; delete
      the `consumeCrystallizedPerf()` line in `_chargePerformanceFee`. Rewrite
      `_chargePerformanceFee`'s NatSpec always-call rationale from "release
      crystallized fees" to the high-water-mark ratchet.
- [x] 2.6 Vault storage hygiene: grow `__gap` `uint256[28]` → `uint256[31]`
      (3 slots freed: `_laneALockPid`, `_interimNetFlow`,
      `_crystallizedMgmt`+`_crystallizedPerf`; `instantExitFeeBps` frees none —
      packed). Legal only because no vault proxy is live.
- [x] 2.7 Reference sweep (no build needed):
      `grep -rn "interimNetFlow\|consumeCrystallized\|previewExitFees\|instantExitFeeBps\|_laneState\|SharesLocked\|UnwindShortfall\|ExitFeesCrystallized" src/ test/ script/`
      → only hits allowed: none (comment mentions get fixed in section 6).
- [x] 2.8 Checkpoint (build 2): `forge build` — the tree compiles with the vault
      float-NAV-only. From here the strategy hooks have zero src callers.

## 3. Strategy hooks + behaviour-preservation pins

- [x] 3.1 `src/interfaces/IStrategy.sol` — remove `positions()`,
      `availableLiquidity()`, `withdrawTo()` and the
      `import {Position} from "./IPriceRouter.sol";` line. `Position` is NOT
      relocated (design Q1: zero non-Lane-A consumers; V2 reintroduces the hook
      with its consumer).
- [x] 3.2 `src/strategies/BaseStrategy.sol` — remove the three virtual defaults,
      the `Position` import, and `OnDemandExitUnsupported`. Do not touch
      `PortfolioStrategy.sol` / `VeniceInferenceStrategy.sol` (they override
      none of the hooks — verified Q1/Q8).
- [x] 3.3 `test/mocks/MockStrategyAdapter.sol` — drop the three stubs and the
      `Position` import.
- [x] 3.4 NEW behaviour-preservation tests (in
      `test/SyndicateVault.AsyncRedeem.t.sol` or the InstantLiquidity file):
      `test_maxWithdrawAndMaxRedeem_zeroDuringActiveProposal` (re-pins the
      surviving property the deleted
      `test_maxWithdraw_zeroStrategyCapacity_whenLaneAOff` guarded) and
      `test_withdraw_shortfallBeyondFloat_revertsQueueReserveBreached` (unlocked
      vault, reserve pinned above float — pins the Q3 replacement error surface).

## 4. Factory + deploy scripts (the last consumers outside `src/pricing`)

These move together: the deploy scripts call `factory.setPriceRouter` /
`factory.priceRouter()`, so factory surface and scripts cannot be split.

- [x] 4.1 `src/SyndicateFactory.sol` — `address public priceRouter;` (slot 7) →
      `address private __deprecated_priceRouter;` (same slot, same type — the
      factory IS deployed and golden-pinned; NEVER vacate or reorder slot 7).
      Delete `setPriceRouter` and `event PriceRouterUpdated`; fix the field's
      Lane-A NatSpec.
- [x] 4.2 `src/interfaces/ISyndicateFactory.sol` — remove `priceRouter()`.
- [x] 4.3 Scripts (design Q7 table): `script/robinhood-mainnet/Deploy.s.sol` —
      remove the `PriceRouter` import, deploy+wire block, ownership handoff, log
      lines, the `PRICE_ROUTER` persist patch, and the two `_validate` checks +
      param; rewrite the header comment. `script/robinhood-testnet/DeployV2.s.sol`
      — same removals. `script/robinhood-testnet/RedeployShimAdapter.s.sol:13` —
      comment only. `script/deploy-vnet.sh:40` — remove the stale
      `DeployPriceRouter` line (script it names doesn't exist on main).
- [x] 4.4 Regenerate `script/syndicate-factory-layout.golden.json` via
      `./script/check-layout-goldens.sh --update-golden` (this builds — lock
      discipline per 0.2). Verify the diff is LABEL-ONLY on slot 7
      (`priceRouter` → `__deprecated_priceRouter`); any slot/offset/type change
      is a stop-the-line error.

## 5. Delete the pricing files (LAST source deletion)

- [x] 5.1 Pre-delete gate: `grep -rln "IPriceRouter\|PriceRouter" src/ script/ test/`
      must return exactly `src/pricing/PriceRouter.sol` and
      `src/interfaces/IPriceRouter.sol` (plus any comment-only mentions slated
      for section 6). If anything else appears, a consumer was missed — stop.
- [x] 5.2 Delete `src/pricing/PriceRouter.sol` and
      `src/interfaces/IPriceRouter.sol`.
- [x] 5.3 DO-NOT-DELETE guard: `src/pricing/WoodTwapOracle.sol` and
      `src/interfaces/IWoodTwapOracle.sol` MUST remain. They are independent of
      Lane A — wired only into `ExposureLedger` for the WOOD/USD guardian-bond
      feed (import `ExposureLedger.sol:6`, storage `:217`, consult `:526-533`,
      setter `:663`). "Delete the pricing folder" is wrong; confirm both files
      still exist and `ExposureLedger` still compiles against them.

## 6. Comment-only touch-ups

- [x] 6.1 `src/interfaces/ISyndicateGovernor.sol:79` — drop the PriceRouter
      mention from the `strategy` field NatSpec.
- [x] 6.2 Optional riders (no logic changes; may be skipped): the seven
      comment-only test/file mentions listed at the end of design Q6.

## 7. Verification — proving the invariant that must not regress

- [x] 7.1 Full gate (build 3): `forge build` clean, then the full non-fork
      `forge test` suite green, foreground, lock-disciplined.
- [x] 7.2 **Ordinary-redemption invariant — explicit, not inferred from "tests
      pass"** (several deleted files were the old coverage). Prove: with no
      active proposal, exits are still instant against idle float, capped by
      `_availableFloat()`. Evidence required, all three legs:
      (a) named tests green — the kept
      `test/SyndicateVault.AsyncRedeem.t.sol::test_maxWithdraw_capsAtFloatMinusReserve`,
      the 10 kept InstantLiquidity tests, and both new 3.4 tests;
      (b) a line-read of the FINAL `maxWithdraw`/`maxRedeem`/`_withdraw` code
      confirming the no-proposal path is `_availableFloat()`-capped instant exit
      with `QueueReserveBreached` beyond it and no strategy interaction, matching
      design Q3's before/after identity (`_availableFloat() + 0` ≡
      `_availableFloat()`);
      (c) mid-proposal leg: `Vault_redemptionLockSemantics` suite green
      (deposits revert `DepositsLocked`; `requestRedeem` path intact).
- [x] 7.3 Dead-symbol sweep:
      `grep -rn "laneA\|LaneA\|IPriceRouter\|instantExitFee\|crystalliz\|interimNetFlow\|_exitPenalty\|withdrawTo\|availableLiquidity\|OnDemandExitUnsupported" src/ script/ test/`
      → zero hits (case-sensitive; `positions()` checked separately against the
      unrelated `StakedWood` "Positional" comments).
- [x] 7.4 `./script/check-layout-goldens.sh` passes (factory golden re-baselined
      in 4.4; governor/registry/sWOOD goldens untouched — this change deletes no
      governor storage). Note the 98,304-byte Robinhood size gate only gets
      easier (~300 vault lines removed).
- [x] 7.5 `forge fmt` with a CI-matching forge (CI checks `src/`, `test/`, AND
      `script/`; a version-mismatched local fmt actively breaks CI).

## 8. Spec sync + bookkeeping

- [x] 8.1 `openspec validate retire-lane-a --strict` passes. At sync/archive:
      apply the 5 deltas; `instant-exit-fees` ends with zero requirements —
      delete `openspec/specs/instant-exit-fees/spec.md` entirely, and move its
      "Deposits are not charged a fee" requirement into `syndicate-vault` (ADDED
      there).
- [x] 8.2 Commit on this branch referencing #54; open the PR against `main`
      (stacked PRs get NO CI in this repo — verify locally if ever retargeted).
- [x] 8.3 Record this change on #148 as the motivating example: the outright
      vault field deletions are safe only because no vault proxy exists; a vault
      layout golden would make this class of change mechanically verifiable.
- [x] 8.4 **#151 interaction — flag, do not fold in.** #151 (delete
      `selfManagesFees`) is specced in parallel and touches the governor fee path
      near `chargeNew`. This change removes `chargeNew`'s second purpose
      (releasing crystallized instant-exiter fees via the always-call of
      `_chargePerformanceFee`); its remaining purpose here is the high-water-mark
      ratchet (task 2.5 NatSpec). AFTER BOTH land, check whether the
      `chargeNew == false` invocation of `_chargePerformanceFee` has become
      vacuous — file it as a follow-up on #151, not here. Whichever branch lands
      second must reconcile the `_chargePerformanceFee` NatSpec and call shape.
