# Guardian Economic Security: Making Coordinated Collusion Infeasible

**Date:** 2026-07-22
**Status:** Draft for review — revised after review #4759928193 (F1–F6 + precision items remediated)
**Scope:** GuardianRegistry, StakedWood, SyndicateVault (custody guards + compensation escrow), SyndicateGovernor (approve quorum, proposer bond, hooks)

## 0. Revision log

Review #4759928193 (agent-assisted, verified against `main`) confirmed the §1
impossibility result and the mechanical-guard layer, and found six ways the
central inequality leaks in the regime v1 actually ships. This revision
remediates all of them:

- **F1** slash-to-victim recoupment → compensation snapshot (§3.5, §3.8).
- **F2** WOOD-denominated inequality → dollar-denominated coverage cap + multi-collateral pulled into v1 for over-budget vaults (§2, §3.7).
- **F3** retroactive liability presupposes a signer → explicit bond-encumbered approve quorum replaces pure optimistic passage for coverage-consuming proposals; cold-start addressed; risk-scaled proposer bond added (§3.3a, §3.9).
- **F4** honest-guardian economics mispriced → coverage-weighted approver reward (§3.10).
- **F5** temporal netting / salami → unstake delay covers the drawdown window; rotation-resistant drawdown key (§3.3, §3.4).
- **F6** court capture / non-independent layers → pre-accumulation defense + panel-bond restructure (§3.5).
- **Precision:** `slashableBond` defined (§3.3); §1 "equally" corrected; "reuses slash rails" framing corrected and authorized-slasher entrypoint made explicit (§4); `refundSlash` fate stated (§4).

## 1. Problem

The guardian mechanism today cannot make a coordinated rug unprofitable:

- The guardian fee is attributed to approvers by **stake weight**, not by
  diligence (`getApproverWeights` returns stake-weighted data,
  `GuardianRegistry.sol:302-315`). Raising the fee pays an auto-approver the
  same per-stake rate as a guardian who actually simulated — pay is not tied to
  work.
- Slashing fires only when a review reaches the block quorum
  (`resolveReview` slashes approvers only inside `if (blocked_)`,
  `GuardianRegistry.sol:657-671`; `slashGuardians` has exactly one caller). A
  proposal that **executes** — the attacker's success case — carries zero
  guardian penalty.
- Passage is optimistic: silence passes (`GuardianRegistry.sol:637-651` — never
  opened, cohort-too-small, and below-quorum all resolve not-blocked). With
  universal auto-approve, nobody blocks, nobody is ever slashed. The equilibrium
  is circular.

**Threat model:** a malicious proposer agent colluding with guardians (and
optionally the vault owner) to drain a vault, because the drain payoff exceeds
anything the mechanism can take from the coalition. The coalition may hold or
acquire vault shares and WOOD, short WOOD, and file its own challenges.

**Impossibility result.** Any fix that leaves the executed-outcome path
penalty-free cannot deter collusion, regardless of bond size or severity curves.
Economic infeasibility requires exactly two properties:

- **R1 — executed outcomes carry liability:** an **identified approver** loses
  stake when the proposal they signed drains funds, after the fact. R1 has no
  force where no approver is identified, so passage cannot stay purely
  optimistic for value-moving proposals (§3.3a).
- **R2 — exposed stake scales with extractable value, in the drain's unit of
  account:** a proposal can only move value covered by slashable stake whose
  **dollar** value at slash-time meets or exceeds the extractable value.
  Coverage denominated in a volatile token the attacker can short does not
  satisfy R2 (§2, F2).

## 2. Design overview

**Adjudicated retroactive slashing + tiered max-extractable coverage.**

Coalition arithmetic the design enforces (all quantities in the drain's unit of
account, i.e. vault assets / USD):

```
coalition gain  ≤  Σ certified max-extractable value of approved proposals
coalition loss  ≥  Σ dollar value of slashable approver stake at slash-time
                ≥  Σ extractable value                          (k = 1, tier 2)
recoupment      =  0        (compensation is snapshot-gated to pre-drain holders)
net             ≤  0  −  bribes  −  gas  −  proposer bond forfeited
```

