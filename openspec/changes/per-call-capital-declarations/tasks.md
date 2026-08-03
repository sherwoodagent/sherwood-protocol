# Tasks

**Ordering is load-bearing. The tree MUST compile after every numbered section**
(src + test + script — forge builds all three). The breaking-ABI edits are
staged as an add-overload → migrate-callers → delete-old ladder so no section
leaves a caller pointing at a signature that no longer exists. Line references
are against `origin/main` @ `388460c`.

Sequencing preconditions (do not start §2 before these hold):

- **#118 merged** (`fix/issue-118-propose-target-validation`): its
  `_rejectPrivilegedTargets` sits in the exact `propose` region §4 edits, and
  the spec delta text here already incorporates its requirement wording.
- **#151 merged or explicitly re-ordered by the owner** (agreed order
  #147 → #118 → #151 → #43). If #151 lands after instead, this change's golden
  regen (§7) happens first and #151 re-regenerates on top — flag it in the PR.
- Re-verify deployment reality: `ls broadcast/` still has no `4663` directory
  and no new governor/vault proxy broadcast anywhere. If that changed, STOP —
  the storage and migration sections assume append-only-is-free and must be
  re-planned against the live layout.

## 0. Preliminaries

- [ ] 0.1 Rebase onto `main` after the preconditions above. Then confirm the
      anchors this spec pins still hold: `_resolveTierAndCoverage` computes
      `maxCapital * (execBps + settleBps) / 10_000`; `BatchExecutorLib.executeBatch`
      has no accounting; `executeGovernorBatch` takes `(calls, maxNetOutflow)`.
      Any drift → update design.md line references before coding.
- [ ] 0.2 Build discipline for every forge invocation below: FOREGROUND only,
      generous timeout, serialized behind the shared lock
      (`while pgrep -x forge >/dev/null; do sleep 30; done` — guard the parent;
      `pgrep -x solc` is inert, the binary is `solc-0.8.28`), never judge a
      build through a piped exit code. Compile checkpoints are marked; avoid
      extra builds between them.

## 1. BatchExecutorLib — metered executor (additive; nothing else changes)

- [ ] 1.1 `src/BatchExecutorLib.sol`: add errors `CapsLengthMismatch()` and
      `CallCapExceeded(uint256 index, uint256 outflow, uint256 cap)`; add the
      metered `executeBatch(Call[] calldata calls, address asset, uint256[] calldata caps)`
      per design.md D3: empty caps ⇒ unmetered loop identical to today;
      non-empty wrong length ⇒ `CapsLengthMismatch` before any call; metered ⇒
      one `balanceOf` before the loop, one after each call, consecutive-snapshot
      reuse, `outflow_i = max(0, before − after)`, breach reverts. Keep the OLD
      `executeBatch(Call[])` in place for now (deleted in §5) so the tree
      compiles with the vault untouched.
- [ ] 1.2 Extend simulation: `simulateBatch(Call[] calldata, address asset, uint256[] calldata caps)`
      returning per-call `(success, returnData, outflow)` (append `outflow` to
      `CallResult`); keep the old overload until §5. Natspec: simulation
      measures, never enforces.
- [ ] 1.3 Checkpoint (build 1): `forge build` green with zero non-lib diffs.

## 2. Vault — caps plumbing + executor re-point (additive overload)

- [ ] 2.1 `src/SyndicateVault.sol`: add
      `executeGovernorBatch(BatchExecutorLib.Call[] calldata calls, uint256[] calldata callCaps, uint256 maxNetOutflow)`
      — body is today's :467-516 verbatim except the delegatecall encodes the
      metered `executeBatch(calls, asset(), callCaps)`. Refactor the existing
      2-arg version to delegate to the 3-arg one with `new uint256[](0)`
      (temporary shim, deleted in §5) so the governor and every test compile
      unchanged. Do NOT touch the net-outflow/reserve/buffer block (design.md
      D4 — byte-for-byte after the delegatecall).
