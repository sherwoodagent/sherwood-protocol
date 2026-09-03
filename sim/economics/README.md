# `sim/economics` — protocol economics scenario runner (SHE-182)

A dependency-free (stdlib Python 3, no pip) model of one year of Sherwood protocol
operation. It reads its protocol constants **out of the Solidity source at run time**,
runs a declared scenario library with no user input, ranks the inputs by effect size,
and renders a report.

```
python3 sim/economics/run.py
```

That does extract → drift-check → scenarios → sensitivity → report in one go and writes
`sim/economics/out/report.md`, `out/report.html` and `out/results.json`.

---

## Commands

| command | what it does |
|---|---|
| `python3 sim/economics/run.py` | the whole pipeline; **exits non-zero if a constant drifted** |
| `python3 sim/economics/run.py --allow-drift` | same, but renders anyway and reports the drift at the top |
| `python3 sim/economics/run.py --list` | list the scenarios |
| `python3 sim/economics/run.py --scenario shared-coverage` | run one (repeatable) |
| `python3 sim/economics/run.py --no-sensitivity` | skip the tornado sweeps |
| `python3 sim/economics/extract_constants.py` | print the constant table with file:line |
| `python3 sim/economics/extract_constants.py --check` | the drift detector on its own; exit 1 on drift |
| `python3 sim/economics/extract_constants.py --write` | re-pin `constants.lock.json` |
| `cd sim/economics && python3 -m unittest test_model -v` | the tests |

## Files

| file | role |
|---|---|
| `extract_constants.py` | regex extraction from the Solidity source + the drift detector |
| `constants.lock.json` | the pinned snapshot the drift check compares against |
| `constants.py` | binds extracted constants and assumptions into one surface |
| `assumptions.json` | everything that is **not** a code fact: doc figures and stage profiles |
| `model.py` | the mechanics; every scenario is a dict of overrides |
| `scenarios.py` + `scenarios/*.json` | the declared scenario library |
| `sensitivity.py` | one-at-a-time tornado sweeps |
| `report.py` | renders `out/report.md`, `out/report.html`, `out/results.json` |
| `run.py` | the pipeline |
| `test_model.py` | regression tests, `python3 -m unittest` |

---

## What it models

In the order the contracts do it:

1. **Management fee** on a *single* execute-time base for the deployed span.
   `_accrueManagementFee()` has exactly one call site (`SyndicateVault.sol:2643`) and no
   hooks on deposit, withdraw, batch execution or queue settlement — so the "asset-seconds"
   integral is one rectangle at the execute-time balance, **not** a time-weighted average.
   The NatSpec at `:2581-2583` claims otherwise; on this branch it is wrong, and anyone
   modelling from the comments will get it wrong too.
2. **Performance fee** on the excess above the high-water mark, measured *after* the
   management transfer has left the vault.
3. **High-water mark** ratchets monotonically, fee or no fee.
4. **Coverage**: `requiredCoverage = Σ capᵢ · boundBpsᵢ / 10⁴`, tier 2 at full notional,
   certified tiers at a per-adapter bound (the model assumes 50 bps — see caveats).
5. **Reservation**: each approver reserves the **whole** coverage against haircut-priced
   stake, so a cohort of *A* approvers ties up *A × coverage* of budget until
   `settleCoverage` runs.
6. **Exposure hold**: `duration + challengeWindow + epochLength/2`.
7. **Slash**: 100 % of the at-anchor stake, burned to `0x…dEaD`. The proposer bond pays
   `prosecutorFeeBps` to the challenger and burns the rest. The depositor receives nothing.
8. Proposer bond 1 % of coverage, challenger bond 1.5 %, prosecutor fee 20 %.

### The two mechanism toggles

Both default to **today's behaviour**, so an unmodified run describes the protocol as
deployed. They exist to price fixes that are currently on the table.

| toggle | value | meaning |
|---|---|---|
| `reservation_mode` | `"full"` (today) | Each approver reserves the whole coverage. `ExposureLedger.sol:268` says so in as many words. Adding approvers **multiplies** the collateral requirement instead of sharing it. |
| | `"shared"` (**SHE-227**) | Approvers declare amounts that sum to the coverage, so the cohort budget is `coverage`, not `approvers × coverage`. The stake multiple stops scaling with cohort size. |
| `slash_mode` | `"whole"` (today) | A conviction burns 100 % of the approver's at-anchor slashable stake regardless of how much coverage they carried. `slashBpsFor` returns a flat 10 000 for every approver with a live pledge, and `DeployPlanB` pre-flight hard-requires `maxSlashBps == 10 000`. |
| | `"allocated"` (**SHE-232**) | Burn only the stake allocated to *that* proposal — the approver's pro-rata share. Always ≤ the whole-stake slash; equal only at one approver. |

