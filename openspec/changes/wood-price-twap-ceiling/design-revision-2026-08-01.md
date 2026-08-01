# Design revision — post-audit, 2026-08-01

**This supersedes decisions 1–3 of `design.md` and the two-number model in
`proposal.md`.** A 12-agent adversarial audit of the shipped implementation
(PR #88) found eight defects. Four trace to a single design error made in this
document, not to the implementation, which faithfully built what was specified.

---

## The error

The original single-number model was sound:

```
price = haircut( min(governance, twap) )
```

It was one-directional because `governance` was the **maintained conservative
price** — a snug number. A `min` against a snug number is a real bound.

The emergency-only doctrine (owner decision, 2026-08-01) then required
`woodUsdPriceX8` to be set **HIGH and non-binding**. I recognised that this
conflicted with its use as a staleness fallback and split the number in two.
But I assigned the wrong one to the `min`:

```
woodUsdPriceX8       HIGH, non-binding   → used as the min's bound   ✗
woodFallbackPriceX8  snug, maintained    → used only when TWAP stale ✗
```

**A `min` against a number chosen so it never binds is not a bound.** Every
downstream claim — the manipulation table, the "push up gains nothing" row,
the spec requirement "the TWAP may only lower the price" — rested on it
binding. Those claims were written against the old model and never re-derived.

The general lesson, stated so it is not repeated: **when a parameter's
*semantics* change, re-derive every consumer of that parameter, not just its
setter.** Findings 1, 3, 4 and 7 are the same mistake seen from four consumers.

## The revision: one number, and it wants to be snug

Collapse back to a single maintained reference. `woodFallbackPriceX8` is
deleted; `woodUsdPriceX8` is the only governance price, and it keeps its
existing brake-shaped setter (unbounded immediate decreases, 2× per interval
increases).

```
sourceX8 =
    feed fresh              ? feedX8
  : twap fresh              ? min(twapX8, woodUsdPriceX8)   ← the TWAP may only LOWER
  : woodUsdPriceX8 != 0     ? woodUsdPriceX8
  :                           revert NoWoodPrice

price = haircut(sourceX8), floored at 1 when sourceX8 != 0
```

Nothing in this system wants to sit high any more, which is why the
contradiction disappears.

### What each mechanism now does

| Need | Mechanism |
|---|---|
| Track a crash in real time | **TWAP** — bond value falls within one window, no human action |
| Cap upward manipulation | **`woodUsdPriceX8`** — the TWAP can never exceed it |
| Survive a TWAP outage | **`woodUsdPriceX8`** — same number, no second parameter |
| Emergency throttle | **Lower `woodUsdPriceX8`** — already the safe, unbounded, immediate direction |
| No price at all | **`revert NoWoodPrice`** — zero is fail-loud, never "no cap" |

### The division of labour, stated plainly

- The **TWAP's** job is to make the price fall fast. That is the
  safety-relevant direction, and it is the direction a manually maintained
  number is worst at.
- The **reference's** job is to bound how high the price can go. That is a
  rate limit on the dangerous direction, and it does not need to be precise —
  only maintained within a bounded multiple of market.

## The honest cost

**You cannot have a bound that requires no maintenance and also binds.** The
TWAP removes the need for the reference to be *precise*; it does not remove
the need for it to exist and be roughly current.

Concretely, if the reference is kept within `M×` of market, upward
manipulation is capped at `M×`. At the measured reserves, achieving a factor
`k` costs `r·(√k − 1)`:

| Reference maintained at | Manipulation ceiling | Cost to reach it |
|---|---|---|
| 1.25× market | +25% overvaluation | ~$26k committed |
| 1.5× market | +50% | ~$49k |
| 2× market | +100% | ~$91k |
| unbounded (the shipped model) | **unbounded** | ~$91k for the first 2× |

A reference reviewed on the order of weeks, not days, is sufficient — a
drifting reference degrades the *cap*, while the TWAP keeps handling the
crash direction. This is a materially weaker maintenance burden than the
pre-TWAP arrangement, which is the real benefit of the change and should be
the claim made for it.

## Findings addressed

| # | Finding | Resolution |
|---|---|---|
| 1 | `min` binds against a non-binding ceiling | **Design change above** — the TWAP is capped by the maintained number |
| 2 | `DeployPlanB` never seeds the fallback | Seed `woodUsdPriceX8` (already done at `:436`) and add the post-broadcast assertion. With one number this is nearly fixed already — but the env var must be re-documented: `WOOD_PRICE_HAIRCUT_X8` ("≤ 30-day low") is now *too low*, since a below-market reference makes the TWAP permanently inert. Seed slightly above market. |
| 3 | Slash rail reads the price live | **Out of scope here** — pin `woodPriceX8AtFiling` into the `Challenge` struct at `file()`, alongside the four clocks and two burn rates already pinned there for the same reason. Separate change against `ChallengeGame`. |
| 4 | ETH/USD staleness compounds | Reject the TWAP when the ETH/USD answer is older than `twapWindow` — the two legs must describe the same period. Lower `MAX_ETH_USD_DELAY_LIMIT` toward one observed heartbeat plus margin (~12–24h, not 7 days). |
| 5 | `twapWindow > maxTwapAge` unsatisfiable | Enforce `maxTwapAge >= twapWindow` in both setters; lower `MAX_TWAP_WINDOW` to `MAX_SNAPSHOT_AGE_LIMIT`. |
| 6 | `_haircut(1) == 0` | Floor the post-haircut result at 1 when `sourceX8 != 0`, so the never-serve-zero invariant is checked after the last arithmetic step rather than before it. |
| 7 | Zero disables the `min` | Zero now means **revert `NoWoodPrice`**, not "no cap". Fail-loud is the correct reading once there is only one number. |
| 8 | Idle guard permits 100% extrapolation | Bound the extrapolated tail against the **span**, not against `maxTwapAge`: require `idle * N <= twapWindow`. The math being exact is not a defence — exactly reproducing spot is the failure. |

## Testing requirements

The audit's sharpest finding was about the tests, not the code: `grep
setWoodTwapOracle test/` returned **nothing**, and the ledger fixture pinned
`ceiling == fallback`, the one configuration where the old invariant held.

1. **Test the production configuration.** Every test of the price path must
   run with the reference set *above* market, because that is how it ships.
2. **A test that pumps the TWAP and asserts the price does not rise.** This
   is the invariant; it had no test.
3. **A test per unavailability path**, asserting fall-through rather than
   revert — except the all-sources-absent case, which must revert.
4. **A test that the emergency lever works under a non-default haircut** —
   finding 6 passed CI only because the fixture left the haircut at 10,000.

## Still open

- **Finding 3** needs a `ChallengeGame` change and should be its own proposal.
- **Contested, pre-existing:** three agents produced traces showing
  `settleCoverage`/`slashBpsFor` on `main` can be gamed via a permissionless
  settle at a WOOD trough (and a per-guardian cap bypass needing no
  manipulation); one agent traced the same path and concluded it is defeated.
  Untouched by this PR, but this PR changes its threat model, since
  `woodPriceX8` previously moved only by rate-limited owner action. Needs
  adjudication in its own issue.
- **Issue #89** (the brake's once-per-day gate) becomes load-bearing under
  this revision, since lowering the reference *is* the emergency action.
