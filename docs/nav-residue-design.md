# Counting strategy-held value in the vault's NAV (finding #3, Option B)

Status: **design only, not implemented.** Written after two failed attempts to
correct the settle price at the stamp; see PR #227 for why that site cannot work.

## The problem

`totalAssets()` counts only `balanceOf(vault)`. Value a strategy still holds —
a Morpho position at full utilization, collateral behind residual debt — prices
at **zero**. Two consequences:

- A queued depositor mints against a frozen price that excludes the residue,
  then `sweep()`s it in. Attacker-driven, atomic, riskless.
- A queued redeemer is **underpaid** by the same blindness. No attacker needed.

## Why the stamp cannot be fixed in place

`stampSettlement` derives the queue reserve as `mulDiv(redeemShares, num, den)`,
and `_availableFloat` is `balanceOf - reserve`. Raising `num` reserves assets the
vault does not hold, flooring instant exits for every LP. Capping `num` does not
help: the reserve scales with `redeemShares / den`, a ratio the caller does not
control. One number, two opposite requirements.

## THE CONSTRAINT THAT MUST SHAPE ANY IMPLEMENTATION

The vault deliberately prices off a frozen REALIZED figure. `VaultWithdrawalQueue`'s
header states it: the vault must "never mint or burn against an unrealized,
strategy-influenced NAV". Findings #2 and #3 are what pulling that lever looks
like — an attacker moves the strategy or its oracle, and the vault believes it.

So a NAV that counts live positions MUST answer: what stops a proposer moving the
valuation and re-pricing the whole vault? An implementation without an answer here
is strictly worse than the gap it closes.

Non-negotiables:

1. **Never value through a venue the proposal can trade.** The pool-quoted floor
   is exactly how finding #3 was exploited.
2. **Attested oracles only**, bound at init through the TierRegistry pairing that
   `PortfolioStrategy._requirePairedPriceSource` already enforces — never a
   proposer-supplied address checked against another proposer-supplied address
   (finding #4).
3. **Bias low, always.** An over-count mints against value that may never arrive;
   an under-count only under-prices. Every rounding and every unpriceable leg
   resolves downward.
4. **Degrade to the float-only figure**, never to a higher one, on any read
   failure. Same posture as the existing probes.
5. **Do not make it a settlement veto.** A strategy that cannot be valued must not
   be able to block settlement — that is the capital-hostage failure the
   deliverable-maximum design exists to avoid.

## The restamp route, and why it is NOT the plan

An earlier in-source note suggested: skip the stamp while `hasUndeliveredValue()`
holds, then add a permissionless `restamp(pid)`. Recorded here as REJECTED so it
is not rediscovered — it does not survive `VaultWithdrawalQueue`:

- `claim` requires `_lastStampedPid >= r.pid`. Skipping the stamp strands EVERY
  queued request for that pid — redeemers included — until a restamp lands.
- `stampSettlement` reverts `StampOutOfOrder` when `pid < _lastStampedPid`. If any
  later proposal settles first, `restamp(pid)` reverts PERMANENTLY and those
  requests are stranded for good. Strictly worse than the mispricing it fixes.
- `sp.stamped` reverts `AlreadySettled`, so restamping a stamped pid additionally
  needs `_reservedAssets` and `_stampedUnclaimedShares` unwound and re-added.

The narrowing below has none of these properties, which is why it is the
recommendation.

## Sketch

- `IStrategyDelivery.undeliveredValue()` already exists (PR #227) and is the right
  shape. Morpho reports exactly (loan token IS the vault asset, no oracle needed);
  CL reports partially and low.
- The open question is the LIVE case, not the settled one. A settled residue is a
  receivable and is safe to count. A live position is a mark to market and is the
  dangerous one.
- **Recommended narrowing:** count only positions denominated in the vault asset,
  where no price conversion is required at all. That covers the Morpho template
  fully and the CL template's 1:1 wrapper case, and needs no oracle — so
  constraint (1) and (2) are satisfied by construction rather than by policy.
  Legs needing a price conversion stay uncounted and keep the current
  under-pricing, documented.

That narrowing closes the attacker-driven deposit path AND the redeemer
under-payment for the templates that ship, without introducing an oracle into the
share price. It is materially smaller than a general NAV redesign and it is where
I would start.

## Not yet decided

- Whether `totalAssets()` changes, or only the settle-time stamp reads the wider
  figure. The former fixes redeemers; the latter is smaller but leaves them.
- Interaction with the high-water mark and the management-fee accrual base, both
  of which read `totalAssets()`.
- Whether `_availableFloat` should net out uncounted residue.
