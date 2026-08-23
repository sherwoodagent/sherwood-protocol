# Strategy-held value and the vault's pricing (finding #3)

Status: **BOTH halves are implemented. The attack half in PR #243, the
fairness half in PR #245.** The mechanism of (a) is gone; a bounded RESIDUAL of
it is measurably still open, at roughly 1/34,600 of the original size — see
"(a) The skim" below before treating this as finished. This file is kept as the
design record: the trap in the middle is a live hazard for anyone touching the
settle stamp, and the non-negotiables still bind any future change here.

Finding #3 has two harms, and they are fixed at different sites by different
mechanisms:

- **(a) the skim** — a depositor mints against a price that excludes value a
  settled strategy still holds, then calls the permissionless `sweep()` to pull
  it into the enlarged pool. An ATTACK, inducible on demand. **MECHANISM
  CLOSED, RESIDUAL OPEN**: the price now includes the residue, but only as the
  call-free probe quotes it, and the probe is short by the interest accrued
  since the venue's last on-chain accrual. The same transfer survives at that
  scale.
- **(b) the underpayment** — a queued redeemer is paid at a stamp that excludes
  the same value, and the shortfall accrues to the LPs who stayed. A FAIRNESS
  gap: no attacker, no loss to the protocol, a transfer between LPs. **CLOSED.**

The attack was closed first and in isolation, deliberately: an earlier build
order closed nothing until step 6 of 8, leaving the exploit live across seven
steps of work.

## The problem

`totalAssets()` counts only `balanceOf(vault)` (minus reserved queue assets and
escrowed fees). Value a strategy still holds — a Morpho position at full
utilization, collateral behind residual debt — prices at **zero**.

