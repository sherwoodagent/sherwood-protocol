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

- `finalizeEmergencySettle` passes a net egress budget of `0`. The batch may pass on what the strategy
  returns in the same batch (net outflow is measured across the batch) but cannot move vault float. Funds an
  unwind needs, such as a repay, are sent to the strategy from outside the vault. The guardian-veto
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
- Open changes `structural-batch-rules` (emergency budget = `effectiveMaxCapital`) and
  `per-call-capital-declarations` (unconditional `rotateOwner` gates) carry the old text for the same two
  requirements; reconcile them or archive them before this change, or a later sync regresses it.
- Same-owner rotation still calls `SyndicateVault.rotateOwnership`, which drains the agent set; the owner
  re-registers before proposing again.
