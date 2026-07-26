# ADR 2026-07-26 — §4 blocking ROE validation: guardian participation closes only at tier 0/1

**Status:** proposed — this is the §4 BLOCKING gate, and it resolves to a
governance decision, not an implementation.

**Resolves:** §4 gate 2, *"validate the §3.10 ROE arithmetic at the intended
launch parameters."*

**Depends on:** the fee model in `docs/specs/2026-07-24-fee-model-design.md`
(branch `claude/fee-mechanism-design-lzl07b`, rev. 3 — "2 and 20"), and
`2026-07-26-capped-duration-coverage.md` (PR #22).

**Home:** written in the Plan F worktree for convenience. Plan F is parked as v2
(draft PR #28), so **this ADR must be cherry-picked onto the branch where §4 is
signed off** — PR #22 is the natural home, since the capped-duration ADR already
lives there.

---

## The question

§3.10 gives approvers a coverage-weighted premium so pay scales with underwritten
risk rather than only with realized profit. §4 makes one thing blocking: does the
premium actually clear a guardian's tail-risk hurdle **at the intended launch
parameters**? If it does not, guardians rationally decline, the cohort collapses,
and every mechanism in Plans A–F is decorative — protection nobody is paid to
provide.

The original spec's worked example left ~$2,000 of annual return on $2M of
at-risk capital and concluded the arithmetic "only closes when exposure is
tier-0/1". That example predates the fee redesign. This ADR re-runs it against the
actual proposed fee model and answers the gate.

## Method

```
E    extractable exposure   = TVL × boundBps/10_000   (tier 0/1)
                            = TVL                      (tier 2 — full notional)
B    bond the guardian posts = E / k                   (§3.3: coverage ≤ k × bond)
L    expected annual tail loss = p_e × severity × E
P    guardian fee pool         = management slice + performance slice
ROE  = (P − L) / B
```

Severity is **100%**: a conviction slashes at `maxSlashBps`, and Plan E's D7 fixed
that at no-ramp. `k = 1` (`ExposureLedger.kNumerator`, the target capacity).

**Inputs, labelled.** *Derived from the fee spec:* management 200 bps split
`7000/2000/1000` (agent/protocol/**guardian**); performance 2000 bps split
`6000/1500/1500/1000` (agent/protocol/**guardian**/owner); management deducted
before performance, per §2.1/§2.2. *Assumed, carried from the original spec:* TVL
$2M, gross yield 12%, `p_e` = 0.5%/yr. *Assumed here:* tier-0 bound 100 bps,
tier-1 bound 500 bps — representative closed-loop and oracle-bounded adapters.

## The pool, under the proposed fee model

```
TVL                          $2,000,000
Gross yield 12%                $240,000

Management  2% × $2M            $40,000  → guardian 10%  =  $4,000
Profit after management        $200,000
Performance 20% × $200k         $40,000  → guardian 15%  =  $6,000
                                          ───────────────────────────
GUARDIAN POOL                                        $10,000 / yr
```

**The fee redesign reduced the guardian pool.** The old model paid 5% of gross
profit = $12,000; the two-number model pays $10,000. Not a criticism of the
redesign — it fixes a real defect, below — but the gate must be judged against the
number that will actually ship.

**What the redesign did fix:** the old 5%-of-profit paid **zero in a flat or down
year**, precisely when approval risk is highest and challenges most likely. The
management leg is always-on, so guardians now earn in bad years too. Better shape,
slightly smaller amount.

## Result

| Tier | bound | E | B (k=1) | L (p_e=0.5%) | Net | **ROE** |
|---|---|---|---|---|---|---|
| **2** (uncertified, default) | full | $2,000,000 | $2,000,000 | $10,000 | **$0** | **0.0%** |
| **1** (oracle-bounded) | 500 bps | $100,000 | $100,000 | $500 | $9,500 | **9.5%** |
| **0** (closed-loop) | 100 bps | $20,000 | $20,000 | $100 | $9,900 | **49.5%** |

At tier 2 the **entire cohort pool exactly equals one guardian's expected tail
loss**. Net return zero, before any hurdle — worse than the original spec's
example, which at least left $2,000.

The tier effect is **double**, which is why it dominates everything else: bounding
extractable value cuts the tail loss *and* cuts the bond required to carry the
same TVL, by the same factor. Both sides of the ratio move together.

## Sensitivity

**Adjudication error rate `p_e`** — the most contested input, since it is assumed:

| p_e | Tier 2 ROE | Tier 0 ROE |
|---|---|---|
| 0.1 % | 0.4 % | 49.9 % |
| 0.5 % | 0.0 % | 49.5 % |
| 2.0 % | −1.5 % | 48.0 % |

**Tier 0/1 is insensitive to `p_e`; tier 2 changes sign with it.** This matters
procedurally: the gate can be signed off at tier 0/1 *without first settling what
`p_e` is*, because the conclusion holds across two orders of magnitude. At tier 2
the answer depends entirely on an assumption nobody has measured.

**Guardian fee split.** Tripling the guardian slices (10→30% management, 15→40%
performance) raises the pool to $28,000. At tier 2, k=1: net $18,000 on $2,000,000
= **0.9% ROE**. Still far below any hurdle — and it comes straight out of the
agent's 70/60 shares, a product decision with its own consequences. **Splits
cannot fix tier 2:** the gap is ~2 orders of magnitude, splits move it by ~3×.

**Scale.** Pool ∝ TVL. Exposure ∝ TVL. **ROE is scale-invariant** — identical at
$2M and $200M. Growing the fund does not fix this, and any plan assuming it will
is mistaken.

**Capacity `k`.** Raising k shrinks the required bond and so raises ROE — but only
where net return is already positive. At tier 2 net is zero, and 0/anything is
still 0. k amplifies; it does not remedy.

**Commitment duration.** The capped-duration ADR lengthens the worst-case lock
from `epochLength + challengeWindow` (42d) to `reviewEnd + executionWindow +
maxStrategyDuration + challengeWindow`. Same annual pool, capital tied up longer,
so return per unit capital-time falls further. Direction only — magnitude depends
on the duration cap, which the multisig has not set.

## Decision

**The §4 ROE gate PASSES at tier 0/1 and FAILS at tier 2.** Proposed resolution:

> Guardians underwrite **tier-0/1 certified adapters at k = 1**. Tier-2 exposure
> is either refused, or admitted only at a materially lower k with the ROE
> shortfall accepted explicitly and in writing.

This is a **governance decision about what guardians are asked to insure**, not a
contract change. `TierRegistry` already carries the tier and its bound;
`ExposureLedger` already sizes `requiredCoverage` from it. Nothing needs building
to adopt this.

Three consequences to accept knowingly:

1. **Tier 2 is the DEFAULT for any uncertified `(target, selector)`.** So this
   decision means: *no proposal may execute an uncertified call under guardian
   coverage.* Certification becomes a launch prerequisite and an ongoing operating
   cost, not an optimization.
2. **Certification is a governance judgment, and the codehash check is weaker than
   it looks.** Per `TierRegistry`'s own note, EXTCODEHASH catches metamorphic
   redeploys but **not proxy implementation swaps** — for EIP-1967/UUPS/beacon
   proxies the proxy bytecode is static while behaviour behind it changes
   arbitrarily. Governance MUST NOT certify proxied adapters at tier 0/1. This
   result rests on that discipline holding.
3. **The result is only as good as the bound.** A tier-0 certification with an
   over-generous `extractableBoundBps` slides the analysis back toward tier 2
   continuously. The bound is the actual risk parameter.

## What this does NOT settle

- **`p_e` is unmeasured.** Immaterial at tier 0/1 (see sensitivity), material if
  tier 2 is ever admitted.
- **Cohort splitting.** The table models one guardian carrying full coverage — the
  spec's worst case. With N guardians sharing coverage the pool splits N ways but
  so do bond and tail loss, so ROE should be roughly preserved; a real cohort model
  should confirm that rather than assume it.
- **The fee splits are marked *proposed***, not decided, in the fee spec.
- **The duration cap value is deferred** to the multisig, so the lock-length term
  cannot yet be quantified.
- **`coolDownPeriod` ships at 7 days against a ≥42-day requirement**, and the
  capped-duration ADR raises that requirement further. `DeployPlanB`'s pre-flight
  refuses the deploy until resolved. Independent of this gate, but it lands on the
  same stakeholders — lengthening every guardian's exit worsens the same ratio this
  ADR measures.

## Consequence for Plan G

Plan G (§3.10 premium + watchtower funding) is **worth building once the tier
policy above is adopted, and pointless before it** — the premium allocates a pool
fairly; it cannot enlarge one. Its scope also shrank: per-epoch repricing and
epoch-checkpoint watchtower funding are gone with §3.4a, while the always-on
guardian management-fee slice now exists at v1 by design.

What remains genuinely unfunded and worth Plan G's attention: the court panel
reward (`panelRewardWood` defaults to **0**, and an unpaid panel **acquits by
default**), the off-chain detector bounty, and the permissionless-but-unpaid
liveness calls throughout the stack.
