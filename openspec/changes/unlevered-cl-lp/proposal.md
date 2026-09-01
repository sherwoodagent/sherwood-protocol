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
against wrapper collateral. That borrow leg is dead on chain 4663 today, and
not marginally:

| collateral | template-compatible? | lendable (2026-08-31, live) |
|---|---|---|
| spUSDG | yes — verified 4626, `asset() == USDG` | **$3** (drained; was $1.19M on 08-04) |
| syrupUSDG | **no** — no `asset()` selector, `_isWrapperOf` rejects it (correctly) | $9.15M |
| USDe | no — not a wrapper of the vault asset, by design | $27M |

So the template's only valid collateral has an empty market, and the deep
markets are structurally outside its (sound) wrapper rule. Every levered CL
proposal on this chain is currently unfundable — while the unlevered version
of the same strategy needs no Morpho at all and is economically live today.

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
