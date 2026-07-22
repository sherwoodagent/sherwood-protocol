# Guardian Economic Security: Making Coordinated Collusion Infeasible

**Date:** 2026-07-22
**Status:** Draft for review
**Scope:** GuardianRegistry, StakedWood, SyndicateVault (custody guards), SyndicateGovernor (two hooks)

## 1. Problem

The guardian mechanism today cannot make a coordinated rug unprofitable:

- The guardian fee is attributed to every approver equally (off-chain Merkl via
  `getApproverWeights`), so raising it pays lazy approvers the same as diligent ones.
- Slashing fires only when a review reaches the block quorum
  (`resolveReview` slashes approvers only on the `blocked` path). A proposal that
  **executes** — the attacker's success case — carries zero guardian penalty.
- Passage is optimistic: silence passes. With universal auto-approve, nobody blocks,
  nobody is ever slashed. The equilibrium is circular.

**Threat model:** a malicious proposer agent colluding with guardians (or exploiting
their inattention) to drain a vault, because the drain payoff exceeds anything the
mechanism can take from the coalition.

**Impossibility result.** Any fix that leaves the executed-outcome path penalty-free
cannot deter collusion, regardless of bond size or severity curves. Economic
infeasibility requires exactly two properties:

- **R1 — executed outcomes carry liability:** approvers lose stake when the thing
  they approved drains funds, after the fact.
- **R2 — exposed stake scales with extractable value:** a proposal can only move
  value covered by slashable stake behind it; otherwise TVL outgrows the security
  budget and collusion becomes profitable at scale.

## 2. Design overview

**Adjudicated retroactive slashing + tiered max-extractable coverage.**

Coalition arithmetic the design enforces:

```
coalition gain  ≤  certified max-extractable value of approved proposals
coalition loss  ≥  slashable approver stake  ≥  that same extractable value   (k = 1, tier 2)
net             ≤  0  −  bribes  −  gas
```

Slash proceeds route to the drained vault (victim compensation), not burn. Honest
guardians who did not approve are untouched; liability lands exclusively on signers.

Coverage is sized to **max-extractable value**, not notional, so TVL scales past
staked WOOD: capital sitting in custody or in bounded positions needs no coverage;
only value genuinely at risk in open proposals consumes the security budget, and
that budget recycles every challenge window.

## 3. Components

### 3.1 Risk envelope (per proposal)

Every proposal declares:

- `maxCapital` — net outflow ceiling, enforced by SyndicateVault at the custody
  layer (transfer metering per proposal).
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

