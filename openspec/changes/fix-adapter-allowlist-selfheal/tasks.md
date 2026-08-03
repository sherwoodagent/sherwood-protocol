# Tasks — fix-adapter-allowlist-selfheal

NOTE FOR THE IMPLEMENTER: do NOT touch `certify`, `_demote`, `poke`,
`setAdapterAllowed`'s `false` branch, `ITierRegistry`, `SyndicateVault`, or
anything in issue #45's scope (certify timelock — owned by another agent).
The whole contract diff is confined to `src/TierRegistry.sol`: one mapping,
one helper, one line in the setter's grant path, one expression in the view.
Line references below are against `main` @ `cb35df6`.

## 1. TierRegistry

- [ ] 1.1 Add
      `mapping(address adapter => bytes32) private _adapterAllowedCodehash;`
      next to `_adapterAllowed` (`src/TierRegistry.sol:74`), with natspec
      stating: (i) the adversary (metamorphic same-address redeploy /
      code appearing at a codeless allowlisted address keeping the standing
      right to receive vault funds until someone pokes — and `poke` is
      unreachable for uncertified adapters); (ii) the invariant (meaningful
      only while `_adapterAllowed[adapter]` is true; records the effective
      codehash attested at the LAST grant; inert when the flag is false);
      (iii) the #45 fence (dedicated to the transfer-permission axis — a
      future certify-path audit trail must use its own mapping, design.md
      D6). New storage is layout-free: TierRegistry is non-proxied
      (`script/Deploy.s.sol:282`) and not golden-pinned
      (`script/check-layout-goldens.sh` covers only
      governor/factory/guardian-registry/staked-wood).
- [ ] 1.2 Add an internal view helper
      `_effectiveCodehash(address a) internal view returns (bytes32)`
      returning `a.codehash`, normalized so `_EMPTY_CODEHASH`
      (`src/TierRegistry.sol:64`) reads as `bytes32(0)` — non-existent and
      existing-codeless accounts are one "no code" value (design.md D3:
      kills the 1-wei-donation grief on codeless allowlisted addresses).
- [ ] 1.3 In `setAdapterAllowed` (`src/TierRegistry.sol:365-368`): on the
      grant path only, write
      `_adapterAllowedCodehash[adapter] = _effectiveCodehash(adapter);`.
      The `false` branch and the event are unchanged. Extend the setter's
      natspec: every grant re-attests the CURRENT code; re-granting after a
      verified upgrade is the recovery ceremony; grants must follow
      deployment (a counterfactual-address grant snapshots "no code" and
      closes the moment code appears).
- [ ] 1.4 In `isAdapterAllowed` (`src/TierRegistry.sol:372-374`): return
      `_adapterAllowed[adapter] && _effectiveCodehash(adapter) == _adapterAllowedCodehash[adapter];`
      keeping the `view` mutability and the exact signature
      (`ITierRegistry` and the vault's `private view` guard depend on it —
      design.md D2). Natspec: mirror `tierOf`'s lazy fail-safe language
      ("no state write in the hot path, nothing to grief"), state the
      adversary, state that persistence still comes from
      `poke`/`demote`/owner clear, and cross-reference the proxy caveat.

## 2. Unit tests (test/TierRegistry.t.sol)

- [ ] 2.1 Update `test_poke_clearsAdapterAllowlist` (`:532-546`): the
      `assertTrue(reg.isAdapterAllowed(target))` at `:538` pinned the bug's
      stale-`true` window — flip it to `assertFalse` with a comment that
      the read now self-heals BEFORE any `poke` (issue #137). Keep the
      `vm.expectEmit` + `poke` + final `assertFalse`: storage is still set
      pre-`poke`, so `poke`'s clear still emits `AdapterAllowedSet(target,
      false)` — that half of the test still pins the persistence path.
- [ ] 2.2 New: metamorphic swap self-heals without poke — grant a contract
      target, `vm.etch` different bytecode, assert `isAdapterAllowed` is
      false immediately, with NO demotion call of any kind; then owner
      re-grants and assert true again (re-attestation refreshes the
      snapshot).
- [ ] 2.3 New: uncertified allowlisted adapter is protected — grant a
      contract target that was NEVER certified, etch, assert the read is
      false AND `poke` on it reverts `NotCertified` (proving the read-side
      gate is the only automatic protection there — design.md D2), AND
      owner `setAdapterAllowed(target, false)` still works as the manual
      cleanup.
- [ ] 2.4 New: zero-code semantics (design.md D3) — (a) grant a codeless
      `makeAddr` address, assert true; `vm.deal` it 1 wei, assert STILL
      true (normalization pins the anti-grief property); (b) etch code onto
      it, assert false; (c) separate fixture: grant a contract, etch empty
      code over it (simulating selfdestruct), assert false.
- [ ] 2.5 New: `setAdapterAllowed(adapter, false)` still answers false
      regardless of codehash state, and a stale snapshot under a cleared
      flag is overwritten by the next grant (grant → etch → revoke →
      re-grant → assert true against the NEW code).

## 3. Vault-level attack-path test (test/vault/SelectorGuard.t.sol)

- [ ] 3.1 New test: the issue's exact attack path dies in the guard —
      deploy a real contract adapter (NOT the codeless `adapter` fixture at
      `:44`), grant it, `vm.etch` different bytecode over it, then execute
      a batch `usdc.approve(swappedAdapter, X)` via `_exec` and expect
      `DisallowedTransferTarget(usdc, SEL_APPROVE, swappedAdapter)`. Using
      an UNCERTIFIED adapter keeps the proposal tier 2 throughout, so no
      `TierRegressed` shadows the guard (design.md D5). Also assert the
      codeless-`adapter` pass-through tests (`:112-115`, `:137-140`) still
      hold unchanged — they pin D3's no-code semantics.

## 4. Operator docs

- [ ] 4.1 Update `docs/adapter-onboarding-checklist.md` per the
      operator-docs delta: Gate B section gains the codehash binding
      (grant after deploy + verify; re-grant to re-attest after upgrades;
      proxy caveat applies to the allowlist too), and the watcher section's
      "un-`poke`d lazy demotion" bullet narrows to storage/indexer hygiene
      — the funds path now closes on read for BOTH `tierOf` and
      `isAdapterAllowed`, and `poke` remains unreachable for uncertified
      adapters (owner clear is the persistence path there).

## 5. Verification

- [ ] 5.1 `openspec validate fix-adapter-allowlist-selfheal --strict`
      passes.
- [ ] 5.2 Full `forge test` green (respect the machine's build
      serialization rules: foreground forge, `pgrep -x forge` guard or a
      PID-carrying lock — never `pgrep -x solc`, never pipe forge's exit
      through `tail`). Expected fallout is EXACTLY the one flipped
      assertion (design.md D5); triage any other failure with
      `sort | uniq -c`, not `sort -u`.
- [ ] 5.3 Confirm no golden churn: `git status` shows no
      `script/*.golden.json` changes (TierRegistry is not pinned;
      touching a golden means something went wrong).
- [ ] 5.4 `forge fmt` with a CI-matching forge before pushing (CI checks
      `src/`, `test/`, `script/`).
- [ ] 5.5 Sanity: repo-wide grep still shows `SyndicateVault.sol:667`
      region as the sole `src/` consumer of `isAdapterAllowed`, and no new
      caller assumed non-view mutability.
