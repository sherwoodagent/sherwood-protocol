# ADR 2026-07-27 — v1 tier policy: tier 2 refused, every covered tier provably covered

**Status:** accepted for v1.

**Resolves:** the §4 blocking gate, together with `2026-07-26-roe-validation.md`.
That ADR established *whether* guardians can afford to underwrite; this one records
*what they are asked to underwrite*.

**Unblocks:** lowering `ExposureLedger.quorumTierThreshold`, whose natspec says
"Lowering is gated on the §3.10 ROE validation — a BLOCKING launch gate."

**Home:** written in the Plan F worktree. Plan F is parked as v2 (draft PR #28), so
**cherry-pick this onto the branch where §4 is signed off** — PR #22, alongside the
capped-duration and ROE ADRs.

---

## Decision

**1. Tier-2 exposure is refused in v1.** A proposal whose `envelopeTier` resolves to
2 cannot be proposed or executed. Since tier 2 is the DEFAULT for any uncertified
`(target, selector)`, this means: **no proposal may execute an uncertified call.**

**2. `quorumTierThreshold` drops from 2 to 0.** Every proposal with non-zero
`requiredCoverage` must satisfy `requireApproveQuorum` at execute — its approvers'
combined slashable bonds must cover its extractable value. Not tier 2 only.

## Why

`2026-07-26-roe-validation.md` found guardian ROE of **0.0% at tier 2** — the entire
cohort fee pool exactly equals one guardian's expected annual tail loss — against
**9.5% at tier 1** and **49.5% at tier 0**. Guardians cannot rationally underwrite
tier 2 at k=1, and a cohort that will not participate is the likelier failure than
one that colludes (§3.10's own framing).

Refusing what cannot be priced is more honest than pricing it wrong. The tier result
is also insensitive to `p_e` at tier 0/1 and changes sign with it at tier 2, so this
decision removes the protocol's dependence on an unmeasured input.

**On (2):** coverage sizing is already per-tier and already correct —
`requiredCoverage = maxCapital × Σ boundBps / 10_000`, where each tier-0/1 call
contributes its certified extractable bound and each tier-2 call contributes full
notional, summed across execute AND settlement calls. A closed-loop adapter that can
leak 1% requires 1% of coverage. What was missing was *enforcement*: at
`quorumTierThreshold = 2` that correctly-sized number was only checked at tier 2, so
a tier-0/1 proposal could execute with no covering approver at all.

This makes the guardian layer **mandatory rather than advisory**, and it is what
makes the §2 guarantee true for every proposal rather than for tier 2 alone.

## What stays

`requiredCoverage == 0` continues to pass optimistically (review finding M-1). A
proposal that can extract nothing has nothing to underwrite, and demanding a
covering signer for it is pure throughput loss. Not an exception to the rule above —
the same rule evaluated at zero.

## Accepted costs

1. **Certification becomes a launch prerequisite and an ongoing operating cost.**
   Tier 2 is what you get by omission, so every adapter-selector a strategy touches
   must be certified before it can be proposed. Uncertified means unproposable, not
   merely expensive.
2. **Proposals now block on guardian capacity.** With the threshold at 0, a proposal
   cannot execute until approvers with sufficient slashable bond have covered it.
   A throughput cost accepted knowingly; the ROE work is what says guardians can
   afford to supply that capacity at tier 0/1.
3. **Long-tail and experimental strategies are foreclosed in v1** unless someone
   certifies their adapters at tier 0/1 — which, per (4), is a judgment nobody
   should make casually.
4. **Certification is a governance judgment the code cannot check, and the codehash
   guard is weaker than it looks.** Per `TierRegistry`'s own note, EXTCODEHASH
   catches metamorphic redeploys (CREATE2 + SELFDESTRUCT) but **not proxy
   implementation swaps**: for EIP-1967 / UUPS / transparent / beacon proxies the
   proxy's runtime bytecode is static across upgrades, so the certified hash keeps
   matching while behaviour behind it changes arbitrarily. **Governance MUST NOT
   certify proxied adapters at tier 0/1.** This entire ADR rests on that discipline.
5. **The bound is the real risk parameter.** A tier-0 certification carrying an
   over-generous `extractableBoundBps` slides the economics continuously back toward
   the tier-2 result this ADR exists to avoid. Certifying at tier 0 with a loose
   bound is worse than refusing to certify, because it looks safe.

## Implementation

**(a) Tier ceiling — NOT YET BUILT.** No tier ceiling exists today; `grep` for
`maxTier` / `TierTooHigh` finds nothing. What exists is the opposite knob
(`quorumTierThreshold`, which makes coverage *mandatory* at or above a tier, not
*refused*). Required:

- `maxEnvelopeTier` (protocol-level, following `ProtocolConfig.maxStrategyDuration`'s
  shape from `2026-07-26-capped-duration-coverage.md`), launch value **1**.
- Checked at **propose**, where `envelopeTier` is resolved and snapshotted
  (`SyndicateGovernor:941`).
- Re-checked at **execute**. Tier can move between the two — `TierRegressed`
  (`SyndicateGovernor:444`) exists precisely because live tier can exceed the
  snapshot after a lazy demotion. A ceiling enforced only at propose would let a
  demoted adapter execute at tier 2.
- A distinct error (`EnvelopeTierTooHigh`) rather than reusing `TierRegressed`: the
  two conditions have different remedies (certify the adapter vs. re-propose).

**(b) Threshold — parameter only.** `setQuorumTierThreshold(0)`. No code change; the
`>=` comparison at `SyndicateGovernor:468` already admits every tier at 0.

**(c) Deploy pre-flight.** Assert `maxEnvelopeTier <= 1` and
`quorumTierThreshold == 0` **together**. They are coupled in intent but independently
settable, so a deploy landing one without the other is silently outside this ADR:
ceiling without threshold leaves tier-0/1 unenforced; threshold without ceiling
demands coverage for tier 2 that no guardian will supply.

## What this does not settle

- **Whether tier 1 or tier 0 is the right ceiling.** Launch value 1 admits
  oracle-bounded discretion (9.5% ROE). A ceiling of 0 would admit only closed-loop
  adapters (49.5%) at a further throughput cost. Revisit with real certification data.
- **`k` stays at 1.** Raising it multiplies capacity per bond and raises ROE where
  net return is positive, but also raises what a single guardian can lose.
- **v2 re-admission of tier 2** requires either a materially larger guardian pool or
  a materially lower `k`, and should re-run the ROE arithmetic rather than assume
  this decision was launch caution.
