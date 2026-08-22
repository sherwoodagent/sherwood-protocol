> Merged via PR #68 (originally authored as an independent OpenSpec change proposal, reconciled into the migrated spec tree on 2026-08-01).

## Why

Sherwood's fee code today is a four-step sequential waterfall in
`SyndicateGovernor._distributeFees` — protocol, then guardian, then agent, then owner
— each taking a haircut off the remainder of the last, all of it gated on `pnl > 0`
measured per proposal against the execute-time balance. Three consequences follow, and
each is a real defect rather than a preference:

1. **Nobody is paid in a flat month.** Every fee is profit-gated, so guardians who
   review proposals and agents who manage the book earn nothing when markets go
   sideways. The economic-security analysis (`docs/papers/guardian-network-economic-security.md`
   §3.10) names the resulting cohort-collapse risk directly: reward that scales only
   with profit cannot fund work that happens regardless of profit.
2. **A volatile fund is charged twice on the same dollars.** Profit is measured per
   proposal with no high-water mark, so a fund that runs $100 → $120 → $95 → $120 pays
   a performance fee on the $95 → $120 recovery it already paid for.
3. **A Lane A instant exiter escapes their fee share.** Instant exits happen
   mid-proposal at a live oracle price with no fee deducted, so the exiter's accrued
   management and performance fees leak onto the depositors who stay. (Lane B queue
   exits are already correct — they claim at the frozen post-`_distributeFees` price.)

The product decision of 2026-07-24 replaces the whole stack with two depositor-facing
numbers priced like a hedge fund — **2 and 20** — and pays everyone else out of
governance-set internal splits. This change applies that model. The design, product
framing, and a task-level implementation plan already exist in-repo
(`docs/specs/2026-07-24-fee-model-design.md`,
`docs/product/2026-07-24-fee-model-product-spec.md`,
`docs/superpowers/plans/2026-07-24-fee-mechanism.md`); none of it is built.

## What Changes

- **New always-on management fee.** `managementFeeBps` (proposed 200 = 2%/yr) charged
  on time-weighted deployed capital and paid on *every* settlement, not only profitable
  ones. Split three ways (agent/protocol/guardian, proposed 70/20/10). This is the
  guardian funding that §3.10 called for, and it exists at v1.
  - **BREAKING**: `managementFeeBps` semantics change from profit-gated to
    AUM-time-weighted. The storage slot is reused; the meaning is not the same.
- **New high-water mark on the performance fee.** `highWaterPricePerShare` stored on
  the vault; the performance fee applies only to `max(pps − highWaterPricePerShare, 0)
  × totalSupply`, and the mark ratchets after each charge. Ordering is management fee
  first (it lowers `pps`), then the HWM gate, then performance.
- **BREAKING: the four-step sequential waterfall is replaced by two split
  distributions.** `_distributeFees` no longer compounds protocol → guardian → agent →
  owner haircuts. One split on one base, twice. This lowers total fee load on the same
  month while raising the headline rate.
- **New split configuration on `ProtocolConfig`.** `MgmtSplit` (agent/protocol/guardian)
  and `PerfSplit` (agent/protocol/guardian/owner), each required to sum to 10 000,
  snapshotted onto the proposal at propose exactly as `protocolFeeBps`/`guardianFeeBps`
  are today.
- **BREAKING: `MAX_PERFORMANCE_FEE_BPS` raised 1500 → 3000**, with the factory default
  `maxPerformanceFeeBps` raised 1500 → 2000 so a 20% headline is not silently clamped
  at settle. The protocol constant is a backstop, not a target; three limits stack
  below it.
- **New fee crystallization on Lane A instant exit.** The exiting shares' pro-rata
  management and performance fees are booked into the vault (excluded from
  `totalAssets()`) at exit and paid to the correct snapshot recipients at the next
  settlement. Exit timing becomes fee-neutral.
