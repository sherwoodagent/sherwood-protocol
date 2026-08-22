# Fee Mechanism — Two-Number Model

> Migrated from docs/superpowers/plans/2026-07-24-fee-mechanism.md + docs/specs/2026-07-24-fee-model-design.md + docs/product/2026-07-24-fee-model-product-spec.md (superpowers workflow) on 2026-08-01.

## Why

An earlier draft of Sherwood's fee model had grown to six separate depositor-facing
fees: management, volume (per-trade), performance, protocol, guardian, and owner.
That is not how a fund is priced — it is how a fund gets *audited*. A real hedge
fund pays a whole cast (portfolio manager, analysts, prime broker, administrator,
auditor) but shows the investor **two numbers**; everyone else's cut comes out of
those two, invisibly.

Two research findings drove the simplification:

- **No onchain fund charges a per-trade / volume fee.** Enzyme, dHEDGE, Yearn,
  Sommelier, Balancer, Index Coop, Ribbon, Arrakis — none of them. Per-trade fees
  exist only at the exchange layer (Hyperliquid taker fees, builder codes). A
  volume fee on a fund has no onchain precedent and reads as nickel-and-diming.
- **The management fee already does the volume fee's job.** The volume fee existed
  to earn revenue in flat months, back when performance-share was the only fee. An
  always-on management fee on assets is the industry-standard way to earn in flat
  months, so once one exists the volume fee is redundant.

So the volume fee is removed, and the four separate profit-side fees (protocol,
guardian, agent, owner) are folded into one 20% performance fee that splits behind
the scenes instead of a sequential four-step waterfall that compounded four
haircuts.

**The two numbers:**

| Fee | Rate | Charged on | Paid when |
|---|---|---|---|
| Management fee | 2%/yr (cap 3%) | fund assets, time-weighted, while a strategy is live | every settlement — profit, flat, or loss |
| Performance fee | 20% (cap 30%) | profit above the high-water mark | profitable settlements only |

**The splits** (governance-set, must each sum to 10,000 bps): management fee
70/20/10 (agent/protocol/guardian); performance fee 60/15/15/10
(agent/protocol/guardian/owner). The agent remains the largest earner in every
market — 70% of the always-on fee and 60% of the carry. Giving the guardian
network a slice of the *management* fee (0.20%/yr on AUM, paid regardless of
profit) is what replaces the volume fee's flat-month role and closes the
guardian-funding gap the economic-security analysis flagged: review effort
doesn't stop when markets go flat, so the funding shouldn't either.

**The high-water mark** is new, and table stakes: the performance fee is only
charged on gains above the fund's previous peak (~85% of hedge funds have this;
every onchain fund with a performance fee does — Enzyme, dHEDGE, Hyperliquid
vaults). Sherwood's prior per-proposal profit measurement did not have one, which
meant a volatile fund could be charged twice on the same recovered dollars.

**Redemption terms** (not headline fees): no deposit fee; the settlement queue is
always free; an instant exit is charged twice for two different reasons — (1) the
exiter's fair share of fees is crystallized at the moment of exit so leaving early
cannot dodge them, and (2) an early-exit penalty (≤2%, proposed 0.5%) on top,
which accrues to the fund (the depositors who stay) rather than to any fee
recipient, compensating them for the cost of an out-of-schedule unwind.

## What Changes

- **Management fee** becomes an always-on, time-weighted charge on deployed
  capital (asset-seconds accumulator on `SyndicateVault`, restamped on every
  base-changing event: execute, Lane A deposit/instant-exit, `strategyMint`/
  `strategyBurn`), charged at every settlement regardless of P&L instead of being
  profit-gated.
- **Performance fee** becomes profit above a stored per-share high-water mark
  (`highWaterPricePerShare`) instead of raw per-proposal `pnl`; computed on
  post-management-fee price per share; the mark ratchets upward only, after each
  charge.
- **`_distributeFees`** rewritten from a four-step sequential waterfall
  (protocol → guardian → agent → owner) to two single-division split-distributions
  — management always, performance only on above-mark profit — each split
  snapshotted onto the proposal at propose time (`ProtocolConfig.mgmtSplit()` /
  `perfSplit()`) so a post-vote governance change cannot move what an in-flight
  proposal pays.
- **Fee crystallization on Lane A instant exit**: exiting shares' pro-rata accrued
  management fee and above-mark performance fee are computed at exit and retained
  in the vault (`_crystallizedMgmt`/`_crystallizedPerf`), excluded from
  `totalAssets()`, and paid to the recorded recipients at the next settlement —
  rather than transferred immediately, which would require a governor call on the
  ERC-4626 hot path.
- **Instant-exit fee** (`instantExitFeeBps`, ≤200 bps, proposed 50): a second,
  independent early-exit penalty on the strategy-pulled portion of a Lane A exit,
  accruing to the vault, revived from a design that had been deferred on Base's
  EIP-170 bytecode ceiling — unblocked by Robinhood Chain's 98,304-byte
  `MaxCodeSize`.
- **`MAX_PERFORMANCE_FEE_BPS`** raised 1500 → 3000 (30%) to allow the 20% headline
  with governance headroom; new factory-deployed vaults default their per-vault
  governor cap to `DEFAULT_MAX_PERFORMANCE_FEE_BPS` = 2000 (the headline), not the
  3000 ceiling, so charging above the advertised rate requires an explicit,
  separately visible governor param change (fail-closed default).
- **Volume fee removed** — turned out to be a no-op: `grep -rn
  "volumeFee\|_chargeVolume\|VolumeFeePaid" src/` found nothing built, so no
  deletion work was required.
- **`selfManagesFees`** strategies now still pay the management fee (only the
  performance leg is skipped) since the profit-measurement defect that motivates
  the exemption does not reach a fee computed from capital × time.

## Capabilities

- fee-splits
- management-fee
- performance-fee
- instant-exit-fees
- syndicate-vault
- syndicate-governor

## Impact

- `src/FeeConstants.sol` — raised performance-fee ceiling, new default cap and
  shared `BPS_DENOMINATOR`
- `src/interfaces/IProtocolConfig.sol`, `src/ProtocolConfig.sol` — `MgmtSplit`/
  `PerfSplit` structs, setters, `InvalidSplit` error, events
- `src/interfaces/ISyndicateGovernor.sol` — `StrategyProposal` gains
  `snapshotMgmtSplit`/`snapshotPerfSplit`; old flat-rate snapshot fields
  deprecated in place
- `src/interfaces/ISyndicateVault.sol`, `src/SyndicateVault.sol` — management-fee
  accrual accumulator, high-water mark storage, crystallization storage/logic,
  instant-exit-fee logic, renamed `performanceFeeBps()` accessor
- `src/SyndicateGovernor.sol` — execute-time accrual stamp, rewritten
  `_finishSettlement`/`_distributeFees`, propose-time split snapshot
- `src/SyndicateFactory.sol` — default `maxPerformanceFeeBps` raised to the
  headline (2000)
- `test/fees/*.t.sol` — new suites: `FeeConstantsCap`, `ProtocolConfigSplits`,
  `MgmtFeeAccrual`, `HighWaterMark`, `FeeDistribution`, `CrystallizeOnExit`,
  `InstantExitFee`
- `README.md`, storage-layout goldens — updated fee table and regenerated goldens
