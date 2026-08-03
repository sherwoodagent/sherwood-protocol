# Design — fix-adapter-allowlist-selfheal (issue #137)

## Context

Two reads on `TierRegistry` guard the vault's money paths, and only one of
them is codehash-bound:

- `tierOf(target, selector)` (`src/TierRegistry.sol:93-99`): reads the
  `TierConfig`, and if `certifiedCodehash` is zero OR the target's live
  `target.codehash` differs from it, reports `(2, 10_000)` — the lazy
  fail-safe demotion. No state write on the read path; `poke`
  (`:289-294`) persists it permissionlessly, but the protection does not
  depend on `poke` ever being called.
- `isAdapterAllowed(adapter)` (`:372-374`): `return _adapterAllowed[adapter];`
  — nothing else. The mapping (`:74`) is set only by owner
  `setAdapterAllowed` (`:365-368`) and cleared only inside `_demote`
  (`:324-327`), reached via `demote` / `demoteByChallenge` / `poke`. None of
  those fires automatically, and `poke` requires an existing certification
  (`NotCertified`, `:291`) — so for an allowlisted adapter with no
  certified selector there is NO permissionless path that can ever clear a
  stale entry.

The consumer: `SyndicateVault._guardBatchCalls`
(`src/SyndicateVault.sol:590-671`), a `private view` function run on every
governor batch before the executor delegatecall. For the four value-moving
ERC20 selectors it decodes the spender/recipient (`:657-662`), skips the
vault itself (`:666`), and reverts `DisallowedTransferTarget` unless
`ITierRegistry(registry).isAdapterAllowed(recipient)` (`:667`). Verified by
repo-wide grep: this is the ONLY `src/` consumer of `isAdapterAllowed`
(the other hits are the interface declaration, tests, a test mock at
`test/audit-fixes/Vault_batchQueueTargets.t.sol:24`, and docs/specs). It
performs no `tierOf` and no codehash check of its own.

So a metamorphic (same-address) bytecode swap under an allowlisted adapter
leaves the primary fund-movement gate answering the question "may vault
funds be approved/sent here?" from a snapshot of a world that no longer
exists. `test/TierRegistry.t.sol:532-546` already exhibits the window:
`vm.etch(target, hex"6001600101")` at `:537`, then
`assertTrue(reg.isAdapterAllowed(target))` at `:538` — before `poke`.

### TierRegistry is non-proxied and not golden-pinned (evidence)

Stated here so neither the implementer nor the auditor re-derives it:

- Deployment is a plain `new TierRegistry(d.deployer)` at
  `script/Deploy.s.sol:282` (the only `new TierRegistry` in `script/` or
  `src/`; `DeployPlanB.s.sol:835` mentions a manual "TierRegistry redeploy"
  as a console note, not a deployment). No proxy, no initializer, no
  upgrade path — a code change here ships as a REDEPLOY plus re-certify /
  re-allowlist ceremony, which the Plan B runbook already contemplates.
- `script/check-layout-goldens.sh` pins exactly four contracts:
  SyndicateGovernor, SyndicateFactory, GuardianRegistry, StakedWood (the
  `check_contract` calls at the bottom of the script; the golden files in
  `script/` are `syndicate-governor-`, `syndicate-factory-`,
  `guardian-registry-`, `staked-wood-`, plus `leveraged-aero-` owned by
  `check-storage-parity.sh`). No `tier-registry` golden exists.

Together: appending a new mapping to `TierRegistry` costs nothing in layout
management — no golden regeneration, no append-only discipline, no
migration. This is what makes the dedicated-mapping design (D1) cheap.

## Goals / Non-Goals

Goals:

- Close the stale-`true` window on `isAdapterAllowed` with the same lazy,
  read-side, nothing-to-grief self-heal `tierOf` already has, without
  depending on `poke`.
- Keep the `ITierRegistry` read surface, the vault call site, and the
  `AdapterAllowedSet` event exactly as they are.
- Fail closed on any code change at an allowlisted address — including
  code appearing where none was, and code disappearing (selfdestruct).