Three properties make each line hold and are the load-bearing changes from the
first draft:

1. **Coverage is dollar-denominated (F2).** The exposure cap (§3.3) measures
   `slashableBond(g)` at a conservative dollar haircut, and covered TVL per
   vault is capped so that total slashable dollars ≥ extractable dollars *even
   under a WOOD drawdown*. Vaults whose TVL exceeds the WOOD-only budget must use
   multi-collateral bonds (§3.7), which are therefore **in v1**, not deferred.
2. **Recoupment is zero (F1).** Slash proceeds compensate **pre-drain-block
   shareholders** via a non-transferable claim snapshot, not the live ERC4626
   NAV. A coalition that drains, self-challenges, and accumulates shares from
   exiting holders receives nothing from the slash — its share fraction at
   compensation time is irrelevant because claims are fixed to holders as of the
   pre-drain block.
3. **A signer always exists (R1/F3).** Coverage-consuming proposals cannot
   execute without a bond-encumbered approve quorum (§3.3a). Silence no longer
   passes a value-moving proposal, so there is always an identified,
   stake-backed approver to hold liable.

Coverage is sized to **max-extractable value**, not notional, so TVL scales past
staked WOOD for bounded strategies: capital in custody or in tier-0/1 positions
consumes little coverage; only value genuinely at risk in open proposals
consumes the budget, and that budget recycles every challenge window.

## 3. Components

### 3.1 Risk envelope (per proposal)

Every proposal declares:

- `maxCapital` — net outflow ceiling, enforced by SyndicateVault at the custody
  layer (per-proposal net-outflow metering; the vault today enforces only global
  batch buffers, `SyndicateVault.sol:443-448`, so this is a **new** per-proposal
  meter, and `StrategyProposal` gains an extractable-value field).
- `maxDrawdownBps` — declared risk envelope. Realized losses inside it are market
  risk (no slash); losses beyond it are challengeable (§3.4).

### 3.2 Adapter tiering with runtime guards

Tier is a property of the **adapter selector**, assigned at listing, enforced at
execution. Proposal tier = max tier across its calls. Zero per-proposal discretion.

| Tier | Meaning | Coverage required | Runtime guard |
|------|---------|-------------------|---------------|
| 0 | Closed loop: funds can only travel vault↔adapter | slippage/manipulation bound (bps of notional) | post-execution balance-delta: `vault assets + position value ≥ pre − bound`, else revert |
| 1 | Oracle-bounded discretion (swaps/LP with min-out) | max deviation vs oracle | min-out vs manipulation-resistant oracle at execution block |
| 2 | Arbitrary calldata, external recipients, unknown selectors | full notional | none possible — priced instead |

**Default-deny: unknown selector = tier 2.**

Hardening (all verified buildable against existing patterns — codehash assertion
already exists at `SyndicateVault.sol:426`, manipulation-resistant valuation
exists in the pricing layer):

- **Manipulation-resistant valuation is a tier-0/1 eligibility requirement.** The
  boundedness invariant must be evaluated against a valuation the executing
  transaction cannot move (TWAP or an external oracle — never spot reserves of a
  pool the adapter trades into, never share prices the adapter itself can inflate).
  If no such valuation exists for an adapter, it is tier 2 by definition.
- **Execution-time codehash assertion.** The guard asserts the adapter target's
  `EXTCODEHASH` equals the certified hash; mismatch reverts and auto-demotes the
  selector to tier 2. Upgradeable/proxied targets and adapters with mid-call
  external callbacks (reentrancy, delegatecall, hooks) are ineligible for
  tier 0/1 as a listing predicate.
- **Oracle-health and divergence checks.** The guard requires the valuation
  oracle to be live (heartbeat/staleness bound) and probes the target protocol's
  `paused()` where exposed; a stale oracle or paused target reverts the
  execution. The guard also reverts if its valuation deviates from an independent
  reference (TWAP) beyond a generous static multiple of the certified bound
  (e.g. 5×). Binary, stateless, per-execution checks — they block the
  transaction; they do not demote the adapter (threshold-calibrated auto-demote
  triggers are v2).

