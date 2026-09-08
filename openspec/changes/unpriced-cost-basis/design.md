# Design — unpriced cost basis

## The defect in one line

Settlement measures performance as a vault-asset balance delta, which silently
asserts that every strategy round-trips into the vault asset. Two templates
deliberately do not, and the protocol reports their deliberate conversions as
losses.

## Why this is not a LaunchpadStrategy bug

`ConcentratedLiquidityStrategy.hasUnvaluedResidue()` returns `true` for a live
LP position and for the volatile leg. A CL proposal that settles holding its
position reports the same false loss and faces the same settle-price floor.
The two templates that override `hasUnvaluedResidue()` are exactly the two
that need the fix, which is the signal that the fix belongs at the
`IStrategyDelivery`/governor seam and not inside either template.

`MorphoSupplyStrategy` and `PortfolioStrategy` never override the residue
predicates; they inherit `false`/`0` and are untouched by this change in both
source and behaviour.

## Rejected alternatives

**Price the inventory.** Register a feed for the launch token so
`totalAssets()` counts it. Rejected on two independent grounds. It contradicts
the stated fee policy — pricing unrealized inventory lifts price-per-share
above the high-water mark and pays a performance fee on paper gains that no
one can redeem. And it imports oracle risk into settlement, which this
codebase has deliberately kept out: `undeliveredValue()` exists precisely
because the templates refuse to price what they cannot price honestly.

**Let the governor derive it.** Treat capital that left and did not return as
converted whenever `hasUnvaluedResidue()` is true. Requires no interface
change and no new trusted number — and cannot distinguish a real loss from a
conversion. A strategy that lost its entire deployment while holding one wei
of an unpriced token would report zero P&L and waive the settle-price floor
completely. That is strictly worse than the overstated loss we have now, which
at least errs toward alarm.

## The load-bearing invariant

The governor accepts a number from the strategy, so the change is only as safe
as the bound the governor puts on it. That bound is computed by the governor
from values it already owns:

```
apparentLoss = snapshot > balanceNow ? snapshot - balanceNow : 0
basis        = min( probe(strategy), apparentLoss )
pnl          = int256(balanceNow + basis) - int256(snapshot)
```

Because `basis <= apparentLoss`, `pnl <= 0` whenever the proposal is nominally
down, and the credit can move P&L to at most exactly zero.

> **A conversion can erase a reported loss. It can never manufacture a gain.**

This is what makes the new trusted number safe to introduce at all. A
template that is buggy, miscompiled, or outright malicious and returns
`type(uint256).max` moves reported P&L to zero and no further. It cannot
create profit, so it cannot create a performance fee, so it cannot extract
value through this path. The worst it achieves is concealing a loss it already
caused — and the settle-price floor, which is credited by the same clamped
figure, still bounds how far price-per-share may have fallen before the
proposal is refused the ordinary settlement path.

This also promotes the user-facing policy from coincidence to guarantee. "No
performance fee until tokens are realized" currently holds because
`totalAssets()` omits unpriced inventory and `aboveHighWaterMark()` returns
zero below the mark — two subsystems that happen to agree. After this change
the clamp enforces it directly at the P&L seam as well.

## Reading the basis

The governor reads `unpricedCostBasis()` through the bounded-gas staticcall
idiom `SyndicateVault` already uses for `undeliveredValue()` and
`hasUnvaluedResidue()`: `staticcall{gas: _PROBE_GAS}` with `_PROBE_GAS =
150_000`, treating a revert, an out-of-gas, or a short return as zero.

Zero-on-unreadable is what removes the migration. A certified template
compiled before this change fails the probe, contributes no basis, and settles
byte-for-byte as it does today. No deployed clone needs redeployment. The
probe is retained even though the repo is pre-migration and every in-repo
template will implement the view, because the callee is an arbitrary clone
address and a typed call that reverted would brick settlement outright.

### Timing

`settleProposal` runs the pre-committed settlement calls — including
`strategy.settle()` — before `_finishSettlement` computes P&L. The strategy is
therefore already `Settled` when the probe fires, in the same transaction, and
`LaunchpadStrategy._settle()` pushes only the vault asset to the vault
(`_pushAllToVault(asset)`), leaving the launch token with the clone. The
figure is read once, at that instant; nothing decays or needs recomputing
later.

### Why the basis is recorded, not measured live

The obvious implementation reads live balances at probe time. It is wrong at
the edges: `sweep()` may move the inventory to the vault, and the vault does
not price it either, so the P&L stays understated while a balance-derived
basis would have collapsed to zero. The inventory changing hands between two
contracts that both decline to price it does not realize anything.

So each template RECORDS the vault-asset cost at execute and reports the
recorded figure while that capital remains unrealized, rather than deriving it
from whatever it happens to hold when asked. Realization — selling the
inventory back into the vault asset — happens through a later proposal, whose
own settlement measures the gain against the mark in the ordinary way.

## Governor changes

**P&L.** The credit is a second adjustment term alongside the existing
interim-LP-flow exclusion, which already establishes that the raw balance
delta is not by itself the performance measure.

**Both drawdown gates.** Settlement applies two independent drawdown gates,
and a conversion trips both. Crediting only one would leave the defect in
place.