Non-Goals:

- Anything in `certify`'s grant path — that is issue #45's scope (owned by
  another agent; see D6).
- Making `poke` reachable for uncertified allowlisted adapters, extending
  `poke` to clear allowlist-only entries, or any `_demote` change. The
  read-side gate makes persistence optional, same as `tierOf`; storage
  hygiene for the uncertified case remains owner `setAdapterAllowed(false)`.
- Proxy-implementation-swap detection (structurally impossible via
  EXTCODEHASH — same caveat as `tierOf`, restated in the spec delta).
- The Base legacy deployment. The guardian econ-security stack is
  Robinhood-only; TierRegistry redeploys freely there.

## Decisions

### D1 — Snapshot at grant time, in a NEW dedicated mapping

`setAdapterAllowed(adapter, true)` snapshots the adapter's normalized
codehash into
`mapping(address adapter => bytes32) private _adapterAllowedCodehash`.

The existing certification-time snapshot (`TierConfig.certifiedCodehash`)
is NOT reusable, for four independent reasons:

1. **Keying**: certifications are keyed `keccak256(target ‖ selector)`
   (`:87-89`); the allowlist is keyed by bare address. There is no single
   cert entry to consult — and no rule for which selector's entry would
   speak for the address.
2. **The allowlisted-but-uncertified state is legal and specced**: the
   dual-gate model (tier-policy spec, "Adapter allowlist is a separate axis
   from tiers"; `docs/adapter-onboarding-checklist.md` §5 "nothing on-chain
   enforces the pairing") explicitly admits an allowlisted adapter with
   zero certifications — tier 2 is a price, not a prohibition. For that
   adapter no certification-time snapshot exists at all.
3. **Lifecycles diverge**: `_demote` deletes the cert config while allowlist
   recovery is a separate, explicit owner grant (`certify` never restores
   the allowlist — pinned by `test_recertify_doesNotRestoreAllowlist`).
   Two certifications of different selectors made at different code
   generations can also legitimately hold different hashes. A borrowed
   snapshot would couple the two axes exactly where the spec demands they
   stay uncoupled.
4. **It's cheap**: non-proxied, no golden (Context above) — a new mapping
   is one storage slot of layout with zero migration cost.

Write rules (deliberately minimal — two write sites total in the change):

- Grant (`allowed == true`): always (re)write the snapshot with the
  CURRENT normalized codehash. An idempotent re-grant is therefore the
  owner's re-attestation ceremony after a verified legitimate upgrade.
- Revoke (`allowed == false`), `_demote`, `poke`: untouched. A snapshot
  left behind under a `false` flag is inert — `isAdapterAllowed` requires
  the flag AND the match, and the next grant overwrites the snapshot
  unconditionally. Not clearing it keeps the diff minimal and keeps
  `_demote` — and therefore issue #51's `DEMOTION_GAS = 200_000` sizing and
  the bracketing measurement in
  `test/SlashGasCeiling.t.sol:692-721` — completely out of this change's
  blast radius.

Invariant to state in natspec: `_adapterAllowedCodehash[a]` is meaningful
only while `_adapterAllowed[a]` is true; it records the effective codehash
the owner attested to at the LAST grant.

### D2 — `isAdapterAllowed` stays `view`: a read-side gate (the crux)

A `view` cannot write, so the two candidate shapes were:

- **(a) chosen**: keep the signature; return
  `_adapterAllowed[adapter] && _effectiveCodehash(adapter) == _adapterAllowedCodehash[adapter]`.
  Returns `false` on mismatch WITHOUT clearing state; persistence, where a
  certification exists, happens on the next `poke`/`demote` exactly as
  today.
- (b) rejected: make it non-view and self-clear on mismatch.

Why (a), decisively:

1. **The sole consumer cannot call a non-view**:
   `SyndicateVault._guardBatchCalls` is itself declared `private view`
   (`src/SyndicateVault.sol:590`). A state-mutating `isAdapterAllowed`
   would not compile at the call site — fixing that means de-`view`-ing the
   vault's guard pipeline and changing `ITierRegistry`
   (`src/interfaces/ITierRegistry.sol:6`), an interface/ABI blast radius
   the tier-policy spec explicitly fences ("External read surface" pins the
   two reads as the vault-facing interface).
2. **It mirrors `tierOf` exactly**, whose contract-level natspec states the
   design rule this repo already accepted: "no state write in the hot path,
   nothing to grief" (`src/TierRegistry.sol:19-22`). A writing read would
   also hand griefers a storage-touching external call on the vault's
   execute path.
3. **No caller depends on the stale `true`**. Sweep: the vault guard treats
   `false` as revert `DisallowedTransferTarget` — fail closed, the desired
   outcome; the only test depending on the stale `true` is the
   bug-pinning assertion at `test/TierRegistry.t.sol:538` (updated by this
   change); operator docs use `cast call` reads informationally.

Consequence worth stating: for allowlisted-but-UNcertified adapters
(`poke` unreachable, Context above) the read-side gate is not merely a
faster complement to `poke` — it is the ONLY automatic protection that can
exist. Storage for that case stays `true` until the owner clears it, but
the funds path is closed from the first post-mutation read. This is
strictly stronger than `tierOf`'s guarantee needs to be, and it is why the
fix cannot be "just call poke more often".

### D3 — Codehash normalization; zero-code fails closed on CHANGE

Define the effective codehash used for both snapshot and comparison:

```
_effectiveCodehash(a) = (a.codehash == keccak256("")) ? bytes32(0) : a.codehash
```

(`_EMPTY_CODEHASH = keccak256("")` already exists at
`src/TierRegistry.sol:64`.) EIP-1052 background: a NON-EXISTENT account
reads `bytes32(0)`; an EXISTING account with no code (e.g. a funded EOA)
reads `keccak256("")`. Both mean "no executable code" — the normalization
makes them one value.

Resulting semantics, case by case:

- **Adapter had code at grant, code swapped (the issue's attack)**: live
  hash ≠ snapshot → `false`. Closed on the first read, no `poke` needed.
- **Adapter had code at grant, selfdestructed (zero code now)**: live
  effective hash `bytes32(0)` ≠ non-zero snapshot → `false`. Fail closed.
  This cannot brick a legitimate batch: the gate is per-recipient, so only
  calls directing value at the vanished adapter revert — and any such call
  is precisely the hazard (funds approved/sent to an address whose next
  code is unknown and attacker-choosable via redeploy). Batches not naming
  that adapter are untouched; a reverted proposal is cancellable
  (`SyndicateGovernor.cancelProposal`), and recovery is one owner re-grant
  after verifying whatever was redeployed.
- **No code at grant, still no code at read**: snapshot `bytes32(0)` ==
  live `bytes32(0)` → `true`. Allowlisting a plain payout address keeps
  working, and — thanks to normalization — merely FUNDING that address
  (non-existent → existing-codeless flips raw `EXTCODEHASH` from `0` to
  `keccak256("")`) cannot be used as a 1-wei griefing donation that closes
  the vault's fund path. Without normalization that grief is real and
  costs an attacker almost nothing.
- **No code at grant, code appears later**: live hash ≠ `bytes32(0)`
  snapshot → `false`. This is the counterfactual-CREATE2 variant of the
  metamorphic attack (allowlist the predicted address, deploy malicious
  code after), and it fails closed.

Rejected alternative: have `setAdapterAllowed(adapter, true)` revert
`NotAContract` for codeless addresses, mirroring `certify`
(`:204-205`). Rejected because (i) it changes setter behavior beyond the
defect — the defect is the read, not the grant; (ii) the codeless-recipient
use is currently exercised and pinned:
`test/vault/SelectorGuard.t.sol:44` (`adapter = makeAddr("adapter")`), `:78`
(grant in `setUp`), with pass-through asserted at `:112-115` and
`:137-140`; (iii) the snapshot semantics already give the stronger
guarantee that matters — the gate answers `true` only while the code at the
address is byte-identical (including "absent") to what the owner attested.

Accepted residual (identical to `tierOf`'s, restated for honesty): a
redeploy of BYTE-IDENTICAL runtime code at the same address re-opens the
gate, even though storage was wiped and the constructor re-ran — codehash
identity cannot see storage. Post-Dencun (EIP-6780) the selfdestruct
paths that enable this are nearly extinct, and `tierOf` accepts the same
bound. Likewise proxies: an EIP-1967/UUPS/beacon implementation swap never
changes the proxy's codehash, so allowlisting proxied adapters remains a
governance-discipline matter, same as certifying them.

### D4 — No event change

`AdapterAllowedSet(address indexed adapter, bool allowed)` keeps its
signature. The snapshot hash is not emitted: indexers that want it can read
`adapter.codehash` at the grant block, and changing the event shape would
touch every `vm.expectEmit` in `test/TierRegistry.t.sol` plus any indexer
for zero security value. The lazy `false`, like `tierOf`'s lazy tier 2,
emits nothing by design — `poke` remains the event-producing persistence
path where a certification exists.

### D5 — Test impact (complete sweep)

Every `src/`, `test/`, and `script/` site that grants or reads the
allowlist was checked for reliance on a stale `true` across a code change:

| Site | Verdict |
| --- | --- |
| `test/TierRegistry.t.sol:532-546` `test_poke_clearsAdapterAllowlist` — etch at `:537`, `assertTrue(reg.isAdapterAllowed(target))` at `:538` | **UPDATE — was pinning the bug.** The `:538` assertion documents the pre-`poke` stale-`true` window. Flip to `assertFalse` (read self-heals before any `poke`) with a comment; the rest of the test (expectEmit `AdapterAllowedSet(target,false)`, post-`poke` `assertFalse`) stays valid — storage is still set pre-`poke`, so `poke`'s clear still emits. |
| `test/governor/TierResolution.t.sol:246-265` — grants at `:111-112`, etch over `mockAdapter` at `:259`, `expectRevert(TierRegressed)` at `:263-264` | **Unaffected — pins correct behavior.** `SyndicateGovernor.executeProposal` re-resolves tier at `src/SyndicateGovernor.sol:407` (revert `TierRegressed`) BEFORE `executeGovernorBatch` at `:436`; the vault guard is never reached post-etch. |
| `test/integration/TierEndToEnd.t.sol:252-277` — grant at `:141`, etch at `:271`, `expectRevert(TierRegressed)` at `:275-276` | **Unaffected** — same ordering argument. |
| `test/vault/SelectorGuard.t.sol` — codeless `adapter = makeAddr` (`:44`), grant (`:78`), pass-throughs (`:112-115`, `:137-140`) | **Unaffected under D3** (no-code snapshot matches no-code read). This suite is the reason D3 rejects a grant-time `NotAContract`. |
| `test/GovernorCoverageGates.t.sol:658-659`; `test/governor/TierResolution.t.sol:111-112`; `test/integration/TierEndToEnd.t.sol:141` (grants of real contracts whose code never changes before the guarded reads) | **Unaffected.** |
| `test/audit-fixes/Vault_batchQueueTargets.t.sol:24` — hand-rolled registry mock | **Unaffected** — implements the unchanged `ITierRegistry` shape. |
| `test/SlashGasCeiling.t.sol:692-721` — `DEMOTION_GAS` bracket | **Unaffected** — `_demote` is not modified (D1). |
| `script/` | **No `setAdapterAllowed` call sites exist** (grep). |

No test legitimately needs the stale `true`. New tests are enumerated in
tasks.md; the one that proves the issue's exact attack path end-to-end is a
`SelectorGuard`-style vault test: grant a CONTRACT adapter, etch different
bytecode over it, run a batch `approve(adapter, X)`, expect
`DisallowedTransferTarget` — using an UNCERTIFIED adapter so the proposal
was tier 2 all along and no `TierRegressed` shadows the guard.

### D6 — Coordination note for issue #45 (certify timelock — OFF LIMITS here)

Issue #45 is owned by another agent and scoped to the `certify()` GRANT
path; `certify` never touches `_adapterAllowed`, and nothing in this change
touches `certify`, so the two land fully independently in either order.

One standing rule for whichever lands second — and for any future change:
if #45 (or a successor) adds its own codehash audit trail for the
certification path, it MUST introduce a SEPARATE mapping.
`_adapterAllowedCodehash` is the transfer-permission attestation — keyed by
bare address, lifecycle bound to `setAdapterAllowed` — while certification
tier is a per-`(target, selector)` pricing axis with its own snapshot
already (`TierConfig.certifiedCodehash`). Repurposing this mapping would
re-couple the two axes exactly where the tier-policy spec ("Adapter
allowlist is a separate axis from tiers") and `certify`'s own natspec
(`:192-197`) demand one-way, fail-closed separation.

## Gas

Per guarded call in `_guardBatchCalls`, on the `true`-flag path only
(the `false` path short-circuits and costs what it costs today):

- `EXTCODEHASH(recipient)`: 2,600 cold / 100 warm. The recipient account is
  cold in the typical case — the guard runs before the batch executes, and
  an `approve`/`transfer` target address is not otherwise touched first.
- `SLOAD _adapterAllowedCodehash[recipient]`: 2,100 cold / 100 warm.
- Normalization compare: ~20.

Worst case ≈ **+4,700 gas per unique cold recipient; ≈ +200 for warm
repeats** of the same adapter within a batch. Bound:
`MAX_CALLS_PER_PROPOSAL = 64` (`src/SyndicateGovernor.sol:82`), so even a
pathological batch of 64 guarded calls to 64 distinct cold adapters adds
≈ 300k gas — under 1% of the 32M Robinhood tx-gas ceiling the repo's gas
work is sized against (`test/SlashGasCeiling.t.sol`).

Issue #51's budgets are untouched: `SLASH_GAS_PER_APPROVER` /
`SLASH_GAS_BASE` (`src/ChallengeGame.sol:196-197`) budget the challenge
settle path, which never calls `isAdapterAllowed`; `DEMOTION_GAS = 200_000`
(`:236`) budgets `demoteByChallenge` → `_demote`, which this change does
not modify (D1). The setter `setAdapterAllowed(true)` gains one SSTORE
(~22.1k worst-case new slot) — an owner ceremony, not on any budgeted path.

## Migration Plan

No live-state migration: the fix ships in a REDEPLOYED `TierRegistry`
(non-proxied), and the deploy runbook's existing re-certify /
re-allowlist ceremony (`script/Deploy.s.sol`, DeployPlanB manual notes)
populates snapshots naturally — every `setAdapterAllowed(adapter, true)` on
the new registry records the attested hash as a side effect. Any
environment keeping an OLD registry simply keeps the old (vulnerable)
semantics until re-pointed; no data needs copying because grants must be
re-made by the owner anyway.

## Risks / Trade-offs

- **Lazy `false` without an event**: indexers tracking `AdapterAllowedSet`
  will believe an adapter is allowed while the read already answers
  `false` (mirror of `tierOf`'s existing lazy-demotion observability gap).
  Mitigation: unchanged from today — `poke` persists+emits where a
  certification exists; the operator drift sweep (narrowed by this change
  to state/indexer hygiene) covers the rest.
- **Legitimate upgrades now require a re-grant**: an adapter that upgrades
  its bytecode in place loses the funds path until the owner re-attests
  with `setAdapterAllowed(adapter, true)`. This is the designed direction
  of error (identical to the demote → re-certify cycle for tiers) and is a
  single owner call.
- **False `true` for byte-identical redeploys and proxies**: accepted
  residual, identical to `tierOf` (D3).

## Open Questions

None — all five design questions posed by issue #137's triage are resolved
above (D1 snapshot source, D2 view-vs-non-view, D3 zero-code, D5 test
impact, Gas).
