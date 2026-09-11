# Proposal: Unlevered mode for ConcentratedLiquidityStrategy

## Why

The datanet's highest-conviction strategy family (NVDA/USDG CL LP — 8.9M WOOD
on the momentum pod) targets a venue that has quadrupled since the pods were
minted: NVDA/USDG 0.05% at $5.2M TVL, $33.4M/day — ~0.32% fees/day full-range
equivalent, verified live 2026-08-31.

`ConcentratedLiquidityStrategy` already implements everything the family needs
— TWAP execute gate, rerange policy, pool-share cap, settlement/residue
conformance — but it structurally REQUIRES leverage: `_initialize` reverts on
`borrowAmount == 0`, and `_execute` funds the LP entirely from a Morpho borrow
against wrapper collateral. On chain 4663 that leg rests on a single market:

| collateral | template-compatible? | lendable (2026-09-01, live) |
|---|---|---|
| spUSDG (`0x0309c02d…`) | yes — verified 4626, `asset() == USDG` | **~$2.4M** (on-chain: supply 21.58M, borrow 19.14M USDG) |
| spUSDG (`0x6c023a68…`) | yes — same collateral, duplicate market | $3 (empty; never used) |
| syrupUSDG | **no** — no `asset()` selector, `_isWrapperOf` rejects it (correctly) | $9.08M |
| USDe | no — not a wrapper of the vault asset, by design | $30.5M |

(An earlier draft of this table reported spUSDG as "$3, drained" — that was
the empty duplicate market; the deep one is the `MARKET_ID` the levered fork
test already uses. Corrected per review.)

So a levered CL proposal IS fundable today, up to roughly the lendable figure
of one market whose depth has swung between $1.2M and $3.9M over the past
month. The deep markets sit outside the template's (sound) wrapper rule and
cannot substitute. That makes the borrow leg a single-market dependency the
strategy's economics do not need: the NVDA/USDG venue is live and deep on its
own, and an unlevered position carries no liquidation surface, no interest
drag, and no exposure to that one market's utilization. Unlevered mode makes
the family proposable at the size the venue supports regardless of what
Morpho is doing that day.

## What changes

One capability, one mode:

- `ConcentratedLiquidityStrategy` accepts an UNLEVERED configuration:
  `collateralAmount == 0 && borrowAmount == 0`, with a new explicit
  `lpAmount > 0` field naming the vault asset to pull and deploy directly
  into the position. Mixed configurations (exactly one of collateral/borrow
  zero, or `lpAmount` set alongside a borrow) revert at init — a proposal is
  either levered or unlevered, never an ambiguous blend.
- In unlevered mode the Morpho surface is fully absent: `morpho` and
  `marketParams` may be zero, the market-existence / borrow-fits-lendable /
  LTV-buffer init checks are skipped (there is nothing they would check), and
  every runtime Morpho read is zero-guarded so settle, sweep,
  `undeliveredValue` and the emergency paths never call a zero address.
- Levered mode is byte-for-byte unchanged, including the `borrowAmount == 0`
  revert *within* it — the guard's original intent (no accidental
  zero-borrow levered config) survives as the mixed-mode revert.

## Non-goals

- No syrupUSDG accommodation. Its rejection by `_isWrapperOf` is the rule
  working: a collateral the template cannot statically verify as a wrapper of
  the vault asset carries depeg risk the LTV math does not price. If Maple
  depth matters later, that is its own proposal with its own risk argument.
- No changes to the rerange policy, TWAP gate, pool-share cap, or any
  settlement semantics.
- No new template contract — this widens the existing one, so the factory
  allowlist entry, guardian known-targets and audit surface stay singular.
  (The vnet factory does not yet carry the CL template at all; deploying and
  approving it is an ops task in tasks.md, not a spec change.)

## Deployment intent

First proposal after merge: unlevered NVDA/USDG 0.05% LP on the vnet, full
lifecycle through the guardian fleet (the first economically real strategy
the fleet reviews). The levered variant re-arms automatically the day a
compatible market has depth — no further protocol work.