### 3.3 Aggregate exposure cap

Guardian-level invariant, checked at `voteOnProposal` (approve side):

```
Σ maxExtractable(open approvals of guardian g)  ≤  k · slashableBond(g)
```

- **`slashableBond(g)` — defined (precision bug).** The amount of `g`'s stake
  that a 100% verdict slash can actually reach, in dollars at a conservative
  haircut:

  ```
  slashableBond(g) = ownStake(g) · priceHaircut
                   + delegatedInbound(g) · (maxDelegatedSlashBps / 10_000) · priceHaircut
  ```

  Delegated stake is counted **only at the `maxDelegatedSlashBps` haircut**
  (`StakedWood.sol:664`; a delegated pool cannot be slashed 100% — first-loss
  spills onto own stake). Counting full vote weight (own + full delegations)
  would violate the inequality at the accounting layer before any attack.
  `priceHaircut` (§5) converts WOOD to a conservative dollar value robust to a
  WOOD drawdown; multi-collateral bond legs (§3.7) enter at their own haircuts.
- `k = 1` for tier-2 exposure (hard infeasibility where rugs live); tier-0/1
  exposure is weighted by certified extractable bound, not notional.
- **No per-proposal earmark locks.** The cap nets across time: the same stake
  covers sequential proposals across many vaults; it blocks *simultaneous*
  over-exposure — the batching attack (approve N drains in one window, lose one
  bond once).
- **Temporal exposure (F5).** "Open" = until the LONGER of the challenge window
  and the trailing drawdown-predicate window (§3.4 predicate 5) has elapsed.
  Unstake delay ≥ that same maximum (§5). A guardian cannot approve salami clips
  and unstake before the aggregate-drawdown predicate can fire against them.

### 3.3a Explicit approve quorum (F3)

Optimistic passage remains for proposals that move no coverage-consuming value
(pure settle, zero-`maxCapital`). **Any proposal that consumes coverage must
clear a bond-encumbered approve quorum before it can execute:**

- Execution requires approve-side stake ≥ `minApproveCoverage(proposal)` where
  the covering approvers' aggregate `slashableBond` ≥ the proposal's
  `maxExtractable`. No coverage-consuming proposal executes with zero covering
  signers.
- **Cold-start interaction.** Today a below-cohort-floor review
  (`MIN_COHORT_STAKE_AT_OPEN = 50_000e18`, `GuardianRegistry.sol:612,642-646`)
  auto-resolves not-blocked with zero approvers. Under the approve quorum, a
  proposal that cannot raise covering approvals simply **does not execute** — it
  expires — rather than executing unreviewed. This removes the
  engineer-a-thin-cohort attack (a coalition cannot force execution by
  suppressing the cohort; suppression only blocks execution).
- Non-coverage-consuming proposals are unaffected, preserving throughput for
  rebalances that move nothing extractable.

### 3.4 Challenge game (retroactive liability)

Post-execution challenge window. Anyone may post a bonded challenge citing
**objective violation predicates** checkable from public calldata + trace:

1. Net outflow to addresses outside the whitelisted adapter set.
2. Execution price deviation beyond bound vs manipulation-resistant oracle.
3. Outflow destination linkable to the proposer (funding-graph predicate).
4. Allowance/ownership granted to a non-protocol address.
5. **Aggregate rolling drawdown** (anti-salami): cumulative realized loss over a
   trailing window exceeding an aggregate bound, challengeable independently of
   any single proposal.
   - **Rotation-resistant key (F5).** The drawdown bucket keys on the **vault**
     alone (plus time window), not `(vault, proposer, guardian-set)`. Rotating
     Sybil proposers or swapping one guardian out of the set no longer resets the
     bucket. Approver liability for a drawdown breach attaches to every guardian
     who approved any clip contributing to the windowed loss, pro-rata by the
     extractable value they signed.
   - The per-epoch per-vault outflow cap complements it but is not relied on
     alone (it is per-vault and set generously for real trading).

