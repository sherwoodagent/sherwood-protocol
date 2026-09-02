# Report converted capital as converted, not lost (SHE-153)

## Why

`_finishSettlement` computes P&L as the vault's asset-balance delta against
the capital snapshot:

```solidity
uint256 balanceAdjusted = IERC20(asset).balanceOf(vault);
pnl = int256(balanceAdjusted) - int256(snapshot);
```

That measure assumes every strategy round-trips back to the vault asset. Two
templates deliberately do not, and both already say so through
`IStrategyDelivery.hasUnvaluedResidue()`:

- `LaunchpadStrategy` spends vault capital acquiring a launch token the fund
  refuses to price. A live launch settles with the whole deployment reported
  as loss.
- `ConcentratedLiquidityStrategy` returns `true` for a live LP position
  (`tokenId != 0`) and for its volatile leg. A CL proposal that settles
  holding its position reports the same false loss.

The consequences are not cosmetic:

1. **P&L reads as theft.** A verified launch on the vnet reported the full
   1,200 USDG deployment as a loss. The first reviewer to see it read it as
   malicious, which is the correct reading of the number the protocol emitted.
2. **The proposal must declare a total-loss envelope to settle at all.**
   Settlement applies TWO independent drawdown gates, and a conversion trips
   both because it is indistinguishable from a loss in the measure each uses:
   - the CAPITAL floor — `allowance = effectiveMaxCapital * maxDrawdownBps`,
     and if the capital snapshot exceeds it, the vault's realized asset
     balance must clear `snapshot - allowance` or settlement reverts
     `SettlementBelowDrawdownFloor`;
   - the SETTLE-PRICE floor — `_requireSettlePriceAboveFloorHook` compares
     live price-per-share against
     `ppsAtExecute * (10_000 - maxDrawdownBps) / 10_000`.

   The capital floor is skipped entirely when `allowance >= snapshot`, which
   is why the vnet launches declared `maxDrawdownBps = 10_000`: a maximal
   declaration is currently the only way to settle a launch. Guardians
   reviewing such a proposal are shown a declared total loss for an ordinary
   operation, and the declaration is load-bearing rather than decorative.
3. **There is a hard ceiling on deployment size.** The price floor caps
   `declared` at `MAX_STAMP_DRAWDOWN_BPS = 9_000`, so even a maximal
   declaration cannot waive it: a fund cannot route more than 90% of NAV
   through a converting strategy and still settle by the ordinary
   permissionless path; beyond that it needs owner-gated `unstick`.

The performance fee is NOT part of the defect. It is high-water-mark gated:
`aboveHighWaterMark()` returns zero while price-per-share sits below the mark,
and unpriced inventory never lifts `totalAssets()`. The policy "no performance
fee until tokens are realized" is already the behaviour. This change makes it
a structural guarantee rather than a coincidence of two subsystems.

## What Changes

- `IStrategyDelivery` gains `unpricedCostBasis()` — the vault-asset amount the
  strategy spent acquiring inventory it refuses to price — with a
  `return 0` default on `BaseStrategy`, so only templates that already
  override `hasUnvaluedResidue()` implement it.
- `SyndicateGovernor._finishSettlement` probes that view through the same
  bounded-gas staticcall idiom `SyndicateVault` already uses
  (`_PROBE_GAS = 150_000`, unreadable → 0) and credits the result to P&L:
  `pnl = int256(balanceAdjusted + basis) - int256(snapshot)`.
- **The credit is clamped by the governor to the proposal's own apparent
  loss.** A conversion can erase a reported loss and can never manufacture a
  gain, so the new trusted number cannot create a performance fee that would
  not otherwise exist — see design.md, which treats this as the load-bearing
  invariant of the change.
- BOTH drawdown gates credit the same clamped basis: the capital floor
  compares `realized + basis` against its floor, and
  `_requireSettlePriceAboveFloorHook` credits the basis converted into
  price-per-share units, rounded DOWN so the relief never exceeds the
  conversion that earned it. This removes both the total-loss declaration and
  the 90% deployment ceiling for converting strategies, and restores
  `maxDrawdownBps` to describing risk the proposer is actually taking.
- `StrategyProposal` gains `bool expectsUnpricedResidue`, declared at propose
  time. At settle, a strategy reporting a basis on a proposal that did not
  declare one SHALL revert. Guardians see the intent during review; the
  proposer cannot inflate the relief.
- New event `UnpricedConversion(proposalId, vault, costBasis)`, emitted only
  when the credited basis is nonzero. `ProposalSettled` keeps its exact
  signature — appending a field would break every consumer decoding it.
- `LaunchpadStrategy` and `ConcentratedLiquidityStrategy` implement the view.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-governor`: settlement P&L gains a second adjustment term
  alongside the existing interim-LP-flow exclusion; the settle-price floor
  becomes conversion-aware; the risk envelope gains a propose-time
  declaration that settlement checks against the strategy's own report.
- `performance-fee`: the guarantee that unrealized conversions earn no
  performance fee becomes structural — stated as a requirement and enforced
  by the clamp, rather than resting on the high-water mark alone.

## Impact

- `src/interfaces/IStrategyDelivery.sol` — new view declaration.
- `src/strategies/BaseStrategy.sol` — `virtual` default returning 0.
- `src/strategies/LaunchpadStrategy.sol` — override: quote spent plus the
  venue's native launch fee, in vault-asset terms at execute-time cost.
- `src/strategies/ConcentratedLiquidityStrategy.sol` — override: vault asset
  contributed to the live position, less what has been returned.
- `src/strategies/MorphoSupplyStrategy.sol`, `src/strategies/PortfolioStrategy.sol`
  — unchanged; neither overrides the residue predicates, so both inherit 0.
- `src/SyndicateGovernor.sol` — probe, clamp, P&L credit, credits in both
  drawdown gates, propose-time declaration, new event.
- `src/interfaces/ISyndicateGovernor.sol` — `RiskEnvelope` and
  `StrategyProposal` gain the declaration, plus the new event. The field is a `bool` packed into the existing
  `maxDrawdownBps`/`envelopeTier` slot (3 of 32 bytes used), so the struct's
  layout is unchanged and no later member shifts.
- No migration: no deployed clone requires redeployment, because an
  unreadable probe is treated as zero and settles exactly as it does today.