- [ ] 2.2 Add the factory-only re-point: `setExecutorImpl(address newImpl)` —
      `msg.sender == _factory` else revert, reject zero/codeless, write
      `_executorImpl` and `_expectedExecutorCodehash = newImpl.codehash`
      together; event `ExecutorImplSet(address oldImpl, address newImpl)`.
      Declare on `ISyndicateVault` (with the 3-arg `executeGovernorBatch`;
      keep the 2-arg declaration until §5).
- [ ] 2.3 Checkpoint (build 2): full `forge build` — src, test, script all
      green with only lib/vault/interface diffs.

## 3. Governor storage + coverage math (internal; `propose` ABI still old)

- [ ] 3.1 `src/SyndicateGovernor.sol`: append (AFTER the last existing storage
      variable — append-only even though no proxy is deployed)
      `mapping(uint256 => uint256[]) private _executeCallCaps;` and
      `mapping(uint256 => uint256[]) private _settlementCallCaps;` plus the
      `tier2CallCapBps` parameter slot (beside `maxCapitalBps`, matching its
      unset-reads-as-10_000 pattern — put the slot wherever that pattern's
      storage actually lives; follow it exactly).
- [ ] 3.2 Rewrite `_resolveTierAndCoverage` to take `(execCalls, execCaps,
      settleCalls, settleCaps, maxCapital)` and return the per-call sum
      (design.md D2): `registry == address(0)` → `(2, maxCapital)` unchanged;
      else tier = max exec tier, `coverage = Σ cap×bound/10_000` over both
      arrays. Extend `_scanCalls` to take caps and return `(maxTier, coverageSum)`
      instead of `(tier, sumBps)`; fold the per-call tier-2 ceiling check into
      the same sweep behind a `checkCeiling` flag (true at propose, false at
      execute re-resolve). Errors: `CallCapsLengthMismatch()`,
      `CallCapsExceedMaxCapital()`, `Tier2CallCapExceedsCeiling(uint256 index)`,
      `InvalidTier2CallCapBps()` on `ISyndicateGovernor`.
- [ ] 3.3 Update the two `_resolveTierAndCoverage` call sites to load caps from
      the new mappings (`_loadCaps` helper mirroring `_loadCalls`):
      `_snapshotTierAndGate` (propose path — caps stored by §4 before it runs)
      and `executeProposal`'s re-resolve (:415-418).
- [ ] 3.4 `tier2CallCapBps` setter + getter per the parameter house pattern
      (owner-only, `whenNoActiveProposal`, bounds `[1,10_000]`,
      `ParameterChangeFinalized`), threaded into `forceSetParams` only if that
      path carries per-param values today — match `maxCapitalBps`'s treatment
      exactly, no more.
- [ ] 3.5 TRANSITIONAL semantics for this section only: a proposal with no
      stored caps (empty arrays) must price EXACTLY as today so the tree stays
      green before §4 swaps the ABI — in `_resolveTierAndCoverage`, treat
      `caps.length == 0` (with non-empty calls) as "legacy: cap_i = maxCapital
      for every call", reproducing `maxCapital × Σbps / 10_000`. Mark it
      `// TEMP(#43 §4 removes)`. Checkpoint (build 3): full build + run
      `test/governor` suites — behavior must be bit-identical.

## 4. Governor — `propose` ABI change + validation (the breaking step)

- [ ] 4.1 `ISyndicateGovernor.propose`: insert `uint256[] calldata executeCallCaps`
      after `executeCalls` and `uint256[] calldata settlementCallCaps` after
      `settlementCalls` (design.md D1). Natspec: caps are per-call gross-outflow
      declarations in the vault asset; zero = "moves nothing"; Σ per batch ≤
      `envelope.maxCapital`.