Hardening (premortem findings #1, #2 — the two top-ranked failure modes):

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

### 3.3 Aggregate exposure cap

Guardian-level invariant, checked at `voteOnProposal` (approve side):

```
Σ maxExtractable(open approvals of guardian g)  ≤  k · slashableBond(g)
```

- "Open" = challenge window (§3.4) not yet expired.
- `k = 1` for tier-2 exposure (hard infeasibility where rugs live); tier-0/1
  exposure is weighted by certified extractable bound, not notional, so routine
  flow consumes little cap.
- **No per-proposal earmark locks.** The cap nets across time: the same stake
  covers sequential proposals across many vaults; it only blocks *simultaneous*
  over-exposure — which is precisely the batching attack (approve N drains in one
  window, lose one bond once).
- Unstake queue: a guardian's withdrawable stake excludes their open exposure;
  unstake delay covers the longest open challenge window.

### 3.4 Challenge game (retroactive liability)

Post-execution challenge window (7–14 days; shorter for tier-0/1 to recycle
coverage faster). Anyone may post a bonded challenge citing **objective violation
predicates** checkable from public calldata + execution trace:

1. Net outflow to addresses outside the whitelisted adapter set.
2. Execution price deviation beyond bound vs manipulation-resistant oracle at the
   execution block.
3. Outflow destination linkable to the proposer (funding-graph predicate).
4. Allowance/ownership granted to a non-protocol address.
5. **Aggregate rolling drawdown** (premortem #3): cumulative realized loss for a
   (vault, proposer, guardian-set) tuple over a trailing window exceeding an
   aggregate bound — challengeable independently of any single proposal. Closes
   the salami/slow-drain bypass where every clip stays inside its per-proposal
   envelope. Complemented by a per-epoch cumulative outflow cap per vault.

Flow:

- **Undisputed** challenge → slash auto-executes after a delay.
- **Disputed** (accused post a counter-bond) → escalates to adjudication (§3.5).
- Failed challenge → challenger bond forfeits to the accused.
- **Freeze scope** (premortem #8): a filed challenge freezes only the accused
  guardians' coverage attributed to the challenged proposal — not their whole
  stake. Challenger bond scales with the exposure it freezes. Adapters are demoted
  only on a **passed** challenge; an unproven filing merely flags the adapter for
  expedited review. This keeps the freeze from becoming a mass-griefing weapon.
- **Standing watchtower** (premortem #4): the challenge trigger must not depend on
  altruism. Sherwood forensic agents run the predicate monitor as a funded protocol
  role (feeding SGRD reputation), plus a first-detector bounty sized to cover real
  forensic cost. Health metric: a live challenge game shows noise (some filings),
  not silence.

### 3.5 Adjudication

Trust hierarchy: mechanical guards (instant) → challenge game (days) →
adjudication (weeks, contested cases only).

- **Voting snapshot precedes the exploit** (premortem #5): voting power for a
  dispute is taken from stake/balances snapshotted **before the challenged
  proposal's execution block**, and restricted to pre-exploit-staked WOOD.
  Drain proceeds cannot finance an acquittal; flash-loaned WOOD cannot vote.
- **Two-layer court: bonded adjudication panel + token-vote appeal.**

  *Why one layer is not enough.* A WOOD token vote as the sole judge fails two
  ways: (1) **competence** — a dispute is a forensic question ("does this trace
  show funds routing to a proposer-linked address, or a legitimate trade that
  got sandwiched?"); answering requires reading execution traces, and dispersed
  token votes get single-digit turnout deciding on narrative, not evidence;
  (2) **capture** — at ~$15M WOOD mcap, an attacker who drained a vault can
  spend part of the proceeds buying/borrowing WOOD to vote their own case
  innocent. A standalone expert panel fails differently: 5 trusted humans,
  capturable by bribing 3, with no check above them. The two layers cover each
  other's failure mode.

  *Layer 1 — the panel (trial court).* A small panel (~5 members, elected by
  WOOD governance) of parties competent to read forensic evidence. Each member
  posts a slashable bond. Disputed challenges go to the panel first; it reviews
  the trace and rules within days. This is where competence and speed live.

  *Layer 2 — the appeal (supreme court).* Any panel ruling is appealable to the
  full WOOD token vote within the appeal window (§5). The token vote is
  sovereign: it can overturn any panel ruling. The panel therefore holds no
  final authority — it is a first-instance court whose every decision token
  holders can veto.

  *The binding incentive.* If an appealed ruling is overturned by the token
  vote, the panel members who signed it **lose their bonds**. A corrupt ruling
  is not merely reversible — it is personally expensive for the signers. The
  only ruling that reliably survives appeal is the one the public evidence
  supports, so bonded panelists are paid to rule with the evidence.

  *Capture resistance, combined:* an attacker must corrupt a majority of the
  panel AND win the public appeal vote AND do so against a voting snapshot
  taken before the exploit (below) — three independent barriers instead of one
  buyable poll.
- Guilty verdict → `slashGuardians` at `maxSlashBps` (100%; ground truth
  established, no severity ramp), delegated-slash caps and first-loss spill
  preserved, proceeds → drained vault.

### 3.6 Adapter listing pipeline

- **Born tier 2.** Deploy + register = usable immediately at full-notional
  coverage. No permission to exist.
- **Tier downgrade = bonded claim.** Submitter posts runtime guards, certified
  extractable bound per selector, valuation method, and a bond underwriting the
  claim itself.
- **Probation:** audit of guards + live tier-2 stats (volume, time, zero passed
  challenges) + red-team window where Sherwood adversarial agents attack the
  guards. Then WOOD governance vote + timelock.
- **Liability layering:** guardians underwrite the *certified bound*; loss beyond
  it (guard bypass) slashes the adapter submitter's bond first, then the protocol
  insurance backstop. Keeps tier-0 approval pricing sane.
- **Demotion:** instant and permissionless on a passed challenge; codehash
  mismatch auto-demotes (§3.2).

### 3.7 Multi-collateral bonds (v2)

WOOD mcap (~$15M) cannot underwrite large TVL alone. v2 allows guardian bonds in
sWOOD + blue-chip collateral (USDC/ETH, or restaked ETH), with a required WOOD
skin-in-game slice. Decouples the security budget from token price; the
underwriting-premium → staking-yield loop paces capacity growth.

## 4. Phasing (premortem #6)

The full surface is too large to ship jointly correct on v1. Every new accounting
path requires a one-sentence invariant + fuzz test before merge.

**v1 (MVP — reuses existing slash rails):**
1. Risk envelopes + custody outflow metering.
2. Tiering with manipulation-resistant valuation + codehash guards (small initial
   adapter set, tiers assigned by governance directly — no probation pipeline yet).
3. Aggregate exposure cap.
4. Challenge game with predicates 1–5, per-proposal freeze, watchtower funding.
5. Adjudication: pre-exploit snapshot + panel with appeal.

**v2:** adapter probation/downgrade pipeline, auto-demote circuit breakers beyond
codehash mismatch, multi-collateral bonds, dynamic k by risk class.

## 5. Parameters (initial)

| Parameter | Initial value | Notes |
|---|---|---|
| k (tier-2 aggregate cap) | 1 | hard infeasibility for arbitrary calldata |
| Challenge window | 14d tier-2, 7d tier-0/1 | shorter window = faster coverage recycling |
| Challenger bond | scales with frozen exposure | griefing deterrent |
| Slash severity (proven malice) | `maxSlashBps` (100%) | proceeds → victim vault |
| Aggregate drawdown predicate window | 30d rolling | per (vault, proposer, guardian-set) |
| Panel appeal window | 7d | overturned ruling slashes signers |
| Unstake delay | ≥ longest open challenge window | covers open exposure |

## 6. Monitoring (premortem dashboard)

- Intra-block divergence between guard valuation and independent TWAP on any
  tier-0/1 execution (leading indicator: valuation manipulation).
- Per-vault realized alpha vs benchmark: variance, venue concentration
  (Herfindahl), guardian-approval overlap (leading indicator: slow drain).
- Challenge activity: filings, challenger loss rate, frozen-exposure ratio
  (silence = no watchtower; high-loss-rate-with-rising-filings = griefing).
- Tier-2 exposure utilization vs queued proposals (throughput strangulation).

## 7. Rejected alternatives

- **Honeypot proposals / sting bribes:** fixes attention, not informed collusion —
  a real briber proves authenticity through the bribe channel itself.
- **Per-proposal earmark underwriting:** capital-inefficient for guardians
  covering concurrent proposals across vaults; replaced by the netting aggregate
  cap.
- **Notional-based coverage:** caps TVL at staked WOOD; replaced by
  max-extractable coverage.
- **Security council as standing fast path:** removed as general machinery;
  reinstated only as the narrow bonded adjudication panel (§3.5) after the
  premortem showed a spot token vote is capturable as a sole forensic judge.

## 8. Accepted risks / open questions

- Existence of manipulation-resistant valuations is per-adapter engineering; if
  the flagship strategy's adapter has none, its flow is tier-2 priced and the
  capacity economics change.
- Challenge-ease vs griefing is a live tension; bond sizing will be tuned after
  real challenge flow exists.
- Funding-graph predicate (§3.4 #3) needs an evidentiary standard the panel can
  apply consistently; off-chain evidence quality varies.
- Settlement/valuation oracles are load-bearing for both guards and PnL
  measurement; inherits and extends the frozen-settle-price work.