1. The CAPITAL floor takes `allowance = effectiveMaxCapital * maxDrawdownBps /
   10_000` and, when the capital snapshot exceeds it, requires the vault's
   realized asset balance to clear `snapshot - allowance` or reverts
   `SettlementBelowDrawdownFloor`. The credit makes the comparison
   `realized + basis >= floor` — converted capital counts as realized for the
   purpose of a gate that exists to catch value that vanished.
2. The SETTLE-PRICE floor (`_requireSettlePriceAboveFloorHook`, pashov finding
   #2) credits the basis converted into price-per-share units, rounded DOWN so
   the relief can never exceed the conversion that earned it.

Together these remove the total-loss declaration and the
`MAX_STAMP_DRAWDOWN_BPS = 9_000` ceiling for converting strategies. Both
floors remain fully in force for the uncredited remainder: a converting
strategy that ALSO loses money is still held to its declared envelope on the
loss.

Note the asymmetry this repairs. The capital floor is skipped outright when
`allowance >= snapshot`, so today a launch can only settle by declaring
`maxDrawdownBps = 10_000` — which does not merely look alarming to a
guardian, it switches the capital gate off completely for that proposal. After
this change a launch declares an envelope describing the risk it is actually
taking, and the gate stays armed on the portion that is genuinely at risk.

`unstick` and `finalizeEmergencySettle` route through
`_finishSettlementHook` and remain ungated by the capital floor, and the
rescue path keeps its existing absolute backstop. Both unchanged.

**Propose-time declaration.** The governor probes the named strategy for
`IStrategyDelivery.expectsUnpricedResidue()` at propose time — the same
bounded staticcall shape it already uses there to read `IStrategy.proposer` —
and snapshots the answer onto `StrategyProposal`. The flag is a property of the
TEMPLATE rather than of one proposal's parameters, so it is answerable before
the clone has run: every launch converts, no Morpho supply does.

Deriving it from the template rather than accepting it from the proposer is
strictly stronger. A proposer input could be asserted falsely to buy drawdown
relief a strategy never earned; a template input cannot be set by the proposer
at all. Guardian visibility — the actual requirement — is unaffected, since the
snapshot lives on the proposal either way. It also leaves `RiskEnvelope` and
the `propose` ABI alone: an earlier draft added the field there, which forced
56 mechanical call-site edits and pushed the full test build past the Yul stack
limit.

At settle:

| declared | strategy reports | outcome |
|---|---|---|
| true | basis > 0 | credited, `UnpricedConversion` emitted |
| true | basis == 0 | ordinary settlement, no credit |
| false | basis > 0 | **revert** |
| false | basis == 0 | ordinary settlement |

Both halves now come from code the TierRegistry certified — the amount at
settlement, the intent at propose — and neither is proposer-supplied. The
proposal's snapshot is what makes the intent visible to a guardian before
execution; the settle-time comparison is what stops a template quietly
converting on a proposal that never announced it.

**Storage.** `maxDrawdownBps` (`uint16`) and `envelopeTier` (`uint8`) occupy
3 bytes of a 32-byte slot. The new `bool` packs into the same slot, so no
later member's offset moves and the mapping layout is unchanged — which
matters because the governor is a `BeaconProxy` and `_proposals` is laid out
by member index.

**Event.** `ProposalSettled` keeps its exact signature; appending a field
would break every indexer decoding it. A companion
`UnpricedConversion(proposalId, vault, costBasis)` is emitted only when the
credited basis is nonzero, so the app can render "1,200 USDG deployed into an
unpriced position" instead of "-1,200".

## Template implementations

**LaunchpadStrategy.** The vault asset actually consumed acquiring the
retained launch tokens: the vault-asset amount swapped into the quote, plus
the venue's native launch fee sourced per `nativeFeeSource()`, less any quote
returned and converted back by `_convertQuote` at settle. Recorded at execute.

**ConcentratedLiquidityStrategy.** The vault asset contributed to the position
that is still open, less what unwinding has already returned. Recorded when
the position is opened.

**The coupling, enforced by test.** A template that overrides
`hasUnvaluedResidue()` to return true owes a cost basis for what it refuses to
price. This mirrors the coupling `BaseStrategy` already documents between
`hasUndeliveredValue()` and `undeliveredValue()` — a bool and the amount it
describes must not diverge — and is the one genuinely new obligation this
change places on future templates.

## Testing

- **The clamp under a hostile template.** A mock reporting
  `type(uint256).max` settles at exactly zero P&L, accrues no performance
  fee, and does not lift the high-water mark. This is the test that says the
  new trusted number cannot be used to extract value.
- **Floor relief.** A launch deploying more than `MAX_STAMP_DRAWDOWN_BPS` of
  NAV settles through the ordinary permissionless path with a modest declared
  envelope — the behaviour that is impossible today.
- **Floor still binds.** A converting strategy that ALSO loses money beyond
  its declared envelope is still refused.
- **Declaration mismatch.** `basis > 0` on an undeclared proposal reverts.
- **CL with a live position.** Settles with honest P&L rather than a reported
  total loss.
- **Unreadable probe.** A template without the view settles exactly as before.
- **Bool/basis coupling** across all four templates.
- **Sweep independence.** Sweeping the inventory to the vault between settle
  and the probe does not change the reported basis.

## Out of scope

- Pricing any unpriced inventory, now or later.
- `totalAssets()`, `pricePerShare()`, the high-water mark, and
  `_chargePerformanceFee` are untouched. The fee remains high-water-mark
  gated and the inventory remains unpriced.
- The Sushi V2 interface and "moon mode" support, pending updated venue docs.
