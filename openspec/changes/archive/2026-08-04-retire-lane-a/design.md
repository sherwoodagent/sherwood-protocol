# Design — retire-lane-a (issue #54)

All line references are against `origin/main` @ `e34526c` and were re-verified for
this document (do not trust them after the implementation lands; trust the symbol
names).

## Context

Lane A is mid-proposal instant entry/exit and nothing else. The whole machine hangs
off one predicate, `_laneState()` (`SyndicateVault.sol:891-908`), which requires ALL
of: an active proposal (`redemptionsLocked()`), a proposal-bound strategy
(`strategyOf(pid)`), a factory-wired PriceRouter, and
`IPriceRouter.valueStrategy(strategy)` returning `ok == true`. When `locked == false`
it early-returns `(false, 0, 0, false)` at `:893` — Lane A is structurally
unreachable outside a proposal. Deleting it therefore cannot touch the two behaviours
that must survive:

- **Outside a proposal**: instant `withdraw`/`redeem` against idle float net of the
  queue reserve (`_availableFloat()`, `:931-935`).
- **Mid-proposal**: `deposit`/`mint` revert `DepositsLocked`; exits return 0 from
  `maxWithdraw`/`maxRedeem` and route through the Lane B queue
  (`requestRedeem`/`requestDeposit`).

## Deployment reality (verified from `broadcast/`)

- **No vault proxy live** — owner-confirmed, and no broadcast record deploys one
  (`RegisterVaults.s.sol` on 8453 registers records, not proxies; regardless, the
  Base lineage is legacy and takes no upgrades — its vault impl sits 18 bytes under
  EIP-170 and cannot even fit one).
- **SyndicateFactory IS deployed**: `broadcast/Deploy.s.sol/{46630,8453,84532}` and
  `broadcast/UpgradeFactory.s.sol/8453` exist. The factory is UUPS and its layout is
  pinned by `script/syndicate-factory-layout.golden.json` (slot 7 = `priceRouter`,
  `t_address`), enforced by `script/check-layout-goldens.sh`.
- **Robinhood mainnet (4663): nothing deployed** — no 4663 directory under
  `broadcast/`.

Consequence: vault fields delete outright; **factory slot 7 must stay occupied**.

## Q1 — The `Position` relocation (resolved: no relocation; delete all three hooks)

`IPriceRouter.sol` declares `Position` + `IPriceAdapter`; `IStrategy.sol:4` and
`BaseStrategy.sol:5` import `Position` for the `positions()` hook. The instruction
was: enumerate every implementor and consumer of `positions()`,
`availableLiquidity()`, `withdrawTo()` before choosing between relocating `Position`
into `IStrategy.sol` and removing the hooks.

**Consumers (exhaustive, grep over `src/`, `script/`, `test/`):**

| Function | Consumers | Lane-A-gated? |
|---|---|---|
| `positions()` | `PriceRouter.valueStrategy` (`PriceRouter.sol:90`) — the ONLY caller anywhere | Yes — PriceRouter is deleted |
| `availableLiquidity()` | `SyndicateVault._strategyLiquidity` (`:947`) — the ONLY caller | Yes — `if (!laneA …) return 0` at `:946` |
| `withdrawTo()` | `SyndicateVault._pullFromStrategy` (`:970`) — the ONLY production caller | Yes — reverts `QueueReserveBreached` unless `laneA` at `:967` |

**Implementors:** `BaseStrategy` (virtual defaults: empty array / 0 / revert
`OnDemandExitUnsupported`). `PortfolioStrategy` and `VeniceInferenceStrategy` inherit
the defaults and override nothing. Test-side: `test/mocks/MockStrategyAdapter.sol`
(stub implementations) and the inline mock in
`test/audit-fixes/Vault_withdrawLaneStateConsistency.t.sol` (file deleted whole).

**Decision:** no non-Lane-A code path consumes any of the three, so **all three are
removed from `IStrategy` and `BaseStrategy`, and `IPriceRouter.sol` is deleted whole —
`Position` is not relocated**. Relocating `Position` to keep a `positions()` hook that
nothing reads would ship exactly the class of dead audit surface this change exists to
remove. V2 re-introduces the hook together with its consumer.

