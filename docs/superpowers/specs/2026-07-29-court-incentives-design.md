# Court incentives — making filing rational, voting honest, and the fallback real

**Date:** 2026-07-29
**Status:** Approved design
**Amends:** `2026-07-28-token-court-design.md` (§1's capture-economics claim is corrected here)
**Motivated by:** the adversarial review of PR #52 (findings M1–M4, A1–A5, B1–B4)

## 1. What this fixes, and what it deliberately does not

PR #52 delivered a working single-layer WOOD-vote court. An adversarial review found the code sound and the *mechanism* underpowered in three specific ways, all tracing to one root: **nobody is paid to make the system work, and nobody pays for getting it wrong.**

| Finding | Problem | This spec |
|---|---|---|
| A4 / F7 | A correct, unanswered challenge **loses money** (−20% of bond). The only profitable branch is one the court struggles to reach. | Conviction bounty |
| B4 | `vote` reads a historical checkpoint and never checks present holdings. A fully exited holder votes at 25% of historic weight forever. | Present-holdings gate |
| M3 | "Inconclusive is survivable because the proposal is re-challengeable" is arithmetically false past day 2, and the accused controls the clock. | Re-challenge window extension |
| M2 | Voters are paid nothing, so abstention dominates and `Inconclusive` is the default outcome. | Off-chain majority-side APY |
| **M1** | **The accused outbids the challenger ~20:1 for a jury with nothing at risk.** | **ACCEPTED RISK — see §6** |

Explicitly NOT in scope, by decision (2026-07-29): vote locking, voter slashing, per-case voter bonds, burn-sink redirection, any reward machinery inside `TokenCourt`. The court keeps its zero-custody property.

## 2. Conviction bounty (on-chain)

A slice of what a conviction actually recovers, paid to the challenger who caused it.

```solidity
uint256 public convictionBountyBps = 500;          // bounded [0, 2_000]
// pinned per challenge at filing, like every other rate
uint256 convictionBountyBpsAtFiling;
bountyWood = slashedWood * c.convictionBountyBpsAtFiling / 10_000;
```

Rules:

- **Paid ONLY on the escalated conviction** — a `Guilty` ruling from the court after the accused actually contested. **Never on the silence settle.** See "why not the silence path" below; this is the decision the whole design turns on.
- Paid **only when `slashedWood > 0`**. A filing that recovers nothing pays nothing.
- Deducted **before** `slashToEscrow` books the case, so the escrow's `proceeds` reflect what claimants actually receive. No accounting fiction.
- **Not** paid on the `_convicted` short-circuit — a second challenge against an already-convicted proposal collects nothing.
- `settleBurnBps` is **unchanged**. It remains the only price on the free-slash attack.

### The approver-membership gate on `contested` (added post-spec, PR review 2026-07-29)

The bounty is gated on `contested`, not merely on `status == Disputed`
completing: an escalated `Guilty` ruling only pays the bounty when at least
one funder of the counter-bond pool is a member of the accused set (the
ledger's approvers for that exact proposal).

Reason: `dispute` is open to anyone (#50's pull-payment counter-bond has no
membership check on who may fund it), so a challenger could stage a contest
from a second address it controls, recover its own pool on a `Guilty` ruling,
and collect the bounty for a fight nobody had. "Was the funder the
challenger?" is unanswerable — addresses are free, and a same-wallet check is
defeated by a second one. "Was the funder one of the accused?" is answerable:
joining the accused set for a proposal means staking WOOD and recording an
approval on the very proposal you are about to accuse — joining the cohort
your own conviction slashes. That turns an unenforceable identity predicate
into a verifiable role predicate.

**Accepted false negative:** a genuine third party who funds a defence
because it believes the accused innocent still forces adjudication —
`dispute`'s open standing is untouched — but a `Guilty` ruling it provoked
pays the challenger no bounty. The gate narrows only what *earns* the bounty,
never what is allowed to happen.

**Why this gate is load-bearing, not tidiness:** it is what keeps the bounty
from widening M1 (§6) into a *profitable prosecution* attack. Pre-gate, a
captured jury convicting an innocent accused paid the attacker 5% of the
slash on top of the conviction itself — profitable even with no underlying
drain to recover. Post-gate, collecting that bounty requires the attacker to
route the contest through the accused set, which it cannot do without
joining the very cohort being slashed. §6's accepted risk stays acquittal
capture only — buying a jury to acquit a real drain — not conviction-for-
profit against an innocent guardian.

### Why not the silence path (decision 2026-07-29)

On the silence path an honest filer and a liar are **indistinguishable to the contract**:

| | Honest filer | Liar |
|---|---|---|
| Accusation | true | false |
| Accused response | none (guilty, or asleep) | none (asleep) |
| Contract observes | silence | silence |
| Payout | −burn + bounty | −burn + bounty |

Any bounty that rewards one rewards the other by exactly the same amount, so **no bounty size works there**. The two constraints are literally contradictory: making honest filing profitable needs `bounty >= settleBurnBps * bond`, and keeping false filing unprofitable needs `bounty < settleBurnBps * bond`.

The escalated path does not have this problem, because the accused fought back and lost on the merits. A liar who picks a guardian that is actually paying attention gets contested, loses on a `NotGuilty` ruling, and forfeits the **entire** bond. That branch separates the two filer types, so the bounty is safe there at any size — which is why no anti-abuse bound is needed and `convictionBountyBps` can be generous.

### Payoffs (coverage $1M, bond 5% = $50k, bounty 500 bps)

| Outcome | Today | With bounty |
|---|---|---|
| Correct, unanswered | −$10k | **−$10k (unchanged, by decision)** |
| Disputed → Guilty | +$50k | **+$100k** |
| Disputed → NotGuilty | −$50k | −$50k |
| Disputed → Inconclusive | 0 | **0 (round 1), then −$2.5k / −$5k / −$10k** (rounds 2/3/4+, escalating burn, §8) |

### Accepted costs

**The silence path stays unprofitable for honest filers.** If genuinely guilty guardians tend to stay quiet rather than burn a counter-bond defending the indefensible, real convictions may mostly arrive that way — and those filers are still not paid. This is the deliberate half of the trade: the cheap branch is also the abusable one, and the only branch where being wrong costs nothing but gas. **Trigger to revisit:** instrument the ratio of convictions arriving via silence versus escalation; if honest filers are systematically underpaid because escalation is rare, the silence path needs a reward that does not also pay liars (delayed/claimable, or conditioned on something the contract can actually distinguish).

**Depositors recover 95% of an escalated slash instead of 100%.** That is the price of anyone outside the affected vault watching at all. Sherwood is a security-agent platform; third-party watchdogs are the intended filers, and they hold no vault shares to recover through. **Burn-fallback exception:** this 95% figure assumes `openCase` succeeds. If the named vault turns out to be unpriceable and `openCase` reverts, the NET remainder burns instead of funding a case (`VerdictSlashUncompensated`) and depositors recover 0%, not 95% — the bounty is still paid on that path (implementation decision, 2026-07-29 review), because depositors were never going to see that WOOD either way, so paying the prosecutor first costs them nothing.

## 3. Present-holdings gate (on-chain)

One line in `TokenCourt.vote`, beside the existing snapshot read:

```solidity
uint256 weight = IStakedWood(stakedWood).getPastVotes(msg.sender, c.snapshotTs);
if (weight == 0) revert NoVotingPower();
if (IStakedWood(stakedWood).getVotes(msg.sender) == 0) revert NoVotingPower();
```

**Historical weight still decides how much a vote counts** — that is the flash-loan and post-hoc-accumulation defence (D2), unchanged. The new check decides only **whether you may vote at all**.

Binary gate, deliberately not a second weighting: re-weighting on present holdings would reintroduce exactly the accumulation vector the snapshot exists to close.

What it deletes: `claimUnstakeGuardian` deletes the guardian record, so `stakedAt == 0`, so `_ageFactorBps` returns `ageFloorBps` (2,500) while the raw checkpoint at `snapshotTs` survives the exit. Today that lets an attacker pre-position stake, execute the drain, request unstake, vote to acquit at 25% weight, and claim out — voting capital liquid before the verdict lands, alignment exactly zero. The gate closes that path and costs an honest staker nothing.

It also makes the premise "voters are WOOD holders" **enforced** rather than assumed, which is what §4's incentive argument rests on.

## 4. Off-chain majority-side APY (policy, not code)

sWOOD stakers earn a participation yield, computed off-chain from events the court already emits — `VoteCast(caseId, voter, guilty, weight)` and `CaseFinalized(caseId, verdict, guiltyVotes, notGuiltyVotes, floor)`. **No contract change is required.**

Chosen over on-chain rewards because no affordable pot deters capture anyway (§6), so paying for one with contract complexity, redirected burn sinks, or victim compensation is a bad trade. Off-chain it is tunable live, verdict-neutral by construction, and touches no value flow.

### The rule

**Pay only voters on the majority side of a RESOLVED case.** Not for participation.

This distinction is load-bearing. Paying for mere participation manufactures turnout without judgment: voters show up to farm yield, click whichever way is cheapest to decide, and **clear the participation floor with noise**. The court then renders real verdicts — 100% slashes, no appeal — backed by people who read nothing. That converts a *safe* failure (Inconclusive: no verdict, no slash, nobody harmed) into an *unsafe* one, while looking like success.

Majority-side conditioning makes coin-flipping lose the reward roughly half the time, so the yield-optimal strategy becomes working out the honest answer. It is the same soft opportunity cost vote-locking would impose, at a fraction of the strength and none of the build cost.

### Fixed rules, published before the first case

1. **`Inconclusive` pays nobody** — there is no majority to be on, and this removes any incentive to deliberately undershoot the floor.
2. **Weight-proportional, not per-address** — splitting stake across addresses must not multiply yield.
3. **Pre-committed and public.** A discretionary reward is a lever on the vote; a published rule is not.

### Accepted cost

An honest voter in a genuinely close case forgoes yield. Gentler than slashing — foregone reward, not lost principal.

## 5. Re-challenge window (on-chain)

`file` today gates on `block.timestamp > executedAt + challengeWindow`. Reaching `Inconclusive` takes at least `filedAt + autoSlashDelay + voteWindow` = **filedAt + 12 days** at defaults, and the accused chooses when the pool completes. So a re-filing is possible only if the first challenge landed **within 2 days of execution** — and any realistic detection delay makes `Inconclusive` a final, unappealable acquittal the accused can force by stalling.

Fix: store a per-`reviewKey` deadline and extend it on the inconclusive unwind.

```solidity
mapping(bytes32 reviewKey => uint256) public challengeableUntil;
// in _refundAll:
uint256 extended = block.timestamp + challengeWindow;
uint256 current = challengeableUntil[key];
challengeableUntil[key] = extended > current ? extended : current;
```

`file` reads `challengeableUntil[key]`, falling back to `executedAt + challengeWindow` when unset. Stalling the pool to force `Inconclusive` now buys the accused a delay instead of an acquittal, and the spec's re-challengeability claim becomes true.

### Lock-time reductions (owner decision, 2026-07-29)

Two ceilings were cut after review found the worst-case coverage-freeze pin
too long relative to what the token court's real clocks need:

- **`MAX_DISPUTE_TIMEOUT`: 180 days → 60 days.** The old figure was 6x the
  30-day default with nothing arguing for the headroom. At the `voteWindow`
  ceiling the cross-contract window invariant (§5 above,
  `autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout`) needs 15
  days of runway, so 60 still permits `autoSlashDelay` up to 45 days against
  a 7-day default.
- **`setChallengeWindow`'s ceiling: the `90 days` literal → read
  `exposureLedger.challengeWindow()` live** (14 days today). The old literal
  sat 6x above the constraint its own natspec named — a game window that far
  above the ledger's actual coverage window let a filing freeze exposure the
  ledger had already aged out of its epoch buckets. Reading it live also
  means the two can never drift apart again.
- **Worst-case single-challenge exit block: 270 days → 74 days**; unchanged
  at 44 days on defaults.

**What the freeze does and does not block** — earlier reviews got this wrong
twice: it blocks full exit (`claimUnstakeGuardian`) and early release of the
challenged commitment. It does **not** block approving new proposals
(`recordApproval` has no frozen check) and it does **not** stop exposure
buckets ageing out on wall-clock — the freeze pins the reviewed commitment,
not the guardian's whole book or the calendar.

**There is no system-wide maximum.** Concurrent challenges plus the M3
window extension above mean a determined attacker can contest a guardian's
exit indefinitely — every `Inconclusive` unwind re-extends
`challengeableUntil`, and a fresh filing can open a new challenge before the
previous freeze has fully cleared. Every round still ends with a gap in
which a matured claim succeeds, and the guardian keeps underwriting coverage
and earning throughout — the freeze blocks exit, not participation, and
never accumulates into a permanent lock.

## 6. ACCEPTED RISK — M1, jury capture

**Decision (2026-07-29): ship without vote locking. This risk is accepted, not solved.**

### The arithmetic

A voter loses nothing by voting wrong — no slash, no lockup, no forfeited principal — so their reservation price for selling a vote is epsilon.

Token-holder alignment does not close the gap, because harm is diffused while the bribe is concentrated. The accused must buy voters summing to the participation floor (10%), so a $1M bribe budget is worth **$10M per unit of share**. For alignment to win, one acquittal would have to destroy more than two-thirds of WOOD's market cap. A 1%-of-supply holder facing a generous 10% price hit loses ~$15k of bag value against a ~$100k share of the bribe — defection at nearly 7:1, faced independently by every voter.

This is empirical, not theoretical. UMA voters are UMA holders, aligned by exactly this argument; in March 2025 a whale with ~25% of voting power forced a false resolution on a $7M Polymarket market, and a May 2026 WSJ investigation found more than half of disputed-market votes coming from the ten largest wallets. UMA already slashes minority voters. This design does not.

### What the fixes in this spec actually buy

| Fix | Effect on M1 |
|---|---|
| Conviction bounty | Challenger can bid ~$100k instead of ~$50k — **10:1 instead of 20:1** |
| Present-holdings gate | Removes the *cheapest* attack (exit and vote anyway), not the only one |
| Off-chain APY | Buys turnout. A bought voter collects the yield **and** the bribe |

None make buying a vote expensive. Only putting the voter's own capital at risk does that.

### What this means in practice

A well-capitalized attacker can: drain a vault, get challenged, post a **fully refundable** counter-bond, buy a jury with nothing at stake, and be acquitted — keeping the drain, their stake, and the challenger's forfeited bond.

**The honest framing, which replaces `2026-07-28-token-court-design.md` §1's claim that capture economics here are "better than UMA's":** the optimistic layer is the mechanism; the court is a backstop effective against unsophisticated adversaries — guardians who are asleep, careless, or unwilling to spend real money defending an indefensible proposal. That is most guardians most of the time. It is not a determined attacker.

Specifically, §1's three "properties UMA lacks" need correcting: property 2 ("voters hold no position in the outcome") is what makes them **cheap to buy**, not a defence; property 1 (the snapshot) does not bind the accused, who is a pre-positioned whale by construction; property 3 (aged weight) has the unstated inverse fixed in §3.

### Trigger for revisiting

**Any case where the tally moves decisively in the final hour of the vote window.** That is what a bought vote looks like: no reason to reveal early, every reason to land where nobody can respond. One occurrence is the signal to implement vote locking (escrow a slice of the voter's already-staked WOOD, forfeited by the losing side — one storage mapping and a settle-time transfer, not a redesign).

## 7. Also open, documented not fixed

- **A1** — address splitting defeats `AccusedCannotVote`: `isAccused` covers the approving *address*, not the party, and the floor's accused-subtraction makes the siblings' quorum *smaller* as the accused cohort grows. Likely unfixable under permissionless staking; the natspec must stop claiming the bar covers a party.
- **A2** — last-mover advantage: public tallies + hard deadline + **tie acquits** means the acquitting side need only *match*, not exceed, in the final block. Mitigation short of commit-reveal is a vote-extension (any late vote pushes the deadline), deferred with §6's trigger.
- **A5 — confirmed on the real contract, not inferred (2026-07-29).**
  `getPastVotes` re-derives its age factor from the guardian's CURRENT
  mutable `stakedAt`, so a past-timestamp read is not a frozen historical
  value: any later action that re-anchors `stakedAt` floors that historic
  weight toward `ageFloorBps`. The drift is deflation-only (every writer
  moves `stakedAt` forward or to the zero sentinel; `cancelUnstakeGuardian`
  deliberately does not restore it), so weight can never be manufactured —
  D2 holds. Two consequences: a guardian who tops up before voting in a live
  case votes at LESS weight than one who votes first, then tops up ("vote
  first, then top up" is load-bearing operational advice); and a guardian
  who cancels an unstake to regain the vote returns at `ageFloorBps`, not
  their matured weight, because the unstake request already re-anchored
  `stakedAt` before the cancel.

## 8. Parameters and testing

New: `convictionBountyBps = 500`, bounded `[0, 2_000]`, pinned per challenge, zero legal (bounty off).

**No anti-abuse pre-flight is required.** The escalated-only rule of §2 removes the attack a bound would have guarded against: a liar cannot reach the bounty without first surviving a contested vote, and being contested costs them the whole bond.

**New: the Inconclusive burn escalates per proposal, not per challenger.** `_refundAll` now increments `mapping(bytes32 reviewKey => uint256) public inconclusiveRounds`, alongside the existing `challengeableUntil` re-arm, whenever a non-convicted proposal goes `Inconclusive`. `file()` reads the count and pins the resulting rate into `inconclusiveBurnBpsAtFiling` on the `Challenge` struct — pinned at filing exactly like every other rate, never retroactive:

```solidity
mapping(bytes32 reviewKey => uint256) public inconclusiveRounds;
uint256 inconclusiveBurnBpsAtFiling; // on Challenge, pinned in file()
```

Schedule: round 1 (first-ever attempt against a proposal) → **0 bps**, free — an honest one-shot filer whose vote merely missed quorum is not charged. Round 2 → **500 bps**. Round 3 → **1,000 bps**. Round 4 and beyond → **`inconclusiveBurnBps`** (repurposed: was a flat rate for every round, now specifically the round-4+ steady-state target; default 2,000 bps, matching `settleBurnBps`'s default — the ceiling this whole burn family (`settleBurnBps`/`forfeitBurnBps`/`inconclusiveBurnBps`) is built around: a non-verdict must never cost more than a verdict that recovered real value). `file()` resets `inconclusiveRounds[reviewKey]` to zero once `block.timestamp > challengeableUntil[reviewKey]` — the re-armed window lapsed with nobody refiling inside it, so the grind streak is over and a cold proposal does not punish a later, unrelated filer. Keyed on `reviewKey` alone, not `(reviewKey, challenger)` — the same tradeoff `_convicted` and `challengeableUntil` already make, since per-challenger keying lets a sybil reset the escalation by switching addresses between rounds.

`inconclusiveBurnBps` stays cross-checked against `settleBurnBps` in both directions via `setInconclusiveBurnBps`/`setSettleBurnBps` (unchanged mechanism from a prior review round). **That check only covers the round-4+ tier — the round 2/3 flat steps (500/1,000 bps) are not bounded by it.** So `setSettleBurnBps` can now legally be lowered to a value below 500 or 1,000. Reverting `file()` over that interaction is unacceptable — filing must never fail for a parameter reason — so `file()` additionally clamps: whatever the schedule's raw target is for the round in question, the pinned rate is `min(raw, live settleBurnBps)`. This is a new invariant, not previously documented: the clamp never reverts, it silently prices the round at the live ceiling instead.

Tests:

- Bounty paid on the escalated `Guilty` ruling ONLY — not on the silence settle, not on `_fail`, not on `_refundAll`, not on the `_convicted` short-circuit.
- Escrow `proceeds` net of the bounty; claimants receive exactly the reduced amount.
- Bounty pinned at filing — moving `convictionBountyBps` mid-challenge does not move the payout.
- Exited holder refused; current holder with historical weight accepted; holder with present stake but no snapshot weight still refused.
- Inconclusive → re-file succeeds at day 20 (fails today); the extension only ever lengthens.
- Inconclusive-round escalation: round 1 pins 0 bps; round 2 pins 500; round 3 pins 1,000; round 4+ pins live `inconclusiveBurnBps`; a lapsed `challengeableUntil` resets the counter before the next `file()`.
- Round 2/3 clamp: `setSettleBurnBps` lowered below 500 (or 1,000) makes the corresponding round's `file()` pin `settleBurnBps`, not the schedule value, and does not revert.
- The mutation battery re-run over all of the above — a test that does not fail under the corresponding mutation does not count.
