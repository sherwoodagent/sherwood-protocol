# ADR 2026-07-26 — Capped strategy duration replaces epoch chaining in v1

**Status:** accepted for v1. Supersedes §3.4a of
`2026-07-22-guardian-economic-security-design.md` for the v1 scope; §3.4a
remains the v2 target if long-duration strategies are ever required.

**Supersedes:** the 2026-07-23 decision "epoch-based renewable coverage".

---

## Context

§3.4a exists to solve one problem: predicate 5 (drawdown) needs realized PnL,
which for a long strategy only exists at settlement — potentially months after
the approving guardians' commitment expired and their stake recycled. Locking
stake to settlement was rejected as a non-starter ("no guardian locks a year per
approval; recycling is the capacity model").

Its answer was a chain of short covers: per-epoch NAV checkpointing, per-epoch
drawdown evaluation, claims-made attribution, renewal-or-wind-down, and (v2)
mid-epoch transfer. Guardian commitment stays bounded at one epoch + challenge
window regardless of strategy duration.

Two facts drove this reconsideration.

**One: four of the five mechanisms were never built.** `ExposureLedger`
implements the epoch-bucketed exposure budget and nothing else. There is no
`renewCoverage`, no NAV checkpoint, no forced wind-down, no claims-made
attribution. The status line records v1a as COMPLETE, and against Plan B's
stated scope it is — but the coverage chaining §3.4a was written to provide does
not exist.

**Two: the accounting does not reach settlement even for SHORT strategies.**
`recordApproval` books into `currentEpoch()` — the epoch containing the moment
the guardian voted. That bucket expires at `epochEnd + challengeWindow`. But the
risk window runs to `executeBy + strategyDuration + challengeWindow`. At
defaults the gap is roughly:

```
need coverage until   approval + executionWindow(7d) + duration + W(14d)
bucket expires at     approval + W(14d)              [worst case]
```

So a guardian's budget recycles well before the drain they backed can still be
challenged. This is not the long-strategy gap §3.4a describes; it is a
straightforward keying bug that affects every duration.

## Decision

**1. Strategy duration is capped by the PROTOCOL, not the vault.**

`maxStrategyDuration` moves to `ProtocolConfig` as a ceiling. Vaults keep their
own `maxStrategyDuration` but it is clamped by the protocol value — the same
shape already used for fees.

Rationale: today a vault owner may set `maxStrategyDuration` up to
`ABSOLUTE_MAX_STRATEGY_DURATION` (3650 days), while it is the GUARDIANS who
carry exposure for that period. The party bearing the risk does not currently
bound it. The ceiling belongs with the party that answers for it.

The initial value is deferred — the multisig sets it. The invariants below are
NOT deferred.

**2. Commitment covers the whole strategy, so no chaining is needed.**

With duration capped, a single commitment spans the entire risk window and
predicate 5 becomes enforceable without renewal. The chain of covers, the NAV
checkpoints, the wind-down rule and claims-made attribution are all unnecessary
at v1 scope.

Worst-case guardian commitment becomes:

```
reviewEnd + executionWindow + maxStrategyDuration + challengeWindow
```

This is LONGER than today's `epochLength + challengeWindow` (42d at defaults).
That is the point: today's figure is short because it does not reach settlement.
Correctness costs lock-up, and the cap is what bounds how much.

**3. Epochs stop being a mechanism and become bucket granularity.**

The commitment window is `executeBy + strategyDuration + challengeWindow` — a
property of the proposal, not of the calendar. `epochLength` no longer models a
"coverage epoch"; it is only the width of the accounting bucket, chosen so the
budget read stays bounded.

Consequences that fall out:
- Two identical approvals no longer cost 3x different budget-time depending on
  where in the month they land. The current asymmetry (14d if you vote late in
  an epoch, 42d if you vote early) is a pure artefact of calendar keying.
- `epochLength` remains a deploy-time constant. Deriving it live from
  `maxStrategyDuration + challengeWindow` would reindex every existing bucket
  whenever the protocol changed the cap, which is exactly why it is immutable.
  "Derived" here means "sized from D + W at deploy", not "recomputed".

## Implementation

**(a) Protocol duration ceiling — SHIPPED WITH THIS ADR.**

`ProtocolConfig.maxStrategyDuration` plus setter; `GovernorParameters` validates
vault params against it. `GovernorParameters` already reads `ProtocolConfig`, so
no new dependency.

**(b) Key the bucket to settlement — SHIPPED.**

Book into the bucket containing `executeBy + strategyDuration` instead of
`currentEpoch()`:

```solidity
uint256 coverUntil = view.executeBy + view.strategyDuration;
uint256 epoch      = (coverUntil - epochGenesis) / epochLength;
```

Expiry is then `bucketEnd + challengeWindow >= settlement + challengeWindow`,
which is the property missing today.

Three things this touches, and the reason it is sequenced separately rather than
rushed alongside the C1 fix and per-approver slashing:

  1. `ILedgerGovernorMinimal.ProposalViewLite` must carry `executeBy` and
     `strategyDuration`. Interface change, with `SyndicateGovernor` as the
     implementer.
  2. `openExposureUsd` currently sums BACKWARD from the current epoch. A
     forward-dated bucket would not be counted at all, so the loop must span
     both directions: from `(now - W)/L` to `(now + executionWindow + D)/L`.
     Bounded — roughly 4-5 buckets at D=30d, W=14d, L=28d — but it is a real
     change to the hot path.
  3. `testFuzz_exposureAccountingConserved` pins the current accounting
     invariant and will need to move with it.

**(c) Cross-parameter invariants must be enforced at every setter.**

Deferring the VALUES is fine. Deferring the INVARIANTS is not: a multisig
setting these independently, in an arbitrary order, will otherwise seat a
combination that is silently unsafe.

```
coolDownPeriod   >= longest commitment      (see (2) above)
challengeWindow  >= reviewPeriod + executionWindow
```

Known state: the cooldown invariant is asserted in three places (ledger
constructor, `setChallengeWindow`, `DeployPlanB` pre-flight). The
`challengeWindow` floor was added for review finding M1.
`GuardianRegistry.setReviewPeriod` does NOT check that it invalidates the
ledger's window — the registry has no handle on the ledger. That gap is open.

## Bucket width is now a dial (decided 2026-07-26)

Keying the bucket to settlement fixed WHERE a commitment sits; it did not
change how WIDE a bucket is. At 28 days a 7-day strategy still rounded up to
~42 days of lock-up:

```
12d  the job itself (execution window + duration)
16d  rounding up to the end of a 28-day bucket   <- waste
14d  challenge window                            <- real
```

Only the middle is waste, and narrowing the bucket removes most of it (~42d ->
~28d at a 7-day width). The remainder is dominated by the challenge window, so
exact per-commitment expiry would buy only ~2 further days for a rewrite of the
accounting core — not worth it.

The larger gain is not the waste. It is that two commitments of different
lengths land in DIFFERENT buckets and expire independently: a guardian's 7-day
work frees up while their 30-day work stays held. Under 28-day buckets both
often shared one bucket, so the short commitment was held hostage by the long.

**`challengeWindow <= epochLength` is removed.** It was never a correctness
rule — it was a proxy for keeping `openExposureUsd`'s walk short, and as a proxy
it pinned buckets at >= 14 days, forbidding exactly the narrow widths that make
independent release work. It is replaced by `MAX_SCAN_BUCKETS`, a direct bound
on the walk, checked in the constructor and in `setChallengeWindow`.

The coverage horizon moved from an epoch COUNT to a TIME (`MAX_COVERAGE_HORIZON`
= 60 days). An epoch-count horizon would have silently shrunk to nothing the
moment someone narrowed the buckets — three 7-day epochs is 21 days, so a 30-day
strategy would have started reverting `CoverageHorizonExceeded` for no reason a
reader could see. This is the failure mode the change was most likely to
introduce, and it is why the two constants moved together.

Bucket width remains a deploy-time constant. Nothing here changes that; it
changes only which widths are legal.

## Exit gating (decided 2026-07-26)

The flat `coolDownPeriod` is the wrong instrument. It is a proxy for "cannot
escape before a challenge lands", and as a proxy it punishes EVERY guardian for
the worst case: someone with no open commitments waits six weeks for no reason.

**Decision: gate the exit on actually having open exposure, not on a long
timer.** `StakedWood` refuses to release stake while
`exposureLedger.openExposureUsd(guardian) > 0`, and the baseline cooldown stays
short for churn protection.

This is strictly better than raising the cooldown:

- Exact rather than conservative. You cannot leave while you owe coverage, and
  you leave promptly when you do not.
- It removes the `coolDownPeriod >= epochLength + challengeWindow` invariant
  entirely — the invariant existed only to approximate this check.
- It resolves the unmet prerequisite below without asking every guardian to
  accept a six-week exit.

Costs, stated rather than discovered: it couples `StakedWood` to the ledger (the
ledger already reads sWOOD, so the two become mutually referential — both
directions are views, so there is no reentrancy concern, but it is a real
dependency). And a guardian is held until their exposure genuinely expires, so
a stuck or over-conservative exposure figure delays an exit. Bucket expiry is
time-based and self-clearing, so it cannot hang indefinitely.

NOT YET BUILT. `StakedWood` is golden-pinned on the Plan C branch, so the
ledger pointer must be added with layout care.

## Chain target (decided 2026-07-26)

Deployment is **Robinhood Chain only**. Review finding H2 — `SyndicateGovernor`
at 27,586 bytes against EIP-170's 24,576 — is therefore NOT a blocker: Robinhood
allows 98,304, leaving roughly 70 KB of headroom. What remains is a tooling fix
so `forge build` stops failing on a limit that does not apply to the target
chain. If any part of this stack is ever pointed at Base, H2 becomes blocking
again and the governor needs splitting.

## Known unmet prerequisite

`coolDownPeriod` ships at **7 days** (`script/Deploy.s.sol` `DEFAULT_COOLDOWN`,
both testnet scripts, and the §5 spec value) against a requirement of
`epochLength + challengeWindow` = **42 days** at current defaults.
`DeployPlanB.s.sol` has a pre-flight that will refuse the deploy.

This predates the ADR and is not created by it — but the decision above raises
the requirement further (to `executionWindow + maxStrategyDuration +
challengeWindow`), so it must be resolved before either path ships. Raising it
lengthens every guardian's exit by weeks, which is a stakeholder decision, not a
config tweak.

## What we give up

Long-duration strategies become impossible until v2 builds §3.4a's chain. If the
roadmap wants six-month mandates, this forecloses them.

§3.4a's consequence (d) — adverse-selection repricing at renewal, so a strategy
that gets riskier mid-life pays more — also goes. Over a capped window it matters
far less, but it is a real loss and should be re-examined if the cap is ever
raised.