- [ ] 4.2 `SyndicateGovernor.propose`: new private helper (stack budget —
      sibling of #118's `_rejectPrivilegedTargets`, never folded into it,
      design.md D6) validating lengths (`CallCapsLengthMismatch`) and per-batch
      sums (`CallCapsExceedMaxCapital`) after the `TooManyCalls` cap; store caps
      via `_storeCaps` right after `_storeCalls` (:316-317) so
      `_snapshotTierAndGate` prices from storage; delete the 3.5 TEMP branch
      (empty-caps-with-calls is now unreachable at propose — the length check
      rejects it since calls are non-empty). Watch the Yul stack budget
      (design.md Risks — store-early, helpers, validate-while-storing in that
      order).
- [ ] 4.3 Thread caps into execution: `executeProposal` →
      `executeGovernorBatch(calls, _loadCaps(_executeCallCaps, id), maxCapital)`;
      `settleProposal` and `GovernorEmergency`'s `unstick` path →
      stored settlement caps; `finalizeEmergencySettle` → `new uint256[](0)`
      (design.md D3, empty-caps rescue). Update the :438-441 "not currently
      reachable" natspec (zero coverage is now reachable; why it is sound).
- [ ] 4.4 Add `getCallCaps(uint256) returns (uint256[] memory, uint256[] memory)`
      (+ interface) — the #27 seam (design.md D7).
- [ ] 4.5 Test-harness sweep, SAME section (the tree does not compile until it
      is done): update the shared fixtures/helpers (`GovEnvelope`, lifecycle
      harnesses, any `propose(...)` wrapper) to the new arity with ONE
      documented default — `caps = [maxCapital, 0, 0, ...]` per array — then
      mechanically fix remaining direct `propose(...)` call sites. Remember the
      argument-position-call gotcha: hoist any `x.read()` out of pranked call
      arguments while rewriting.
- [ ] 4.6 Checkpoint (build 4): full `forge build` + full `forge test`.
      Pre-existing behavioral tests must pass with defaults; any test asserting
      the OLD coverage formula (grep `requiredCoverage` in `test/`) is updated
      to the per-call sum in the same commit, with the arithmetic shown in a
      comment.

## 5. Delete the transitional surfaces (breaking step complete)

- [ ] 5.1 Delete: lib's old `executeBatch(Call[])` and old `simulateBatch(Call[])`;
      vault's 2-arg `executeGovernorBatch` shim + its `ISyndicateVault`
      declaration. Grep for stragglers (`executeGovernorBatch(` with two args,
      `executeBatch(` with one) across src/test/script.
- [ ] 5.2 Checkpoint (build 5): full build + test. The unmetered selector now
      exists nowhere (spec: a mis-wired vault fails closed, never unmetered).

## 6. Factory — migration primitives + deploy wiring

- [ ] 6.1 `src/SyndicateFactory.sol`: `setExecutorImpl(address)` (owner-only,
      nonzero, event) and `pushExecutor(address vault)` (owner-only; verify
      factory-deployed via the `governorOf` round-trip; require
      `getActiveProposal() == 0 && openProposalCount() == 0` on the vault's
      governor — same gates as `rotateOwner`; call the vault's
      `setExecutorImpl(executorImpl)`). Declarations on `ISyndicateFactory`.
- [ ] 6.2 Deploy scripts: fresh deploys pick up the new lib with no structural
      change, but add to `DeployPlanB`: set `tier2CallCapBps = 200` on governor
      defaults (or via the params override) and a post-wiring PRE-FLIGHT assert
      that it is nonzero-and-≤-200 — policy per issue #43 ("~100–200bps"),
      mechanism per design.md D2. Document the D5 six-step migration sequence
      in the script header for the testnet-46630 rehearsal.
- [ ] 6.3 Checkpoint (build 6): full build (script/ compiles — CI's
      `forge fmt --check` covers script/ too).

## 7. Storage-layout goldens

- [ ] 7.1 Regenerate `script/syndicate-governor-layout.golden.json`
      (`./script/check-layout-goldens.sh --update-golden`). Diff MUST be
      append-only: two new mapping slots (+ the parameter slot if it lives in
      governor storage) at the tail; every pre-existing entry's slot/offset/type
      unchanged. `StrategyProposal`'s encoding must be untouched (no new struct
      fields in this change). Any non-append diff → STOP, layout was disturbed.
