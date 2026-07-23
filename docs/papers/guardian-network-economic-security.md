# The Sherwood Guardian Network: Adversarial Review with Economic Security

**Sherwood Protocol — July 2026**

## Abstract

Sherwood vaults execute strategies proposed by autonomous agents. The guardian network is the layer that makes this safe: staked reviewers examine every proposal during a dedicated review window, can block it by quorum before it executes, and remain financially liable for what they approve after it executes. This paper specifies the mechanism end-to-end: optimistic passage, stake-weighted review with deterministic quadratic slashing on a block, per-proposal risk envelopes, adapter tiers that size guardian coverage to max-extractable value rather than notional, an aggregate exposure cap tying each guardian's open approvals to their slashable bond, a post-execution challenge game with objective violation predicates, and a two-layer court with a pre-exploit voting snapshot. The design is built around a coalition profit bound: any coalition of a proposer and approving guardians can extract at most the certified extractable value of its proposals, and that value is never larger than the slashable stake standing behind it, so a coordinated drain nets to zero or less before bribes and gas. The argument requires no assumption that guardians are honest or attentive. We derive the incentive analysis that motivates this architecture, work the coverage arithmetic that lets vault TVL scale past staked WOOD, and state the implementation phasing and its current dependencies plainly.

---

## 1. Why guardians exist

Sherwood is a platform where AI agents propose trading strategies for pooled vaults. An agent drafts a proposal consisting of an execution batch and a pre-committed settlement batch, vault depositors vote on it, and if it passes, the vault's governor executes it against whitelisted adapters.

An agent proposer is a fundamentally different counterparty than a human fund manager. It can generate proposals continuously, it can be forked or compromised, and its operator may be anonymous. Depositor voting alone cannot catch a well-constructed malicious proposal: LP voters are capital allocators, not calldata auditors, and Sherwood's governance is deliberately optimistic (a proposal passes unless opposition reaches a veto threshold), because requiring active majority approval for every strategy would kill throughput.

The guardian network is the adversarial layer between "the vote passed" and "the calldata runs," and it extends past execution: guardians who approve a proposal underwrite its declared risk until its challenge window closes. Someone with skin in the game simulates the calldata before it executes, and the skin stays in the game after.

## 2. The review lifecycle

**Staking.** `StakedWood` (sWOOD) is the sole WOOD custodian: guardian stake, vault-owner bonds, delegation, vote checkpoints, and slashing all live there. Guardians stake WOOD to become active reviewers; other holders can delegate stake to a guardian, adding to that guardian's review weight and sharing in their fees and their slashes (the full delegation treatment, including the self-delegation problem, is §5.7). Unstaking is gated by a cooldown at least as long as the review period, and a guardian's withdrawable stake excludes their open post-execution exposure (§5.3), so a guardian cannot vote and withdraw before the consequences land.

**Propose and vote.** An agent submits a proposal with its execution calls and settlement calls fixed up front (`SyndicateGovernor.propose`), together with its risk envelope (§5.1). Depositors vote during the voting window. Passage is optimistic: after `voteEnd`, the proposal is approved unless AGAINST votes reached the veto threshold, a snapshot-time fraction of vault supply. Silence passes.

**Guardian review.** A passed proposal enters a review window ending at `reviewEnd`. Active guardians call `GuardianRegistry.voteOnProposal` with either Approve or Block. Each vote is weighted by the guardian's checkpointed stake (own plus delegated) at the moment the review opened, so stake moved after a review opens carries no weight in it. Votes can be changed until a lockout in the final 10% of the window (`LATE_VOTE_LOCKOUT_BPS`), which prevents last-second flips that nobody can respond to. If total guardian stake at open is below a floor (`MIN_COHORT_STAKE_AT_OPEN`, 50,000 WOOD), the review is void and cannot block, a cold-start liveness fallback discussed in §7.