Flow:

- **Undisputed** challenge → slash auto-executes after a delay. Because slash
  proceeds are compensation-snapshot-gated (§3.8), a coalition filing its **own**
  undisputed challenge to trigger a self-directed payout gains nothing — the
  recoupment channel F1 identified is closed at the payout, not the challenge.
- **Disputed** (accused post a counter-bond) → escalates to adjudication (§3.5).
- Failed challenge → challenger bond forfeits to the accused.
- **Freeze scope:** a filed challenge freezes only the accused guardians'
  coverage attributed to the challenged proposal — not their whole stake.
  Challenger bond scales with the exposure it freezes. Adapters demote only on a
  **passed** challenge; an unproven filing flags for expedited review.
- **Standing watchtower:** the challenge trigger must not depend on altruism.
  Sherwood forensic agents run the predicate monitor as a funded protocol role
  (feeding SGRD reputation), plus a first-detector bounty sized to cover forensic
  cost. Health metric: a live challenge game shows filings, not silence.

### 3.5 Adjudication

Trust hierarchy: mechanical guards (instant) → challenge game (days) →
adjudication (weeks, contested cases only).

- **Voting snapshot precedes the exploit:** dispute voting power is snapshotted
  **before the challenged proposal's execution block**, restricted to
  pre-exploit-staked WOOD. Kills post-drain buying and flash-loan acquittals.
- **Pre-accumulation defense (F6).** The snapshot does not stop an attacker who
  buys WOOD *before* a planned exploit. Mitigations, layered:
  - Dispute voting weight uses **aged** stake (the age-weighting already in the
    voting system), so WOOD accumulated shortly before the exploit carries
    reduced weight.
  - A conviction requires either an unappealed panel ruling OR a token vote that
    clears a **participation floor** (a minimum fraction of eligible pre-exploit
    stake must vote); below the floor, the panel ruling stands. This removes the
    "swing a single-digit-turnout appeal cheaply" path.
- **Two-layer court: bonded panel + token-vote appeal.**

  *Why one layer is not enough.* A token vote alone is (1) incompetent for
  forensic questions (single-digit turnout, narrative over trace) and
  (2) capturable at ~$15M mcap. A standalone panel is bribable (5 humans, bribe
  3) with no check above it. The layers cover each other's failure mode.

  *Layer 1 — panel (trial court).* ~5 members elected by WOOD governance,
  competent to read traces, each posting a slashable bond. Disputed challenges
  go to the panel first; it rules within days.

  *Layer 2 — appeal (supreme court).* Any ruling is appealable to the full WOOD
  vote within the appeal window. The token vote is sovereign.

  *The binding incentive, restructured (F6).* The first draft slashed the panel
  bond **only if overturned on appeal**, which let an attacker who controls the
  cheap appeal make a corrupt ruling safe and gave panelists a beauty-contest
  incentive to predict the vote. Instead:
  - Panel members post a bond slashable for a ruling later shown **fraudulent or
    evidence-contradicting**, adjudicated by the token vote on an explicit
    "was this ruling made in bad faith" question — a separate track from the
    merits appeal, so overturning the merits does not automatically slash, and
    controlling the merits appeal does not immunize a corrupt panelist.
  - Panelist reward is flat (independent of which way they rule), removing the
    incentive to track the expected vote rather than the evidence.
  - Appeals that overturn a panel ruling require the participation floor above,
    so a corrupt panelist cannot be rescued (nor an honest one condemned) by a
    thin appeal.

- Guilty verdict → slash via the authorized-slasher entrypoint (§4) at
  `maxSlashBps` (100%; ground truth established, no severity ramp),
  delegated-slash caps and first-loss spill preserved, proceeds → **compensation
  escrow** (§3.8), never the live NAV.

### 3.8 Compensation escrow (F1 — the regression fix)

