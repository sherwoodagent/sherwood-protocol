# Design revision — post-audit

**Revision 1, 2026-08-01** — after a 12-agent adversarial audit of PR #88.
**Revision 2, 2026-08-02** — after PR #102 (*burn slash proceeds*) merged, and
an owner decision to drop the staleness fallback.

**This supersedes decisions 1–3 of `design.md` and the two-number model in
`proposal.md`.**

---

## The error (revision 1)

The original single-number model was sound:

```
price = haircut( min(governance, twap) )
```

It was one-directional because `governance` was the **maintained conservative
price** — a snug number. A `min` against a snug number is a real bound.

The emergency-only doctrine then required `woodUsdPriceX8` to be set **HIGH and
non-binding**. I recognised the conflict with its use as a staleness fallback
and split the number in two — but assigned the wrong one to the `min`:

```
woodUsdPriceX8       HIGH, non-binding   → used as the min's bound   ✗
woodFallbackPriceX8  snug, maintained    → used only when TWAP stale ✗
```

**A `min` against a number chosen so it never binds is not a bound.** Every
downstream claim rested on it binding, and none was re-derived.

The general lesson: **when a parameter's *semantics* change, re-derive every
consumer of that parameter, not just its setter.**

## What PR #102 changed (revision 2)

`slashBpsFor` was rewritten. It no longer reads the WOOD price at all:

```solidity
if (_recorded[key][g].usd == 0) continue;
bps[i] = BPS_DENOMINATOR;   // flat 100% for every committed approver
```

Slash proceeds are burned rather than paid to anyone harmed, so the rate is no
longer sized to the loss. Three consequences for this design:

1. **The slash path is out of the price's blast radius.** Manipulating the
   price can no longer move a seizure in either direction.
2. **Pinning the price at `file()` is no longer a prerequisite** for anything
   here. It was revision 1's gate on dropping the fallback; that gate is gone.
3. **The harm from over-valuation is now a *deterrence* shortfall, not a
   *recovery* shortfall.** A guardian who appears to hold $2M of bond but holds
   $1M can back a $2M proposal and be slashed 100% of $1M. Depositors lose $2M
   against $1M of deterrence. The spec §2 inequality (`recovery >= loss`) that
   several audit findings cited has been deliberately retired by #102 — do not
   re-derive arguments from it.

## The revised design

One number, and it is **only ever a cap**. `woodFallbackPriceX8` is deleted.

```
sourceX8 =
    feed fresh   ? min(feedX8,  woodUsdPriceX8)
  : twap fresh   ? min(twapX8,  woodUsdPriceX8)     ← the market may only LOWER
  :                revert NoWoodPrice

price = haircut(sourceX8), floored at 1 when sourceX8 != 0
```

`woodUsdPriceX8` is never served as a price. It caps whatever the market says,
and lowering it is the emergency brake. There is no branch in which a
hand-maintained number *becomes* the valuation, which is the property that
makes its staleness tolerable.

### Halting semantics — this is the part that needs care

Reverting inside `_woodPrice` is normally forbidden, because it takes
`recordApproval` and `requireApproveQuorum` down protocol-wide. With no
fallback branch, a stale TWAP now reaches that revert. Each consumer must be
handled deliberately:

| Consumer | On `NoWoodPrice` | Why |
|---|---|---|
| `requireApproveQuorum` | **let it revert** | Execution halts. Correct: no price means no proof of coverage. |
| `proposerBondWood` → `propose` | **let it revert** | New risk cannot be admitted unpriced. |
| `ChallengeGame.file` | **let it revert** | Acceptable: the challenge window is 14 days against staleness measured in hours. |
| **`recordApproval`** | **CATCH — book nothing** | **Load-bearing.** A revert here disenfranchises approvers while block votes still land, which is the block-only-review failure reviews M3/N1/N4 each removed. Booking nothing is already this function's documented behaviour for a failed asset-feed read; extend the same treatment to the WOOD read, which currently sits outside the `try`. |
| `slashBpsFor` | n/a | No longer reads the price (PR #102). |

Net effect of a stale TWAP: proposals cannot execute and none can be created,
votes still function, nothing reverts protocol-wide, and live challenges
resolve normally. That is a clean fail-safe rather than a halt.

### What each mechanism does

| Need | Mechanism |
|---|---|
| Track a crash in real time | **TWAP** — bond value falls within one window, no human action |
| Cap upward manipulation | **`woodUsdPriceX8`** |
| Emergency throttle | **Lower `woodUsdPriceX8`** — safe direction, unbounded, immediate |
| No price at all | **`revert NoWoodPrice`**, caught only by `recordApproval` |

## The honest cost

The number still exists and still needs review — it is the only thing bounding
upward manipulation. What it no longer needs is *accuracy*, because it is never
served as a price. Kept within `M×` of market, upward manipulation is capped at
`M×`; at the measured reserves, reaching factor `k` costs `r·(√k − 1)`:

| Reference at | Manipulation ceiling | Cost |
|---|---|---|
| 1.25× market | +25% | ~$26k |
| 1.5× | +50% | ~$49k |
| 2× | +100% | ~$91k |
| unbounded (shipped in #88) | **unbounded** | ~$91k for the first 2× |

Reviewing it monthly is sufficient: drift degrades the cap gradually and never
mis-prices anything, because a drifted cap simply stops binding. That is the
claim to make for this change — **not** "no maintenance."

## Findings addressed

| # | Finding | Resolution |
|---|---|---|
| 1 | `min` binds against a non-binding ceiling | **Design change above.** Harm reframed as deterrence shortfall per #102. |
| 2 | `DeployPlanB` never seeds the fallback | Moot for the fallback (deleted). Still must assert `woodUsdPriceX8 != 0` post-broadcast, and re-document `WOOD_PRICE_HAIRCUT_X8` — a "≤ 30-day low" cap binds permanently and makes the TWAP inert. Seed **above** market. |
| 3 | Slash rail reads the price live | **Resolved by PR #102** — `slashBpsFor` no longer reads the price. |
| 4 | ETH/USD staleness compounds | Reject the TWAP when the ETH/USD answer is older than `twapWindow`; lower `MAX_ETH_USD_DELAY_LIMIT` to ~12–24h. |
| 5 | `twapWindow > maxTwapAge` unsatisfiable | Enforce `maxTwapAge >= twapWindow`; lower `MAX_TWAP_WINDOW` to `MAX_SNAPSHOT_AGE_LIMIT`. |
| 6 | `_haircut(1) == 0` | The convicted-but-recovers-nothing chain is **broken by #102**. Still floor the post-haircut result at 1 — a zero price reverts `WoodPriceUnset` in `ChallengeGame` and breaks `proposerBondWood`. |
| 7 | Zero disables the `min` | Zero now means **revert**, not "no cap". |
| 8 | Idle guard permits 100% extrapolation | Bound the tail against the **span** (`idle * N <= twapWindow`), not against `maxTwapAge`. Exact math is not a defence when it exactly reproduces spot. |

## Testing requirements

The audit's sharpest finding was about tests: `grep setWoodTwapOracle test/`
returned nothing, and the fixture pinned the one configuration where the old
invariant held.

1. **Run the price-path tests in the production configuration** — cap set
   *above* market, because that is how it ships.
2. **Pump the TWAP and assert the price does not rise.** The invariant, never
   tested.
3. **A test per unavailability path**, asserting `recordApproval` books nothing
   rather than reverting, and that execute/propose do revert.
4. **A test that the emergency lever works under a non-default haircut** —
   finding 6 passed CI only because the fixture left the haircut at 10,000.

## Still open

- **Contested, pre-existing:** the `settleCoverage` per-guardian cap bypass
  (3 agents produced traces; 1 disputed). #102 removed the *slash-basis* half
  of this by making `_recorded` a membership test rather than a magnitude, but
  the cap-bypass variant is independent of price and untouched. Needs
  adjudication in its own issue.
- **Issue #89** (the brake's once-per-day gate) is load-bearing here, since
  lowering the cap is the emergency action.
