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
| `python3 sim/economics/run.py --allow-drift` | same, but renders anyway (CI uses this) |
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
| `fee-ladder` | SHE-18 | 200/2000, 500/1500, 500/3000, 100/2000 at growth and mature. |
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
   only `DeployPlanB` overwrites it to 7 000, and the model uses the Plan B value.)

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

## Caveats — imported verbatim from `caveats.md` (SHE-182 dossier)

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

## B. Things in the contracts that surprised me, or look economically off

Ordered by how much they matter to the narrative.

### 1. Adding approvers *multiplies* the collateral requirement instead of sharing it

Each approver reserves the **full** coverage, not `coverage / N`:

> *"Total USD RESERVED by all approvers of a proposal — runs to `A x coverage` while the review is
> open, NOT to `coverage`, because each approver reserves up to the whole thing in case it ends up
> carrying the proposal alone."* — `src/ExposureLedger.sol:268`

With `kNumerator = 1` and a 0.70 haircut, the aggregate staked-WOOD face value needed to underwrite a
book at full size is `approvers / 0.70 × open coverage`. That is **4.3× at 3 approvers, 7.1× at 5,
10.0× at 7.** The sim's most robust output is exactly this ratio, and it is *price-invariant*: the
mature stage's much better coverage factor (15.4 % of notional vs 100 %) is almost exactly cancelled
by its higher approver count and proposal frequency, so **all three stages land at $1.49–$1.59 of
WOOD face value locked per $1 of TVL.**

The economic effect: **decentralising the guardian set is a direct tax on TVL capacity.** Going from
3 to 10 approvers cuts the binding TVL from $3.01M to $903k at $0.05. That is the opposite incentive
from the one you want.

The pro-rata collapse (`_allocate`, `:2020-2023`) fixes the *accounting* at settlement but not the
*budget* during the review — and the budget is what gates the next proposal.

### 2. WOOD lockup exceeds the entire float long before TVL is interesting

At $0.05 and 25 % of the M12 effective float, the flywheel binds at **$1.8M–$1.9M of TVL** across all
three stages. At the derived spot price of $0.00628 it binds at **$227k–$244k**. Even at $1.00 —
a ~160× re-rating from spot — it binds at **$36M–$38M**.

Every lever except one is weak. From `results.md` §E (growth, $0.05, 25 % of float):

| Change | Binding TVL |
|---|---|
| baseline (40 % tier-2, 5 approvers) | $1.81M |
| 100 % tier-2 (launch reality — nothing certified) | $728k |
| 3 approvers instead of 5 | $3.01M |
| 6 proposals/fund/yr instead of 12 | $3.61M |
| **0 % tier-2 (everything certified at 50 bps)** | **$142.0M** |

**Adapter certification is the only lever with an order of magnitude in it** — a 200:1 coverage
reduction. And **no deploy script certifies anything**; `script/Deploy.s.sol:303` and
`script/DeployPlanB.s.sol:1047` only print the runbook. The protocol ships in its most
capital-expensive configuration. This is the finding the narrative should lead with.

The protocol's own paper reaches the same conclusion from the other direction: *"The binding
constraint at any scale is simultaneous tier-2 exposure, never total TVL"*
(`docs/papers/guardian-network-economic-security.md:173`).

### 3. Worst-case fee stacking leaves the depositor ~40 % of gross (SHE-18 confirmed, and worse)

At the post-audit ceilings (mgmt 500 bps, perf 3000 bps) the mature stage keeps **39.5 %** of gross
for the depositor. At the #330 caps (500 / 1500) it is **47.9 %**. Only at current defaults
(200 / 2000) does it reach 66.1 %.

The driver is **not** the performance fee — it is the management fee interacting with proposal
frequency. Management fee accrues on asset-seconds only while a proposal is open, so a fund running
24 × 21-day proposals is "open" ~138 % of the year, capped at 100 %, and pays the full 5 %. The
mature stage's management fee ($70.7k per $1M of TVL) exceeds its performance fee ($27.4k). A 5 %/yr
management fee on a fund that is always deployed is the single largest fee leg in the system, and it
is charged win or lose.

Note the non-monotonicity: on a *single winning short proposal* the #330 set is **better** for the
depositor than current defaults ($8 337 vs $7 939 on a $100k / +10 % / 14-day trade), because the
15 % perf cap saves more than the 5 % management rate costs over two weeks. It inverts as duration
and frequency rise. Any narrative claim of the form "lower caps protect depositors" needs the time
horizon attached.

### 4. The slash pays nobody, and it is a supply sink rather than a burn