Settlement is deliverable-maximum: `MorphoSupplyStrategy` caps delivery at the
market's idle balance and emits `SettlementIncomplete`, so a settled proposal can
leave a **residue** on the clone after the open count clears. It is inducible
rather than merely unlucky — a fee-free flash loan empties Morpho's idle balance
for one callback frame, forcing under-delivery on demand (proven on a live
Robinhood fork, findings #2/#3).

## THE TRAP: the stamp cannot be corrected in place

Tried twice in PR #227, reverted twice. Recorded here because an in-source
comment points at this section, and because it is the first idea everyone has.

`stampSettlement` derives the queue reserve as `mulDiv(redeemShares, num, den)`,
and `_availableFloat` is `balanceOf - reserve`. Raising `num` to include the
residue therefore reserves assets the vault does not hold: instant
`maxWithdraw`/`maxRedeem` floor to zero for every LP, and a queued `claim` reverts
outright if the residue never frees. Capping `num` does not help — the reserve
scales with `redeemShares / den`, a ratio the caller does not control.

**One number, two opposite requirements**: the price wants to rise, the reserve
wants to stay backed. Any fix must decouple them rather than tune the number.

The neighbouring idea — skip the stamp while a residue is outstanding, then add a
permissionless `restamp(pid)` — does not survive `VaultWithdrawalQueue` either:
`claim` requires `_lastStampedPid >= r.pid`, so skipping strands every queued
request for that pid including redeemers; `stampSettlement` reverts
`StampOutOfOrder` once a later proposal settles, stranding them permanently; and
`sp.stamped` reverts `AlreadySettled`, so restamping needs `_reservedAssets` and
`_stampedUnclaimedShares` unwound first.

## Non-negotiables

Each traceable to a finding already hit:

1. **Never value through a venue the proposal can trade.** The pool-quoted floor
   is exactly how finding #3 was exploited.
2. **Attested, principal-derived reporters only** — Settled-gated,
   vault-asset-denominated, oracle-free, position-derived; NEVER a
   `balanceOf`-style read an attacker can donate into, and never through a
   proposer-chosen contract (the Morpho IRM lived on this path and could suppress
   the whole figure by burning gas). The word "settled" is NOT the safety property
   — the Lazy Summer, Jul 2026 exploit donation-gamed a settled-looking figure
   that read a raw balance.
3. **Bias low, always.** Over-counting mints or pays against value that may never
   arrive; under-counting only under-prices.
4. **Degrade to the float-only figure**, never to a higher one, on any read
   failure.
5. **Do not make it a settlement veto.** A strategy that cannot be valued must not
   block settlement — that is the capital-hostage failure deliverable-maximum
   exists to avoid.

---

## (a) The skim — MECHANISM CLOSED IN PR #243, RESIDUAL STILL OPEN

**Deposits are PRICED against the residue, not blocked by it.**

Blocking is a bet on an unanswerable question — will the value come back? — and
it pays nothing in the branch where the answer is no: if the residue never
arrives, the residue-free price was correct all along and the vault was frozen for
nothing, potentially forever, since a market that never refills never clears.

Charging is safe in both branches. A mint pays
`depositNav() = totalAssets() + what settled strategies still owe`:

- the residue arrives → the depositor paid a fair price
- it never arrives → the depositor overpaid, incumbents unharmed either way

and the skim's MECHANISM dies by construction rather than by refusal: it *was*
"mint at a price excluding the residue, then sweep it in", and there is nothing
left to take once the price includes it — **to the extent the price includes it**.
That qualifier is the whole of the residual below: the leak is now exactly the
part of the residue the probe cannot see, and not a byte more.

**DEPOSIT SIDE ONLY, and that asymmetry is the whole safety argument.** On a mint,
counting a receivable makes the depositor receive FEWER shares, so over-counting
costs only them. On a redeem it would pay out assets the vault does not hold,
over-paying early exiters and stranding the tail. So `totalAssets()`, the settle
stamp, every redeem path, both fee bases and the governor's sizing reads are
untouched. ERC-4626 permits deposit and redeem to price differently — that is how
a vault expresses an entry fee, and this is one.

**One narrow lock survives, and only where a price cannot exist.**
`ConcentratedLiquidityStrategy.undeliveredValue()` is deliberately partial: it
excludes a live LP position, the volatile leg and non-asset collateral, because
valuing them means reading a price the proposal can trade. Under-reporting was
harmless while a boolean lock covered every residue shape; once the figure sets
the price, "biased low" IS the skim. Templates therefore declare what they cannot
value (`IStrategyDelivery.hasUnvaluedResidue()`) and the vault refuses to mint
while anything is unvalued. Unlike a residue lock this cannot wedge the vault:
every unvaluable shape is unwindable by the permissionless `sweep()` — burning an
LP position always returns its tokens, there is no illiquid market to wait on.

**Bounded self-report.** Each strategy's contribution is clamped to
`min(capitalSnapshot, effectiveMaxCapital)`; an unbounded report would overflow
`depositNav()` or floor a mint to zero shares. The bound covers PRINCIPAL, not
principal-plus-yield.

### The residual, and why it is the same bug at 1/34,600 scale

This section used to end at the clamp, listing two under-counts and calling them
harmless — "they cost the depositor a sliver and never the incumbents".
**That is backwards, and the correction matters more than the arithmetic.** The
"One narrow lock survives" paragraph above already states the rule: *once the
figure sets the price, "biased low" IS the skim.* `depositNav()` IS the price.
An under-count under-states it, the mint therefore buys shares too cheaply, and
the difference comes out of the LPs who were already in — the exact direction
finding #3 named. The rule was applied to `ConcentratedLiquidityStrategy` and
not to the two residuals sitting directly underneath it.

**The two under-counts are unchanged; only the verdict on them is wrong.**

1. **Interest since `lastUpdate` is excluded** — the price of keeping the
   proposer's IRM off the read that prices a mint. `MorphoSupplyStrategy.
   undeliveredValue()` values the position over Morpho's RAW stored market
   totals (`_ownRaw`), with zero external calls, because the accruing read
   (`expectedSupplyAssets`) calls `IIrm(marketParams.irm).borrowRateView` and
   `_initialize` binds nothing about that address — an IRM whose view burns past
   the vault's `_PROBE_GAS` cap would fail the read entirely and price mints as
   if there were no residue at all, which is finding #3 restored whole.
2. **The capital clamp truncates yield above the ceiling** — same direction,
   bounded by whatever the position earned above its principal ceiling.

**MEASURED, on the live Robinhood fork, in
`test/integration/strategies/MorphoSupplyVaultE2EFork.t.sol`.** Two tests there
are deliberately red and are the finding, not breakage:

- `test_e2e_residue_pricedLockedAndSweptExactlyOnce` measures the gap directly.
  On a 4,000 USDG residue the probe quoted `3,999.999999` against Morpho's own
  view accrual of `4,000.142747` — short by `142,748` (units of 1e-6 USDG),
  about 0.36 bps of the position. `collectResidue` then delivers the true value,
  so exactly that much more arrives than was priced.
- `test_e2e_residueSkim_isolatedAgainstTheNoAttackerCounterfactual` establishes
  that the gap is a TRANSFER rather than yield, by running the identical
  settlement with and without the attacker off one `snapshotState`. Honest LPs
  alone: `19,999,868,772`. Honest LPs with the attacker present:
  `19,999,840,222`, i.e. `-28,550`. Attacker: `+28,549`. Conservation to one
  unit of share-math rounding.

**The identity is exact**: gain = (the minter's share of the post-mint pool) x
(the under-count). 5,000/25,000 = 20%, and 20% x 142,748 = 28,550 — which is
what the honest LPs lost, to the unit. Pre-#243 the same test measured +952 USDG
on the same setup, so #243 shrank it ~34,600x. It did not change its sign.

**BOTH DOORS LEAK, IN THE SAME PROPORTION.** The tempting reading — that the
instant path is fixed and only the queued path is exposed — is wrong: a queued
claim routes through `VaultWithdrawalQueue.claim` → `previewDeposit`, which
converts LIVE against `depositNav()` exactly as an instant `deposit` does, and
reads no stamp at all. The same test file measures the instant door at
`+6,797` on a 1,000 USDG deposit into a ~21,000 pool, and
`142,748 x 1,000/21,000 = 6,797.5`. One under-count, two entrances.

**Bounded, and the bound is the whole under-count.** A minter approaching 100%
of the pool captures at most all of it. It grows with the residue's size and
with the time the position sits unaccrued, so it is not a constant — it is
small on a market that accrues often and larger on one that does not.

### What would actually close it

The probe has to accrue without routing through an address the proposer chose.
Three shapes, in the order they should be tried:

1. **Vendor the rate math.** The repo already vendors Morpho's view accrual
   (`MorphoBalancesLib`), and `test_e2e_navTracksLiveIrmAccrual_notAStaleSnapshot`
   pins the port against the singleton's own storage accrual to the wei. Vendor
   the AdaptiveCurve rate the same way and the projection needs no external call,
   which removes the gas-grief lever by construction rather than by declining to
   look.
2. **Pin the IRM.** Bind `marketParams.irm` at `_initialize` against an attested
   allowlist, then call the accruing read directly. Cheaper to write, but it
   moves a safety property into registry curation and makes the template refuse
   markets it can otherwise serve.
3. **Bound the gap from above.** Add a call-free ceiling on the unaccrued
   interest (max rate x elapsed) instead of zero, staying inside the existing
   `min(capitalSnapshot, effectiveMaxCapital)` clamp so a mint can still never be
   floored to zero shares.

**NOTE THE DIRECTION, because non-negotiable #3 reads the other way and is
written for a different figure.** "Bias low, always" is correct for a
`totalAssets()`-style number that also prices redemptions: over-counting there
pays out value that may never arrive. `depositNav()` is read by nothing but
`previewDeposit` / `previewMint`, and on a deposit-only figure the asymmetry
argument above applies instead — over-counting makes the depositor receive FEWER
shares and costs only them, while under-counting dilutes the incumbents. On this
figure specifically, the safe bias is HIGH, bounded by the clamp. Option 3 is
the only one of the three that depends on getting that right; 1 and 2 are
corrections rather than biases, and are preferable for exactly that reason.

---

## (b) The underpayment — CLOSED, PR #245

### The mechanism

Pay the leaver in two parts, and never write a guessed number into the ledger.

- **Senior floor, now.** Today's float-only stamp: fully backed, always payable,
  byte-for-byte unchanged. This is exactly what a redeemer receives today, and it
  is the floor they can never fall below.
- **Junior top-up, as money actually arrives.** Record what FRACTION of future
  arrivals the exiting cohort is owed — `q = the pid's queued-redeem shares /
  total shares at stamp`. When `collectResidue` delivers real assets, split them
  `q : (1-q)` between that cohort and the staying LPs. The cohort claims their
  slice once it has landed.

If nothing ever arrives, they keep the floor — never worse than today, never
stranded behind a promise the vault cannot keep. Nothing is ever valued, so a
bias-high over-count is unrepresentable.

### Where the money lives: the QUEUE, not the vault's reserve

The cohort's slice is **transferred to `VaultWithdrawalQueue`** on arrival, and
paid out from there.

This is the load-bearing simplification. The queue is already an asset custodian
(it holds escrowed deposits), so parking the cohort's share there needs no new
custody surface — and critically it avoids threading the top-up through
`_reservedAssets`, which is the number that gates instant exits and blocks the
next proposal from deploying float. Adversarial review flagged that integration as
the highest bug-risk surface in the whole design: saturating subtractions,
duplicate release paths, and an invariant that must hold across permissionless
claims arriving in any order.

Assets sitting in the queue are simply not in the vault's balance, so they do not
lift the stayers' price — which is correct, because they are not the stayers'.

### Required properties

- **Checked subtractions.** Every decrement reverts on underflow. The existing
  queue code has a saturating-subtract pattern (`reserved > release ? … : 0`) that
  would hide exactly this class of bug; the new paths must not copy it.
- **One release path.** All payouts funnel through a single internal function so
  the same money cannot be freed twice — the final-claim dust release and any
  later close are the two that would otherwise collide.
- **Frozen denominator.** The cohort's share count is snapshotted at the stamp and
  never re-read from the live counter, which floor claims decrement.
- **Arrivals only.** A cohort can never be paid more than
  `floor + its share of what physically arrived`.

### Invariants, now asserted

```
∀pid: paidToCohort(pid) <= floorPaid(pid) + arrivalsReceived(pid)
∀pid: Σ unclaimed cohort entitlements <= assets the queue holds for that pid
Σ arrivalsReceived(pid) <= assets that pid's clone actually pushed in
a cohort with zero queued redeems routes 100% of an arrival to the stayers
```

The first two are structural rather than merely tested. `cohortShare <= arrival`,
so a split never spends pre-existing float — the senior leg cannot be starved.
And `Σ(request amounts) == the frozen cohort share count` holds exactly, because
a redeem `cancel` reverts once the pid is stamped: no request in a stamped cohort
can vanish. With floor-rounding that makes `Σ entitled <= arrived` a property of
the code, not of the fuzzer's luck.

### Residual, accepted

`ConcentratedLiquidityStrategy`'s `otherToken` / LP / non-asset-collateral legs
are recovered by `releaseUnconvertible` in a token the vault cannot attribute in
asset terms, so the cohort under-recovers on that leg specifically. Counting it
would require the oracle machinery non-negotiable #1 forbids.

---

## What shipped

Built in the order below, each step landing green before the next began.

1. **Queue-side round record.** `stampSettlement` freezes `_pidCohortShares` /
   `_pidCohortDen` for the settling pid, and `_pidArrived` accumulates that
   pid's arrivals. Per-pid rather than global, so one cohort's residue coming
   home can never enlarge another's entitlement.
2. **Split at arrival.** `collectResidue` routes the cohort's fraction to the
   queue via `creditCohort` and emits `CohortShareRouted`; the remainder stays
   in the vault and lifts the stayers' price.
3. **`claimRemainder(requestId)`.** Permissionless, idempotent, a no-op rather
   than a revert when nothing is owed. Shares `_entitlementOf` with
   `claimableRemainder` so the view and the mutator cannot drift.
4. **Invariants.** `INV-Q5` pins
   `balanceOf(queue) >= cohortAssets + pendingDepositAssets`, plus unit coverage
   for the zero-cohort case, interleaved two-pid arrivals, over-delivery, and a
   depositor priced inside the settle-to-arrival window.

### The bug this build order did NOT prevent

Worth recording, because it is the same shape the review history below warns
about and the build order gave no protection against it.

Pricing a mint has to exclude the cohort's slice, or a window depositor is
charged for money routed to somebody else — finding #3's own shape, flipped onto
the depositor. That netting was written and it was correct, but it ran at the
TOP of `onProposalSettled`, before `stampSettlement` froze the fraction it
depends on. It read a cohort of zero, subtracted nothing, and stored the gross
figure. Every direct test of the netting passed, because in isolation the
function is right; only a test driving the whole settlement path could see it.

The fix is ordering, not arithmetic — and the reverse dependency had to be
proven before moving the call: the stamp reads `totalAssets()` and
`_pricingSupply()`, neither of which the residue record touches. That reasoning
lives in the source so it is not re-derived.

**Generalise:** a value derived from state that some other call in the same
transaction establishes reads as zero until that call runs, and a helper that
degrades to a neutral value on a failed read makes it SILENT — "not written
yet" and "read failed" are indistinguishable. Prove the order; never infer it
from a passing test.

Grep `test/` stubs for every new cross-contract selector and patch them in the
SAME commit — the repo has been bitten by this four times.

## Exploration record

Two design workflows and a premortem produced the shape above. External review
confirmed the general approach ships elsewhere — MetaMorpho prices vault-asset
positions with no oracle, defended purely by denomination-in-kind; ERC-7540
locates the fix at the fulfillment price; Yearn's profit-locking is incompatible
with a permissionless sweep; and no production precedent exists for trustless
live-portfolio NAV, which is why the live case is never valued here.

Four review rounds on PR #243 each found a real defect in the attack-half fix.
Every one was the same mistake shape: a mechanism's form was changed and the new
form reasoned about in isolation, rather than against what the old one was
quietly doing. That is the risk to watch when building (b), where the same
substitution happens again.
