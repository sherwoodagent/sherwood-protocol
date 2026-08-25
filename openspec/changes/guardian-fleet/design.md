## Context

The guardian daemon is written as a single process that watches for opened reviews and votes. Running
the guardian layer in production means running several of them, and every guardian is operated by the
same party — there is no third-party cohort now and none is planned. That single fact changes which
arguments apply.

## Goals / Non-Goals

**Goals**

- The guardian layer is live: reviews open promptly and resolve on time, without a human.
- One guardian's failure — crash, drained gas, leaked key — does not silence the layer.
- The operator can tell, at a glance, whether the layer could still block something right now.

**Non-Goals**

- Third-party guardians. Nothing here assumes strangers, and the shared-evidence decision below
  would have to be revisited if that changed.
- The depth of any individual review. That is `guardian-review-depth`.
- Increasing blocking power. M cannot do that; see Decision 1.

## Decisions

### Decision 1 — M is set by uptime, not by economics

Recording what M does and does not buy, because three of the intuitive reasons are wrong:

| | Does M > 1 help? |
|---|---|
| Blocking power | **No.** `_isBlocked` compares block weight against `blockQuorumBpsAtOpen × totalStakeAtOpen`; M addresses sum to the same weight. Only the operator's share of total staked WOOD moves this |
| Capital or coverage | **No.** Same bond, sliced finer |
| Availability | **Yes** — and this is the reason |
| Key blast radius | **Yes.** One leaked key costs one bond |
| Graded slash exposure | **Yes, if policies differ.** Only approvers are slashed |
| Decentralisation | **No.** One operator. Documentation should say operator-run cohort |

The availability argument is worth stating precisely, because it is a systems argument. Two
hot-standby processes sharing one guardian key build transactions at the same nonce; one loses to
replacement-underpriced or silently drops. Avoiding that needs leader election or a nonce lease. M
distinct identities on M distinct EOAs share no mutable on-chain state and are independent by
construction. **M > 1 is how availability is bought without building a consensus layer.**

### Decision 2 — Keeper and voter are separate roles

A keeper holds gas and no stake. It discovers work from `ReviewRegistered`, calls `openReview` once
`voteEnd` passes and `resolveReview` once `reviewEnd` passes, and signs nothing else. A voter holds
stake and signs only `voteOnProposal`.

*Why separate:* the two roles have opposite risk profiles. A keeper cannot be slashed, so it can be
run redundantly and cheaply and its only failure mode is missed liveness. A voter carries the bond.
Collapsing them means every redundant instance is also a staked instance.

*Why this is urgent rather than tidy:* `openReview` and `resolveReview` already exist in
`src/signer.ts` and are never reachable, so today nothing opens reviews at all. The guardian layer is
inert by default — `SyndicateGovernor`'s mutating `_resolveState` resolves an unopened review inline
as not blocked and executes, and the CLI documents this as the cold-start norm.

*Liveness budget:* a cohort's usable voting time is `reviewEnd − openedAt` minus the late-vote
lockout. Opening at `voteEnd + ε` gives the cohort the whole window; opening late silences it
structurally with no attacker involved. The keeper's promptness is therefore a security parameter,
not an operational nicety.

### Decision 3 — Keepers race, and that is fine

Both entrypoints are permissionless and idempotent: `openReview` returns early when already opened
and `resolveReview` returns the cached result. So N−1 racers pay gas for a *successful no-op* rather
than reverting, and the slash lands exactly once.

Redundant keepers with randomized jitter therefore need no coordination. `signer.ts` already
pre-checks `opened` and `resolved` before sending, which narrows the race to roughly one poll
interval without closing it — and closing it is not worth a lock.

*Trade-off accepted:* a small, bounded gas waste in exchange for no leader election. Sized against
the alternative — a missed `openReview` silences the entire cohort for that proposal — it is cheap.

### Decision 4 — One simulation, many policies

A single review pipeline simulates each proposal once and publishes an evidence record: risk
findings, simulation outcome, invariant measurements, coverage inputs. It holds no key. Each guardian
reads that record and applies its own policy — drawdown bound, posture, whether a model is consulted,
per-proposal coverage ceiling — and signs with its own key.

*Why not simulate per guardian:* running identical code M times is replication, not diversification.
Same inputs and same analyzer produce the same verdict, so M simulations decorrelate only transient
infrastructure failures. And because one party owns every bond, a correlated slash costs the same as
slashing one guardian that held the whole position. There is no economic payoff to buy.

*What diversity is still worth having:* policy divergence is genuine position sizing. If two of five
guardians approve a proposal that later blocks, only those two bonds are exposed. That is cheap,
deterministic, and unit-testable — unlike simulation diversity, which is expensive and identical
anyway.

A worked composition, all reading one evidence record:

| | Drawdown bound | Posture | Model |
|---|---|---|---|
| g1 | — | `defend` | on |
| g2 | tight | `autonomous` | on |
| g3 | loose | `autonomous` | off |
| g4 | — | `defend` | off |

The two `defend` guardians carry no slash exposure at all, so the veto stays live even when every
underwriter abstains on capacity.

*Revisit if third parties ever run guardians.* Shared evidence across independent operators would
reintroduce correlation between bonds that are not all yours, and the argument above would no longer
hold.

### Decision 5 — Health is blockable capacity, not liveness

Per-instance health answers "is guardian 3 up". The operator's real question is whether the layer
could still block something, which is a fleet-level quantity: the summed weight of guardians with a
fresh heartbeat *and* a funded gas balance, against `blockQuorumBps × totalStake`.

Gas belongs inside the signal because a guardian with an empty balance is silently non-voting and
presents exactly like a healthy one that saw nothing.

Weight is read with the same growth gate the registry applies, so the number means what the contract
would compute rather than what the operator hopes.

### Decision 6 — Fleet composition is fixed before staking

`FLOOR_LOOKBACK` is 30 days, and `_growthGatedVoteWeight` clamps a voter to
`min(stake_now, stake_30d_ago)` whenever its raw stake grew. Rebalancing between the operator's own
guardians is therefore asymmetric: the source loses weight immediately, the destination stays clamped
to its pre-transfer value for a full lookback, and net fleet weight drops by the moved amount for 30
days.

Splitting one guardian into M is precisely this operation. **Choose M and the per-guardian
allocation before staking**; revising it costs 30 days of blocking weight.

## Risks / Trade-offs

- **Correlated verdicts by construction.** Accepted deliberately under Decision 4, and load-bearing
  on the single-operator assumption. It is the first thing to revisit if that assumption changes.
- **A shared pipeline is a shared point of failure.** It holds no key, so its failure costs liveness
  rather than stake — but it does silence every guardian at once. It needs the same heartbeat
  treatment as the daemons.
- **Keeper gas waste.** Bounded and intentional; see Decision 3.
- **M keys across M Railway services.** More surface to manage than one service with M keys, and
  chosen for exactly that reason: one compromise costs one bond.
- **Operator-run cohort is not a decentralised one.** Documentation must not imply otherwise.

## Open Questions

- What is M? Decision 1 says it follows from an uptime target, which has not been stated.
- What share of total staked WOOD will the operator hold? That number, not M, decides whether the
  cohort can block at all.
- Does the keeper open reviews for every governor it sees, or only for vaults on a configured list?
  Every governor is the safer default and the more expensive one.
- Should the pipeline cast the fleet's own votes inside the fork to measure the block outcome before
  any real vote is signed?
