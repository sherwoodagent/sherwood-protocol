# Fix adapter-allowlist lazy self-heal against metamorphic redeploy (issue #137)

## Why

Pashov-panel finding on merged PR #129 (pre-existing on `main`, not
introduced there; 2-agent convergence). `TierRegistry.isAdapterAllowed`
(`src/TierRegistry.sol:372-374`) is a plain storage read of
`_adapterAllowed` with no codehash cross-check, unlike its sibling `tierOf`
(`src/TierRegistry.sol:93-99`), which verifies the target's live
`EXTCODEHASH` against the certification-time snapshot on every read and
lazily reports tier 2 on mismatch.

Consequence: an adapter whose bytecode is swapped underneath its address
(metamorphic CREATE2 + SELFDESTRUCT redeploy, or any path that changes the
codehash) keeps a standing `true` on the allowlist until somebody happens to
call the permissionless `poke` — and `poke` is reachable only for a
`(target, selector)` that was actually certified (`NotCertified` guard,
`src/TierRegistry.sol:291`), so for an allowlisted-but-uncertified adapter
no permissionless path can ever close the window.

This matters more than the sibling lazy-demotion issues because of WHO
consumes the read: `SyndicateVault._guardBatchCalls`
(`src/SyndicateVault.sol:667`) is the sole consumer in `src/`, and it is the
gate on the spender/recipient of value-moving ERC20 calls (approve /
increaseAllowance / transfer / transferFrom-out) in every governor batch —
the primary fund-movement path of every syndicate vault, live today. The
guard does no `tierOf` or codehash check of its own. The existing test
`test_poke_clearsAdapterAllowlist` (`test/TierRegistry.t.sol:532-546`)
demonstrates the stale-`true` window directly: it etches new bytecode over
an allowlisted adapter and asserts `isAdapterAllowed` still returns `true`
before `poke` (line 538) — pinning the bug without flagging it.

Attack path: owner allowlists adapter `A`; `A`'s operator redeploys
malicious bytecode at the same address; nobody pokes; a governor batch
containing `approve(A, big)` executes; the guard reads the stale `true`;
vault funds are approved to arbitrary bytecode.

## What Changes

- **Snapshot the adapter's codehash at grant time**: a new
  `mapping(address adapter => bytes32) private _adapterAllowedCodehash` in
  `TierRegistry`, written by `setAdapterAllowed(adapter, true)` with the
  adapter's normalized live codehash (`bytes32(0)` and `keccak256("")` both
  normalize to `bytes32(0)` — "no code"). Every grant (re)writes the
  snapshot: re-granting IS the owner's re-attestation after a legitimate
  upgrade.
- **Self-heal on every read**: `isAdapterAllowed(adapter)` returns `true`
  only when `_adapterAllowed[adapter]` is set AND the adapter's normalized
  live codehash equals the snapshot. It stays `view` — a pure read-side
  gate, exactly mirroring `tierOf`'s "no state write in the hot path,
  nothing to grief" design. Storage cleanup remains `poke` / `demote` /
  `demoteByChallenge` / owner `setAdapterAllowed(adapter, false)`.
- **No interface, ABI, or event change**: `ITierRegistry`
  (`src/interfaces/ITierRegistry.sol:6`) keeps
  `isAdapterAllowed(address) external view returns (bool)`;
  `AdapterAllowedSet(address,bool)` keeps its signature; `_demote`,
  `setAdapterAllowed(adapter, false)`, and the vault call site are untouched.
- **New storage is safe because `TierRegistry` is non-proxied**: deployed
  with plain `new` (`script/Deploy.s.sol:282`), and no storage-layout golden
  covers it — `script/check-layout-goldens.sh` pins only SyndicateGovernor,
  SyndicateFactory, GuardianRegistry, and StakedWood.
- **One existing test updated** (`test/TierRegistry.t.sol:538` — the
  stale-`true` assertion that pinned the bug flips to `assertFalse`), plus
  new unit tests for the self-heal semantics and one vault-level test on the
  exact attack path.
- **Operator docs updated**: `docs/adapter-onboarding-checklist.md` gains
  the codehash-binding of the allowlist (grant AFTER deployment; a later
  code change closes the funds path on the next read without waiting for
  `poke`; re-grant to re-attest after a verified upgrade).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tier-policy`: the "Adapter allowlist is a separate axis from tiers"
  requirement — the allowlist becomes codehash-bound with a lazy read-side
  self-heal mirroring `tierOf`; new scenarios for metamorphic swap,
  selfdestructed adapter, no-code adapters, and re-attestation.
- `operator-docs`: the "Adapter onboarding is a written dual-gate procedure"
  requirement — the de-onboarding/watcher section's lazy-path bullet
  narrows (an un-`poke`d codehash drift no longer leaves the funds path
  open; the drift sweep becomes state/indexer hygiene), and onboarding
  gains the grant-after-deploy and re-attest-after-upgrade rules.

## Impact

- `src/TierRegistry.sol` — one new private mapping, one internal
  normalization helper, a one-line write in `setAdapterAllowed`, the
  cross-check in `isAdapterAllowed`, natspec (house style: state the
  adversary).
- `src/interfaces/ITierRegistry.sol`, `src/SyndicateVault.sol` — no change.
- No layout-golden regeneration (TierRegistry is not proxied and not
  golden-pinned; see design.md).
- Gas: +1 `EXTCODEHASH` + 1 `SLOAD` on the `true` path of each guarded
  batch call — worst case ~+4,700 gas per cold recipient, bounded by
  `MAX_CALLS_PER_PROPOSAL = 64` to ~+300k per batch against Robinhood's
  32M tx gas; issue #51's `SLASH_GAS_*` / `DEMOTION_GAS` budgets are
  untouched (`_demote` is not modified).
- Tests: `test/TierRegistry.t.sol` (one assertion flip + new units),
  `test/vault/SelectorGuard.t.sol` (new attack-path test); all other
  consumers verified unaffected (design.md D5 has the full sweep).
- Coordination: independent of issue #45 (certify timelock — grant-path
  only; `certify` never touches `_adapterAllowed`). If #45 later adds its
  own codehash audit trail it MUST use a separate mapping (design.md D6).