100 % of every slash goes to `0x…dEaD`. WOOD has no `burn()`, so `totalSupply` never falls
(`StakedWood.sol:453-468`) — the tokens are stranded, not retired. There is no treasury path on any
outcome, deliberately (`ProposerBondEscrow.sol:169`).

Consequence: **a harmed depositor is made whole by nothing.** In Scenario 3, $143 775 of WOOD burns
and the depositor receives $0. The guardian network is a *deterrent*, not an *insurance* layer, and
the narrative must not describe it as coverage in the insurance sense. The word "coverage" in the
code means "how much stake is at risk if this goes wrong", not "how much the depositor gets back".

### 5. `minSlashBps` is an unbounded over-slash

> *"an approver who underwrote $10 of a $1,000 bond pays `minSlashBps` of the bond — 10x what they
> insured at a 1,000-bps floor… the over-slash multiple is `minSlashBps / derivedRate` and is
> UNBOUNDED"* — `src/StakedWood.sol:1264-1273`

Combined with `slashBpsFor` returning a flat 10 000 bps for **every** approver holding a live pledge
(`ExposureLedger.sol:1541-1542`) and a deployed `maxSlashBps` of 10 000 that Plan B **hard-requires**
(`script/DeployPlanB.s.sol:500-502`), the verdict path is: **every approver loses 100 % of their
at-anchor stake**, regardless of how much of the coverage they actually carried. There is no
proportionality and no per-epoch cap.

### 6. The minimum stake is an entry requirement only

`_isActiveGuardian` is just `stakedAmount > 0 && unstakeRequestedAt == 0`
(`src/StakedWood.sol:562-565`). A guardian slashed to 1 wei still votes and still occupies one of the
100 review seats. It is documented as deliberate at `:537-561`, but it means the sim's
`minGuardianStake` floor is an upper bound on how binding that floor really is.

### 7. Three parameters ship inert, and the docs disagree about whether that is intentional

`tier2CallCapBps` reads 10 000 (100 % of TVL), `maxCapitalBps` reads 10 000, `minBufferBps` reads 0 —
all via 0-sentinels (`GovernorParameters.sol:288-320`, `SyndicateVault.sol:90`). Neither can be set
by a deploy script (both are `onlyVaultOwner`, and no governor exists at deploy time).
`docs/pre-deployment-parameter-review.md:102` recommends 200 bps for the tier-2 cap;
`openspec/specs/deployment-docs/spec.md:103` decides it **stays** at 10 000. That conflict is
recorded, unresolved, and it changes the per-proposal blast radius by 50×.

Similarly, `coveredTvlCapUsd` defaults to **0 = fail-closed, nothing proposable**
(`ExposureLedger.sol:186`); only the fork script sets it, to $10M
(`script/deploy-robinhood-fork.sh:101`). **No mainnet value is pinned anywhere.**

And `woodHaircutBps` defaults to **10 000 = no haircut** in the contract
(`ExposureLedger.sol:238`); only `DeployPlanB` overwrites it to 7 000. A deployment that skips
Plan B ships with no conservatism on the WOOD price at all.

### 8. The WOOD price cap is an owner-set number with no rate limit and no ceiling

`woodUsdPriceX8` is a **cap, never a price**, and `setWoodUsdPrice` has no rate limit and no size
bound (`ExposureLedger.sol:176`, `:648-652`). It gates every coverage computation: set it to 0 and
the whole protocol reverts `NoWoodPrice`; set it high and stake is over-valued and under-collateralised.
Compound worst-case oracle staleness is `maxTwapAge + ethUsdMaxDelay` = **up to 2 days** at the limits
(`WoodTwapOracle.sol:136-138`). The pool it reads is ~$438k deep and costs ~$91k to move 2×
(`ExposureLedger.sol:175`, `openspec/specs/deployment-docs/spec.md:405`) — that is thin relative to
the coverage decisions it underwrites.

### 9. The management-fee base is stamped once and the NatSpec says otherwise

`_accrueManagementFee()` has exactly one call site (`SyndicateVault.sol:2643`); there are no hooks on
deposit, withdraw, batch execution or queue settlement. So the "asset-seconds" integral is a single
rectangle at the execute-time balance, not a time-weighted average. The NatSpec at `:2581-2583`
claims the base is restamped "on every mid-proposal event that can move the base" — it is not, on
this branch. Anyone modelling this from the comments will get it wrong. A fund that deposits heavily
mid-proposal pays management fees on the *pre-deposit* balance; one that redeems heavily pays on the
*pre-redemption* balance.

### 10. Fee splits are snapshotted, but the management *rate* is read live

