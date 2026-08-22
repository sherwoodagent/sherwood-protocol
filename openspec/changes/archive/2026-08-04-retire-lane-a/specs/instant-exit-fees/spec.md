# instant-exit-fees (delta)

The capability is retired whole with Lane A (issue #54). Every charge it defines —
crystallization of accrued fees on instant exit, and the early-exit penalty — exists
only on the mid-proposal instant-exit path, which is deleted: mid-proposal exits are
queue-only, and queue exits pay through the settle price with no separate charge (the
spec itself says so in "A queue exit pays through the settle price and owes no
crystallization"). Reachability was verified in both directions in design.md
("Crystallization reachability"): no write, read, or charge in this capability can
fire without `_laneState().laneA == true`, so keeping any of it would ship a fee
mechanism that can never fire. The single general requirement, "Deposits are not
charged a fee", is relocated verbatim to `syndicate-vault` (see that delta's ADDED
section) — it was never Lane-A-specific.

At sync/archive time this spec ends up with zero requirements: delete
`openspec/specs/instant-exit-fees/spec.md` entirely rather than leaving an empty
shell. V2 reintroduces the capability together with the lane it prices.

## REMOVED Requirements

### Requirement: An instant exit crystallizes the exiting shares' accrued fees

**Reason**: Crystallization (`_crystallizedMgmt`/`_crystallizedPerf`, written only in
`_withdraw` under `laneAAtEntry`) is unreachable without Lane A; deleted with it.
**Migration**: None on-chain (no vault proxy is live; the counters are zero on every
deployed lineage by construction).

### Requirement: Exit timing is fee-neutral

**Reason**: With no instant exit mid-proposal there are no two timing paths to keep
neutral: every mid-proposal exit holds to settlement via the queue and pays through
the settle price. The property is vacuously preserved, not weakened.
**Migration**: None.

### Requirement: Crystallized fees are paid to the correct recipients at the next settlement

**Reason**: Nothing crystallizes, so there is nothing to distribute. The two governor
release sites (`consumeCrystallizedMgmt` in `_chargeManagementFee`,
`consumeCrystallizedPerf` in `_chargePerformanceFee`) are deleted; ordinary fee
distribution and its fail-open escrow path are untouched.
**Migration**: None.

### Requirement: Crystallized fees are not charged again at settlement

**Reason**: The netting exists to avoid double-charging amounts crystallized on exit;
with crystallization gone the settlement charge is simply the full accrual, which is
the same number (the netted term was identically zero).
**Migration**: None.

### Requirement: A partial exit does not advance the high-water mark

**Reason**: The mark could only be tempted to move by an exit-time performance
crystallization, which is deleted. The surviving rule — the mark advances only at
settlement — is owned by the performance-fee capability and is unchanged.
**Migration**: None.

### Requirement: An instant exit is charged a separate early-exit penalty

**Reason**: The penalty (`instantExitFeeBps`, `_exitPenalty`) applies only to the
strategy-pull portion of a mid-proposal instant exit; the vault no longer pulls from
strategies at all (`_pullFromStrategy` deleted; exits beyond float revert
`QueueReserveBreached`).
**Migration**: None. `setInstantExitFeeBps`, `MAX_INSTANT_EXIT_FEE_BPS`, and
`InstantExitFeeUpdated` are removed from the vault surface.

### Requirement: The two exit charges apply in a fixed order

**Reason**: Both charges are deleted; there is no order to fix.
**Migration**: None.

### Requirement: Quoted proceeds match delivered proceeds

**Reason**: The `previewRedeem`/`previewWithdraw` overrides and `previewExitFees`
exist only to quote the two deleted charges. With them gone the vault falls back to
stock ERC-4626 previews, which match delivered proceeds by construction.
**Migration**: None; the preview overrides are removed from `ISyndicateVault`.

### Requirement: Deposits are not charged a fee

**Reason**: Not retired — relocated. This is the one requirement in the capability
with no Lane A dependency; it moves verbatim to `syndicate-vault` (ADDED there in
this change) so it survives the capability's deletion.
**Migration**: See the `syndicate-vault` delta in this change.