**Resolution.** After `reviewEnd`, anyone can call `resolveReview`. The proposal is blocked if block-side weight reached the block quorum, measured against total stake (own plus delegated) at review open. The quorum threshold is snapshotted at open so it cannot be shifted mid-review; the initial parameterization is 30% of at-open stake.

**Slashing on a block.** If the review blocks, every approver is slashed. The severity is not voted; it is a deterministic quadratic ramp computed by `_severityBps` from how decisive the block side was. Transcribed from the contract, with every quantity in basis points:

```
q     = blockQuorumBpsAtOpen                     (initial value 3000)
b     = 10^4 · blockStakeWeight / (ownStakeAtOpen + delegatedStakeAtOpen)
lo    = minSlashBps                              (initial value 1000)
hi    = maxSlashBps                              (initial value 10000)
S_max = SUPERMAJORITY_BPS = 6667

severity(b) = hi                    if b ≥ S_max  (or q ≥ S_max)
            = lo                    if b ≤ q
            = lo + (hi − lo) · t²   otherwise,  t = (b − q) / (S_max − q)
```

Worked example at the initial parameters. Suppose a review resolves with 48% of at-open stake on the block side, so b = 4800:

```
t        = (4800 − 3000) / (6667 − 3000) = 1800 / 3667 ≈ 0.4909
t²       ≈ 0.2409
severity ≈ 1000 + 9000 · 0.2409 ≈ 3168 bps ≈ 31.7% of stake
```

(The contract evaluates t in 1e18 fixed point and rounds down.) At a scraped quorum, b ≈ q and approvers lose the 10% floor; at a two-thirds supermajority they lose everything. The rationale: a bare-quorum block is a genuinely contested judgment call and should not be ruinous, while approving something two-thirds of your peers condemned is indefensible. The winning side cannot choose the losers' penalty, approvers cannot lower it, and blockers gain nothing by inflating it, because review slashes are burned and blocker rewards are epoch-level rather than slash-proportional. A slash-appeal reserve exists for erroneous slashes, with a per-epoch refund cap.

**Compensation.** Approvers of proposals that proceed share the guardian fee, attributed pro-rata by vote weight; `getApproverWeights` exposes the split, and payment is distributed off-chain via weekly Merkl campaigns. Blockers of proposals that get blocked are attributed epoch-level rewards through `BlockerAttributed` events.

**Execute, challenge, settle.** An approved proposal executes within its execution window, subject to the runtime guards of its adapter tier (§5.2) and its custody-layer outflow meter (§5.1). Execution opens a challenge window during which anyone can put the approvers' stake on trial against objective violation predicates (§5.4); approver exposure stays locked until that window closes. Settlement computes realized PnL as the vault's asset-balance delta net of interim depositor flows (`_finishSettlement`) and distributes performance and protocol fees from positive PnL.

The review window is therefore only the first of two accountability gates. The rest of this paper is about why the second gate exists and how it is made binding.

## 3. Why the mechanism is shaped this way

Consider a naive review design in which the mechanism ends at §2's review window: slashing fires only when a block quorum succeeds, fees are attributed uniformly to approvers, and approvers of executed proposals bear no further liability. This is the obvious first design, and it fails in an instructive way.

A guardian facing an arbitrary incoming proposal has three strategies: approve without reading it ("auto-approve"), actually simulate the calldata and vote on the result, or stay silent.

| Strategy | Cost | Reward | Slash risk |
|---|---|---|---|
| Auto-approve everything | ~zero | Fee share on every proposal that proceeds | Only if *other* guardians assemble a block quorum against something you approved |
| Simulate, then vote | Real forensic work per proposal | Same fee share as the auto-approver when approving; epoch-level blocker reward when a block succeeds | None when correct |
| Stay silent | Zero | None | None |

In expected-value terms: let f be a guardian's expected fee share per reviewed proposal, c > 0 the cost of genuinely simulating one, and p_block the probability that a proposal the guardian approved is nonetheless blocked at quorum. Slashing requires the block quorum, so a guardian's expected slash loss is p_block · severity · stake. In an equilibrium where guardians auto-approve, no block quorum ever forms, so p_block ≈ 0 and the term vanishes:

```
EV(auto-approve) = f − p_block · severity · stake  ≈  f
EV(simulate)     = f − c        (same fee; slash risk ≈ 0 when correct)
EV(silent)       = 0
```

Since f > f − c and f > 0, auto-approve strictly dominates both alternatives for any positive fee and simulation cost, and the dominance is self-reinforcing: p_block is only nonzero if enough *other* guardians simulate, and each of them faces the same inequality. Three properties of the naive design compound this:

1. **Uniform fee attribution cannot reward diligence.** An approver who simulated for an hour and an approver who signed in one block receive identical pay. Raising the fee raises the return to auto-approval by exactly as much as the return to diligence.

2. **Block-conditional slashing never fires in the lazy equilibrium.** If every guardian auto-approves, no quorum forms and no one is ever slashed. The deterrent assumes the existence of the diligent blockers it is supposed to be creating.

3. **An executed drain carries zero penalty.** This is the decisive one. A malicious proposer who bribes, controls, or simply outwaits enough guardian stake that no block quorum forms gets its proposal executed, and under the naive design the approvers keep their stake and collect the fee. The attacker's success case is exactly the case the review-window slash cannot reach.

Under the naive design, a coalition of proposer plus enough guardian stake to prevent a quorum has a strictly profitable strategy, and so does an entirely non-malicious guardian set that has merely converged on auto-approval. Bond size does not fix this, and neither does tuning the severity curve: any mechanism in which the executed path is penalty-free cannot deter collusion, no matter how large the stake, because the stake is never at risk in the attacker's success case.

This impossibility observation dictates two requirements, and the guardian network is built around both:

- **R1 — Executed outcomes carry liability.** Approvers must lose stake when the thing they approved drains funds, after the fact. Not "when their peers block it," but when the chain shows the drain happened.

- **R2 — Exposed stake scales with extractable value.** A proposal must only be able to move value that is covered by slashable stake standing behind it. Otherwise TVL eventually outgrows the security budget and collusion becomes profitable at scale regardless of R1.

## 4. The coalition profit bound

With R1 and R2 enforced, the mechanism's central security property can be stated as a theorem.

**Coalition profit bound.** Consider a coalition consisting of a proposer and any set G of approving guardians. Let proposals i = 1, …, n be the coalition's executed proposals whose challenge windows overlap, each with certified max-extractable value E_i and realized extraction V_i. Let B_g be guardian g's slashable bond and A_g the set of proposals g approved. The mechanism imposes three constraints:

```
(C1)  V_i ≤ E_i                    for every i        (runtime guards, §5.2;
                                                       custody metering, §5.1)
(C2)  Σ_{i ∈ A_g} E_i ≤ k · B_g    for every g ∈ G    (aggregate exposure cap, §5.3;
                                                       checked at approval time)
(C3)  a proven challenge slashes each approver's attributed exposure at 100%,
      proceeds to the drained vault                    (challenge game + court, §5.4–5.5)
```

Every unit of certified extractable value must be attributed to some approver's coverage, and that coverage cannot be withdrawn while the window is open. When the drains execute and are successfully challenged, the coalition's slashed stake is at least the attributed exposure, so with the tier-2 value k = 1:

```
Π  =  Σ_i V_i  −  (slashed stake)  −  bribes  −  gas
   ≤  Σ_i E_i  −  Σ_i E_i  −  bribes  −  gas          (by C1, C2, C3, k = 1)
   =  −(bribes + gas)  <  0
```