`snapshotMgmtSplit` / `snapshotPerfSplit` are pinned at propose time
(`SyndicateGovernor.sol:2320-2326`), but `rateBps` is read live from the vault at settle
(`:2381`), justified by the absence of a vault-side setter. That justification holds only as long as
`SyndicateFactory.setManagementFeeBps` cannot reach existing vaults — which it currently cannot
(`SyndicateFactory.sol:589`). It is a load-bearing invariant that is not enforced by a test I found.

### 11. The performance-fee clamp fails open in one direction

`_clampPerformanceFee` **silently** clamps and emits `FeeClamped` rather than reverting
(`SyndicateGovernor.sol:2328-2335`). `FeeConstants.sol:24-31` explains the choice: a permissive
default would let an owner quietly charge above the headline, so the default was set *at* the
headline to fail closed. Correct reasoning, but it means the on-chain record of an attempted
over-charge is an event nobody is required to watch.

### 12. Both fee recipients are currently the deployer

`script/robinhood-mainnet/Deploy.s.sol:193-194` sets `protocolFeeRecipient` and
`guardiansFeeRecipient` to the deployer EOA; the runbook at `:229-230` says the Safe must re-point
them. Until that happens, **the guardian pool accrues to a single EOA.** Worth a sentence in the
narrative if it is still true at publication.

### 13. There is no appeal reserve in the challenge system

The ticket names an "appeal reserve". `TokenCourt` says the opposite in as many words: *"No panel, no
appeal"* (`src/TokenCourt.sol:36`). There is no appeal round, no appeal bond, no escalation-game
reserve anywhere in `ChallengeGame` or `TokenCourt`. The only object with that name is
`GuardianRegistry.slashAppealReserve` — an **off-chain-adjudicated, owner-funded, owner-disbursed**
refund pot with **no default, no target and no sizing formula**, capped at 20 % of its own current
balance per 7-day epoch (`GuardianRegistry.sol:260`, `:1466-1488`, `:56`). It is seeded with 1M WOOD
on the generic script and **0 on robinhood-mainnet** (`script/robinhood-mainnet/Deploy.s.sol:92`).
Do not describe it as an appeals mechanism; it is a discretionary make-good fund.

### 14. Court jurors have no skin in the game

No juror stake, no deposit, no fee, no reward. Voting costs only gas. Turnout is defended by a 10 %
participation floor (`TokenCourt.sol:94`) below which the verdict is Inconclusive and the window
re-arms. `finalize` documents the unmitigated last-mover advantage itself: votes are public, the
deadline is hard, there is no vote extension (`:488-492`). Ties acquit (`:498-509`).

### 15. The paper's own attack arithmetic is off by 4×

`docs/papers/guardian-network-economic-security.md:325` computes the coalition's prosecutor-fee
rebate as "5 % of bond = $3 750" on a $75 000 bond. The deployed `prosecutorFeeBps` is **2 000
(20 %)**, already at its hard cap (`ChallengeGame.sol:361`, `:343`) — the real figure is $15 000.
The paper's conclusion (Π < 0) survives because the $500 000 slash dominates, but the published
number is wrong. Same 5 % claim appears at `docs/proposal-lifecycle.md:169`.

---

## C. The single highest-severity doc/code divergence

`docs/guardian-network.md:229-230` tells guardians they earn **10 % of management and 15 % of
performance**. The code pays **20 % and 25 %** (`src/ProtocolConfig.sol:76`, `:80`). Those are exactly
the pre-rebalance values the constructor comment names as *raised from* at `:72` and `:79`.

This is SHE-229, and it is confirmed. It matters more than the other 18 divergences because the ROE
argument that justifies guardian participation at all — *"the guardian pool reaches 0.9 % of TVL/yr
at the 2-and-20 headline, which clears the 15 % tier-1 ROE hurdle (17.5 %) that the 70/20/10 +
60/15/15/10 seeds missed (9.5 %)"* (`src/ProtocolConfig.sol:70-75`) — is presented to the audience it
needs to convince at **half the real rate**.

The sim tests that 0.9 % claim directly (`results.md` §B). At current defaults the guardian pool
reaches **0.337 % of TVL/yr at bootstrap, 0.702 % at growth, 1.261 % at mature**. The 0.9 % figure is
reachable, but only at mature-stage proposal frequency — it is a ceiling for a fund that is deployed
nearly all year, not a floor. A bootstrap-stage guardian earns roughly **one third** of what the ADR
promises.

`docs/fees.md` is the only doc whose economic values all match the code. Use `src/ProtocolConfig.sol`
and `src/FeeConstants.sol` as the sole authority; treat `docs/guardian-network.md`,
`docs/protocol-overview.md`, `docs/papers/`, `openspec/specs/challenge-game/`,
`openspec/specs/token-court/`, `sherwood/contracts/src/`, `sherwood/skill/` and the app's fallback
constants as stale. Full list in `constants.md` §11.
