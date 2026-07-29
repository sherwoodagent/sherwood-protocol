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

- Paid on **both** conviction paths — the silence settle and the escalated guilty ruling. The silence path is where the incentive is most broken today.
- Paid **only when `slashedWood > 0`**. A filing that recovers nothing pays nothing, so the bounty can never fund a bogus accusation on its own.
- Deducted **before** `slashToEscrow` books the case, so the escrow's `proceeds` reflect what claimants actually receive. No accounting fiction.
- **Not** paid on the `_convicted` short-circuit — a second challenge against an already-convicted proposal collects nothing.
- `settleBurnBps` is **unchanged**. It is the only price on the free-slash attack (a bogus unopposed filing against a well-covered guardian), and removing it to help honest challengers would reopen that attack. The bounty is what offsets the burn for filers who are right.

### Payoffs (coverage $1M, bond 5% = $50k, bounty 500 bps)

| Outcome | Today | With bounty |
|---|---|---|
| Correct, unanswered | −$10k | **+$40k** |
| Disputed → Guilty | +$50k | **+$100k** |
| Disputed → NotGuilty | −$50k | −$50k |
| Disputed → Inconclusive | 0 | 0 |

### The bound that must hold

The bounty must not make speculative filing profitable. A bogus unopposed filing still produces a real slash against a well-covered guardian, so it also collects a bounty. The burn must stay the larger number:

```
settleBurnBps * bond  >  expected bounty on a filing with no basis
```

Checked in `WireTokenCourt` as an explicit pre-flight rather than left to reasoning (§8).

### Accepted cost

Depositors recover 95% of a slash instead of 100%. That is the price of anyone outside the affected vault watching at all — and 95% of a conviction that happened beats 100% of one nobody filed. Sherwood is a security-agent platform; third-party watchdogs are the intended filers, and they hold no vault shares to recover through.

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
- **A5** — `_ageFactorBps` reads live `stakedAt`, so a voter who tops up mid-case silently drops toward the age floor; achievable turnout decays during the window.

## 8. Parameters and testing

New: `convictionBountyBps = 500`, bounded `[0, 2_000]`, pinned per challenge, zero legal (bounty off).

New pre-flight in `WireTokenCourt`: the speculative-filing bound of §2 — the burn must exceed the bounty on a baseless filing.

Tests:

- Bounty paid on both conviction paths, and nowhere else (not on `_fail`, not on `_refundAll`, not on the `_convicted` short-circuit).
- Escrow `proceeds` net of the bounty; claimants receive exactly the reduced amount.
- Bounty pinned at filing — moving `convictionBountyBps` mid-challenge does not move the payout.
- Exited holder refused; current holder with historical weight accepted; holder with present stake but no snapshot weight still refused.
- Inconclusive → re-file succeeds at day 20 (fails today); the extension only ever lengthens.
- The mutation battery re-run over all of the above — a test that does not fail under the corresponding mutation does not count.