Two knock-on edits this forces (both enumerated in tasks.md):
- `test/audit-fixes/Vault_batchQueueTargets.t.sol::test_adapterOnlyVaultEntrypointsStayReachable`
  uses `BaseStrategy.withdrawTo` + `OnDemandExitUnsupported` as its third
  "adapters stay reachable" probe (`:307-315`). The test's property (the batch target
  denylist is exactly {vault, queue}, never adapters) is fully proven by its
  `execute()` and `settle()` legs; the `withdrawTo` leg is dropped, the other two stay.
- `test/mocks/MockStrategyAdapter.sol` drops the three stubs + `Position` import.

## Q2 — `ISyndicateFactory.priceRouter` / `setPriceRouter` (resolved: deprecate slot, remove surface)

Finding (see "Deployment reality"): the factory is deployed and layout-pinned, so
slot 7 cannot be vacated. But nothing needs to keep READING it once the vault's
`_getPriceRouter()` is gone.

- `address public priceRouter;` (`SyndicateFactory.sol:125`) →
  `address private __deprecated_priceRouter;` — same slot, same type, getter gone.
- `setPriceRouter` (`:545-548`) and `event PriceRouterUpdated` (`:239`) deleted.
- `ISyndicateFactory.priceRouter()` (`ISyndicateFactory.sol:35`) deleted.
- `script/syndicate-factory-layout.golden.json` regenerated in the same step
  (`./script/check-layout-goldens.sh --update-golden`): only the slot-7 LABEL
  changes; slot/offset/type are unchanged, which is upgrade-safe (the EVM does not
  see labels).

**Callers of the getter (exhaustive):** `SyndicateVault._getPriceRouter` (`:869`,
deleted in this change) and the post-deploy validations in
`script/robinhood-mainnet/Deploy.s.sol:186` / `script/robinhood-testnet/DeployV2.s.sol:200`
(edited in this change). **Callers of the setter:** the same two deploy scripts
(`:102` / `:97`). No test calls either (grep over `test/`).

Rejected alternative — keeping the public getter as a dead slot: ships a permanently
misleading "protocol has a price router" API into the audit and into every integrator
ABI, for zero migration benefit (nothing on any chain has a nonzero value that
matters; the legacy Base lineage takes no upgrades).

## Q3 — What replaces `_laneBOnly` in `maxWithdraw` / `maxRedeem` (resolved)

`_laneBOnly(owner_)` (`:923-926`) is `(locked && !laneA) || _isLaneALocked(owner_)`.
With `laneA` identically false and the per-holder lock gone (it only ever held while
its proposal was the active one, i.e. only while `locked`), the predicate reduces to
**`redemptionsLocked()`**. That is the exact replacement:

```solidity
// maxWithdraw / maxRedeem, non-queue owner:
if (redemptionsLocked()) return 0;   // mid-proposal exits route to the queue, full stop
```

Notes that make this exact, not approximate:
- `redemptionsLocked()` keeps the fail-closed `GovernorNotSet` revert on a zero
  governor — the same revert `_laneState()` produced via its first statement, so the
  misconfigured-factory behaviour of `maxWithdraw`/`maxRedeem`/`totalAssets` is the
  same error surface as today.
- The queue bypass (`owner_ == _withdrawalQueue → super.max*`) is untouched and stays
  ABOVE the new check, exactly as it sits above `_laneBOnly` today.
- `_strategyLiquidity()` is deleted; instant capacity becomes `_availableFloat()`
  alone.

**Proof the no-proposal path is unchanged:** today, with no active proposal,
`_laneBOnly` returns false (`locked == false`, `_isLaneALocked` false because
`_activePid() == 0`), and `_strategyLiquidity()` returns 0 (its `laneA` read is false
via the `:893` early-return). So today's capacity is `_availableFloat() + 0` and
tomorrow's is `_availableFloat()` — identical, including the `maxRedeem` share-side
clamps (`pendingQueueShares`, the dust-case skip), which are untouched. Pinned by the
kept `test/SyndicateVault.AsyncRedeem.t.sol::test_maxWithdraw_capsAtFloatMinusReserve`
and the new tests in tasks.md 3.4.

Companion change in `_withdraw` (`:1188-1190`): the shortfall branch called
`_pullFromStrategy`, which for a non-Lane-A vault reverts `QueueReserveBreached`. The
replacement preserves that exact error surface:

```solidity
if (assets + reserve > float) revert QueueReserveBreached();
```

