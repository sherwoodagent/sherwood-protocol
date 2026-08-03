# Design: VeniceInferenceStrategy adapter allowlist (issue #155)

## Decision 1 — Two call sites, not one

`PortfolioStrategy` has a single `swapAdapter_`. `VeniceInferenceStrategy` has
two addresses that receive approvals for different tokens: `aeroRouter_`
(spends `asset`, only when `needsSwap()`) and `sVVV_` (spends `vvv`, always).
Both get an independent `_requireAllowedAdapter` call in `_initialize`, in the
same conditional shape the existing validation already uses:

```solidity
if (p.asset != p.vvv) {
    if (p.aeroRouter == address(0) || p.aeroFactory == address(0)) revert ZeroAddress();
    ...
    _requireAllowedAdapter(p.aeroRouter);
}
_requireAllowedAdapter(p.sVVV);
```

`aeroFactory` and `weth` are never approval targets — only `aeroRouter` and
`sVVV` are. `agent` receives `stake()`'s recipient argument, not an approval;
out of scope (same reasoning `PortfolioStrategy` applied to its non-adapter
addresses).

## Decision 2 — Reuse the exact helper triple, not a shared library

`_requireAllowedAdapter` / `_isAdapterAllowed` / `_readAddress` and the
`ITierBindingPath` interface are duplicated verbatim from `PortfolioStrategy`
rather than extracted to a shared base/library. `BaseStrategy` is the actual
shared ancestor and adding cross-strategy coupling there for a 3-function,
~25-line helper is not worth the risk of touching a file every strategy
depends on. `PortfolioStrategy`'s own implementation set this precedent
(duplicated from PR #104 rather than referencing it), so this stays
consistent with the codebase's existing pattern here rather than introducing
a new one.

## Decision 3 — Degrade table (identical to PortfolioStrategy's)

| Walk state | Behavior |
|---|---|
| Codeless vault | skip (return, no revert) |
| `vault().governor()` returns 0 | skip |
| Governor has no `governor()`-shaped getter (or none at all) | skip — treated as unresolved by the length/success check |
| `governor().tierRegistry()` returns 0 | skip |
| Registry resolved, `isAdapterAllowed` reverts or returns malformed data | **fail closed**: `AdapterNotAllowed` |
| Registry resolved, `isAdapterAllowed` returns `false` | **fail closed**: `AdapterNotAllowed` |
| Registry resolved, `isAdapterAllowed` returns `true` | pass |

No new degrade cases beyond what `PortfolioStrategy` already established;
this table is reproduced here only so the test plan below cites a single
source per scenario without cross-referencing another change's design doc.

## Test plan

New file `test/VeniceInferenceStrategyAdapterAllowlist.t.sol`:

1. Non-allowlisted `aeroRouter` refused at init (`needsSwap()` path),
   `AdapterNotAllowed(aeroRouter, registry)`.
2. Non-allowlisted `sVVV` refused at init (direct path, `asset == vvv`, so
   `aeroRouter` is never touched — isolates the `sVVV`-only check).
3. Non-allowlisted `sVVV` refused at init on the swap path too (both checks
   fire independently; assert the FIRST one — `aeroRouter` — reverts before
   `sVVV` is ever read, since `_initialize` checks it first).
4. Both allowlisted: init succeeds unchanged (regression guard on the
   existing happy path).
5. Direct path (`asset == vvv`, no swap needed) with `sVVV` allowlisted:
   init succeeds without ever evaluating `aeroRouter`'s allowlist status
   (uninitialized/zero `aeroRouter` is legal on this path per existing
   `ZeroAddress` logic — confirm the allowlist check does not spuriously run).
6. Unresolved walk skips (one fixture reused across both call sites): codeless
   vault.
7. Resolved-but-unreadable registry fails closed for both call sites.

Existing `test/VeniceInferenceStrategy.t.sol` (if present) is the blast-radius
check — any fixture that inits without allowlisting `aeroRouter`/`sVVV` will
start reverting and needs `setAdapterAllowed` added to its setUp, mirroring
`PortfolioStrategy`'s PR #165 fork-suite fix (task 6 there).