### `wood_price_path`

A list of `[month, price]` points, linearly interpolated across twelve months. WOOD demand
is USD-denominated, so the WOOD quantity is exactly inversely proportional to price. The
reported lockup is the **12-month mean**; the binding-TVL figures use the **worst
(lowest-price) month**, because that is the month the constraint actually binds in.

---

## What it does **not** model

Read this section before quoting any number out of the report.

The list below is imported verbatim from the SHE-182 dossier (`caveats.md`). Two things
have changed since it was written and are worth flagging against it:

- Caveat **A10** describes the `#330` mapping as a judgement call. The `fee-ladder`
  scenario keeps that reading and adds a `management-capped` (100 / 2000) variant that is
  **not** in any ticket — it exists to test the finding in §B3 that the management rate,
  not the performance rate, is the depositor's real lever.
- Caveats **B1** and **B5** are exactly what the `reservation_mode` and `slash_mode`
  toggles now let you price. `shared` and `allocated` are *proposals*, not code.

---

## How to add a scenario

One JSON file in `scenarios/`. The filename (minus `.json`) must equal the `name` field.

```json
{
  "name": "my-scenario",
  "title": "Human-readable title",
  "ticket": "SHE-999",
  "question": "What this answers",
  "note": "Caveats, provenance, judgement calls. Shown in the report.",
  "cells": [
    {
      "label": "the cell as it appears in the report",
      "overrides": { "stage": "growth", "tvl": 10000000.0, "wood_price": 0.05 }
    }
  ]
}
```

`overrides` keys are validated against `model.OVERRIDABLE` and an unknown key **raises** —
a typo that silently does nothing is the worst failure mode a scenario runner can have.
The available keys are the stage profile fields (`stage`, `avg_fund_size`,
`proposals_per_fund_year`, `proposal_frac_of_fund`, `strategy_duration_days`,
`approvers_per_proposal`, `tier2_share`, `gross_return_annual`, `frac_profitable`,
`loss_ratio`, `challenge_rate`), the fee selection (`fee_set`, `mgmt_bps`, `perf_bps`),
the market (`tvl`, `wood_price`, `wood_price_path`), the protocol knobs a scenario may
move (`certified_bound_bps`, `wood_haircut_bps`, `proposer_bond_bps`,
`challenger_bond_bps`, `k_numerator`, `epoch_length_days`, `challenge_window_days`,
`min_guardian_stake_wood`), the toggles (`reservation_mode`, `slash_mode`), and the worked
single-proposal case (`worked_fund_size`, `worked_gross_move`, `worked_duration_days`).

Anything you leave out comes from the stage profile in `assumptions.json`, and anything
that is a protocol constant comes from the Solidity source.

The scenario library as it stands:

| scenario | ticket | what it answers |
|---|---|---|
| `launch-as-is` | — | Day one, nothing certified, at spot and at the tokenomics anchor. |
| `certified-adapters` | — | What certification buys: 100 / 40 / 10 / 0 % tier-2. |
| `shared-coverage` | SHE-227 | Full vs shared reservation. |
| `allocated-slash` | SHE-232 | Whole-stake vs allocated slash. |
| `mechanism-combined` | SHE-227 + SHE-232 | Both fixes, alone and together. |
| `approver-ladder` | SHE-227 | 3 / 5 / 7 / 10 approvers. |
| `fee-ladder` | SHE-18 | 200/2000, 500/1500, 300/2500, 100/2000 at growth and mature. |
| `cadence` | — | 6 / 12 / 24 proposals per fund-year at 14 and 21 days. |
| `price-path` | — | Flat spot, a re-rate to $0.05, and a crash to $0.01. |
| `reference-cells` | SHE-182 | bootstrap / growth / mature at $1M / $10M / $100M. |

---

## How the drift check works

`extract_constants.py` holds a table of `(name, file, regex, converter, note)`. Each regex
has exactly one capture group: the value token. Extraction records the value, the raw
token, and the **file and line it was found at**.

`constants.lock.json` is a committed snapshot of that extraction.
`extract_constants.py --check` re-extracts from the live source and compares:

- **A changed, added or removed value is drift.** It prints a diff and **exits 1**.
- **A constant whose value is unchanged but whose file:line moved** is reported as an
  advisory, not a failure. A refactor that shifts a line is not an economics change.
- **A regex that does not match raises** with the file and the pattern, and **exits 2**.
  There is no silent fallback to a literal, ever — a stale literal that looks live is
  worse than a crash. If the Solidity changed shape, fix the pattern; do not hard-code
  the value.

`run.py` runs the check as step 2 and stops before rendering unless you pass
`--allow-drift`. When drift is present the report **opens** with it (section 1), so a
report computed from numbers nobody reviewed announces itself.

