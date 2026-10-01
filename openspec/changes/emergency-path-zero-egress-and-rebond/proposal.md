# Emergency path: zero egress budget, same-owner re-bond (audit 2026-10-01 V1-02, V1-03)

## Why

- **V1-02 (Medium).** `finalizeEmergencySettle` ran the owner-supplied batch with a net egress budget of
  `effectiveMaxCapital`. For a proposal with zero-cap legs (no coverage, no approver, no bond) that is
  `maxCapital`, up to 100% of TVL. Propose-time stake padding (the accepted NM 6.13 residual) makes the
  guardian veto unreachable, so an owner could send the vault's float to any address.
- **V1-03 (Medium).** A blocked emergency round burns the owner bond. The only route back to a funded slot,
  `rotateOwner` → `transferOwnerStakeSlot`, refused while a proposal was open, and the stuck proposal is
  open. A vault whose settlement leg is dead was then locked until a contract upgrade.

## What Changes

- `finalizeEmergencySettle` passes a net egress budget of `0`, measured across the whole batch. Vault float
  may leave inside the batch only if at least as much returns before it ends (a solvent repay the vault fronts
  and the redeemed collateral returns passes), and what the strategy returns may be passed on. Only an
  insolvent unwind needs funds sent to the strategy from outside the vault. The guardian-veto
  electorate is unchanged; it remains the control on redirecting returned capital.
- `rotateOwner` applies its two open-proposal gates only when `newOwner != currentOwner`. The same owner can
  re-post a bond through the existing prepared-stake and consent flow while a proposal is open. Rotation to
  any other address mid-proposal is still refused. No new function.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `syndicate-governor`: the emergency settlement budget and the factory's `rotateOwner` lifecycle gate.

## Impact

- `src/GovernorEmergency.sol` (one argument), `src/SyndicateFactory.sol` (gates scoped to a different owner).
- No storage change, no new surface, no deploy-script change. Existing governors pick up the budget through
  the beacon upgrade; the factory change ships with the factory upgrade.
- The open changes `structural-batch-rules` and `per-call-capital-declarations` carried the old text for the
  same two requirements; their deltas are aligned here (zero net egress; same-owner rotation exempt), so the
  sync order does not matter.
- Same-owner rotation still calls `SyndicateVault.rotateOwnership`, which drains the agent set; the owner
  re-registers before proposing again.
