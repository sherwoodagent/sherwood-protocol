# Delegated-Slash Cap, First-Loss Spill, Age-Weighted Voting, and Deterministic Slash Severity

**Date:** 2026-07-19
**Status:** Approved (design), pending implementation plan
**Contracts:** `StakedWood.sol`, `GuardianRegistry.sol` (Part D); `StakedWoodDelegation.sol` untouched
**Related:** issue #4 (deterministic slash severity — **implemented here as Part D**, decisiveness variant)

## 1. Motivation

Three problems in the staking/slashing surface:

1. **Delegator over-exposure.** Delegators are slashed at the same blocker-voted
   severity as their guardian — up to `maxSlashBps` (deployed 9_999 = 99.99%).
   An industry survey (Cosmos, Polkadot, EigenLayer, Symbiotic, Chainlink,
   The Graph, Livepeer, Rocket Pool, Lido, Babylon) found no protocol that
   exposes delegators to near-total loss: delegator slashing is either removed
   (Polkadot Referendum 1910; Chainlink community stakers; The Graph; Livepeer),
   tiny and fixed (Cosmos 5% double-sign), or structurally capped with veto
   layers (EigenLayer allocations, Symbiotic capture guarantees + resolver
   veto). Sherwood at 99.99% is an outlier and makes delegation economically
   irrational. Delegation must ship **enabled** at launch, so this blocks launch.

2. **Flash-stake voting.** Vote weight is instant at stake time. Fresh capital
   can be staked just before a review/proposal snapshot and wield full weight
   with 7-day exit. The unused `Guardian.stakedAt` field already records what
   we need to fix this. Original issue framing: "lock period is 7 days for
   everyone, but make voting weight increase based on current lock time."

3. **Adversarially-voted severity.** Slash severity is the stake-weighted
   median of the BLOCKERS' proposed `slashBps` — the winning side of the
   dispute picks the losers' penalty per-incident. The survey found no
   precedent: severity elsewhere is fixed constants (Cosmos, Chainlink),
   deterministic formulas (Polkadot `min((3x/n)², 1)`), or capped-plus-vetoed
   middleware choice (Symbiotic). A whale blocker can dominate the median and
   impose near-max severity on rivals. Part D replaces the median with a
   deterministic function of block-side decisiveness.

A naive delegated-slash cap alone opens a sybil hole (Livepeer LIP-10's
documented rationale): a guardian stakes `minGuardianStake` from wallet A and
delegates the rest from wallet B, keeping full vote weight while capping most
of their exposure. The design closes this with a first-loss spill onto the
guardian's own stake plus a delegated-weight cap keyed to the guardian's
**aged** own weight.

## 2. Design summary

| Parameter | Meaning | Proposed default | Bounds | Setter |
|---|---|---|---|---|
| `maxDelegatedSlashBps` (**C**) | Max bps a delegation/unbonding pool can lose per slash event | 2_000 (20%) | `[0, min(maxSlashBps, 9_999)]` | protocol owner |
| `ageFloorBps` | Weight fraction of raw stake at age 0 | 2_500 (25%) | `[1, 10_000]` | protocol owner |
| `maturationPeriod` | Age at which own stake reaches full (par) weight | 30 days | `[7 days, 90 days]` | protocol owner |
| `delegatedWeightCapX` (**k**) | Max delegated weight as a multiple of aged own weight | 4 | `[1, 20]` | protocol owner |
| `maxSlashBps` (existing) | Severity ceiling (own stake) | **10_000 (100%)** | `(minSlashBps, 10_000]` — **relaxed from < 10_000** | protocol owner |
| `SUPERMAJORITY_BPS` | Block decisiveness at which severity hits the ceiling (Part D) | 6_667 (2/3), constant | — | — |

**Ceiling relaxation.** The strict `maxSlashBps < 10_000` bound existed solely
as the C-2 pool-bricking guard (a 100% slash zeroes `poolTokens` while
`poolShares` stays nonzero → `Math.mulDiv` divide-by-zero bricks
`delegateStake`). Under this design the pools are only ever slashed through
`min(S, C)`, so the 1-wei guard **moves to `maxDelegatedSlashBps < 10_000`**
and the own-stake ceiling may be a full 100%: `stakedAmount` is a plain
integer (no share math), and a full wipe is the existing deregistration path.
`initialize` / `setMaxSlashBps` / `setMinSlashBps` bounds change accordingly;
the C-2 comments move to the `maxDelegatedSlashBps` setter.

