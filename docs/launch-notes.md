# Launch notes (Robinhood Chain 4663, v1)

Operating decisions taken for the v1 launch that the code does not record.
Each entry names its ticket. Append; do not rewrite history.

## Beta capacity plan (SHE-355, 2026-10-08)

### Inputs, measured 2026-10-08

| input | value | source |
| -- | -- | -- |
| WOOD spot | $0.00466 | GeckoTerminal; V2 pair `0xBF3BB81…` 82.2 WETH : 42.73M WOOD at ETH/USD $2,431 (Chainlink `0x78F3556…`) |
| coverage value per WOOD | $0.00233 | `WOOD_HAIRCUT_BPS = 5000`; the 4× cap does not bind |
| `kNumerator` | 1 | `ExposureLedger` default |
| Safe `0x0aEB6792F3d7cE56460F96a66ff5abf518Ed04F3` | 147.4M WOOD | Blockscout holders |
| `totalGuardianStake` | 0 | `StakedWood` `0xdDf2B4C5…` |
| coverage per uncertified proposal | 2 × deployed capital | execute + settle calls, both at full notional (`docs/coverage.md`) |
| Portfolio class bound, if ratified | 2,000 bps | PR #324 `PORTFOLIO_BOUND_BPS`; SHE-235 decides |

### Arithmetic

Capacity is **approving** stake only. `recordApproval` caps each key at
`kNumerator × guardianStake(key) − openExposure(key)`; a key that never
approves contributes nothing.

```
capacity_usd = Σ approving stake × $0.00466 × 50%
             = approving WOOD × $0.00233
```

A lock is booked into the epoch bucket holding `executeBy + strategyDuration`
and is released at `bucketEnd + 14d`, executed or not. Measured from the
Approve, with `S` the strategy duration and `L` the epoch length:

```
lock held  = S + 16d  …  S + 16d + L          (avg S + 16d + L/2)
```

A creator who redeploys back-to-back therefore holds `1 + (16d + L/2) / S`
locks at once. Steady-state demand on the fleet:

```
demand_usd = 2 × TVL × bound × (1 + (16d + L/2) / S)
```

| S | L | lock held | locks per creator |
| -- | -- | -- | -- |
| 30d | 28d | 46–74d | 2.00 |
| 30d | 7d | 46–53d | 1.65 |
| 7d | 28d | 23–51d | 5.29 |
| 7d | 7d | 23–30d | 3.79 |

### Approving WOOD needed, by beta TVL

| beta TVL | S / L | uncertified | 2,000 bps | 500 bps |
| -- | -- | -- | -- | -- |
| $100k | 30d / 28d | 172M | 34M | 9M |
| $100k | 7d / 28d | 454M | 91M | 23M |
| $250k | 30d / 28d | 429M | 86M | 21M |
| $250k | 30d / 7d | 354M | 71M | 18M |
| $250k | 7d / 28d | 1,134M | 227M | 57M |
| $250k | 7d / 7d | 812M | 162M | 41M |
| $500k | 30d / 28d | 858M | 172M | 43M |
| $500k | 7d / 7d | 1,625M | 325M | 81M |

Read against the Safe's 147.4M: **uncertified, no split reaches a $250k
beta.** Every WOOD the Safe holds, all of it approving (which SHE-351
forbids), underwrites ≈ $86k of 30-day strategies or ≈ $32k of 7-day ones.

### The lever: certification bound (SHE-235)

The bound multiplies capacity; nothing else does.

- **Certify the Portfolio class.** At 2,000 bps a 30M approving tranche carries
  ≈ $87k of 30-day beta TVL (≈ $33k at 7-day cadence); at 500 bps, ≈ $350k
  (≈ $132k). Whether the Portfolio runtime guards justify a bound under
  2,000 bps is SHE-235's call (PR #324 records the case against); the plan
  needs **≤ 500 bps** for a $250k beta on a 30M tranche.
- **`EPOCH_LENGTH` 7d (SHE-356 / SHE-250): yes.** Worth 17% at 30-day
  cadence and 28% at 7-day, costs nothing at launch.
