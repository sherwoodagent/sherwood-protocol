# Guardian Economic Security: Making Coordinated Collusion Infeasible

**Date:** 2026-07-22
**Status:** Design of record, signed off (re-reviews #4760018146, #5053349247) — F1–F6 + precision items remediated; §2 guarantee scoped to detectable extraction and reconciled with §8; F4-viability + ROE-before-fail-closed tracked as (blocking) pre-launch gates. **Scope cuts 2026-07-22:** salami drawdown predicates + cross-vault accumulators + 30d lock removed (slow-bleed accepted, §7/§8) but the per-vault per-epoch outflow cap kept as a trustless bleed-rate bound (§3.1a); multi-collateral bonds deferred to v2 (v1 WOOD-only, hard covered-TVL ceiling, §3.7).
**Scope:** GuardianRegistry, StakedWood, SyndicateVault (custody guards + compensation escrow), SyndicateGovernor (approve quorum, proposer bond, hooks)

## 0. Revision log

Review #4759928193 (agent-assisted, verified against `main`) confirmed the §1
impossibility result and the mechanical-guard layer, and found six ways the
central inequality leaks in the regime v1 actually ships. This revision
remediates all of them:

- **F1** slash-to-victim recoupment → compensation snapshot (§3.5, §3.8).
- **F2** WOOD-denominated inequality → dollar-denominated coverage via a hard covered-TVL cap (§2, §3.7). Multi-collateral bonds (the ceiling-lifting fix) **deferred to v2 by decision 2026-07-22**; v1 launches WOOD-only, small-vault-only, cap binding hard.
- **F3** retroactive liability presupposes a signer → explicit bond-encumbered approve quorum replaces pure optimistic passage for coverage-consuming proposals; cold-start addressed; risk-scaled proposer bond added (§3.3a, §3.9).
- **F4** honest-guardian economics mispriced → coverage-weighted approver reward (§3.10).
- **F5** temporal netting → unstake delay covers the challenge window (§3.3). Most of the salami/drawdown machinery this finding prompted (rolling-drawdown predicate, cross-vault accumulators, 30d lock) was **removed by decision** (2026-07-22); the **per-vault per-epoch outflow cap was kept** (§3.1a, re-review #5053349247) as a trustless bleed-rate bound. Slow-bleed is an accepted risk (§7, §8) but rate-bounded on-chain.
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

**Scope of the guarantee (reconciled with §8).** The coalition inequality below
holds for **detectable extraction** — any drain that trips an objective challenge
predicate (§3.4): out-of-adapter outflow, oracle-deviation, proposer-linked
destination, rogue allowance, or a single proposal breaching its own declared
envelope. That covers one-shot and fast multi-proposal drains. It does **not**
cover the *patient slow-bleed*: a coalition extracting value through many trades
that each stay inside their per-proposal envelope and trip no predicate. v1 ships
no on-chain accumulator for that vector (removed by decision — §7); it is an
accepted, monitored residual (§8), caught by the §6 dashboard and watchtower
reaction, not by the inequality. The doc title's "infeasible" is therefore a
claim about *detectable coordinated collusion*, not about every conceivable
patient bleed.

Coalition arithmetic the design enforces **for detectable extraction** (all
quantities in the drain's unit of account, i.e. vault assets / USD):

```
coalition gain  ≤  Σ certified max-extractable value of approved proposals
coalition loss  ≥  Σ dollar value of slashable approver stake at slash-time
                ≥  Σ extractable value                          (k = 1, tier 2)
recoupment      =  0        (compensation is snapshot-gated to pre-drain holders)
net             ≤  0  −  bribes  −  gas  −  proposer bond forfeited
```

The slow-bleed residual is not bounded by this inequality (§8), but its *rate* is
bounded trustlessly by the per-vault per-epoch outflow cap (§3.1a) — so a patient
bleed is capped per epoch, giving the §6 dashboard and watchtower time to react.
The residual is thus "monitoring latency within a bounded per-epoch rate," not
"unbounded extraction."

Three properties make each line hold and are the load-bearing changes from the
first draft:

1. **Coverage is dollar-denominated (F2).** The exposure cap (§3.3) measures
   `slashableBond(g)` at a conservative dollar haircut, and covered TVL per
   vault is capped so that total slashable dollars ≥ extractable dollars *even
   under a WOOD drawdown*. v1 enforces this by **capping covered TVL to the
   WOOD-only budget** (§3.7) — a hard per-vault ceiling; multi-collateral bonds
   (which would lift the ceiling) are deferred to v2. Large vaults do not launch
   until then.
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

### 3.1a Per-vault per-epoch outflow cap (trustless bleed-rate bound)

A single per-vault accumulator: cumulative net outflow across all of a vault's
proposals within an epoch cannot exceed a per-vault cap. Enforced at execution
(custody layer), no cross-vault tracking, no stake lock — the cheapest piece of
the removed salami set (§7), kept because it is the only *trustless* bound on the
slow-bleed vector. It does not detect malice; it caps how fast a vault can lose
value regardless of how the loss is sliced, converting "unbounded-rate patient
extraction" into "bounded-rate extraction the §6 dashboard has time to catch."
Set generously enough not to throttle real trading (a legitimate vault rarely
moves a large fraction of its assets net-out per epoch); the cap is a rate limit
on bleeding, not a limit on activity.

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
  WOOD drawdown. (v1 bonds are WOOD-only; multi-collateral legs at their own
  haircuts are a v2 extension — §3.7.)
- `k = 1` for tier-2 exposure (hard infeasibility where rugs live); tier-0/1
  exposure is weighted by certified extractable bound, not notional.
- **No per-proposal earmark locks.** The cap nets across time: the same stake
  covers sequential proposals across many vaults; it blocks *simultaneous*
  over-exposure — the batching attack (approve N drains in one window, lose one
  bond once).
- **Temporal exposure.** "Open" = until the challenge window (§3.4) has elapsed.
  Unstake delay ≥ the challenge window (§5), so a guardian cannot approve and
  unstake before its approvals can be challenged. (v1 does not track cumulative
  cross-proposal drawdown — see the accepted salami risk in §8.)

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
5. **Single-proposal drawdown breach:** a proposal whose realized loss exceeds
   its own declared `maxDrawdownBps` (§3.1). This gives the per-proposal envelope
   teeth for one bad proposal; it is NOT an aggregate/rolling accumulator. v1
   deliberately ships no cumulative cross-proposal or cross-vault drawdown
   predicate (the slow-bleed "salami" attack is an accepted risk — §8).

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

**Snapshot block (R1, re-review).** Every conviction in v1 is tied to a single
proposal's execution (predicates 1–5 all key on one proposal), so "pre-drain
block" is unambiguous — the block before that proposal executed. (The trailing-
window drawdown predicate that would have needed a time-weighted snapshot was
removed with the rest of the salami machinery — §8.)

**WOOD-only payout boundary (R1×F2 coupling, re-review).** Compensation is funded
from slash proceeds, which in v1 are WOOD. So a victim payout is worth only what
the slashed WOOD fetches at slash-time — the same denomination gap the covered-TVL
cap bounds on the coverage side. The cap is what keeps this acceptable: because
covered TVL is held below the WOOD budget (§3.7), the dollars recoverable stay
proportionate to the dollars at risk. v2 multi-collateral funds payouts partly in
stable legs and lifts the ceiling.

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

**Worked ROE example (F4 viability gate, re-review — illustrative inputs).** The
open question is whether the premium can clear a guardian's tail-risk hurdle at
the target k=1 capacity. Concrete instance, assumed numbers labeled as such:

```
Vault TVL                         $2,000,000
Strategy gross yield (annual)     12%  → $240,000 gross profit/yr
Guardian fee share (default)      5% of gross profit  → $12,000/yr fee pool
Tier-2 exposure a guardian carries (k=1)   $2,000,000 (worst case, full notional)
Adjudication false-conviction rate p_e (assumed)   0.5%/yr
Expected tail loss  = p_e · 100% · exposure = 0.005 · $2,000,000 = $10,000/yr
```

At these numbers the entire $12,000 fee pool barely exceeds the $10,000 expected
tail loss of a *single* guardian carrying the full exposure — leaving ~$2,000 to
split across the cohort as actual return on $2M of at-risk capital, an ROE far
below any rational hurdle. The arithmetic only closes when exposure is
**tier-0/1** (extractable is basis points of notional, so expected tail loss
falls by the same 10⁴/boundBps factor coverage does): at a 50 bps bound the
$2M notional carries ~$10,000 extractable, expected tail loss ~$50/yr, and the
$12,000 pool is ample. **Implication, stated as a launch constraint:** at the
default 5% fee share and a nonzero conviction-error rate, k=1 *tier-2* capacity
is affordable only at small TVL; sustained large-TVL tier-2 flow requires either
a higher guardian fee share (LP-return tradeoff, §8), a lower conviction-error
rate (better adjudication), or accepting that large vaults run predominantly
tier-0/1. The premium clears comfortably for the bounded tiers that should
carry most real flow; it does not clear for large unbounded exposure, and the
design does not pretend otherwise.

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

### 3.7 Covered-TVL cap (WOOD-only in v1; multi-collateral deferred to v2)

WOOD mcap (~$15M) cannot underwrite large TVL alone, and a colluding guardian can
short WOOD (or the rug itself craters the token), so a WOOD-only bond's
slash-time dollar value can fall below the drain. Multi-collateral bonds are the
full fix, but they are a genuinely new accounting subsystem (per-leg haircuts,
per-collateral oracle pricing) and were judged disproportionate for v1
(decision 2026-07-22). Instead v1 makes R2 hold in dollars by **capping covered
TVL**, not by adding collateral:

- Covered TVL per vault is capped at the dollar value of the slashable WOOD bonds
  behind it at the conservative `priceHaircut`. A vault **cannot open
  coverage-consuming proposals beyond that cap** — the cap is a hard per-vault
  TVL ceiling, not a trigger to add collateral.
- Consequence, stated plainly: with WOOD-only bonds the per-vault safe-coverage
  ceiling is low (a fraction of a ~$15M-mcap token at a conservative haircut —
  plausibly low-single-digit millions per vault). Large vaults do not launch
  until v2 multi-collateral exists. This is a **capacity ceiling accepted as a
  scope decision**, not a security relaxation: inside the cap, R2 holds in
  dollars; the cap is what keeps it holding.
- **Small ≠ unconditionally safe.** The deliberate-WOOD-short vector (§1 threat
  model) is *bounded but not closed* even for capped vaults: short size is limited
  by WOOD borrow liquidity, not vault size, so a capped vault is protected mainly
  because thin borrow at a low mcap plus the haircut headroom make a large short
  expensive — not because the cap itself neutralizes shorting. Keep this labeled;
  as borrow liquidity for WOOD grows, revisit the haircut.
- **v2 — multi-collateral bonds.** Guardian bonds may hold sWOOD + blue-chip
  collateral (USDC/ETH, or restaked ETH), each leg entering `slashableBond` at
  its own haircut, lifting the per-vault ceiling. Required before any vault above
  the WOOD-only budget onboards.

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
  dollar-denominated exposure cap with `slashableBond` as defined; hard covered-TVL
  cap (WOOD-only; multi-collateral is v2, §3.7); explicit approve quorum (§3.3a);
  risk-scaled proposer bond. This alone hard-caps extractable value and
  guarantees a covering signer — it degrades safely to "value-moving proposals
  need covering approvers or they don't execute" with no court yet.
- **v1b — retroactive liability:** authorized-slasher entrypoint + compensation
  escrow; challenge game (predicates 1–5, all single-proposal, per-proposal
  freeze); watchtower funding; approver reward (§3.10).
- **v1c — adjudication:** pre-exploit + pre-accumulation-hardened voting snapshot;
  two-layer court with the restructured panel bond.

**v2:** multi-collateral bonds (lifts the per-vault TVL ceiling — §3.7); adapter
probation/downgrade automation; threshold-calibrated auto-demote circuit breakers
(need live traffic to set thresholds without a DoS lever); dynamic k by risk
class; on-chain cumulative-drawdown predicates if monitoring shows real
slow-bleed attempts (§8).

**Scope + liveness gate (re-review, updated after 2026-07-22 scope cuts).**
Multi-collateral bonds and the salami machinery were both cut from v1 as
disproportionate, which shrinks the v1 surface back toward the "reuses existing
rails" spirit. The remaining coupling to watch: the F3 fail-open→fail-closed
switch means liveness now *depends on* the F4 reward economics recruiting enough
covering bond — an underfunded premium means legitimate proposals fail to reach
approve quorum and flow halts, a coupling optimistic passage did not have. Gates
before v1a ships:

1. Confirm the WOOD-only cap + approve quorum + compensation escrow ship
   *jointly correct*, each with the one-sentence invariant + fuzz test this
   section requires. Launch **WOOD-only, small-vault-only** with the covered-TVL
   cap binding hard; no large vault onboards until v2 multi-collateral exists.
2. **BLOCKING:** validate the §3.10 ROE arithmetic at the intended launch
   TVL/tier mix *before* flipping passage to fail-closed. Because liveness now
   depends on the premium recruiting covering bond, launching fail-closed with an
   underfunded premium halts legitimate flow. Set the launch TVL/tier target
   where the ROE arithmetic actually closes; if it doesn't close at the desired
   scale, lower the capacity target or keep optimistic passage for the
   bounded-tier flow that doesn't need a covering signer to be safe. This gate is
   blocking, not merely tracked.

## 5. Parameters (initial)

| Parameter | Initial value | Notes |
|---|---|---|
| k (tier-2 aggregate cap) | 1 | hard infeasibility for arbitrary calldata |
| `priceHaircut` (WOOD→USD) | conservative, ≤ 30-day-low | robust to a coordinated WOOD drawdown |
| Covered-TVL cap per vault | Σ slashableBond · priceHaircut | hard ceiling in v1 (WOOD-only); v2 multi-collateral lifts it |
| Challenge window | 14d tier-2, 7d tier-0/1 | shorter window recycles coverage faster |
| Unstake / exposure-open delay | ≥ challenge window | guardian can't unstake before its approvals can be challenged |
| Per-vault per-epoch outflow cap | generous (won't throttle real trading) | trustless bleed-rate bound (§3.1a); kept from the salami set |
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
  guardian-approval overlap. **This is v1's primary *detection* of the slow-bleed
  salami attack** (§8); on-chain drawdown predicates were cut, so malice is caught
  by this dashboard + watchtower reaction, not auto-slashed. The per-vault
  per-epoch outflow cap (§3.1a) trustlessly bounds the *rate*, guaranteeing this
  dashboard has at least one epoch to react.
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
- **Most on-chain anti-salami machinery removed (decision 2026-07-22), one piece
  kept.** The earlier draft carried an aggregate rolling-drawdown predicate,
  cross-vault proposer/guardian drawdown accumulators, a per-vault per-epoch
  outflow cap, and a 30-day exposure lock. **Removed:** the rolling-drawdown
  predicate, the cross-vault accumulators, and the 30-day lock — disproportionate
  for v1 (multiple accumulators + cross-vault forensics + a long stake lock, for
  an attack slower and harder than the one-shot rug the guards already stop).
  **Retained (per re-review #5053349247):** the per-vault per-epoch outflow cap
  (§3.1a) — one accumulator, no cross-vault tracking, no lock — because it is the
  only *trustless* bound on bleed rate and is nearly free. The per-proposal
  drawdown-breach predicate (§3.4 #5) is also retained (bounds a single bad
  proposal, not salami). Net: slow-bleed is an accepted risk (§8) but rate-bounded
  on-chain, not monitoring-plus-human alone.

## 8. Accepted risks / open questions

- `priceHaircut` calibration is a live tension: too conservative starves
  throughput, too loose reopens F2. Tuned by governance against observed WOOD
  volatility; monitored (§6). In v1 (WOOD-only, §3.7) it can't beat a forward
  shock that pushes WOOD below any trailing low, which is precisely why the
  covered-TVL cap is a hard ceiling and large vaults wait for v2 multi-collateral
  — the cap, not the haircut, is what bounds the residual.
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
- **WOOD price source is a pre-launch external dependency (no feed today).**
  There is currently no Chainlink WOOD feed on Robinhood Chain. Both the tier-0/1
  runtime guards (§3.2 manipulation-resistant valuation) and `priceHaircut` (§5,
  WOOD→USD for `slashableBond`) require a manipulation-resistant WOOD price.
  Options: stand up a Chainlink feed (being pursued by the team), or a
  protocol-run TWAP over the main WOOD pool as fallback. Note either source is
  only as robust as WOOD's underlying liquidity (~$500k pool today), so the feed
  improves *measurement* but does not remove `priceHaircut` or the F2 economics —
  an accurate low price is still a low price. Track feed availability as a gate on
  the tier-0/1 valuation design.
- **Slow-bleed / salami (accepted risk, decided 2026-07-22; rate-bounded).** v1
  ships no on-chain cumulative-*drawdown* predicate (single- or cross-vault), so a
  coalition bleeding a vault via many individually-in-envelope losing trades trips
  no malice predicate and no one is slashed for the bleed as such. Accepted
  because: (a) it is materially slower/harder than a one-shot rug (needs a
  controlled counterparty and sustained deniability), (b) the mechanical guards +
  single-proposal predicates stop the fast rug, (c) the §6 dashboard surfaces a
  sustained bleed for intervention, and — the piece added back on re-review —
  (d) the **per-vault per-epoch outflow cap (§3.1a) trustlessly bounds the bleed
  rate**, so the attacker cannot extract faster than one epoch's cap and the
  dashboard/watchtower always has at least that long to react. Residual: within
  the per-epoch rate and the per-proposal envelopes, a patient bleed is not
  auto-slashed — detection of *malice* (vs bad trading) is still
  monitoring-plus-human. Revisit a full drawdown predicate in v2 if monitoring
  shows real attempts.
- **F4 is now priced-but-possibly-unaffordable at scale, not unpriced.** The
  §3.10 worked example shows the premium clears for bounded tiers and does not
  clear for large tier-2 exposure at the default fee share. This is a viability
  constraint on *capacity*, not a soundness hole; the launch TVL/tier target must
  be set where the ROE arithmetic closes.