If a change to a constant is intended, re-run `--write` and commit the new lock **in the
same PR as the Solidity change**. The diff on `constants.lock.json` is then the reviewable
record of an economics change.

### Fragile patterns

Two extractions are more brittle than the rest, and both are called out here rather than
hidden:

1. **`WOOD_USD_PRICE_X8_FORK`** (`script/fork/DeployForkWoodUsdFeed.s.sol`) is read from
   the usage block of a **doc comment** — `WOOD_USD_PRICE_X8=627821` — not from a Solidity
   declaration. It is the only WOOD price anywhere in either repo grounded in real
   on-chain state (fork pool reserves × Chainlink ETH/USD), which is why it is worth
   extracting at all, but an edit to that comment will trip the check. If it ever moves
   into a real constant, repoint the pattern at the declaration.
2. **`LEDGER_DEFAULT_WOOD_HAIRCUT_BPS`** (`src/ExposureLedger.sol`) is written
   *symbolically*: `uint256 public woodHaircutBps = BPS_DENOMINATOR;`. The extractor
   resolves the symbol against the other extracted constants rather than assuming
   10 000. If a third file introduces a different `BPS_DENOMINATOR`, that resolution
   becomes ambiguous. (The value matters: the ledger's own default is **no haircut** —
   only `DeployPlanB` overwrites it to 5 000, and the model uses the Plan B value.)

The `MGMT_SPLIT_*` / `PERF_SPLIT_*` patterns also lean on struct-literal field order via a
non-greedy `[^}]*?` scan inside the brace. That survives field reordering and whitespace,
but not a switch to positional construction (`MgmtSplit(6000, 2000, 2000)`) — which would
fail loudly rather than silently, as designed.

---

## How to read the report

`out/report.md` and `out/report.html` carry the same content; the HTML adds inline SVG
charts and is a single self-contained file (no external stylesheet, script, font or
image), themed off `prefers-color-scheme`.

1. **What changed vs the lock** — empty when there is no drift. If it is not empty, read
   it before anything else: every number below it was computed from the live source.
2. **Headline** — one row per scenario, ranges across its cells, plus a "what it moves"
   column naming the quantities that scenario actually separates. This is the one-screen
   view.
3. **Charts** — where a year of gross profit ends up (stacked, by stage and fee rate); the
   tightest and loosest binding-TVL cells in the whole run on a log scale; and a tornado
   per metric.
4. **Scenarios** — per scenario: the cell table, the WOOD legs, and the fraud waterfall.
   The *to depositor* column is `$0` in every row of every scenario; that is the point,
   not an artefact.
5. **Worked single proposal** — the three canonical examples, to the cent.
6. **Sensitivity** — ranked spreads. OAT cannot see interactions: where two inputs
   multiply (approvers × tier-2 share, cadence × duration) the joint effect is larger than
   either bar, and a ±50 % move around a 40 % tier-2 share badly understates certification
   — the `certified-adapters` scenario runs the real extremes.
7. **Constants** — every value with its `file:line`.
8. **Assumptions** — everything that is not a code fact. Argue with this section first.

Two numbers to keep straight:

- **Stake multiple** — staked-WOOD *face value* required per $1 of open coverage. It is
  `approvers / haircut / k` today and `1 / haircut / k` under SHE-227, and it is
  **price-invariant**.
- **Binding TVL** — the TVL at which required WOOD lockup crosses a share of the M12
  effective float. Every leg is linear in TVL, so one reference evaluation is exact. It is
  *near*-linear in price, not exactly: the vault-owner bond is a fixed WOOD amount per
  fund, so that one leg does not shrink when the price rises.

---

## Known divergence from `worked-examples.md`

`worked-examples.md` prints the total burn on the slashed scenario as **2 875 500 WOOD**
($143 775). That total adds the exact 17 500 WOOD of bond burns to a *rounded* 2 858 000
of guardian stake. The component rows in that same table are correct; only the total is
rounded. The exact figure, and the one this model produces and pins in `test_model.py`, is
**2 874 642.86 WOOD** ($143 732.14) — 857.14 WOOD less.

---

## Modelling assumptions (imported from the SHE-182 dossier)

<!-- The block below is a verbatim copy. Do not edit it here; edit the dossier and re-copy. -->


## A. Modelling assumptions (things the sim invents)

These are **not** protocol constants. They are the stage profiles and simplifications the sim needs
to turn a set of bps into a dollar figure. Anything here is arguable; nothing here is a code fact.

1. **Stage profiles are invented.** Fund size, proposals/year, proposal size as a fraction of the
   fund, tier-2 share, approvers, gross return and win rate for bootstrap / growth / mature come from
   nowhere in the repo. They are in `sim.py` § "STAGE PROFILES" and are the first thing to argue
   about. The *ratios* the sim reports (fee as % of gross, stake per $1 of coverage) are far more
   robust than the absolute dollars.

