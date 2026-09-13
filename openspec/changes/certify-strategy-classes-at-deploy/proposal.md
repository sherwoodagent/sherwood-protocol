# Certify strategy classes as part of the deploy ceremony

## Why

A protocol deployed by the documented ceremony cannot execute a single strategy
proposal.

`SyndicateVault._guardBatchCalls` gates every governor batch on two registry
axes, and a strategy clone satisfies neither out of the box:

- callee axis — `ITierRegistry.isCallableTarget(target)` (`src/SyndicateVault.sol:1221`),
  refusing the clone as a batch target with `DisallowedBatchCallee`;
- funds axis — `ITierRegistry.isAdapterAllowed(to)` (`:1278`, `:1317`), refusing
  the clone as a recipient of vault capital with `DisallowedTransferTarget`.

`TierRegistry` already carries the mechanism that fixes this once rather than
once per proposal: clones of one template share an `EXTCODEHASH`, so a CLASS
grant covers every clone that will ever exist. Nothing in `script/` performs it
— `grep -rln "proposeClassCertification\|certifyClass\|setClassAllowed" script`
returns nothing, and only two test files exercise the API. So every deployment
to date ships with every strategy class uncertified, and the failure surfaces a
governance cycle later as a vault-level revert naming a clone address rather
than the missing deploy step.

The gap is not a missing line in an existing script. The grant is announce-then-
execute with a `certifyDelay` (default 3 days, floor 1 day) between the two, so
it cannot live inside a single deploy transaction and needs its own two-phase
script with its own slot in the runbook.

## What Changes

- **New `script/CertifyStrategyClasses.s.sol`** with two entrypoints. `propose()`
  announces a class certification for each eligible template against both
  selectors a governor batch names (`execute()`, `settle()`), pinning the
  template's live codehash. `finalize()`, run after `certifyDelay`, executes the
  grants and calls `setClassAllowed(template, true)` — the write that opens BOTH
  axes. Both phases skip cleanly with a RUNBOOK line when the deployer no longer
  owns the registry, and `finalize()` is re-runnable.
- **Risk parameters are stated, not derived.** `tier` and `extractableBoundBps`
  are what the governor turns into required guardian coverage, so they sit in a
  named constant block per template with their rationale, overridable by env,
  rather than being a number buried in a loop.
- **`MorphoSupplyStrategy` is excluded by construction.** It interrogates its
  Morpho singleton as its own validator, which disqualifies it under
  `docs/adapter-onboarding-checklist.md` §4b eligibility rule 1. It stays
  address-certifiable only.
- **`Deploy.s.sol` gains one RUNBOOK line** naming the step and the delay, so the
  ceremony is discoverable from the deploy output.

**BREAKING**: none. No `src/` change; the script is additive.

## Capabilities

### Modified Capabilities

- `deployment-docs` — the ceremony order requirement enumerates the scripts an
  operator runs. Running exactly those produces a protocol that cannot execute a
  proposal, so the class ceremony is added as a step with its delay stated.
