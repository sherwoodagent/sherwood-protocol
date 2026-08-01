# Tasks — Fee Mechanism (Two-Number Model)

> Historical record; all work merged via PR #68 "apply-the-new-fee-model"
> (merged 2026-08-01), shipped 2026-07-31. Deviations from the original design
> (D1-D5) and rate/cap decisions (idle-capital exemption, performance-fee
> ceiling, factory default) are recorded in `design.md`.

## 1. Raise the performance-fee ceiling and add a shared BPS denominator

- [x] 1.1 Write failing test `test/fees/FeeConstantsCap.t.sol`: ceiling = 3000
      bps, `BPS_DENOMINATOR` = 10,000, and that `GovernorParameters`/
      `SyndicateVault` caps derive from the one constant rather than a
      hand-copied literal
- [x] 1.2 Raise `FeeConstants.MAX_PERFORMANCE_FEE_BPS` 1500 → 3000; add
      `DEFAULT_MAX_PERFORMANCE_FEE_BPS` (2000) and `BPS_DENOMINATOR` (10,000)
- [x] 1.3 Point `SyndicateFactory`'s default governor param at
      `FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS` (the headline, not the
      ceiling — fail-closed default)
- [x] 1.4 Fix suites pinning the old `1500` literal to reference
      `FeeConstants.MAX_PERFORMANCE_FEE_BPS`; full suite green; commit

## 2. ProtocolConfig — management and performance splits

- [x] 2.1 Write failing tests in `test/fees/ProtocolConfigSplits.t.sol`: split
      storage and getters, sum-to-10,000 validation, owner-only setters, and
      the agent-earns-most invariant at the proposed defaults
- [x] 2.2 Add `MgmtSplit`/`PerfSplit` structs (uint16 members, one storage slot
      each), `InvalidSplit` error, setters/getters, and `MgmtSplitSet`/
      `PerfSplitSet` events to `IProtocolConfig`
- [x] 2.3 Implement `setMgmtSplit`/`setPerfSplit` in `ProtocolConfig` with the
      sum-to-10,000 check; keep the legacy `protocolFeeBps`/`guardianFeeBps`
      fields in place (non-upgradeable contract — no layout benefit to removal)
- [x] 2.4 Tests pass; existing `ProtocolConfig` suite unaffected; commit

## 3. Snapshot the splits onto the proposal at propose

- [x] 3.1 Write failing test pinning that `StrategyProposal` carries both split
      snapshots and that a post-propose config change does not reach an
      already-created proposal
- [x] 3.2 Append `snapshotMgmtSplit`/`snapshotPerfSplit` to the end of
      `StrategyProposal` (append-only — the struct is stored in a mapping value
      on a beacon-upgraded governor); mark the now-unused flat-rate snapshot
      fields `@custom:deprecated` in place rather than removing them
- [x] 3.3 Snapshot both splits (alongside the existing fee recipients) in
      `propose`; stop writing the flat-rate snapshot fields
- [x] 3.4 Confirm `test/governor/GovernorLayoutPins.t.sol` and the regenerated
      storage-layout golden show no moved slot, only appended members; commit

## 4. Vault — management-fee accrual accumulator

- [x] 4.1 Write failing tests in `test/fees/MgmtFeeAccrual.t.sol`: a flat book
      accrues base × elapsed linearly; a mid-proposal outflow prorates the
      accrual correctly (halving the book at the midpoint owes 3/4 of the
      flat-book fee); consuming resets both the accumulator and the base; the
      accrual hooks are governor-only; pending accrual is readable via a view
      without a state-changing touch
- [x] 4.2 Add vault storage: `_mgmtAssetSeconds`, packed
      `_mgmtBase`/`_mgmtLastUpdate`, `_highWaterPricePerShare`, and packed
      `_crystallizedMgmt`/`_crystallizedPerf`/`_instantExitFeeBps` (shrinks
      `__gap` 32 → 28 slots)
- [x] 4.3 Implement `_touchMgmt`/`_adjustMgmtBase` (fold-elapsed-time-before-
      changing-the-base ordering) and the governor-only `onProposalExecuted`,
      `adjustMgmtBase`, `consumeMgmtAccrual`, plus the view
      `mgmtAccrualAssetSeconds`
- [x] 4.4 Wire the vault's own base-changing events: Lane A deposit, Lane A
      instant exit, and the `strategyMint`/`strategyBurn` custody hooks (valued
      via `convertToAssets` at the pre-change ratio)
- [x] 4.5 Stamp the base in `SyndicateGovernor.executeProposal` via
      `onProposalExecuted(balanceBefore)`
- [x] 4.6 Accrual tests, vault suite, and invariant suite pass; commit

## 5. Vault — high-water mark

- [x] 5.1 Write failing tests in `test/fees/HighWaterMark.t.sol`: the mark
      initializes at the first deposit's price per share; a loss-then-recovery
      back to a previously-charged peak charges nothing on the recovery leg;
      the mark advances only after a charged fee and never decreases on a loss