All settable parameters are protocol-global and owner-set (the
parameter-setter multisig), matching the existing
`setMinSlashBps`/`setMaxSlashBps` pattern. Vault owners
have no influence: guardian stakes and delegation pools are protocol-global,
and a vault owner is an adversary in the emergency-settle flow — per-vault
slash parameters would let the vault under review dictate how much of a
global pool burns.

## 3. Part A — delegated-slash cap + first-loss spill

Location: `StakedWood._slashOne`.

Let `S = slashBps` (the deterministic severity from Part D, always within
`[minSlashBps, maxSlashBps]`) and `C = maxDelegatedSlashBps`.

Per approver:

1. **Own base slash**: `ownSlash = min(snapOwnRaw, live) × S / 10_000`, where
   `snapOwnRaw` is the raw own-stake checkpoint at `openedAt` (direct
   `_stakeCheckpoints` read — see §5 for why the old `voteStake` subtraction
   is replaced).
2. **Delegated legs capped at C**: the delegated budget becomes
   `snapDelegated × min(S, C) / 10_000`, spent live-pool-first with the
   remainder spilling to the unbonding pool — the existing PR #359 budget
   mechanics, with `min(S, C)` replacing `S`. The `snapDelegated == 0`
   backward-compat fallback (slash full live + unbonding pools) also uses
   `min(S, C)`.
3. **First-loss spill** (new): the uncovered delegated remainder
   `excess = snapDelegated × (S − min(S, C)) / 10_000`
   is charged to the guardian's own remaining stake, clamped to what is left
   after step 1. Same bookkeeping branches as the base own slash
   (active → decrement `totalGuardianStake` + re-checkpoint;
   unstake-requested → no aggregate decrement, clear the request stamp if
   fully consumed). One checkpoint push covers both own debits.

`GuardianSlashed.ownSlash` reports base + spill (the guardian's total own-stake
hit); `delegatedSlash` continues to report the combined pool hit.

Properties:

- Genuine delegator worst case per incident: `C` (20%), regardless of
  severity. In line with Cosmos (5%) / EigenLayer-style bounded exposure.
- Guardian own stake becomes a first-loss bond backing their delegated book
  (Rocket Pool pattern: operator bond absorbs losses before rETH holders).
- Sybil self-delegation: the shielded excess routes back onto the sybil's own
  stake until it is wiped; combined with Part C the shieldable weight is also
  bounded. Residual discount exists but is bounded and priced (capital lockup
  + guardian death on wipe).
- The 7-day slashable unbonding escrow is **unchanged** — industry-consistent
  (Cosmos full unbonding period, EigenLayer 14d, Symbiotic one epoch).

## 4. Part B — age-weighted own stake (linear discount-to-par)

Own-stake weight ramps linearly from `ageFloorBps` of raw stake at age 0 to
100% (par) at `maturationPeriod`, then stays at par forever. Weight never
exceeds raw stake.

```
age(g, ts)     = ts − stakedAt[g]
ageFactorBps   = ageFloorBps + (10_000 − ageFloorBps) × min(age, maturationPeriod) / maturationPeriod
agedOwn(g, ts) = rawOwnCheckpoint(g, ts) × ageFactorBps / 10_000
```

Applied at **read time** in the vote views — checkpoint traces continue to
store raw stake. This is what makes the change ~10 lines instead of a
veCRV-style slope/bias subsystem: a value that varies continuously with time
cannot be write-checkpointed, but a per-guardian read-time multiply is O(1).

`stakedAt` lifecycle:

- **First stake** (inactive → active): `stakedAt = now` (existing behavior).
- **Top-up** (new): weighted-average re-anchor —
  `stakedAt = (oldStake × stakedAt + amount × now) / (oldStake + amount)`
  (round up / toward `now` so rounding never grants free age). Closes the
  "stake 1 wei early, top up the whale position later, inherit full age" hole.
- **`requestUnstakeGuardian`** (new): `stakedAt = now`. Signaling exit breaks
  the commitment — a request → cancel round-trip restarts the 30-day clock.
  No free age-parking while unvotable.