Slash proceeds do **not** route to the vault's live ERC4626 balance
(`totalAssets` is pro-rata, `SyndicateVault.sol:724`; share transfers are ungated,
`_update` at `SyndicateVault.sol:545-551`). Routing there would let a coalition
drain, let honest holders exit at depressed NAV, accumulate their shares, and
recoup ≈ f·S when the slash lands — a recoupment channel today's burn sink does
not have (`_burnWood` → dead address, `StakedWood.sol:1014,1231`).

Instead:

- On a passed challenge, the system reads a **holder snapshot taken at the
  pre-drain block** (the same block the dispute voting snapshot uses) and mints
  **non-transferable, per-address compensation claims** pro-rata to shares held
  *then*.
- Slash proceeds fund those claims. Holders redeem their own claim; unclaimed
  residue after a window routes to the protocol insurance backstop, not to
  current NAV.
- A coalition's share fraction at compensation time is irrelevant: it holds no
  pre-drain claim on stake it did not hold pre-drain, and claims cannot be bought
  from exiting honest holders because they are non-transferable.

This mirrors the voting-snapshot primitive already in the design; the omission in
the first draft was applying it to the payout as well as the vote.

### 3.9 Risk-scaled proposer bond (F3)

The proposer is the actual attacker yet posted no bond scaled to what it can
extract (emergency-settle likewise sat at a flat 10k-WOOD owner bond, R2 never
applied to it). Add:

- `propose` for a coverage-consuming proposal requires the proposer to post a
  bond scaled to the proposal's `maxExtractable` (a fraction, tuned so honest
  proposers are not priced out but a rug forfeits meaningfully).
- The proposer bond is slashed to the compensation escrow (§3.8) on a passed
  challenge, **before** approver stake, so the attacker's own capital is
  first-loss.
- Emergency-settle owner bond scales the same way (R2 applied to it).

### 3.10 Approver reward commensurate with tail risk (F4)

The first draft added 100% retroactive tail liability to approvers and left
compensation at ≤5% of gross profit (default 500 bps) split by stake. Reward
scaled with profit; risk scaled with extractable value; they did not scale
together, so a rational guardian underwriting large exposure at 100% severity
with any nonzero adjudication-error rate would simply not participate — cohort
collapse, which is the likelier failure than collusion.

- Approver compensation gains a **coverage-weighted component**: pay scales with
  the `maxExtractable` a guardian underwrote and the duration it stayed at risk,
  not only with realized profit. Underwriting risky coverage earns an insurance
  premium proportional to that risk.
- The premium is funded from a protocol-set share of guardian fees plus a slice
  of the proposer bond yield/forfeitures, sized against a target guardian ROE
  that clears the tail-risk hurdle at realistic adjudication-error rates.
- This also repairs the two §1 problems the first draft named but did not solve:
  pay becomes tied to underwriting work, and correct approval of risky-but-sound
  proposals is rewarded rather than merely un-penalized.

### 3.6 Adapter listing pipeline

- **Born tier 2.** Deploy + register = usable immediately at full-notional
  coverage. No permission to exist.
- **Tier downgrade = bonded claim.** Submitter posts runtime guards, certified
  extractable bound per selector, valuation method, and a bond underwriting the
  claim.
- **Probation:** audit of guards + live tier-2 stats + red-team window where
  Sherwood adversarial agents attack the guards. Then WOOD governance vote +
  timelock.
- **Liability layering:** guardians underwrite the *certified bound*; loss beyond
  it (guard bypass) slashes the adapter submitter's bond first, then the protocol
  insurance backstop.
- **Demotion:** instant and permissionless on a passed challenge; codehash
  mismatch auto-demotes (§3.2).

### 3.7 Multi-collateral bonds (now v1 for over-budget vaults — F2)

WOOD mcap (~$15M) cannot underwrite large TVL alone, and a colluding guardian can
short WOOD (or the rug itself craters the token), so a WOOD-only bond's
slash-time dollar value can fall far below the drain. Therefore:

- Covered TVL per vault is capped at the dollar value of the slashable bonds
  behind it at the conservative `priceHaircut`. A vault whose TVL exceeds the
  WOOD-only budget **cannot open coverage-consuming proposals** until backed by
  multi-collateral bonds.