- [x] 5.2 Store `highWaterPricePerShare`; at settlement compute price per share
      on post-management-fee assets and charge performance only on
      `max(pps - mark, 0) × totalSupply`; ratchet the mark to
      `max(old, pps_after_fee)` after charging
- [x] 5.3 Declare the mark getter and the settlement hook on `ISyndicateVault`
- [x] 5.4 Tests pass; commit

## 6. Governor — rewrite `_distributeFees` to two split-distributions

- [x] 6.1 Rename the vault's performance-fee accessor to `performanceFeeBps`
      (the whole performance fee under the new model, not the agent's cut
      alone); keep `agentFeeBps` as a deprecated alias so existing integrations
      and the subgraph do not break; add `crystallizedMgmt`/`crystallizedPerf`
      getters
- [x] 6.2 Write failing tests extending `test/fees/FeeDistribution.t.sol` for
      the full settle path (management always charged, performance gated on
      above-mark profit, both split correctly)
- [x] 6.3 Rewrite the fee block in `_finishSettlement`: management fee charged
      on every settlement, not gated on `pnl > 0`
- [x] 6.4 Rewrite `_distributeFees` from the four-step sequential waterfall
      (protocol → guardian → agent → owner) to two split-distributions, each
      dividing one base directly instead of compounding deductions
- [x] 6.5 Add `ManagementFeeCharged`/`PerformanceFeeCharged` events (and
      `HighWaterMarkUpdated` from Task 5) to `ISyndicateGovernor`
- [x] 6.6 Tests pass; commit

## 7. Crystallize fees on Lane A instant exit

- [x] 7.1 Write failing tests in `test/fees/CrystallizeOnExit.t.sol` on the Lane
      A harness (real governor + PriceRouter mock)
- [x] 7.2 Implement the exit-fee computation: pro-rata share of the accrued
      management fee plus the per-share performance fee above the mark, on the
      exiting shares only
- [x] 7.3 Book crystallized amounts into `_crystallizedMgmt`/`_crystallizedPerf`
      (retained in the vault, not transferred at exit — deviation D2) and
      exclude them from `totalAssets()` so remaining holders' price per share is
      unaffected
- [x] 7.4 Override `previewRedeem`/`previewWithdraw` to account for
      crystallization (iterative gross-up for the non-invertible kinked
      exit-fee function — deviation D5); book the fees in `_withdraw`
- [x] 7.5 Net the settlement management-fee charge against the running
      crystallized total (`mgmtFeeDue_total - mgmtFeeCrystallized`) and clear
      counters in `onProposalSettled`
- [x] 7.6 Tests pass; commit

## 8. Instant-exit penalty

- [x] 8.1 Write failing tests in `test/fees/InstantExitFee.t.sol`: no penalty
      when an exit is served entirely from idle float; the penalty applies only
      to the strategy-pulled portion when an unwind is forced
- [x] 8.2 Implement `_exitPenalty`, gated to Lane A, charged only on the
      `withdrawTo`-sourced portion (kept as specced over a flat whole-exit
      basis — see design.md's adversarial analysis of the trade-off)
- [x] 8.3 Revive `instantExitFeeBps` (≤200 bps, proposed 50); the penalty
      accrues to the vault (remaining depositors), never to a fee recipient
- [x] 8.4 Confirm the vault runtime stays under Robinhood Chain's 98,304-byte
      `MaxCodeSize` (`forge build --sizes`); commit

## 9. Pay crystallized fees at settlement; cover the self-managed path

- [x] 9.1 Write failing tests extending `test/fees/FeeDistribution.t.sol`: an
      instant exiter pays management + performance at exit with no double-count
      at the following settlement; a queue exiter pays only through the settle
      price; a self-managing strategy pays management but not performance
- [x] 9.2 Add the crystallized-payout leg to `_distributeFees`, paid through the
      same `_payFee` fail-open escrow as ordinary distribution
- [x] 9.3 Confirm call ordering: the performance base is read before
      `consumeCrystallizedPerf()` releases the crystallized amount back into
      `totalAssets()` (deviation D5)
- [x] 9.4 Confirm `selfManagesFees` skips only the performance leg, not
      management (deviation D3); tests pass; commit

## 10. Documentation, goldens, and spec status

- [x] 10.1 Regenerate `script/syndicate-governor-layout.golden.json` and
      confirm `check-storage-parity.sh` passes with only appended members in
      the diff
- [x] 10.2 Add the two-number fee table to `README.md`
- [x] 10.3 Correct the product spec's "always-on" wording (headline table row
      and two supporting paragraphs) to state the management fee accrues only
      while a strategy is live, matching the shipped idle-capital exemption
- [x] 10.4 Flip both source docs' status to Implemented; record deviations
      D1-D5 and the rate/cap decisions so the spec and the code do not silently
      diverge
- [x] 10.5 Final verification: `forge fmt --check` clean, `forge build --sizes`
      shows `SyndicateVault`/`SyndicateGovernor` runtime under the size
      ceiling, full `forge test` suite green; commit