- **Slash**: `stakedAt` untouched — the stake loss is the punishment; aging is
  not additionally reset.
- **Claim** deletes the struct; a re-stake starts a fresh clock (existing).

Historical-read semantics: past-vote reads use the **current** `stakedAt`
(it is not checkpointed in V1). Every mutation moves `stakedAt` forward
(top-up average, unstake-request reset, re-stake), so a past read after a
mutation can only report **less** weight than was live at that instant —
deflation-only drift, no inflation vector. Governor/registry snapshots are
taken near proposal open and consumed within the review window, so the drift
window is short. If exact historical fidelity is later required, checkpoint
`stakedAt` in a `Trace224` (V2 note).

## 5. Part C — weight formula and quorum surface

```
getPastVotes(g, ts) = agedOwn(g, ts) + min(getPastDelegatedInbound(g, ts), k × agedOwn(g, ts))
```

- **Cap base is aged own weight**, not raw stake. A young guardian's delegated
  weight matures with the guardian's own age — aging cannot be bypassed by
  routing stake through delegation (with cap on raw stake, a fresh guardian
  could wield `k × own` flat weight from day 0). Delegated stake needs no
  timestamps of its own; delegation stays O(1) share-pool.
- Own checkpoint is 0 while unstake-requested (existing), so the delegated
  term is also 0 — matches the current active-guardian gating.
- `getVotes(account)` delegates to `getPastVotes(account, block.timestamp)`
  (unchanged shape).
- **Denominators stay raw**: `getPastTotalVotes` (guardian total),
  `getPastTotalSupply` (+ delegated totals), and the active-delegated
  aggregates keep their existing raw-sum checkpoint semantics. Raw totals are
  an upper bound on true aged weight, so quorum is **conservative** — a young
  cohort finds quorum slightly harder; a matured cohort is exact. Accepted
  trade-off; documented for the registry's `openReview` and Snapshot
  consumers.
- **Slash sizing decoupled from vote weight**: `voteStake` snapshots now
  record age-adjusted, k-capped weight — which breaks the old
  `snapOwn = snapTotal − snapDelegated` derivation in `_slashOne` (subtracting
  the RAW delegated snapshot from a capped/aged total under-computes the own
  basis, potentially to 0). Fix: `_slashOne` sizes the own slash off the raw
  own-stake checkpoint at `openedAt`
  (`_stakeCheckpoints[approver].upperLookupRecent(openedAt)`), read directly,
  clamped to live stake as today. Rationale: **age discounts voting power,
  not liability** — the capital at risk is the staked amount. This is also
  sybil-tighter (a young guardian cannot shrink slash exposure via the age
  discount) and removes the subtraction fragility entirely. `voteStake`
  remains the registry's vote-accounting snapshot but no longer sizes slashes.
- The delegated slash budget (Part A) likewise uses the raw
  `getPastDelegatedInbound(openedAt)` snapshot as its basis, NOT the k-capped
  weight — the cap limits *voting power*, not the pool's slashable base.

## 6. Part D — deterministic slash severity (replaces the blocker-voted median)

### Why the median goes

Blockers currently attach a proposed `slashBps` to their Block vote; the
registry takes the stake-weighted median over blockers and clamps it
(`_weightedMedianSlashBps`). The blockers are adversarial parties to the
review — slashing approvers removes rival guardians and their weight — and a
whale blocker dominates a stake-weighted median. No surveyed protocol lets
the winning side of a dispute choose the losers' penalty per-incident.

### Why the input is block-side decisiveness (not approver weight)

Slashing fires **only** when the block side reaches quorum
(`resolveReview`: `blockStakeWeight ≥ blockQuorumBpsAtOpen × totalAtOpen`) —
the "offense" is approving a proposal that the system then formally blocked.
This rules out both Polkadot-style inputs:

- **Severity increasing in approver weight** (Polkadot's `x` = objectively
  proven offenders) transplants badly: here approvers are offenders only
  because blockers won, and block quorum is a threshold of TOTAL stake — a
  30%-quorum block can defeat a 50%-approval proposal, so the formula would
  slash a majority at maximum severity on a minority's trigger. A
  blocker-griefing amplifier.
- **Severity decreasing in approver weight** (ambiguity discount) lets an
  attacker self-discount: pile approve weight on a draining proposal and
  either defeat the block quorum (no slash at all) or fail into a milder
  slash. Rewards larger attacks.