- **`kNumerator` > 1: no.** It gives up `Σ locks ≤ stake`, so a conviction
  leaves the other locks under-covered (`docs/coverage.md`, "kNumerator = 1
  contains a conviction"). Leverage, not capacity.
- **More WOOD approving: no, beyond the tranche below.** The Safe's whole
  balance is +47% over 100M, and every approving WOOD raises the A-2 burn and
  the D-1 exposure one for one.

### Split of the 100M (with SHE-351)

| role | WOOD | address | approves | counter-bonds |
| -- | -- | -- | -- | -- |
| approving tranche | 30M = 3 × 10M | voter-2, voter-3, voter-4 (own keys) | yes | no |
| juror reserve | 70M | the Safe, under its own address | no | no |
| liquid | 47.4M | the Safe, unstaked | — | counter-bond treasury (SHE-361) |

- Capacity: **$69.9k of coverage** on the tranche. Beta TVL it carries at
  2,000 bps: ≈ $87k (30d) / $33k (7d); at 500 bps: ≈ $350k / $132k.
- A-2 (block-quorum burn): 10% of approving stake per blocked review =
  **3M WOOD ≈ $14k**. The attacker's bar is `3F/7` of at-open stake =
  **42.9M WOOD** against F = 100M, more WOOD than the V2 pair holds.
- D-1 (court): the 70M reserve never approves, so it is never the accused;
  an outsider needs ≥ R/9 ≈ 7.8M aged WOOD to reach the juror floor.
- voter-1 stays veto-only and unstaked beyond `minGuardianStake`; its block
  weight is not capacity.
- A second approving tranche, if demand shows up, goes into **new keys**, never
  a top-up: top-ups re-anchor `stakedAt` and restart the 30-day court clock.

### Fleet settings that follow

- `MAX_COVERAGE_PER_PROPOSAL` per approving key ≈ one third of the expected
  per-proposal need with margin, not the key's whole budget: the daemon
  declares `min(freeWood, ceiling)` without reading the need (SHE-299), so an
  unset ceiling spends a key on its first Approve.
- Onboarding is paced by the capacity report (`FLEET_GUARDIANS`): a creator is
  admitted while free coverage covers its first proposal; a shortfall scales
  the proposal, it does not block it.

### Expected beta TVL

Carlos supplies the figure. Until it lands, the plan is sized for **$250k**
with 30-day strategies; a 7-day cadence needs the 500 bps bound or a third of
the TVL.

## Run-2 constants (SHE-356, 2026-10-09)

- `EPOCH_LENGTH` **7d** (was 28d; SHE-250). Ana's capacity plan above prices it at
  +17% capacity at 30-day cadence and +28% at 7-day, for free; the audit (F-3) confirms
  7d and 28d both pass the 16-bucket scan bound and keep every lock past the challenge
  deadline. Cost: any future `challengeWindow` is capped at 38d. Constructor immutable.
- `CAP_OVER_SPOT_BPS` stays **40_000** (PR #381). The audit (F-2) recommends ≤ 20_000:
  at 4× with the 50% haircut a source the cap admits can value bonds at up to 2× true
  worth, and the spec's band says 2×. Carlos kept Ana's 4× (the 24h two-pool TWAP is the
  manipulation control; a tighter cap binds on an ordinary rally) and the cap is
  owner-settable after deploy (`setWoodUsdPrice`), reviewed monthly.

## Challenge filings paused through the beta (SHE-352, 2026-10-09)

Run 2 ends with `ChallengeGame.setFilingsPaused(true)`. Reason (audit 2026-10-08,
D-1/D-2/D-1b/F-9): `file` is permissionless; silence for 7 days convicts every approving
key for the 10% floor, and if the fleet counter-bonds, TokenCourt bars the accused and one
outsider with 10k WOOD staked 30 days earlier convicts alone. With filings paused every
court path is unreachable, so the fleet can approve from the first beta proposal.
Cost: no ex-post challenge backstop for depositors during the beta. Accepted because every
depositor is whitelisted by its own vault owner and `ownerOnlyProposals` is on. Unpause
(SHE-361) once the juror reserve staked under the Safe is 30 days old and the counter-bond
treasury (47.4M liquid WOOD in the Safe) and the keeper's `ChallengeFiled` watcher
(sherwood-guardian #84, `COUNTER_BOND_MAX_WOOD` > 0) are live.

## Expected beta TVL (SHE-355, Carlos, 2026-10-09)

At most $10k per vault, median $100–1k, and under $100k for the cohort in total. Against
the table above at EPOCH 7d: a $100k beta of 30-day strategies needs ≈ 28M approving WOOD
at the 2,000 bps Portfolio bound (PR #324) and ≈ 142M uncertified; at 7-day cadence ≈ 65M
at 2,000 bps and ≈ 325M uncertified. So the 30M approving tranche carries the cohort
**only with the Portfolio class certified at ≤ 2,000 bps** (SHE-235); uncertified it
carries ≈ $20k. A 7-day cadence needs a second 30M tranche in new keys or the 500 bps
bound. Lighter is in scope for the beta (Carlos): it is an uncertified community template,
so each Lighter proposal books 2× its capital at full notional out of the same tranche,
and the audit's G-1/G-2 (SHE-365) must be closed before the template is approved on 4663.