- [ ] 7.2 Factory golden: expect NO diff (`setExecutorImpl`/`pushExecutor` are
      code-only; `executorImpl` slot pre-exists). Run the checker to prove it.

## 8. Tests this change owes (beyond the §4 sweep)

- [ ] 8.1 Issue #43's five obligations: (a) mixed batch (tier-0 80% + tier-1
      19% + tier-2 1%) proposes, executes, and `requiredCoverage` equals the
      per-call sum (spec scenario arithmetic: 275,000 on the 10M example);
      (b) a call exceeding its own cap reverts `CallCapExceeded` while batch
      net outflow is far under `maxCapital`; (c) gross rule — inflow in a later
      call does not refill an earlier call's budget, both orderings (vault-spec
      scenario "Refund does not refill"); (d) tier-2 cap above the
      `tier2CallCapBps` ceiling reverts at propose, same cap on a certified
      tier-0 call accepted; (e) golden check green in CI (7.1's append-only
      property pinned by `check-layout-goldens.sh` itself).
- [ ] 8.2 Validation matrix: `CallCapsLengthMismatch` (each array);
      `CallCapsExceedMaxCapital` (each batch; and the two-sums-independently
      case passes); zero-cap call moving 1 wei reverts; all-zero-caps proposal
      → `requiredCoverage == 0`, quorum gate skipped, meter blocks any outflow.
- [ ] 8.3 Regression guards under caps: demote a capped call's adapter after
      propose → `CoverageRegressed` (sum rises by that call's weight);
      demotion raising the max tier → `TierRegressed`; zero-cap-call demotion
      inside an already-tier-2 batch → executes (coverage unchanged) — pins
      design.md D2's residual as deliberate.
- [ ] 8.4 Unwired-registry default: no registry → `(2, maxCapital)` regardless
      of caps; caps still metered at execution.
- [ ] 8.5 Lifecycle of a cap breach: execute-leg breach leaves `Approved`
      (expires); settle-leg breach leaves `Executed`, `unstick` replays and
      reverts identically (`CallCapExceeded`), `emergencySettleWithCalls` →
      `finalizeEmergencySettle` with owner calls succeeds under empty caps +
      `maxCapital` — the spec's rescue story end-to-end.
- [ ] 8.6 Migration: vault `setExecutorImpl` non-factory reverts; factory
      `pushExecutor` lifecycle-gated (open proposal → revert), success
      re-points address+codehash atomically; upgraded-vault-with-old-lib batch
      reverts (fail-closed, "Unmigrated vault" scenario) — keep the old lib
      bytecode as a test fixture for this.
- [ ] 8.7 `simulateBatch` reports per-call outflows matching what `executeBatch`
      enforces on the same batch.
- [ ] 8.8 `tier2CallCapBps`: setter bounds, unset-reads-10_000 inert default,
      frozen mid-proposal, `ParameterChangeFinalized` emitted.

## 9. Docs + verify

- [ ] 9.1 Natspec sweep: `_resolveTierAndCoverage` (delete the "deliberately
      OVER-counts" paragraph — no longer true), `StrategyProposal.requiredCoverage`
      (per-call sum definition), `BatchExecutorLib` header (still stateless /
      access-control-free; now metered; deploy-once + migration pointer),
      `executeGovernorBatch`'s COARSE-cap comment (:492-508 — now names both
      layers per design.md D4), the :438-441 quorum-gate comment (4.3).
- [ ] 9.2 `forge build` + full `forge test` FOREGROUND (per 0.2), then
      `forge fmt --check` on src/test/script with a CI-matching forge.
- [ ] 9.3 `openspec validate per-call-capital-declarations --strict`.
- [ ] 9.4 Post-landing notes: comment on #27 pointing at design.md D7 (the
      interface recorded for it, including the rounding re-assert and the
      persist-the-factor warning); file the follow-up issue for ERC721/1155
      guarded selectors before any exotic-asset adapter onboards (design.md
      Risks, exotic residual).
