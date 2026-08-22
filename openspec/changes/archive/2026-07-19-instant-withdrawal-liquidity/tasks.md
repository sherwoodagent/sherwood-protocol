# Tasks — Instant-Withdrawal Liquidity

> Historical record; all work merged (commits `8bddd57`, `c914fa2`, `95cdcce`, `ebb3dba`, `93354d0`, `bea6f6c`, `74ffaa7`). Items marked "deferred" were closed by an explicit deferral decision recorded in design.md.

## 1. `minBufferBps` parameter + setter

- [x] 1.1 Write failing tests in new `test/SyndicateVault.InstantLiquidity.t.sol` (mock governor/router/liquid-strategy scaffolding reusing the LaneA harness pattern): default 0, owner-only setter, `MinBufferUpdated` event, revert `BufferTooHigh` above 5,000
- [x] 1.2 Add `BufferTooHigh` error, `minBufferBps()` view, `setMinBufferBps(uint16)`, `MinBufferUpdated` event to `ISyndicateVault`
- [x] 1.3 Add vault storage — `minBufferBps`, `minHoldingPeriod`, `_interimNetFlow`, `lastDepositAt` declared together so the layout settles once; `__gap` 35 → 32 — plus the owner setter
- [x] 1.4 Verify tests pass; EIP-170 size check (`forge build --sizes`, < 24,576 B); full-suite smoke; commit

## 2. Buffer enforcement in `executeGovernorBatch`

- [x] 2.1 Write failing tests: batch deploying exactly (1 − buffer) passes, +1 wei reverts `BufferBreached`, buffer-off full deploy allowed, settle (inflow) batch passes trivially
- [x] 2.2 Add `BufferBreached` error; snapshot the pre-batch float in `executeGovernorBatch` and extend the post-batch check to `balanceAfter >= reserve + balanceBefore * minBufferBps / 10_000` (queue-reserve check unchanged, fires first)
- [x] 2.3 Verify tests pass; size check; full suite green (existing `QueueReserveBreached` tests unaffected); commit

## 3. `IStrategy.availableLiquidity` / `withdrawTo` + `BaseStrategy` defaults

- [x] 3.1 Write failing tests: default strategy reports 0 liquidity, `withdrawTo` reverts `OnDemandExitUnsupported`, and is `onlyVault`
- [x] 3.2 Extend `IStrategy` with `availableLiquidity()` (serviceability signal only) and `withdrawTo(uint256)` (all-or-revert, vault-only)
- [x] 3.3 Add inert `BaseStrategy` defaults (return 0 / revert) so every concrete strategy compiles and behaves unchanged
- [x] 3.4 Verify new tests + full existing suite pass; commit

## 4. Vault same-tx strategy pull (instant capacity beyond float)

- [x] 4.1 Write failing tests: `maxWithdraw` = float + strategy liquidity; withdraw pulls shortfall from strategy; float-only exit leaves strategy untouched; under-delivery reverts `UnwindShortfall`; Lane A off ⇒ capacity 0; zero strategy liquidity ⇒ float-capped
- [x] 4.2 Add `UnwindShortfall` error; `_strategyLiquidity()` helper (Lane-A-gated, try/catch fail-to-0) and `_pullFromStrategy()` (balance-diff verified)
- [x] 4.3 Rework `_withdraw`: add `nonReentrant`, pull the shortfall before burn/transfer; extend `maxWithdraw`/`maxRedeem` capacity with `_strategyLiquidity()`
- [x] 4.4 Verify tests pass; size check; full suite green (AsyncRedeem, LaneA, reentrancy, queue-claim paths watched specifically); commit

## 5. `_interimNetFlow` — settlement PnL correction

- [x] 5.1 Write failing tests: Lane A deposit tracked (+), instant exit tracked (−), no tracking outside a proposal, reset on `onProposalSettled`, break-even-strategy PnL formula yields exactly 0 under interleaved flows
- [x] 5.2 Add `interimNetFlow()` view to `ISyndicateVault` and the vault; accumulate in `_deposit` (Lane A branch) and `_withdraw` (live instant exits only, queue callers excluded); reset first thing in `onProposalSettled` (before the no-queue early return)
- [x] 5.3 Adjust `SyndicateGovernor._finishSettlement`: `pnl = balance − snapshot − interimNetFlow` — mid-proposal LP flows are principal, not strategy performance (fixes the pre-existing fee-on-principal bug; surfaced in the PR description)
- [x] 5.4 Verify tests pass; governor suites green (real vaults have `interimNetFlow == 0`, mocks extended where needed); size check; commit

## 6. `minHoldingPeriod` anti-flash-arb gate — deferred

- [x] 6.1 Deferral decided and documented (design.md §Guardrails / status): the vault sits at the EIP-170 ceiling and a lean implementation still needed ~150 B over the ~50 B margin; further library extraction of small functions proved counter-productive. The G1 Lane-A per-holder lock already blocks the primary intra-proposal deposit→exit MEV. Storage slots (`minHoldingPeriod`, `lastDepositAt`) remain reserved for a future dedicated size pass

## 7. `MoonwellSupplyStrategy` on-demand exit

- [x] 7.1 Add `getCash()` to `ICToken`
- [x] 7.2 Implement overrides: `availableLiquidity` = redeemable underlying (via `exchangeRateStored`, no accrual) capped by market cash, 0 unless `Executed`; `withdrawTo` via `redeemUnderlying` with native-ETH wrap handling and `_pushToVault`, state-gated `onlyVault`
- [x] 7.3 Mock-based coverage passes; pinned-block Base fork test (mUSDC market, block 47255670 pin) deferred to CI follow-up — needs a Base RPC endpoint unavailable in the dev sandbox

## 8. EIP-170 size work, invariants, docs, wrap-up

- [x] 8.1 Extract cold-path admin logic to `SyndicateVaultAdminLib` (delegatecall, storage-ref) freeing ~1.2 KB; a later rescue-function extraction was tried and reverted (delegatecall dispatch cost exceeded inlined-body savings)
- [x] 8.2 Property-based invariant suite (reserve seniority, settlement-PnL integrity under interleaved flows, no-exit-without-pricing) deferred to CI follow-up; full 1378-test non-fork suite passes
- [x] 8.3 Update the design doc: status Implemented, deferred items (`instantExitFeeBps`, `maxUnwindSlippageBps`, `minHoldingPeriod`) and no-`InitParams` decision recorded; open questions Q1/Q2 marked resolved
- [x] 8.4 Full regression + CI-matching `forge fmt` + size checks; final commits
