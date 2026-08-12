# Counting strategy-held value in the vault's NAV (finding #3)

Status: **Direction D-final chosen. The ATTACK half is IMPLEMENTED; the FAIRNESS
half is not.** Written after two failed attempts to correct the settle price at
the stamp (see PR #227), then two design workflows that ranked the surviving
directions and a premortem that reordered the build. The chosen design does NOT
count strategy value in the live price at all — it never values the residue.

The two harms are split, and they ship separately:

- **(a) the skim** — a depositor mints against a residue-blind price then sweeps
  the residue into the enlarged pool. An ATTACK, inducible on demand.
  **CLOSED** (queued-deposit gate + live pricing; see "PR 1" below).
- **(b) the underpayment** — a queued redeemer is paid at a stamp that excludes
  the residue, and the shortfall accrues to the LPs who stayed. A FAIRNESS gap:
  no attacker, no loss to the protocol, a transfer between LPs. **OPEN** — the
  rounds ledger below is the fix, and it is the only reason that machinery
  exists.

That split is deliberate and comes from the premortem: the original build order
closed nothing until step 6 of 8, so seven steps carried zero security value
while the exploit stayed live. The order was inverted — the attack is closed
first, in isolation, and everything remaining is fairness.

## The problem

`totalAssets()` counts only `balanceOf(vault)` (minus reserved queue assets and
escrowed fees). Value a strategy still holds — a Morpho position at full
utilization, collateral behind residual debt — prices at **zero**. Settlement is
deliverable-maximum (`MorphoSupplyStrategy` caps delivery at the market's idle
balance and emits `SettlementIncomplete`), so a settled proposal can leave a
**residue** on the clone after the open count clears. Two consequences:

- **(a)** A queued depositor mints against a frozen stamp price that excludes the
  residue, then `sweep()`s it into the enlarged pool. Attacker-driven, atomic,
  riskless — and INDUCIBLE: a fee-free flash loan empties Morpho's idle balance
  for one callback frame, forcing under-delivery on demand (proven on a live
  Robinhood fork, findings #2/#3).
- **(b)** A queued redeemer is **underpaid** by the same blindness. No attacker
  needed.

## Why the stamp cannot be fixed in place

`stampSettlement` derives the queue reserve as `mulDiv(redeemShares, num, den)`,
and `_availableFloat` is `balanceOf - reserve`. Raising `num` reserves assets the
vault does not hold, flooring instant exits for every LP. Capping `num` does not
help: the reserve scales with `redeemShares / den`, a ratio the caller does not
control. **One number, two opposite requirements** — the price wants to rise, the
reserve wants to stay backed. This is the trap every "just widen the stamp"
attempt falls into.

## THE CONSTRAINT THAT MUST SHAPE ANY IMPLEMENTATION

The vault deliberately prices off a frozen REALIZED figure. `VaultWithdrawalQueue`'s
header states it: the vault must "never mint or burn against an unrealized,
strategy-influenced NAV." Findings #2 and #3 are what pulling that lever looks
like — an attacker moves the strategy or its oracle, and the vault believes it.

So any NAV that counts live positions MUST answer: what stops a proposer moving
the valuation and re-pricing the whole vault? An implementation without an answer
here is strictly worse than the gap it closes.

Non-negotiables:

1. **Never value through a venue the proposal can trade.** The pool-quoted floor
   is exactly how finding #3 was exploited.
2. **Attested, principal-derived reporters only** — Settled-gated,
   vault-asset-denominated, oracle-free, position-derived; NEVER a `balanceOf`-style
   read an attacker can donate into. The word "settled" is NOT the safety property
   (the Lazy Summer, Jul 2026 exploit donation-gamed a settled-looking figure that
   read a raw balance). Morpho counts `own` supply-shares via the accrual index —
   never the flash-loanable `deliverable`; CL counts `idle + max(0, collateral -
   owedRoundedUp)` and excludes the LP / `otherToken` / non-asset collateral.
3. **Bias low, always.** An over-count mints against value that may never arrive;
   an under-count only under-prices. Every rounding and every unpriceable leg
   resolves downward.
4. **Degrade to the float-only figure**, never to a higher one, on any read
   failure.
5. **Do not make it a settlement veto.** A strategy that cannot be valued must not
   be able to block settlement — the capital-hostage failure the deliverable-maximum
   design exists to avoid.

---

## THE DECISION — Direction D-final

**Never value the residue. Instead: pay redeemers the honest cash-in-hand
(float-only) price now as a fully-backed floor, record who is owed what FRACTION
of future arrivals, and hand out real money only when `sweep()` actually delivers
it, split `q:(1-q)` between the settling pid's redeemer cohort and the staying
LPs.** No mark, no oracle, no inclusive reserve — so a bias-high over-count is
*unrepresentable*, and Direction A's freeze / tail-stranding / bad-debt over-count
cannot occur.

`totalAssets()` and every stamp stay **byte-for-byte float-only.** No value figure
ever enters the share price, including the deposit-claim price.

### Two forks, resolved from evidence

**Value estimate → ELIMINATED (pure D).** `_undeliveredValueOf` has zero call
sites today; a single-pid deposit estimate would itself be single-round-blind (the
bug we are removing); and widening `sp.num` to carry an estimate re-creates the
reserve-inflation trap above. The deposit skim (harm a) is closed instead by a
*pair*: (i) **live pricing** at deposit claim (`convertToShares`, computed before
the escrow joins the pool — never the frozen residue-blind num) plus (ii) a
**clean gate** — a deposit is admissible only when `openProposalCount()==0 AND
openRoundCount()==0`. Because `hasUndeliveredValue()` reads the POSITION, not the
flash-loanable deliverable, the very flash loan that induces residue also opens
the round: there is no instant where uncounted residue coexists with an admissible
mint.

**One round vs many → PER-PID rounds.** The single-open-proposal invariant orders
*settlements*, not *residue* — once pid N settles, N+1 can settle while N's clone
still holds an unswept position for arbitrarily long. Serializing is forbidden
(non-negotiable #5: it makes an illiquid market a capital hostage). The single
`_lastSettledStrategy` slot becomes a per-pid round ledger.

### Mechanism (MasterChef accumulator over real arrivals)

- **Senior floor** — today's float-only stamp, unchanged, always backed, always
  payable (`mulDiv(amount, sp.num, sp.den)`, `num = totalAssets()+1`).
- **Junior top-up** — `claimRemainder(requestId)` pays `mulDiv(amount,
  accArrivalPerShare[pid], ACC) - arrivalDebt[id]`, clamped to the pid's isolated
  `_pidTopUp[pid]` bucket. Baseline `arrivalDebt = 0` at `queueRedeem`; the floor
  claim NEVER touches it, so an arrival credited before the floor claim is still
  fully claimable.
- **Arrival** — `vault.collectResidue(pid)` (permissionless, holds the VAULT
  reentrancy guard) sweeps the clone, measures a **guarded balance delta**, credits
  `min(delivered, reported)`: a donation → harmless stayer float; a lying clone →
  cannot over-reserve. `sweep()` becomes `onlyVault` on every template.
- **Reserve** stays `<= balanceOf` by widening the EXISTING `_reservedAssets`
  membership to `Σ _pidReserved + Σ _pidTopUp` — every top-up increment corresponds
  to assets `sweep` physically pushed in the same call. No new custody surface, no
  new code at the `executeGovernorBatch` / `_withdraw` / `totalAssets` floors.
- **In-settlement best-effort sweep** (`try vault.collectResidue(pid) {} catch {}`
  in `_finishSettlement`, after `_decOpen`) closes the liquid case in the same tx,
  so a round only lingers when the market genuinely cannot pay.
- **Backstops** — permissionless `forceCloseRound(pid)` after `MAX_ROUND_DURATION`
  (~90d, must exceed realistic Morpho-illiquidity recovery); guardian
  `emergencyWriteOffRound(pid)` for a proven-dead clone. A written-off pid keeps
  its floor + arrived-so-far; it forfeits only FUTURE cohort recovery.

### Master solvency invariant (the fuzz suite asserts this, per pid and global)

```
(1) balanceOf(vault) >= reservedQueueAssets()                              [never deploy reserved float]
(2) reservedQueueAssets() == Σ _pidReserved + Σ _pidTopUp                  [reserve composition]
(3) ∀pid: paidToCohort(pid) <= floorReserve(pid) + arrivalsCollected(pid)
(4) ∀pid: Σ_requests (mulDiv(amount, acc[pid], ACC) - arrivalDebt[id]) <= _pidTopUp[pid]
(5) Σ arrivalsCollected(pid) <= Σ assets that pid's clone actually pushed via collectResidue
```

A cohort is never paid more than `floor + q · delivered` — bias-high is
unrepresentable, which is the whole point of not valuing anything.

### Zero cost the design cannot avoid

Removing the deposit estimate means **any open round freezes ALL deposits** (the
union-of-rounds lock). Mitigated by the in-settlement best-effort sweep (liquid
case closes in-tx), permissionless `collectResidue`, the `RESIDUE_DUST` floor,
always-open deposit-cancel, and the two backstops. This is the honest price of
never valuing anything — document it, do not hide it.

### Residual exposure (all bias-low, documented, none a skim)

1. **CL `otherToken` / unconvertible leg** goes to stayers, not the cohort —
   `releaseUnconvertible()` recovers non-asset value that cannot be attributed in
   asset terms. Cohort under-recovers only on that leg. Optional P2:
   `collectUnconvertible(pid)` mirroring `collectResidue`.
2. **Post-close residue** — a round that closed on sub-`RESIDUE_DUST` `own` whose
   value later compounds back up routes 100% to stayers. Bounded by dust. This is
   the one place the multi-round gate is weaker than today's live per-deposit probe.
3. **Lying / cross-clone `sweep`** — `min(delivered, reported)` bounds it to a
   stayer fairness shift, never a solvency/skim. TierRegistry (now unskippable)
   keeps non-certified clones out of the deployed threat model.
4. **Bounded top-up dust** — accumulator round-down leaves sub-wei-per-share in
   `_pidTopUp`. Open decision: `releaseRoundDust(pid)` vs accept.
5. **Fee seam** — a late stayer-leg arrival raises pps but is not captured by that
   proposal's perf fee (pnl measured float-only). Fairness nuance toward LPs, not
   a security issue.

---

## Rejected directions (recorded so they are not rediscovered)

**A / A-gated — count the settled receivable in `totalAssets()`.** Add
`_undeliveredValueOf(_lastSettledStrategy)` to NAV. NAIVE A is unsound: ungated, an
inducible receivable inflates the governor's propose-time capital ceiling and
tier-2 coverage cap and props up the settle-price floor. A-GATED (count the residue
only while `openProposalCount()==0`) closes that, but even gated it trades the
redeemer's bounded underpayment for **conditional TOTAL stranding** on true default
(the inclusive reserve is unbacked; tail claims revert with cancel closed) plus a
capital-formation freeze whenever a counted receivable fails to deliver. A-gated
ranked #1 in the first workflow ONLY because it is a vault-only upgrade that fixes
already-deployed syndicates — a reason that **evaporates greenfield (no live
syndicates)**, which is why D is preferred. A's failure cascade all traces to one
act: writing a number into the ledger for value that is somewhere else. D never
does.

**B — two-leg stamp (split the claim price from the reserve).** Stamp an inclusive
PRICE but reserve only the deliverable float; pay the remainder from arrivals.
Correct in principle, but the two-pool reserve invariant under interleaved
permissionless claims is the highest bug-likelihood surface in the space, and it
still needs a residue-aware deposit estimate. D obtains B's limited-recourse
property with NO valuation at all, so **B collapses into D**.

**E — sweep-only, do not count.** Land only the best-effort in-settlement sweep and
leave `totalAssets()` float-only. FAILS as a terminal answer: it abandons harm (b),
and (b) is weaponizable via the floor-exempt `finalizeEmergencySettle`. Its two
good ideas (sweep-at-settle, per-pid bookkeeping) are absorbed into D's build order.

**Serialization (forbid a second dirty settle until the prior round closes).**
Rejected: turns an illiquid market into a capital hostage (non-negotiable #5).

**restamp(pid) — skip the stamp while `hasUndeliveredValue()` holds, then restamp.**
Rejected earlier and still rejected — it does not survive `VaultWithdrawalQueue`:
`claim` requires `_lastStampedPid >= r.pid` (skipping strands every queued request
for that pid, redeemers included); `stampSettlement` reverts `StampOutOfOrder` once
a later proposal settles first (permanent stranding); `sp.stamped` reverts
`AlreadySettled` (restamping needs `_reservedAssets` / `_stampedUnclaimedShares`
unwound). Strictly worse than the mispricing.

**correct-num-at-the-stamp (raise `num` in place).** Rejected in PR #227 — the
"one number, two opposite requirements" trap above; tried twice, reverted both.

---

## Build order (greenfield, vault+queue+templates redeployable)

Reordered per the premortem: **the attack closes first, alone.** Each step
independently shippable; grep `test/` stubs for every new cross-contract selector
and patch them in the SAME commit (repo guardrail, hit 4×).

**PR 1 — close the skim. SHIPPED.** Harm (a), no ledger involved.
- `depositsLocked()` made public and **degrades CLOSED** once a strategy is
  pinned. The earlier degrade-OPEN posture was defensible while the probe was
  defence-in-depth on the instant path; it is not once the async path gates on
  the same predicate, because then a probe failure degrades the whole finding-#3
  gate open — in exactly the window an attacker can force.
- The queue's **deposit claim gates on `depositsLocked()`** (the async hole: the
  instant path was already shut, the queued path was not) and **prices live via
  `convertToShares`** rather than any stamp. Both are required: the gate picks an
  honest instant, the live read prices a residue already swept in, which a frozen
  stamp stays blind to.
- Consequences that fall out: no stamp is consulted for a deposit at all, which
  un-bricks deposits tagged to a proposal that never settles; and **deposit
  cancel becomes unconditional**, because with no frozen number there is no
  look-back option to straddle (pashov #10 is closed at its source rather than by
  gate-complementarity — and cancel must stay open so a depositor is never wedged
  between a residue-gated claim and a closed cancel).

**Remaining — close the underpayment.** Harm (b), fairness only.

2. **Mandatory best-effort sweep at settlement** (`try … catch`, never reverts
   settlement). Carries the COMMON case: when the market can pay, the residue
   lands in the settle tx, the stamp is computed off the full value, and the
   queued redeemer is paid correctly with no ledger. This demotes everything
   below to rare-tail insurance.
3. *(optional)* **Propose-time cap on deployment vs the target market's idle
   liquidity**, so the vault's own exit rarely creates a residue at all.
4. **Queue round ledger + accumulator** (queue-only): round mappings + `ACC`,
   `openRound`/`closeRound`/`creditArrival`/`openRoundCount`/`roundInfo`
   (onlyVault), and the `_roundCohortShares[pid] = redeemShares` freeze inside the
   existing `stampSettlement` `redeemShares != 0` block. **Checked subtractions
   only** — delete the saturating pattern in new paths — and one idempotent
   `_release(pid)` so double-release is unrepresentable. Grep-gate any read of
   `_pidRedeemShares` inside round math: the denominator must be the frozen
   cohort. Unit-test cohort==0 → redeemerLeg==0 (no revert), accumulator
   monotonicity, `Σ credits ≤ arrival`, and all-floor-claims-before-first-arrival.
5. **`claimRemainder` + `_arrivalDebt`** (queue-only): baseline 0, mutated only by
   `claimRemainder`, never by the floor claim; clamp to `_pidTopUp`.
6. **Vault `collectResidue` / `payReservedTopUp` / backstops**; strategy `sweep()`
   → `onlyVault`; open-round in `onProposalSettled`. `collectResidue` must be
   callable for ANY pid regardless of round state and must never revert. Round
   opening **fails CLOSED**. Backstops behind guardian quorum + timelock with an
   objective on-chain trigger, and late arrivals after close still honor the
   cohort's q.
7. **Fuzz/invariant suite**: the master solvency invariant (1)-(5) plus the
   exploit-traceable pins (zero-cohort, force-close bounded-loss-not-stranded,
   `Σ credits ≤ arrived`, pid-isolation, reentrancy, post-stamp-depositor
   exclusion).
8. **Docs + comments**: this file; the stale in-source block at
   `SyndicateVault.sol` `onProposalSettled` (the "closes MINT side only" note is
   superseded once the redeem side is closed by rounds); close #233.

**Deploy-blocker:** template registration should revert while #233 is open, so a
partial stack cannot reach production with the fairness half unbuilt.

## Exploration record

Two design workflows produced this: the first ranked A / B / D / E and found the
A-gated ceiling-inflation hole and the "settled is not the safety property"
reframe (MetaMorpho ships D's narrowing; Yearn profit-locking is sweep-incompatible;
no production precedent exists for trustless live-portfolio NAV). The second
deep-designed D across three variants (single-round / per-pid / no-estimate),
adversarially broke each, and produced the D-final spec above. The queue-internals
claims were then verified end-to-end against `VaultWithdrawalQueue.sol`.
