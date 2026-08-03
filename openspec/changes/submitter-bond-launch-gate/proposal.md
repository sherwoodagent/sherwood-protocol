# Document and pin the submitter-bond launch gate (issue #40)

## Why

`TierRegistry.submitterBondWood` has no slash path yet — the only exit is
`claimSubmitterBond`, which always returns the bond in full. Enabling a
non-zero bond before the guard-bypass slash exists (and before a court can
enforce a *disputed* slash, per #25) would impose a real cost on adapter
submitters for a warranty nobody can currently collect, on the exact
activity (certification throughput) the premortem ranks as a top-two launch
risk.

`submitterBondWood` already defaults to `0` and `script/Deploy.s.sol` never
calls `setSubmitterBondWood`, so the currently-deployed path is already
correct. This issue is about making that fact explicit and load-bearing —
documented, pinned by test, and defended by a deploy-script assertion — so a
future change to the deploy script or the setter's default cannot silently
enable an unenforceable bond.

## What changes

1. **Natspec on `submitterBondWood`** (`src/TierRegistry.sol`) stating the
   three-part gate from the issue: non-zero is inert as a warranty until (a)
   a guard-bypass slash path exists that can reach `_bonds`, (b) a court can
   enforce a *disputed* slash (Plan E), and (c) third-party submission volume
   exists for the bond to filter rather than merely deter.
2. **Deploy-script assertion** in `script/Deploy.s.sol`: after `TierRegistry`
   deployment, assert `submitterBondWood == 0` (the setter is never called in
   the script, so this should always hold — the assertion pins that fact
   rather than changing behavior).
3. **Pinning test**: `certify` with `submitterBondWood == 0` locks nothing and
   emits no `SubmitterBondLocked`.

## What does NOT change

- No slash mechanism is added — that is Plan C/E's scope, explicitly out of
  scope here per the issue.
- `submitterBondWood` stays a plain owner-settable `uint256`; no new "gate
  flag" state variable is introduced. The issue's item 2 ("write the gate
  down") is satisfied by documentation + the deploy assertion, not by new
  on-chain enforcement — adding an on-chain gate flag that blocks
  `setSubmitterBondWood` until the slash path exists would require the owner
  to somehow prove the slash path exists, which is not something a
  constructor-time or setter-time check can verify. That is a bigger design
  question the issue itself defers ("Revisit who posts it when the gate is
  met").

## Refs

- Issue #40
- Issue #25 (Plan D, disputed-challenge timeout — why the bond is
  unenforceable even once a slash function exists)
- Issue #27 (tier-2 envelope, noted as related but separate scope)