The post-withdraw `redemptionsLocked()` block (`:1214-1222`, interim-flow + accrual
restamp) is deleted as unreachable: a non-queue `_withdraw` while locked requires
`maxWithdraw > 0`, which the new predicate forbids (OZ's `withdraw`/`redeem` check
`max*` before `_withdraw`; the queue caller is exempt from the block already).
Likewise the `_laneState()`/`pricePerShare()` hoist at `:1177-1178` and the
crystallization block at `:1200-1209` go.

## Q4 — `totalAssets` after the live-NAV term (resolved)

Becomes:

```solidity
function totalAssets() public view override returns (uint256) {
    uint256 gross = IERC20(asset()).balanceOf(address(this));
    uint256 owed = reservedQueueAssets();
    return gross > owed ? gross - owed : 0;
}
```

i.e. idle float minus the queue reserve (issue #92 semantics), floored at zero. The
crystallized-fee subtraction goes with its fields; the queue-reserve subtraction and
its pairing with `_pricingSupply()` (stamped-unclaimed shares out of the denominator)
are untouched.

**Share pricing outside a proposal is unchanged**: today `liveNav == 0` (`:893`) and
`_crystallizedMgmt == _crystallizedPerf == 0` on any vault where Lane A never fired —
which after this change is every vault — so gross and owed are identical before and
after. Mid-proposal, `totalAssets()` is float-only in both worlds whenever Lane A is
unavailable, which after this change is always. Pinned by: `test/SyndicateVault.t.sol`
share-accounting tests (untouched), `test/fees/HighWaterMark.t.sol` (untouched),
`test/SyndicateVault.AsyncRedeem.t.sol` stamped-price tests (untouched), and the kept
`test/fees/MgmtFeeAccrual.t.sol` accrual-base tests. Note `_stampMgmtBase()`'s
try/catch fallback stays: a fee accrual must never be the reason a settlement
reverts, whatever `totalAssets()` grows to depend on later.

## Q5 — Governor surface (resolved: three sites, nothing else)

Grep of `SyndicateGovernor.sol` for the deleted surface finds exactly:

1. `:1287` — `pnl = … - ISyndicateVault(vault).interimNetFlow();` in
   `_finishSettlement`. The subtrahend is identically 0 without Lane A (see Errata),
   so the term is dropped: `pnl = int256(balanceAdjusted) - int256(snapshot);`.
2. `:1439-1444` — `consumeCrystallizedMgmt()` netting in `_chargeManagementFee`.
   Block deleted; `mgmtFee` is the plain annualized integral.
3. `:1524` — `perfFee += consumeCrystallizedPerf();` in `_chargePerformanceFee`.
   Line deleted.

`_chargePerformanceFee`'s shape otherwise survives, including the
`chargeNew == false` (`selfManagesFees`) invocation: its remaining purpose is the
high-water-mark ratchet, which is independent of Lane A. Its NatSpec (`:1492-1497`)
currently justifies the always-call with "fees already crystallized from instant
exiters must be released" — rewrite to the ratchet rationale. The settlement path was
read in full (`_finishSettlement`, `_chargeManagementFee`, `_chargePerformanceFee`,
`_snapshotFeeConfig`, `_clampPerformanceFee`, the `_payFee`/escrow path): no other
reads of the deleted vault surface exist. `ISyndicateGovernor.sol:79` mentions the
PriceRouter in the `strategy` field's NatSpec — comment-only fix.

Vault-side orphan this exposes: `_governorPerformanceCap()` (`:1656-1665`) exists
solely for `_exitFeesAt` and is deleted with it (missed by the prior analysis).

## Crystallization reachability (the main risk — verified in BOTH directions)

**Is any part of the crystallization system reachable without Lane A? No.**

- Writes: `_crystallizedMgmt`/`_crystallizedPerf` are written only in `_withdraw`
  under `caller != _withdrawalQueue && laneAAtEntry` (`:1200-1209`). `laneAAtEntry`
  requires `_laneState().laneA`, which requires an active proposal AND a wired router
  AND `valueStrategy` ok. Queue settlements (`settleRedeem`) never crystallize.
- `_exitPenalty` is charged only inside `previewRedeem` after `if (!laneA) return
  gross;` (`:1709-1710`) — the penalty cannot fire on a non-Lane-A exit.
- `instantExitFeeBps` is read only by `_exitPenalty` (`:1688`) and `previewWithdraw`'s
  gross-up (`:1739`), both behind the same `laneA` gate.
- Reads at settlement: the two `consumeCrystallized*` governor sites release counters
  that can only ever be 0.

So **keeping any of it would ship a fee mechanism that can never fire** — and
deleting it removes nothing an ordinary (out-of-proposal) exit pays today: ordinary
exits hit `previewRedeem`'s `!laneA` early-return and pay no crystallization and no
penalty, before and after. Fee behaviour for ordinary exits is therefore untouched by
construction; `test/fees/HighWaterMark.t.sol`, `test/fees/FeeDistribution.t.sol`, and
the kept `MgmtFeeAccrual` tests pin the surviving fee system end-to-end.

Deliberate KEEPs inside the reviewed region (all consumed by the surviving
settlement fee path): `agentFeeBps()`, `pricePerShare()`,
`managementAssetSeconds()`, `aboveHighWaterMark()`, `ratchetHighWaterMark()`,
`_accrueManagementFee()` (now called only from `consumeManagementAccrual`),
`_initHighWaterMarkIfUnset()`, and the whole `_mgmtAssetSeconds`/`_mgmtBase`/
`_mgmtLastUpdate` accrual trio.

## Q6 — Test surgery, file by file (definitive)

**Delete whole (7 files, ~1,850 lines):**

| File | Lines | Why safe to delete whole |
|---|---|---|
| `test/SyndicateVault.LaneA.t.sol` | 253 | All 10 tests exercise Lane A NAV/lock/deposit. Two carry shadows of general behaviour, both covered elsewhere: `test_deposit_reverts_whenLockedNoLaneA` → `Vault_redemptionLockSemantics::test_deposit_revertsDuring{Pending,GuardianReview,Approved,Executed}`; `test_missingStrategyOfDoesNotBrickWithdrawLanes` → moot (nothing on the withdraw path calls `strategyOf` anymore; `activeStrategyAdapter()` keeps its own try/catch) |
| `test/pricing/PriceRouter.t.sol` | 374 | Contract deleted. (`test/pricing/WoodTwapOracle.t.sol` STAYS.) |
| `test/invariants/InstantLiquidityInvariants.t.sol` | 98 | Its single invariant `invariant_noExitWithoutPricing` is the Lane A gate itself |
| `test/invariants/handlers/InstantLiquidityHandler.sol` | 209 | Handler for the above |
| `test/fees/CrystallizeOnExit.t.sol` | 370 | All 12 tests drive Lane A instant exits (crystallization has no other trigger — see reachability above) |
| `test/fees/InstantExitFee.t.sol` | 341 | All 13 tests exercise `instantExitFeeBps`/`_exitPenalty`/preview kink |
| `test/audit-fixes/Vault_withdrawLaneStateConsistency.t.sol` | 205 | Issue-#100 regression suite for the `laneAAtEntry`/`ppsAtEntry` hoist — the hoist is deleted. **Missed by the prior analysis.** |

**Keep with edits (4 files):**

- `test/fees/MgmtFeeAccrual.t.sol` (337) — **prior analysis said full delete; that is
  wrong.** It covers `openspec/specs/management-fee/spec.md`, a surviving system.
  KEEP 9 tests: `test_halfTheDurationOwesHalfTheFee`,
  `test_aFullYearAtTheHeadlineRateChargesTwoPercent`,
  `test_consecutiveProposalsDoNotDoubleChargeTheFirstAccrual`,
  `test_consumeLeavesNothingBehind`, `test_theGapBetweenProposalsGeneratesNoFee`,
  `test_aDormantFundChargesNothing`, `test_onlyGovernorMayStartAccrual`,
  `test_onlyGovernorMayConsumeAccrual`, `test_theViewIncludesTheInProgressInterval`.
  DELETE 4 Lane-A-dependent tests (mid-proposal base changes / live-NAV base are
  impossible without Lane A): `test_capitalAddedMidProposalIsChargedOnlyForItsTime`,
  `test_aLateDepositorIsNotChargedForTimeBeforeTheDeposit`,
  `test_capitalWithdrawnMidProposalStopsAccruing`,
  `test_liveStrategyValueCountsTowardTheBase`. Harness surgery: drop
  `MockAccrualRouter` and the `priceRouter()` mockCall; rename `_executeWithLaneA` →
  `_executeProposal` (locked + `startManagementAccrual`, no router arming).
- `test/SyndicateVault.InstantLiquidity.t.sol` (360) — MIXED, as the prior analysis
  said. KEEP 10 general tests: `test_minBufferBps_defaultZero`,
  `test_setMinBufferBps_ownerOnly`, `test_setMinBufferBps_setsAndEmits`,
  `test_setMinBufferBps_revertsAboveCap`, `test_setMinBufferBps_acceptsExactCap`,
  `test_setMinBufferBps_resetToZero`, `test_governorBatch_respectsBuffer`,
  `test_governorBatch_revertsOnBufferBreach`,
  `test_governorBatch_bufferOff_allowsFullDeploy`,
  `test_governorBatch_settleBatch_passesTrivially`. DELETE 13 Lane-A tests:
  `test_baseStrategy_defaults_noOnDemandExit`, `test_baseStrategy_withdrawTo_onlyVault`,
  `test_maxWithdraw_includesStrategyLiquidity`,
  `test_withdraw_pullsShortfallFromStrategy`, `test_withdraw_floatOnly_noStrategyCall`,
  `test_withdraw_revertsOnUnderDelivery`,
  `test_maxWithdraw_zeroStrategyCapacity_whenLaneAOff`,
  `test_maxWithdraw_floatOnly_whenStrategyHasNoLiquidity`,
  `test_interimNetFlow_tracksLaneADeposit`, `test_interimNetFlow_tracksInstantExit`,
  `test_interimNetFlow_notTrackedOutsideProposal`,
  `test_interimNetFlow_resetOnSettle`, `test_settlementPnl_excludesLaneAFlows`.
  One deleted test guards behaviour that SURVIVES and must be re-pinned, not dropped:
  `test_maxWithdraw_zeroStrategyCapacity_whenLaneAOff` (locked ⇒ `maxWithdraw` 0) —
  REWRITTEN as `test_maxWithdrawAndMaxRedeem_zeroDuringActiveProposal` (tasks 3.4).
  Harness surgery: drop `MockRouter` and the `priceRouter()` mockCall.
- `test/audit-fixes/Vault_batchQueueTargets.t.sol` (316) — KEEP; edit
  `test_adapterOnlyVaultEntrypointsStayReachable` to drop its `withdrawTo` leg (Q1).
- `test/mocks/MockStrategyAdapter.sol` (68) — KEEP; drop `positions()`,
  `availableLiquidity()`, `withdrawTo()` and the `Position` import.

**Comment-only touch-ups (no test logic changes; may ride along or be skipped):**
`test/SyndicateVault.t.sol:90`, `test/SyndicateGovernor.t.sol:109`,
`test/SyndicateGovernorIntegration.t.sol:113`,
`test/audit-fixes/Vault_batchQueueTargets_lifecycle.t.sol:119`,
`test/audit-fixes/Vault_redemptionLockSemantics.t.sol:62`,
`test/fees/FeeDistribution.t.sol:358` (its
`test_anUnpayableFeeIsEscrowedAndRecoverable` works via `_gain` + settle and does not
depend on crystallization — verified), `test/integration/RobinhoodIntegrationTest.sol:54`.

**New tests (behaviour-preservation pins, tasks 3.4):** in
`test/SyndicateVault.AsyncRedeem.t.sol` (or the InstantLiquidity file):
`test_maxWithdrawAndMaxRedeem_zeroDuringActiveProposal`, and
`test_withdraw_shortfallBeyondFloat_revertsQueueReserveBreached` (unlocked vault,
reserve pinned above float — pins the Q3 replacement error surface).

## Q7 — Scripts (exhaustive enumeration)

| File | Reference | Becomes |
|---|---|---|
| `script/robinhood-mainnet/Deploy.s.sol` | `:94-102` deploy+wire PriceRouter proxy; `:115` ownership handoff; `:130`, `:143` (`PRICE_ROUTER` patch), `:150` log; `:165`, `:186-187` `_validate` (`factory.priceRouter`, `priceRouter.owner`) | All PriceRouter blocks removed; `_validate` loses the two `_checkAddr` lines and the `priceRouter` param; header comment (`:23-27`) rewritten |
| `script/robinhood-testnet/DeployV2.s.sol` | `:93-97` deploy+wire; `:119` handoff; `:126`, `:134` params; `:151-161` persist (`PRICE_ROUTER` patch), `:172` log; `:179-201` `_validateTestnet` | Same removals |
| `script/robinhood-testnet/RedeployShimAdapter.s.sol` | `:13` comment only | Comment updated |
| `script/deploy-vnet.sh` | `:40` runs `DeployPriceRouter.s.sol` — a script that does not exist on main (already-stale line) | Line removed |
| `script/syndicate-factory-layout.golden.json` | slot 7 label `priceRouter` | Regenerated with `--update-golden` after the factory edit (Q2) |
| `script/Deploy.s.sol`, `DeployPlanB/D`, `DeployTemplates`, `UpgradeFactory`, `script/testnet/Deploy.s.sol`, all others | — | Zero references (grep-verified); untouched |

No script or pre-flight references `laneA` or `instantExitFeeBps` anywhere.

## Q8 — Interaction with #147 (lands first)

#147 adds `_requireAllowedAdapter` to `PortfolioStrategy`
(`fix/issue-147-swap-adapter-allowlist`). This change **does not modify
`PortfolioStrategy.sol` at all**: PortfolioStrategy inherits BaseStrategy's hook
defaults, overrides none of the three deleted functions, and imports neither
`Position` nor `IPriceRouter`. The Q1 concern ("touches PortfolioStrategy's
imports") turned out empty on verification. Rebase relationship: rebase this branch
onto main AFTER #147 merges (tasks 0.1); no shared files are expected to conflict.
If #147 unexpectedly adds a `positions()`/`availableLiquidity()`/`withdrawTo()`
override or a `Position` use to PortfolioStrategy, STOP and re-run the Q1 consumer
enumeration before proceeding.

## Vault storage after deletion

Slots freed: `_laneALockPid` (1), `_interimNetFlow` (1),
`_crystallizedMgmt`+`_crystallizedPerf` (1, shared). `instantExitFeeBps` frees no
slot (packed with `minBufferBps`/`minHoldingPeriod`, which stay). Grow `__gap` from
`uint256[28]` to `uint256[31]` so the contract's total reserved footprint is
unchanged — cheap hygiene, legal only because no proxy is live. `minHoldingPeriod`
and `lastDepositAt` are NOT Lane A (they reserve a future cooldown on the general
instant-exit path, which survives) and are deliberately out of scope.

## Errata against the prior blast-radius analysis

1. `_interimNetFlow` / `interimNetFlow()` / the `onProposalSettled` reset / the
   governor's `:1287` subtraction are Lane-A-only and were MISSING from the scope.
   Proof: the `+=` sits inside `_deposit`'s `if (laneA && shares != 0)` block
   (`:1134-1144`); the `-=` sits in `_withdraw` behind `redemptionsLocked()`,
   reachable for a non-queue caller only when `maxWithdraw > 0` mid-proposal — i.e.
   only under Lane A.
2. `_governorPerformanceCap()` (`:1656-1665`) is an `_exitFeesAt`-only helper —
   missing from the scope; deleted.
3. `test/audit-fixes/Vault_withdrawLaneStateConsistency.t.sol` (205 lines) — missing
   from the deletion list.
4. `test/fees/MgmtFeeAccrual.t.sol` full deletion was WRONG (see Q6): 9 of its 13
   tests cover the surviving management-fee capability.
5. `test/audit-fixes/Vault_batchQueueTargets.t.sol` needs a one-test edit (the
   `withdrawTo` probe) — missing from the list.
6. All other cited line numbers verified accurate against `e34526c`
   (`MAX_INSTANT_EXIT_FEE_BPS` is the constant at `:97`; `instantExitFeeBps` the
   packed field at `:184`).

## Relationship to #148

`SyndicateVault` has no storage-layout golden (unlike governor/factory/registry —
#148). This change's outright field deletions are safe purely because no vault proxy
exists; that argument is made here in prose, not by a machine. Once #148 lands a
vault layout pin, a change of this class would fail the golden loudly and be
re-baselined deliberately — record this change as the motivating example on #148.

## Sizing note

Deleting the live-NAV term, previews, and crystallization removes several external
calls and ~300 lines from the vault, RELIEVING the EIP-170 pressure repeatedly cited
in its comments (stack-tuple `_laneState`, non-public `minHoldingPeriod`, etc.). No
size gate is affected (Robinhood's cap is 98,304; the legacy Base lineage takes no
upgrades).
