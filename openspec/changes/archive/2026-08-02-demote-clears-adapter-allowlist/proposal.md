# Demotion auto-clears the adapter allowlist (issue #77, Option 3)

## Why

`TierRegistry._demote` (`src/TierRegistry.sol:270-280`) deletes the tier
config and starts the bond-release timelock, but never touches
`_adapterAllowed` (`:74`) — the only writer of that mapping is the
owner-only `setAdapterAllowed` (`:310-313`). Two demotion paths reach
`_demote` **without any owner action**: permissionless `poke` (`:263`,
fires on any codehash drift) and `demoteByChallenge` (`:256`, the
ChallengeGame's role, called on a passed challenge from
`ChallengeGame.sol:1141`). After either, the adapter keeps the standing
right — via `SyndicateVault._guardBatchCalls` consulting
`isAdapterAllowed` at `SyndicateVault.sol:573` — to appear as the
spender/recipient of value-moving ERC20 calls (`approve` /
`increaseAllowance` / `transfer` / `transferFrom`-out) in governor
batches. An adapter that was just convicted in a challenge, or whose
bytecode was just swapped under it, is exactly the address that must not
retain a standing transfer permission; tier 2 raises its coverage price
but is a price, not a prohibition.

The repo owner has decided **Option 3** on issue #77: clear the
allowlist inside `_demote` (on-chain, atomic with the demotion) AND keep
the off-chain watcher on `TierDemoted` / `AdapterDemotionFailed` as the
complement, because the `try/catch` at `ChallengeGame.sol:1141` means a
*reverted* demotion fires no `_demote` at all — that case is
structurally uncoverable on-chain and remains the watcher's job.

## What Changes

- `TierRegistry._demote` additionally deletes `_adapterAllowed[target]`,
  emitting the existing `AdapterAllowedSet(target, false)` event when
  (and only when) the entry was set, so all three demotion paths (owner
  `demote`, `demoteByChallenge`, `poke`) revoke the transfer allowlist
  atomically with the certification.
- **Deliberately over-broad**: certification is keyed `(target,
  selector)`; the allowlist is keyed by bare `address`. Demoting ONE
  selector de-allowlists the WHOLE adapter. This is the chosen,
  conservative direction of error — recovery is a single owner
  `setAdapterAllowed(adapter, true)` call — and is pinned by natspec and
  by a test so it is not "fixed" back to per-selector later.
- Re-certifying (`certify`) does **not** restore the allowlist: the two
  gates stay independent writes; re-allowlisting remains an explicit
  owner decision.
- `docs/adapter-onboarding-checklist.md` §4 is updated: the watcher's
  job narrows from "react to every `TierDemoted`" to "react to
  `AdapterDemotionFailed` (the on-chain clear cannot fire) and reconcile
  drift"; the de-onboarding order in §4 stays documented as
  allowlist-off-first, now noting that `demote` also clears the
  allowlist on-chain.

No interface change: `ITierRegistry` is untouched; no `SyndicateVault`
change (the sibling issue #93 branch editing `_guardBatchCalls` is not
affected).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tier-policy`: the "Demotion" requirement gains "and deletes the
  adapter's allowlist entry, emitting `AdapterAllowedSet(target, false)`
  if it was set"; the "Adapter allowlist is a separate axis from tiers"
  requirement gains the one deliberate coupling (demotion clears, but
  certification never sets) and the over-broad-by-design clause.
- `operator-docs`: the checklist's §4 watcher expectation narrows to the
  `AdapterDemotionFailed` case and drift reconciliation.

## Impact

- `src/TierRegistry.sol` — `_demote` (one `delete` + conditional emit)
  and natspec on `_demote`, `certify`, and the allowlist section.
- `test/TierRegistry.t.sol` — new tests: clear via all three demotion
  paths, re-certify-does-not-restore, multi-selector over-broad clear
  pinned as intended, owner-re-allowlist recovery.
- `docs/adapter-onboarding-checklist.md` — §4 rewrite of the
  "`_demote` does not touch the allowlist" subsection (now false) and
  the operational-consequence paragraph.
- No test currently demotes-then-relies-on-the-allowlist, so no
  existing test breaks (verified by sweep; see design.md).