The manipulation-resistant input is how overwhelmingly the system condemned
the proposal: attackers cannot reduce honest blockers' weight, adding their
own approve weight does not enter the function, and slashed WOOD is burned
(not redistributed), so blockers gain no direct profit from inflating it.
Obvious malice attracts pile-on blocking → high decisiveness → harsh; a
genuinely contested call barely scrapes quorum → floor.

### Formula

Evaluated in `resolveReview` only when `blocked_` is true; O(1) from fields
already in the `Review` struct:

```
bBps      = blockStakeWeight × 10_000 / (totalStakeAtOpen + totalDelegatedAtOpen)
t         = (bBps − blockQuorumBpsAtOpen) / (SUPERMAJORITY_BPS − blockQuorumBpsAtOpen)   // clamped to [0, 1]
severity  = minSlashBps + (maxSlashBps − minSlashBps) × t²
```

- `SUPERMAJORITY_BPS = 6_667` (2/3), a constant — the decisiveness at which
  severity hits the ceiling.
- Degenerate guard: if `blockQuorumBpsAtOpen ≥ SUPERMAJORITY_BPS`, `t = 1`
  (any successful block at such a quorum is already supermajority-condemned).
- Quadratic in `t`: forgiving just above quorum, steep near supermajority.

Worked examples (quorum 30%, min 10%, max 100%):

| Block weight / total | t | severity |
|---|---|---|
| 30% (scraped quorum) | 0 | 10% (floor) |
| 42% | 0.33 | ~20% |
| 55% | 0.68 | ~52% |
| ≥ 66.7% | 1 | 100% (ceiling) |

### Registry changes

- `voteOnProposal` drops the `slashBps` argument (ABI change — acceptable,
  V1.5 is a fresh pre-mainnet deployment; CLI/app updated in lockstep).
- `blockerSlashBps` mapping and `_weightedMedianSlashBps` (collection,
  O(n²) insertion sort, median walk) are deleted; replaced by a pure
  `_severityBps(Review storage)` helper.
- `swood.slashGuardians(key, openedAt, approvers, _severityBps(r))` — call
  shape unchanged.

Severity legitimacy now comes from being fixed BEFORE the offense (formula +
owner-set clamp band), matching the Cosmos/Polkadot pattern. A future
S-curve (ADR-014) or a deferral/veto layer (Symbiotic resolver, Polkadot
27-day unapplied-slash window) can swap in behind `_severityBps` without
touching the slash plumbing; issue #4 stays open for that follow-up only.

## 7. What is deliberately NOT changing

- 7-day `coolDownPeriod` and the slashable unbonding escrow.
- Delegation share math, commission, unbonding pools
  (`StakedWoodDelegation.sol` has zero diffs).
- Owner bonds, registry review flow, governor interfaces (consumers of
  `getPastVotes` need no ABI change).
- No boost-above-par / perpetual age growth: cap-at-par avoids the veCRV
  aggregation machinery and early-whale plutocracy creep. Post-maturation,
  stake is stake.

## 8. Storage & upgrade

New storage in `StakedWood` (leaf contract): `maxDelegatedSlashBps`,
`ageFloorBps`, `maturationPeriod`, `delegatedWeightCapX` — 4 slots from the
existing `__gap` (12 → 8), with the gap comment updated per convention.
`Guardian.stakedAt` already exists (uint64, currently write-only).
`GuardianRegistry`: `blockerSlashBps` mapping deleted (gap re-baselined per
convention); `voteOnProposal` ABI changes (drops `slashBps`).
V1.5 is a fresh pre-mainnet deployment; no live-proxy migration concerns.

New errors/events: bounds-violation reuses `InvalidParameter`; each setter
emits `ParameterChangeFinalized` with a new `PARAM_*` key, matching the
existing setter pattern.

## 9. Security considerations

- **Sybil self-delegation** (Livepeer LIP-10 vector): bounded by spill
  (Part A) + aged-base weight cap (Part C). Residual: a sybil still caps the
  bulk of exposure at C once own stake is wiped; the cost is guardian death
  + delegators (self) stranded through a 7-day slashable escrow at rate C.