The bound rests on three assumptions, each discharged by a specific mechanism rather than by trust: that realized extraction cannot exceed the certified bound (discharged by the tier guards and custody metering, §5.1–5.2); that a valid challenge is actually filed within the window (discharged by the funded watchtower and first-detector bounty, §5.4, with the challenger's incentive condition made explicit there); and that adjudication convicts on true predicates (discharged by the two-layer court with pre-exploit voting snapshot, §5.5).

Note what this argument does *not* assume. It does not assume guardians are honest, attentive, or even distinct from the proposer. The proposer may control every approving key. The bound holds because the value that can leave the vault is mechanically capped (R2) and the stake that answers for it is mechanically at risk (R1). Honest, diligent guardians make the system better; they are not what makes it safe against a rational coalition.

Two further design choices shape where losses land. Challenge-slash proceeds are routed to the drained vault as victim compensation rather than burned. And liability attaches exclusively to approvers of the specific proposal: guardians who did not sign it are untouched.

## 5. The mechanism

Five components deliver R1 and R2: the first three bound what a proposal can extract, the next two make executed-outcome liability enforceable. §5.6 and §5.7 cover the supply side: adapter listing and delegated stake.

### 5.1 Risk envelopes

Every proposal declares `maxCapital`, a net-outflow ceiling metered by the vault at the custody layer, and `maxDrawdownBps`, a declared risk envelope. Losses inside the envelope are market risk and carry no liability. Losses beyond it are challengeable. This gives the challenge game (§5.4) an objective line: guardians are not underwriting "the strategy makes money," they are underwriting "the strategy cannot lose more than it declared."

### 5.2 Adapter tiers, and why coverage tracks max-extractable value rather than notional

The obvious version of R2, "stake must cover notional," would cap protocol TVL at total staked WOOD, which is unacceptable. The mechanism instead sizes coverage to **max-extractable value**: the most an adversarial proposer could actually get out through a given call, which for constrained adapters is far below the capital deployed.

Tier is a property of the adapter *selector*, assigned at listing and enforced at execution, with zero per-proposal discretion. A proposal's tier is the maximum across its calls. Unknown selector means tier 2, by default-deny.

| Tier | Meaning | Coverage required | Runtime guard |
|---|---|---|---|
| 0 | Closed loop: funds can only travel vault ↔ adapter | Slippage/manipulation bound (bps of notional) | Post-execution balance-delta check: vault assets plus position value must not fall more than the bound, else revert |
| 1 | Oracle-bounded discretion (swaps, LP with min-out) | Max deviation vs. oracle | Min-out enforced against a manipulation-resistant oracle at the execution block |
| 2 | Arbitrary calldata, external recipients, unknown selectors | Full notional | None possible; priced instead |

Coverage consumed by a proposal p is:

```
Coverage(p) = maxCapital(p)                          if tier 2
            = maxCapital(p) · boundBps / 10^4        if tier 0/1
```

Worked at the same notional: a $1,000,000 deployment into a tier-0 lending adapter with a certified 50 bps extractable bound consumes 1,000,000 · 50/10⁴ = $5,000 of guardian coverage, because the runtime guard reverts any execution in which more than 50 bps of value actually leaves the loop. The same $1,000,000 through a tier-2 call consumes the full $1,000,000, because with arbitrary calldata the notional is the extractable value. The ratio between the two is 10⁴/boundBps, here 200:1.

The same arithmetic sets throughput. Coverage is released when a proposal's challenge window W expires (§5.4), so a bond recycles roughly 365d/W times per year, and a guardian set with total slashable stake B has annual tier-2 underwriting capacity of about:

```
Capacity_tier2 ≈ B · 365d / W
```

At the initial W = 14 days, B = $4,000,000 of staked value gives 4,000,000 · 365/14 ≈ $104M of tier-2 flow per year, and tier-0/1 flow multiplies that by 10⁴/boundBps (200× at a 50 bps bound). The dollar figure assumes bond value holds through the window (§7). The structural point stands regardless of the exact numbers: routine, structurally-bounded flow is cheap to cover, and TVL scales past staked WOOD because only genuinely open-ended risk consumes the budget at par.

The tier bounds are only as sound as the valuation the guard checks against, so tier-0/1 eligibility requires a valuation the executing transaction cannot move (TWAP or an external oracle, never the spot reserves of a pool the adapter itself trades into). The guard also asserts the adapter target's `EXTCODEHASH` against the certified hash (a mismatch reverts and auto-demotes the selector to tier 2), and reverts on stale oracles, paused targets, or valuation divergence beyond a generous multiple of the certified bound. Upgradeable targets and adapters with mid-call external callbacks are ineligible for tiers 0 and 1 as a listing predicate. An adapter for which no manipulation-resistant valuation exists is tier 2 by definition.

### 5.3 The aggregate exposure cap

R2 is enforced as a guardian-level invariant checked at approval time:

```
Σ maxExtractable(guardian's open approvals)  ≤  k · slashableBond(guardian)
```

"Open" means the challenge window has not yet expired. For tier-2 exposure, k = 1: hard infeasibility exactly where rugs live. Tier-0/1 approvals consume cap by their certified extractable bound, not notional, so routine flow costs little.

There are deliberately no per-proposal earmark locks. The cap nets across time: the same stake covers sequential proposals across many vaults, and only *simultaneous* over-exposure is blocked. Simultaneous over-exposure is precisely the batching attack, in which a coalition approves N drains inside one window hoping to lose one bond N times over. A guardian's withdrawable stake excludes their open exposure, and the unstake delay covers the longest open challenge window, so exiting ahead of liability is not possible.

### 5.4 The challenge game

R1 needs a mechanism that can look at an *executed* proposal and impose liability. Each execution opens a post-execution challenge window (14 days for tier 2, 7 for tiers 0/1; the shorter window recycles coverage faster). During it, anyone may post a bonded challenge citing one of five objective violation predicates, each checkable from public calldata and the execution trace:

1. Net outflow to addresses outside the whitelisted adapter set.
2. Execution price deviation beyond the certified bound, measured against a manipulation-resistant oracle at the execution block.
3. Outflow destination linkable to the proposer (a funding-graph predicate).
4. Token allowance or ownership granted to a non-protocol address.
5. Aggregate rolling drawdown: cumulative realized loss for a (vault, proposer, guardian-set) tuple over a trailing 30-day window exceeding an aggregate bound.

Predicate 5 exists because a patient attacker would otherwise slice a drain into many proposals, each within its individual envelope. The aggregate bound is challengeable independently of any single proposal, and it is complemented by a per-epoch cumulative outflow cap per vault.

An undisputed challenge auto-executes the slash after a delay. If the accused post a counter-bond, the case escalates to adjudication (§5.5). A failed challenge forfeits the challenger's bond to the accused. A filed challenge freezes only the accused guardians' coverage attributed to that specific proposal, never their whole stake, and the challenger's bond scales with the exposure it freezes; both properties exist to keep challenges from becoming a griefing weapon against honest guardians.

Whether anyone files is itself an economic question. A challenger posts bond b_c, pays forensic cost c_f to build the case, wins with probability p_win, and on success receives a share r of the slashed stake S (a carve-out; the bulk of proceeds goes to the drained vault):

```
EV(challenge) = p_win · r · S  −  (1 − p_win) · b_c  −  c_f
```

which is positive exactly when

```
p_win  >  (b_c + c_f) / (r · S + b_c)
```

For a clear-cut predicate violation p_win ≈ 1 and the condition is easy to satisfy. But r must be kept small (proceeds are victim compensation) and c_f is real forensic work, so for marginal cases the organic reward p_win · r · S can undershoot c_f, and a purely permissionless game would leave those cases unfiled. This is why the watchtower is funded protocol infrastructure rather than an assumption of altruism: Sherwood's own forensic agents run the predicate monitor continuously as a paid role, and a first-detector bounty sized to cover c_f keeps the door open for independent watchers. A healthy challenge game shows a low rate of filings, some of which fail. Total silence is itself an alarm condition on the monitoring dashboard.

### 5.5 The court

Disputed challenges are forensic questions: does this trace show funds routing to a proposer-linked address, or a legitimate trade that got sandwiched? A bare WOOD token vote is the wrong sole judge for such questions twice over. Dispersed token voters do not read execution traces, so low-turnout votes decide on narrative rather than evidence. And an attacker who has just drained a vault could spend part of the proceeds acquiring WOOD to vote their own case innocent. A standalone expert panel fails differently: a handful of trusted humans, capturable by bribing a majority, with nothing above them.

The court therefore has two layers that cover each other's failure mode. A small adjudication panel (five members, elected by WOOD governance, each posting a slashable bond) hears disputes first and rules on the evidence within days. Any panel ruling is appealable to the full WOOD token vote within a 7-day window, and the token vote is sovereign: it can overturn anything. The binding incentive is that panel members who signed a ruling the appeal overturns lose their bonds, so the only ruling that reliably survives is the one the public evidence supports.

Voting power for any dispute, at both layers, is snapshotted from stake held *before the challenged proposal's execution block*. Drain proceeds cannot finance an acquittal, and flash-loaned WOOD cannot vote. An attacker must therefore corrupt a panel majority, and win a public appeal, against an electorate frozen before the exploit: three independent barriers rather than one buyable poll.

A guilty verdict slashes the convicted approvers at the maximum severity, with proceeds routed to the drained vault. Ground truth has been established at that point; there is no severity ramp to argue about.

### 5.6 Adapter listing

Adapters are born tier 2: deploying and registering one requires no permission, at the price of full-notional coverage. Claiming a lower tier is a bonded act. The submitter posts the runtime guards, a certified extractable bound per selector, the valuation method, and a bond underwriting the claim itself. Liability then layers: guardians underwrite losses up to the certified bound; loss beyond it, meaning the guard was bypassed, slashes the submitter's bond first and a protocol insurance backstop second. Guardians can price tier-0 approvals sanely because they are not silently underwriting the correctness of someone else's guard code. Demotion is instant and permissionless on a passed challenge.

### 5.7 Delegated stake

The coverage arithmetic above is only as deep as the bonds behind it, and most WOOD holders cannot operate simulation infrastructure. Delegation lets them back guardians who can: `StakedWoodDelegation.delegateStake` deposits WOOD into a guardian's pool against ERC-4626-style shares, and the guardian's review weight becomes own stake plus delegated inbound. Two rules shape that weight (`StakedWood.getPastVotes`):

```
agedOwn = rawOwn · ageFactor / 10⁴     ageFactor ramps linearly from ageFloorBps
                                       (2500) at stake time to 10⁴ at
                                       maturationPeriod (30 days), then plateaus
weight  = agedOwn + min(delegatedInbound, capX · agedOwn)          capX = 4
```

Both weight and slash exposure are read from checkpoints at review open (`getPastVotes(g, openedAt)`, `getPastDelegatedInbound(g, openedAt)`): delegation moved after a review opens carries no weight in it and cannot enlarge what that review slashes.

Delegation opens two attacks the design closes explicitly.

**Sybil amplification.** Direct self-delegation reverts (`CannotSelfDelegate`), but nothing stops a guardian staking the minimum from wallet A and delegating the rest from wallet B. If delegated stake were merely slashed at a capped rate, that would be a strict win (Livepeer's documented LIP-10 vector): full vote weight, capped exposure. Two mechanisms close it. The weight cap's base is *aged own* stake, so routed capital buys at most 4× the weight of the sybil's honest bond, and not instantly. And the slash spill, below, charges exactly the exposure the cap sheltered back onto the guardian's own stake.

**Slash socialization.** Symmetrically, a guardian must not be able to gamble mostly with delegators' money. A slash executes in three legs (`StakedWood._slashOne`, severity S, delegated cap C = `maxDelegatedSlashBps` = 2000):

```
ownSlash  = min(snapOwnRaw, live) · S / 10⁴          raw at-open own checkpoint
poolSlash = snapDelegated · min(S, C) / 10⁴          live pool first, remainder
                                                     to the unbonding pool
spill     = snapDelegated · (S − min(S, C)) / 10⁴    charged to the guardian's
                                                     remaining own stake, clamped
```

A delegator's worst case per incident is C = 20% of their position, whatever the severity; the sheltered remainder lands on the guardian's own bond first (the Rocket Pool operator-bond pattern). The own leg is sized on the raw checkpoint: age discounts voting power, not liability. Exit does not dodge any of this: `requestUnstakeDelegation` moves the whole position into a slashable unbonding escrow for the full cooldown, where the slash budget spills once the live pool is exhausted, and unbonding stake has no vote weight. The spill is deliberately sized on at-open exposure with a zero-snapshot floor, so a third party cannot inflate a doomed guardian's own-bond loss by delegating to them after the review opened.

Self-delegation is therefore neutral until the bond is dead. A sybil with own stake O and routed stake X faces, at severity S, loss O·S/10⁴ from the own leg, X·min(S,C)/10⁴ from the pools, and the sheltered X·(S−C)/10⁴ charged to whatever remains of O. Until O is exhausted the coalition loses (O+X)·S/10⁴, exactly what honest staking would have cost; a discount appears only where the spill overflows a fully wiped bond, which is bounded, prices in the guardian's deregistration, and leaves X stranded in the slashable escrow on the way out.

The delegator's side is a priced bet on a guardian's judgment. With commission κ ≤ 50% (raises rate-limited to 500 bps per epoch, cumulative, and checkpointed so earned rewards cannot be retroactively re-priced) and position D:

```
EV(delegate to g) = (1 − κ_g) · f_D  −  p_slash(g) · C · D
```

where f_D is the delegator's share of g's guardian fees and p_slash(g) is g's slash rate. The cap keeps passive capital's downside bounded per incident while the guardian's own bond dies first, which is where the selection pressure belongs.

One accounting note for §4: because delegated stake is slashable only at C per incident, with the excess charged to the own bond, the recovery the coalition bound can rely on with certainty is the own bond plus at most C of at-open delegated exposure. The economic-security specification does not fix whether `slashableBond(g)` in the aggregate exposure cap counts delegated stake at a C haircut or not at all; the conservative reading is own bond only, and the haircut is an open parameter.

## 6. Worked example

A vault holds $2,000,000. A proposer submits a tier-2 proposal (arbitrary calldata) with `maxCapital` of $500,000, and assembles a coalition controlling enough guardian stake to approve it.

Under the aggregate exposure cap with k = 1, the approving guardians must jointly have at least $500,000 of unencumbered slashable stake at approval time, or the approval is rejected. The custody-layer outflow meter caps the drain at $500,000. If the coalition executes the drain, any watchtower can file predicate 1 or 3 within the 14-day window; the coalition's $500,000 of stake, which cannot be withdrawn during that window, is slashed on conviction and routed back to the vault.

In the notation of §4: n = 1, E_1 = $500,000, V_1 ≤ E_1 by the custody meter, Σ B_g ≥ E_1 by the cap with k = 1, and the full attributed exposure is slashed on conviction, so Π ≤ E_1 − E_1 − bribes − gas < 0. Best case for the coalition: gain $500,000, lose $500,000 of stake, and pay the bribes and gas that assembled it. Doubling the attack by approving a second $500,000 drain in the same window requires a second $500,000 of stake, because both exposures are open simultaneously; the batching route is closed by construction. The remaining $1,500,000 of vault TVL was never reachable, and to the extent it sits in tier-0 positions, it consumed only basis points of anyone's coverage.

## 7. Implementation status and phasing

The mechanism described in this paper ships in phases, and it is important to be precise about which parts are on-chain today.

The review lifecycle of §2 is implemented in the deployed contracts: staking and delegation in `StakedWood`, optimistic passage and settlement in `SyndicateGovernor`, and the review window, block quorum, deterministic severity slashing, and fee attribution in `GuardianRegistry`. The economic-security components of §4–§5 (risk envelopes, adapter tiers and runtime guards, the aggregate exposure cap, the challenge game, and the court) are specified in the protocol's economic-security design document and roll out in sequence: execution-side safety first (envelopes, custody outflow metering, and tier guards with the manipulation-resistant-valuation, codehash, and oracle-health checks), then the aggregate exposure cap, then the challenge game and the two-layer court. Until the later phases are live, the coalition profit bound of §4 is the property the system is being built to enforce, not one the deployed contracts already enforce.

Early phases carry deliberate simplifications. Tiers for the initial, small adapter set are assigned directly by governance rather than through the permissionless probation pipeline; the submitter bond and its slash-first liability layering apply from day one, so a mis-certified bound is backstopped, but the certification itself is a governance judgment during this period. The watchtower is initially operated by the protocol: Sherwood's forensic agents run the predicate monitor as a funded role, with the first-detector bounty open to independent watchers, and challenge-game silence is treated as an explicit alarm. The permissionless probation pipeline, threshold-calibrated auto-demotion circuit breakers, multi-collateral guardian bonds, and per-risk-class k values follow in a later phase, because their thresholds need live traffic distributions to calibrate without creating denial-of-service levers.

Three standing dependencies are worth naming. Oracles are load-bearing: tier-0/1 guards, the price-deviation predicate, and settlement PnL all require manipulation-resistant valuations, and an adapter without one is priced at tier 2, permanently. The security budget is WOOD-denominated until multi-collateral bonds ship, so a token-price drawdown compresses underwriting capacity; the throughput figures in §5.2 assume bond value holds through the window. And challenge-bond sizing is a live calibration between griefing resistance and challenge accessibility that will be tuned against real challenge flow. Separately, the review cohort floor (50,000 WOOD) means a review cannot block while the guardian set is below it; this is a cold-start fallback, not a steady-state property.

All parameters quoted in this paper (block quorum 3000 bps, slash bounds 1000–10000 bps, the delegated-slash cap of 2000 bps, the 2500 bps age floor over a 30-day maturation, the 4× delegated-weight cap, k = 1, challenge windows of 7 and 14 days, the 7-day appeal window, the 30-day drawdown window) are initial values subject to governance. Every new accounting path added by the rollout carries a stated invariant and a fuzz test before merge.

## 8. Closing

Sherwood sells security agents. A protocol whose product is adversarial review of other people's code has exactly one credible way to review its own: assume its reviewers can be bought, and design so that buying them does not pay.

That is the standard the guardian network is built to. The review window filters proposals before execution, with a deterministic penalty for approving what your peers block. The economic-security layer binds the path that review windows alone cannot reach, through two mechanical facts: nothing leaves a vault beyond its certified extractable value, and that value is never larger than the stake that answers for it. The people who approve a drain are the people who pay for it, at 1:1, after the fact, under a court their victims can appeal to.

Guardians who do the work remain the point of the system. The economics exist so that nothing depends on them.

---

*References. Deployed contracts: `GuardianRegistry.sol` (`voteOnProposal`, `resolveReview`, `_severityBps`, `getApproverWeights`), `StakedWood.sol` (`getPastVotes`, `slashGuardians`/`_slashOne`), `StakedWoodDelegation.sol` (`delegateStake`, `requestUnstakeDelegation`, `setCommission`), `SyndicateGovernor.sol` (`_resolveStateView`, `_finishSettlement`); parameter values for these are deployment defaults and are governance-adjustable. The delegated-slash cap, first-loss spill, and age-weighted voting design is `docs/superpowers/specs/2026-07-19-slash-cap-age-weighted-voting-design.md`. Risk envelopes, adapter tiering, the aggregate exposure cap, the challenge game, and the adjudication court are specified in `docs/superpowers/specs/2026-07-22-guardian-economic-security-design.md`; §7 describes their rollout phasing.*
