# Design — demotion auto-clears the adapter allowlist

## Context

See `proposal.md` — Why. Verified state on `main` (20ca23f):

- `TierRegistry._demote` — `src/TierRegistry.sol:270-280`. Deletes
  `_configs[k]`, starts the bond release timelock once, emits
  `TierDemoted`. Never touches `_adapterAllowed`.
- `_adapterAllowed` — `src/TierRegistry.sol:74`. Sole writer:
  `setAdapterAllowed`, `onlyOwner`, `:310-313`, emitting
  `AdapterAllowedSet` (`:105`, declared; `:312`, emitted).
- Demotion entrypoints — exactly three, all routing through `_demote`:
  owner `demote` (`:248-250`), role-gated `demoteByChallenge`
  (`:256-259`, `authorizedDemoter` only, called best-effort from
  `ChallengeGame.sol:1141` inside `try/catch`), and permissionless
  `poke` (`:263-268`, gated on codehash drift). No other function
  deletes `_configs`; `certify` (`:191-222`) only grants. There is no
  owner-facing demotion path that routes around `_demote`.
- Consumer — `SyndicateVault._guardBatchCalls`,
  `src/SyndicateVault.sol:550-577`; the `isAdapterAllowed` staticcall is
  at `:573`. The surviving allowlist entry grants: the right to appear
  as spender/recipient of `approve` / `increaseAllowance` / `transfer` /
  `transferFrom`-out inside any governor batch.

## Goals / Non-Goals

**Goals**: revoke the transfer-allowlist permission atomically with every
persisted demotion; keep the change contained to `TierRegistry.sol`,
its tests, and the operator doc.

**Non-Goals**:
- No `SyndicateVault` change. A sibling branch is concurrently editing
  `_guardBatchCalls` (`SyndicateVault.sol:550-577`) for issue #93; this
  change deliberately needs nothing there, so there is no conflict.
- No `ITierRegistry` interface change (`isAdapterAllowed` signature
  unchanged).
- No per-selector allowlist. Explicitly rejected — see Decision 3.
- No change to the ChallengeGame `try/catch` — see Decision 5.

## Decisions

### 1. The clear lives in `_demote`, not at the call sites

`_demote` is the single convergence point of all three demotion paths
(owner `demote`, `demoteByChallenge`, `poke`). Placing the `delete` there
makes "demotion ⇒ allowlist cleared" an invariant of the function rather
than a discipline of its callers: a future fourth demotion entrypoint
gets the clear for free, and no call site can forget it. Call-site
placement was considered and rejected — it would triplicate the line
today and silently miss any path added tomorrow, which is precisely how
the current gap arose (allowlist added as "a separate axis" after
demotion semantics were settled).

Shape:

```solidity
function _demote(address target, bytes4 selector) private {
    bytes32 k = key(target, selector);
    delete _configs[k];
    // ... bond release timelock as today ...
    if (_adapterAllowed[target]) {
        delete _adapterAllowed[target];
        emit AdapterAllowedSet(target, false);
    }
    emit TierDemoted(target, selector);
}
```

### 2. Reuse `AdapterAllowedSet`, emitted only on an actual clear

The allowlist already has exactly one observable channel:
`AdapterAllowedSet(address indexed adapter, bool allowed)`
(`src/TierRegistry.sol:105`). Off-chain indexers, the checklist's §3
drift sweep, and any watcher already reconcile allowlist state from that
event. Emitting it from `_demote` means the auto-clear flows through the
normal channel with zero indexer changes; a distinct
`AdapterAllowedCleared`-style event was considered and rejected because
it would force every consumer to union two event types to know the
current allowlist state, for no added information.

Guarded emission (`if (_adapterAllowed[target])`) keeps the channel
truthful: demoting a never-allowlisted target — the common case for
every existing E2E fixture — emits no phantom `AdapterAllowedSet(x,
false)` for an entry that was never true. The `TierDemoted` event pairs
with an `AdapterAllowedSet` only when state actually changed.

### 3. Over-broad by design: one selector's demotion clears the whole adapter

Certification is keyed `key(target, selector)`; the allowlist is keyed
by bare `address`. The clear therefore de-allowlists the WHOLE adapter
when any one of its selectors is demoted, even if other selectors remain
certified. This is the accepted tradeoff, chosen deliberately: for a
safety backstop, de-allowlisting more than strictly necessary is the
correct direction of error. The cost is one owner
`setAdapterAllowed(adapter, true)` call (a stuck batch needing a
governance transaction — recoverable); the alternative cost is vault
funds approved to an adapter that was just convicted or just changed its
code. The `_demote` natspec MUST state this so a future reader does not
"fix" it back to per-selector; the multi-selector test pins it.

### 4. Re-certification does NOT restore the allowlist

`certify` is untouched. Restoring the allowlist on re-certification
would silently re-grant a payment permission (Gate B, reachability) as a
side effect of a pricing action (Gate A, certification) — collapsing the
dual-gate the onboarding checklist is built around, and re-opening the
funds path without the owner ever deciding to. The coupling is one-way
and fail-closed: demotion clears, nothing but an explicit
`setAdapterAllowed(adapter, true)` restores. Pinned by the
re-certify-does-not-restore test.