2. **The $0.20 and $1.00 WOOD prices have no repo source.** They exist to show that every WOOD
   quantity is exactly inversely proportional to price. The only defensible "today" anchor is
   **$0.00628**, derived from live WOOD/WETH reserves × Chainlink ETH/USD
   (`script/fork/DeployForkWoodUsdFeed.s.sol:106`), corroborated independently by the "~$438k pool /
   ~$91k to move spot 2×" pair at `src/ExposureLedger.sol:175`. $0.05 is the tokenomics doc's anchor.

3. **Total supply 500M and float 230M are doc figures, not code.** The production WOOD token is in
   neither repo (`test/mocks/WoodToken.sol:8-10`). The repo contains three mutually inconsistent
   supply numbers (500M / 100M fixture / 1B retired). 230M is the midpoint of the M12 "effective
   float" range in `sherwood/docs/tokenomics-wood.md:596`. All % -of-supply figures inherit this.

4. **Shares are held constant.** No deposits or redemptions during the year, so price-per-share moves
   only with assets and the HWM can be tracked in asset terms. Real flows change the HWM's
   `_pricingSupply()` denominator (`SyndicateVault.sol:2122-2129`) and can reset it entirely if
   supply ever hits zero (`:1471-1473`).

5. **Settlement ordering is a deterministic Bresenham interleave** of wins and losses. Order matters
   because the HWM ratchets monotonically; all-losses-first and all-wins-first bracket the result and
   the sim reports neither.

6. **One coverage number per proposal.** The sim uses a single blended `boundBps` per stage. Real
   `requiredCoverage` sums per-call caps across **both** the execute batch and the settlement batch,
   validated per batch rather than combined (`SyndicateGovernor.sol:1702-1707`), so it can reach
   **~2 × maxCapital** plus sandbox funding. The sim's coverage — and therefore every WOOD figure —
   is optimistic by up to 2× in the worst tier-2 case.

7. **Exposure hold time is `strategyDuration + challengeWindow + epochLength/2`.** The exact release
   is the expiry of the epoch bucket containing `executeBy + strategyDuration`, at
   `epochGenesis + (e+1)·28 d + 14 d` (`ExposureLedger.sol:2032-2045`, `:2076-2084`). The `/2` is a
   uniform-arrival average. Worst case is 28 + 14 = 42 days after the proposal ends; the sim uses 28.

8. **No re-arm, no challenge pinning.** The sim assumes challenges resolve once. Every Inconclusive
   round re-arms the window for another 14 days and keeps the guardians' stake frozen
   (`ChallengeGame.sol:1599-1605`). Repeated inconclusive filings are an unpriced availability cost.

9. **The certified tier-0/1 bound is 50 bps**, taken from the protocol's own worked example
   (`docs/papers/guardian-network-economic-security.md:152`). Real bounds are per-adapter, in
   `[1, 9999]` (`TierRegistry.sol:496`), and **no deploy script issues any certification** — at
   launch, everything is tier 2 at full notional.

10. **The `#330` mapping is a judgement call.** Two of the three #330 constants no longer exist in
    the post-audit code (see `constants.md` §10), so "run the sim at the #330 targets" cannot be done
    literally. The sim interprets them as *rate ceilings under the current two-number model*:
    mgmt 500 bps, perf 1500 bps, splits unchanged. A different reading — e.g. mapping "protocol
    10→1 %" onto `perfSplit.protocolBps` — would give different protocol revenue. The `worst_stack`
    set (500 / 3000, the actual post-audit ceilings) is the unambiguous one.

11. **Off-chain guardian distribution is ignored.** The guardian fee is a single transfer to
    `guardiansFeeRecipient`; the per-guardian split happens off-chain via a weekly Merkl WOOD buyback
    keyed on `GuardianFeeAccrued` (`SyndicateGovernor.sol:2364-2366`, `GuardianRegistry.sol:25-28`).
    The sim reports the pool, not any individual guardian's ROE, and models no buyback demand for
    WOOD from that flow.

12. **Gas, MEV, slippage, oracle deviation and the implicit deposit entry fee are all excluded.**
    The entry fee in particular is real but unsized: `previewDeposit` prices against
    `depositNav() = totalAssets() + _residueTotal` while `convertToShares` prices against
    `totalAssets()` (`SyndicateVault.sol:2151-2157`, `:1589-1591`).

13. **The min-stake and owner-bond floors are modelled as scaling with fund count**, which makes them
    linear in TVL and lets `binding_tvl()` solve exactly from one reference evaluation. In practice
    guardians are shared across funds, so the floor is a step function, not a ray.

---