- Guardian bonds may hold sWOOD + blue-chip collateral (USDC/ETH, or restaked
  ETH), with a required WOOD skin-in-game slice. Each leg enters `slashableBond`
  at its own haircut.
- This is the piece that makes R2 true in dollars; it is **in v1** for any vault
  above the WOOD budget, not deferred. Small vaults within the WOOD budget can
  launch on WOOD-only bonds.

## 4. Phasing

The full surface is too large to ship jointly correct at once. Every new
accounting path requires a stated one-sentence invariant + fuzz test before merge.

**Framing correction.** The first draft called v1 "reuses existing slash rails."
That oversold it: three v1 items are **new subsystems**, not `require`s —
per-proposal outflow metering (the vault has no extractable-value field today,
`ISyndicateGovernor.sol:71-112`), the aggregate exposure ledger (the registry
tracks only `{voteEnd, reviewEnd, vault}`), and the challenge/adjudication/panel
machinery (absent repo-wide). What *does* pre-exist and is reused: the 100%
own-stake slash ceiling is already legal (`setMaxSlashBps` up to `10_000`; the
"can never zero a pool" clamp now lives only on the delegated leg,
`StakedWood.sol:664`), and the first-loss spill / delegated cap.

**Authorized-slasher entrypoint.** `slashGuardians` is `onlyRegistry`, reachable
only from `resolveReview`, and the burn sink is hardcoded. A verdict-driven slash
needs a **new authorized-slasher entrypoint** on StakedWood that (a) the
adjudication path can call and (b) routes to the compensation escrow (§3.8)
rather than the dead address. This is explicit v1 work, not a reuse.

**`refundSlash` fate.** The existing multisig appeal path (`refundSlash`, 20%/epoch
capped reserve, `GuardianRegistry.sol:826-840`) is **retained** for the
block-quorum review-slash path (fat-finger honest-guardian protection). The new
challenge/verdict slash path does **not** use it — a proven-malice verdict is not
refundable — and the two paths are kept distinct so the reserve cap is not shared.

**Ordering correction.** The first draft front-loaded the novel forensic court
while deferring the validation machinery (probation, red-team, auto-demote) that
makes tiering safe — backwards for risk. Revised order puts mechanical safety and
the pieces that bound loss *before* the court:

- **v1a — bound what moves (no new trust):** risk envelopes + per-proposal
  outflow metering; tiering with all §3.2 guards; adapter-submitter bond escrow;
  dollar-denominated exposure cap with `slashableBond` as defined; covered-TVL
  cap + multi-collateral for over-budget vaults; explicit approve quorum (§3.3a);
  risk-scaled proposer bond. This alone hard-caps extractable value and
  guarantees a covering signer — it degrades safely to "value-moving proposals
  need covering approvers or they don't execute" with no court yet.
- **v1b — retroactive liability:** authorized-slasher entrypoint + compensation
  escrow; challenge game (predicates 1–5, rotation-resistant drawdown key,
  per-proposal freeze); watchtower funding; approver reward (§3.10).
- **v1c — adjudication:** pre-exploit + pre-accumulation-hardened voting snapshot;
  two-layer court with the restructured panel bond.

**v2:** adapter probation/downgrade automation, threshold-calibrated auto-demote
circuit breakers (need live traffic to set thresholds without a DoS lever),
dynamic k by risk class.

## 5. Parameters (initial)