### 5. The watcher stays (why Option 1 alone was rejected)

`ChallengeGame._settle` calls `demoteByChallenge` inside `try/catch`
(`src/ChallengeGame.sol:1141-1145`). If that call REVERTS — e.g. the
`authorizedDemoter` role was rotated away while the challenge was live —
no `_demote` runs, so no auto-clear can fire; the only signal is
`AdapterDemotionFailed`. This case is structurally uncoverable on-chain:
the clear is a side effect of a demotion that did not happen. Likewise
the lazy path: `tierOf` reporting tier 2 on codehash mismatch writes no
state until someone calls `poke`. Both remain the watcher's job — which
is why the decision is Option 3 (auto-clear AND watcher), not Option 1
alone. The watcher's job NARROWS to: react to `AdapterDemotionFailed`
(owner `demote`, which now also clears, or direct `setAdapterAllowed(x,
false)`), and keep running the §3 drift sweep for lazy demotions.

## Test/script blast radius (full sweep, verified)

Sweep of `test/` and `script/` for `demote(`, `demoteByChallenge`,
`poke(`, `setAdapterAllowed`, `isAdapterAllowed`, `_demote`:

**No existing test or script breaks.** No test demotes and then relies
on the adapter staying allowlisted, and none asserts allowlist state
after a demotion. Per file:

- `test/TierRegistry.t.sol` — all `demote`/`poke`/`demoteByChallenge`
  calls (`:125-472`) run against targets that were never allowlisted
  (the file never calls `setAdapterAllowed`), so the clear is a no-op
  and the guarded emission fires nothing. The `vm.expectEmit` uses at
  `:74, :123, :368-378` tolerate interleaved extra events by forge
  semantics and are unaffected either way. New tests are ADDED here.
- `test/governor/TierResolution.t.sol` — allowlists at `:111-112`;
  its demotions are `vm.etch` codehash swaps (`:259`) and re-`certify`
  (`:287`), neither of which calls `_demote`. Unaffected.
- `test/integration/TierEndToEnd.t.sol` — allowlists at `:141`; its
  only demotion is `vm.etch` (`:271`, TierRegressed path). Unaffected.
- `test/vault/SelectorGuard.t.sol` (`:78`) and
  `test/GovernorCoverageGates.t.sol` (`:607-608`) — allowlist, never
  demote. Unaffected.
- `test/ChallengeGame.t.sol` — uses `MockChallengeTierRegistry`
  (`:228-251`), not the real registry; asserts only `demoteCount`.
  Unaffected (the mock needs no mirroring — nothing asserts allowlist).
- `test/ChallengeEndToEnd.t.sol`, `test/TokenCourtEndToEnd.t.sol`,
  `test/SlashGasCeiling.t.sol` — real `TierRegistry` +
  real `demoteByChallenge` through the game, BUT the batches call
  `adapter.poke()` (not a value-moving ERC20 selector) and the adapter
  is never allowlisted (`ChallengeEndToEnd.t.sol:45` documents this).
  Post-demotion assertions are on `tierOf` only. Unaffected.
- `script/` — no `setAdapterAllowed`/demotion calls anywhere (only a
  comment in `DeployTokenCourt.s.sol:178`). Unaffected.

The feared case — an end-to-end challenge test that demotes and then
executes a value-moving batch through the same adapter — does not exist
in the current tree. The implementation must still run the full suite to
confirm.

## Risks / Trade-offs

- [Over-broad clear stalls a multi-selector adapter's live proposals]
  → intended; recovery is one owner `setAdapterAllowed` call; natspec +
  pinned test prevent regression to per-selector.
- [Griefing via permissionless `poke`] → `poke` requires an ACTUAL
  codehash change; an attacker cannot force a clear on an honest,
  unmutated adapter. If the codehash did change, clearing is the
  desired outcome, whoever calls it.
- [Docs drift: checklist §4 currently states "`_demote` does not touch
  the allowlist"] → that subsection is rewritten in the same change
  (tasks.md); its line references (`:287` etc.) are re-verified against
  the post-change file.
- [Concurrent PRs] → verified `git diff origin/main...` for #104
  (`feat/lane-a-enablement`) and #88 (`spec/wood-twap-ceiling`): neither
  touches `src/TierRegistry.sol`, `test/TierRegistry.t.sol`, or
  `docs/adapter-onboarding-checklist.md`. #88 touches
  `ChallengeEndToEnd`/`TokenCourtEndToEnd`/`SlashGasCeiling`/
  `GovernorCoverageGates` tests (~8-9 lines each, oracle wiring) — no
  file overlap with this change's edits. #104 touches
  `src/SyndicateVault.sol`, which this change does not.

## Migration Plan

Pure behavior addition inside one private function; no storage layout
change, no interface change, no deploy-script change. Ships with the
next `TierRegistry` deployment; existing deployments keep the watcher
procedure (checklist §4) as the sole mechanism until redeployed.
