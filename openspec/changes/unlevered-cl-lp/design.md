# Design: unlevered mode

## The mode matrix (D1)

```
                     collateralAmount   borrowAmount   lpAmount   morpho/marketParams
levered (unchanged)        > 0             > 0            0        bound + checked
unlevered (new)             0               0           > 0        MUST be zero
anything else                        revert InvalidAmount / MixedModeConfig
```

Both-or-neither, decided at init, immutable after. An explicit new `lpAmount`
field rather than overloading `collateralAmount`, because in levered mode the
pulled amount IS collateral and the LP is funded by the borrow — reusing the
field would silently change what the number means depending on mode, which is
exactly the class of ambiguity `_initialize`'s natspec exists to kill.
`InitParams` is only ever `abi.decode`d from proposal bytes against this
template's own struct, so adding a field is safe; the new template address is
a fresh factory-allowlist entry regardless.

Requiring `morpho == address(0)` in unlevered mode (rather than tolerating a
set-but-unused address) keeps the config honest: a reviewer reading the
proposal must not see a Morpho market named in a proposal that will never
touch it.

## Where each borrow assumption lives, and what happens to it (D2)

Traced 2026-08-31 on `post-audit`:

| site | today | unlevered mode |
|---|---|---|
| `_initialize` guard `collateralAmount == 0 \|\| borrowAmount == 0` | rejects | becomes the mode fork; mixed configs still revert |
| init checks (2)(3)(4): wrapper probe, borrow ≤ lendable, LTV buffer | run always | skipped — nothing to check; gated on mode, not on individual zeros |
| governance binding of `morpho` | bound always | skipped (zero); `pool`, `positionManager`, `uniswapFactory`, `swapAdapter` binding UNCHANGED |
| `_execute`: pull → `_postCollateral` → `morpho.borrow` → mint | all four | pull `lpAmount` → mint. The mint path itself is untouched — it already consumes "held asset", which at execute is identical in both modes |
| `_settle` → `_repayAndWithdraw` | reads `morpho.position` unconditionally, then branches on `borrowShares != 0` | early-return `(0, 0)` when `morpho == address(0)`. The existing zero-shares branch is NOT sufficient — the position read itself would be a call to address zero |
| `undeliveredValue` / `hasUndeliveredValue` / emergency paths | read Morpho state | same zero-guard; audit EVERY `morpho.` and `_marketParams` read site in the sweep task, not just the ones named here |

The settle order comment ("unwind → collect → convert → repay → withdraw →
push") keeps its meaning with the repay/withdraw stages vacuous.

## Why not `borrowAmount = 0` with collateral still posted (D3)

Posting collateral and borrowing nothing parks vault capital in Morpho for
zero yield to the position and adds a supplyCollateral/withdrawCollateral
round trip plus an oracle dependency, for nothing. It also keeps the
market-depth dependency this change exists to remove. Rejected.

## Guard-history check (D4)

Repo discipline: before relaxing a guard, find who depends on it. The
`borrowAmount == 0` revert was introduced with the template itself (not as a
later fix), and no test reasons about zero-borrow mutants of `_execute` —
checked `test/` for the CL suite's mutant-pinning comments. The guard's
purpose is rejecting a nonsensical *levered* config, which the mixed-mode
revert preserves exactly. (Per the `_participationFloor` lesson: this
paragraph is the evidence the relaxation is not walking over a pinned
formula.)

## Test-mock blast radius (D5)

No NEW cross-contract call is added anywhere — unlevered mode only *skips*
calls — so the "new call breaks every stand-in" failure class does not apply
in the dangerous direction. The inverse applies: fixtures that hand the
template a mock Morpho must keep working untouched, pinning that levered
behavior is unchanged.

## Sizing note for the first proposal (informative, not normative)

NVDA/USDG 0.05%: tick spacing 10; the momentum pod's ±3% band ≈ ±296 ticks →
`tickLower/Upper = spot ∓ 300`. In-range depth measured ~$36k per 1% of
price move (2026-08-11), venue since 4×'d — re-measure at proposal time and
size `lpAmount` to the existing pool-share cap, which already binds clone
liquidity to a fraction of pool liquidity.