| Parameter | Initial value | Notes |
|---|---|---|
| k (tier-2 aggregate cap) | 1 | hard infeasibility for arbitrary calldata |
| `priceHaircut` (WOOD→USD) | conservative, ≤ 30-day-low | robust to a coordinated WOOD drawdown |
| Covered-TVL cap per vault | Σ slashableBond · priceHaircut | over-budget vaults require multi-collateral |
| Challenge window | 14d tier-2, 7d tier-0/1 | shorter window recycles coverage faster |
| Drawdown predicate window | 30d rolling, keyed on vault | rotation-resistant |
| **Unstake / exposure-open delay** | **≥ 30d (max of challenge + drawdown windows)** | fixes F5 salami-then-unstake |
| Challenger bond | scales with frozen exposure | griefing deterrent |
| Proposer bond | fraction of `maxExtractable` | first-loss, → compensation escrow |
| Approver reward | coverage-weighted premium | target ROE clears tail-risk hurdle |
| Slash severity (verdict) | `maxSlashBps` (100%) | proceeds → compensation escrow |
| Panel appeal participation floor | min fraction of pre-exploit stake | blocks thin-turnout capture |
| Panel bond slash | bad-faith track only | not auto-slashed on merits overturn |

## 6. Monitoring (dashboard)

- Intra-block divergence between guard valuation and independent TWAP on any
  tier-0/1 execution (valuation manipulation).
- Per-vault realized alpha vs benchmark: variance, venue Herfindahl,
  guardian-approval overlap (slow drain).
- Challenge activity: filings, challenger loss rate, frozen-exposure ratio
  (silence = no watchtower; high-loss-rate-with-rising-filings = griefing).
- Tier-2 exposure utilization vs queued proposals (throughput strangulation).
- **Guardian ROE vs tail-risk hurdle** (F4 leading indicator: under-participation).
- **Covered-TVL headroom vs actual TVL, and WOOD price vs `priceHaircut`**
  (F2 leading indicator: coverage going underwater in dollars).
- **Compensation-claim redemption rate** (F1: confirms proceeds reach pre-drain
  holders, not current NAV).

## 7. Rejected alternatives

- **Honeypot proposals / sting bribes:** fixes attention, not informed collusion.
- **Per-proposal earmark underwriting:** capital-inefficient across concurrent
  vaults; replaced by the netting aggregate cap.
- **Notional-based coverage:** caps TVL at staked WOOD; replaced by
  max-extractable coverage.
- **Slash proceeds to live vault NAV:** creates the F1 recoupment channel;
  replaced by the snapshot-gated compensation escrow (§3.8). Considered and
  rejected precisely because it is a regression vs today's irrecoverable burn.
- **Pure optimistic passage retained for value-moving proposals:** leaves R1 with
  no signer to slash and enables the engineer-a-thin-cohort attack; replaced by
  the explicit approve quorum (§3.3a). This is the simpler shape the first draft
  skipped.
- **No proposer bond:** leaves the actual attacker with no first-loss capital;
  replaced by the risk-scaled proposer bond (§3.9), also skipped by the first
  draft.
- **Security council as standing fast path:** removed; reinstated only as the
  narrow bonded panel (§3.5).
- **Panel bond slashed only on merits overturn:** lets control of a cheap appeal
  immunize a corrupt panel; replaced by the separate bad-faith track + flat
  panelist reward + participation floor (§3.5, F6).

## 8. Accepted risks / open questions

- `priceHaircut` calibration is a live tension: too conservative starves
  throughput, too loose reopens F2. Tuned by governance against observed WOOD
  volatility; monitored (§6).
- Pre-accumulation (F6) is *mitigated, not eliminated* — a patient, well-capitalized
  attacker who buys aged WOOD long before an exploit and clears the participation
  floor can still contest an appeal. The panel bad-faith track and the mechanical
  loss caps (which hold regardless of the court) are the backstop; the court is
  the last line, not the only one.
- Existence of manipulation-resistant valuations is per-adapter engineering; a
  flagship adapter without one is tier-2 priced and changes capacity economics.
- Funding-graph predicate (§3.4 #3) needs a consistent evidentiary standard.
- Approver-reward funding (§3.10) must balance guardian ROE against fee drag on
  LPs; if the premium cannot both clear the tail-risk hurdle and leave LPs
  competitive returns, the k=1 tier-2 capacity target may need to fall (fewer,
  better-paid guardians underwriting less) — an explicit economic tradeoff to
  validate before launch.
- Settlement/valuation oracles are load-bearing for guards, PnL, AND the
  pre-drain compensation snapshot; inherits and extends the frozen-settle-price
  work.