- **New instant-exit penalty.** `instantExitFeeBps` (≤ 200, proposed 50), charged on
  the `withdrawTo`-sourced portion of a Lane A exit only, accruing to the vault
  (remaining depositors). This is a second, independent charge stacking on top of
  crystallization — different purpose, different destination. It was specced and
  deferred in `docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md` §6 on
  EIP-170 bytecode headroom; Robinhood Chain's 96 KiB ceiling lifts that constraint.
- **Not removed, because it was never built:** the per-trade volume fee. `grep -rn
  "volumeFee\|_chargeVolume\|VolumeFeePaid" src/` returns nothing, so the design spec's
  §2.3 "removal" is a no-op. No deletion work.

## Capabilities

### New Capabilities

- `fee-splits`: Governance-set management and performance split configuration on
  `ProtocolConfig` (each summing to 10 000), its caps and validation, and the
  propose-time snapshot of both splits onto `StrategyProposal` so a settlement pays
  the rates that were in force when the proposal was made.
- `management-fee`: The always-on, time-weighted AUM fee — its accrual base
  (an asset-seconds accumulator on `SyndicateVault` updated on every base-changing
  event), its unconditional charge at settlement regardless of P&L, its
  consume-and-reset semantics, and the accepted behaviour that capital idle between
  proposals accrues nothing.
- `performance-fee`: The profit-share fee — the stored `highWaterPricePerShare`, the
  above-mark profit base, the ratchet, the fee ordering relative to the management
  fee, and the clamping behaviour when a vault's configured rate exceeds the
  governor's per-vault ceiling.
- `instant-exit-fees`: Both Lane A exit charges — pro-rata crystallization of accrued
  management and performance fees into the vault at exit (and their deferred payment
  to snapshot recipients at settlement without double-counting), and the separate
  early-exit penalty on the pulled portion that accrues to remaining depositors.

### Modified Capabilities

<!-- None. `openspec/specs/` is empty; this repo has no previously captured
     capability specs, so all four deltas above are new files. -->

## Impact

**Contracts modified** (no linear storage reordering; vault `__gap` shrinks 32 → 28,
governor split snapshots live inside the `_proposals` mapping so the frozen slot pins
in `test/governor/GovernorLayoutPins.t.sol` are untouched):

- `src/FeeConstants.sol` — raised perf ceiling, shared `BPS_DENOMINATOR`
- `src/ProtocolConfig.sol` + `src/interfaces/IProtocolConfig.sol` — split structs,
  setters, validation errors
- `src/SyndicateGovernor.sol` + `src/interfaces/ISyndicateGovernor.sol` —
  `_distributeFees` rewritten (`:1153`), execute-time accrual stamp, two packed
  split-snapshot fields on `StrategyProposal`
- `src/SyndicateVault.sol` + `src/interfaces/ISyndicateVault.sol` — accrual
  accumulator, high-water mark, crystallization ledger, exit-fee preview and penalty
  (4 new storage slots)
- `src/SyndicateFactory.sol` — default `maxPerformanceFeeBps` 1500 → 2000

**Deliberately untouched:** all 12+ concrete strategies. Every management-fee
base-changing event already passes through the vault, so no per-strategy metering is
added. `LeveragedAerodromeCLStrategy`'s existing `selfManagesFees` path keeps skipping
the *performance* leg only — the management fee does not use P&L, so the reason
`selfManagesFees` exists does not apply to it.

**Downstream:** subgraph gains `managementFee`/`performanceFee` per proposal with their
splits plus the high-water-mark series; README fee table; the two source docs flip from
"Proposed"/"Design — not implemented" to implemented.

**Risk to verify at apply time:** the source design and plan were written against a
tree based at PR #13 (`9fafa00`), 26 commits behind this change's base
`integration/lifecycle-planb`. Spot-checked line anchors still hold
(`_distributeFees:1153`, `_finishSettlement:1062`, `_payFee:1267`,
`SyndicateVault.transferPerformanceFee:543`, `__gap[32]:186`,
`SyndicateFactory.maxPerformanceFeeBps:419`), but the plan's remaining anchors must be
re-confirmed before each task rather than trusted.