- **Blocker collusion**: severity is no longer votable (Part D) — a whale
  blocker can still push a block over quorum, but the resulting severity is
  the formula's floor-side value unless broad honest weight joins the
  condemnation. Reaching the 100% ceiling requires ≥ `SUPERMAJORITY_BPS` of
  total at-open weight voting Block — a supermajority attack, out of scope
  for slash-parameter defenses. Delegator damage stays bounded by C in all
  cases.
- **Blocker pile-on**: severity increasing in block weight means honest
  guardians joining an obvious-malice block raise the penalty — intended.
  Blockers gain no direct payoff (slashed WOOD burns; attribution rewards are
  epoch-level, not slash-proportional), so inflating severity is costly
  griefing with no revenue.
- **Flash-stake / snapshot sniping**: fresh stake gets `ageFloorBps` weight;
  full weight requires 30 days of custody with slash exposure.
- **Quorum bootstrap**: an all-young cohort faces raw-denominator quorum with
  discounted numerators. Deployment should account for this (e.g. seed
  guardians staked ≥ `maturationPeriod` before delegation-sensitive votes, or
  temporarily lower quorum bps).
- **Rounding**: age-factor math rounds down (against the staker); top-up
  average rounds toward `now` (against free age); slash math keeps existing
  round-down-in-burn direction.

## 10. Test plan (high level)

- Severity formula: at exactly quorum (floor), between quorum and
  supermajority (quadratic points), at/above supermajority (ceiling = 100%),
  degenerate `quorum ≥ SUPERMAJORITY_BPS` guard, `minSlashBps == maxSlashBps`
  collapse.
- 100%-severity end-to-end: own stake fully wiped (active and
  unstake-requested branches), pools clamped at C, spill absorbs the rest,
  pool share math stays live (no divide-by-zero) — the C-2 regression test
  moves to the `maxDelegatedSlashBps` bound.
- `voteOnProposal` ABI: Block votes carry no severity; median-era tests
  deleted/rewritten.

- `_slashOne` matrix: S ≤ C (no cap engage, no spill), S > C with own stake
  covering excess, S > C with own stake partially covering (clamp), fully
  wiping (deregistration branch + unstake-requested branches), and the
  `snapDelegated == 0` fallback under the cap.
- Age curve: weight at age 0 / mid / exactly `maturationPeriod` / beyond;
  param-boundary values for `ageFloorBps`.
- Top-up weighted average: early-small + late-large ≈ young age; rounding
  direction.
- Reset round-trip: request → cancel restarts clock; slash does not reset.
- Sybil scenario end-to-end: min-stake + self-delegate vs honest, assert
  bounded discount and spill wipe.
- Weight formula: k-cap engagement, aged-base scaling, zero-own ⇒ zero total.
- Quorum: young cohort vs raw denominator (documented conservatism).
- Invariant: existing delegation invariants unchanged; new invariant
  `agedOwn ≤ rawOwn` and `delegatedWeight ≤ k × agedOwn`.

## 11. References

- Cosmos SDK staking state transitions (slashFactor, unbonding slashability):
  https://docs.cosmos.network/v0.46/modules/staking/02_state_transitions.html
- Polkadot offenses (fixed per-offense magnitudes, deferred slashes, formula):
  https://wiki.polkadot.com/learn/learn-offenses/
- Polkadot Referendum 1910 (nominator slashing removed, unbonding 28d → 2d):
  https://forum.polkadot.network/t/staking-updates-nominators-no-longer-slashable-2-day-unbonding/18063
- EigenLayer ELIP-002 (pro-rata staker slashing, allocation caps, 14d delay):
  https://github.com/eigenfoundation/ELIPs/blob/main/ELIPs/ELIP-002.md
- Symbiotic slasher (VetoSlasher, capture-time guarantees):
  https://docs.symbiotic.fi/modules/vault/slasher/
- Chainlink Staking v0.2 (community stakers non-slashable, flat 700 LINK):
  https://blog.chain.link/chainlink-staking-v0-2-overview/
- Livepeer LIP-10 (delegator-slashing proposal, sybil rationale; never merged):
  https://github.com/livepeer/LIPs/issues/10
- Cosmos ADR-014 proportional slashing (S-curve severity):
  https://github.com/cosmos/cosmos-sdk/blob/main/docs/architecture/adr-014-proportional-slashing.md
