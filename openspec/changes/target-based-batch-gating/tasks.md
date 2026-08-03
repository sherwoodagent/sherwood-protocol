# Tasks

> Scope: `src/SyndicateVault.sol`, `src/interfaces/ISyndicateVault.sol`, natspec-only
> edits to `src/TierRegistry.sol`, and tests. NO governor edits, NO TierRegistry
> code/ABI/storage changes, NO new registry methods. Do not touch #35/#45/#115
> branches or worktrees. Line references below are against `origin/main` @ `00a264a`.

## 1. Interface — new error

- [ ] 1.1 `src/interfaces/ISyndicateVault.sol`: after `DisallowedBatchTarget` (:64), declare `error DisallowedBatchCallee(address target);` with the natspec from design.md ("Exact code shape") — states that it fires regardless of selector/calldata length, only when the calling governor resolves a nonzero TierRegistry, and that the selector checks beneath it are defense-in-depth on allowlisted callees.

## 2. Vault — callee gate (Part 2a)

- [ ] 2.1 `src/SyndicateVault.sol` `_guardBatchCalls` (:761-942): after the registry resolution block (:862-867), hoist `address asset_ = asset();` ahead of the Part 2 loop (:869).
- [ ] 2.2 At the TOP of the Part 2 loop body — BEFORE the `if (data.length < 4) continue;` at :871, so empty-calldata and native-`value` calls are gated — add: `address target = calls[i].target; if (target != asset_ && !ITierRegistry(registry).isAdapterAllowed(target)) revert DisallowedBatchCallee(target);` with the "PART 2a" block comment from design.md.
- [ ] 2.3 Replace the two `calls[i].target == asset()` fast-path reads (:922, :937) with `calls[i].target == asset_` (caching only; behavior identical).
- [ ] 2.4 Do NOT touch Parts 1/1b (:808-860), the registry resolution and its two degrade-open returns (:862-867), the selector switch (:872-940), or anything in `executeGovernorBatch` (:495-544). `test_targetGate_bitesEvenWithNoTierRegistryWired` / `test_targetGate_bitesEvenWhenGovernorHasNoTierGetter` must stay green untouched.

## 3. Natspec — describe the landed two-layer model

- [ ] 3.1 `src/SyndicateVault.sol`: rewrite the Option-A/Option-B "deferred follow-up" passages in the selector-constant comments (:120-127) and the `_guardBatchCalls` doc comment (:639-652, the "COVERAGE IS PER-SELECTOR" + RESIDUAL block :717-749): the callee gate is now the outer boundary closing the selector class; the retained selector checks are the inner boundary on allowlisted callees; `asset()` is the sole, metered exemption. Compress — do not delete — the round 2-4 history. Update the Part 2 header (:555-559, :665-691) to name the registry-gated concerns in order: callee gate (2a), then destination checks (2b).
- [ ] 3.2 `executeGovernorBatch`'s NOTE (:524-536): replace "exotic assets … until their selectors join the guarded set (see `_guardBatchCalls` RESIDUAL)" with the callee-gate framing (exotic-asset contracts are refused as callees by default; residual is only an unenumerated selector on `asset()` or an explicitly-allowlisted token).
- [ ] 3.3 `src/TierRegistry.sol` natspec ONLY (no code): `_adapterAllowed` (:135-141), `setAdapterAllowed` (:684-706), `isAdapterAllowed` (:715-742) — add the second consumer (batch callee gate: "may be reached by a governor batch at all, and hence may receive vault funds") and the governance-discipline rule: exotic-asset contracts (ERC-721/1155/777) MUST NOT be allowlisted as batch callees; batches reach positions through allowlisted adapters.

## 4. Tests — new callee-gate suite

- [ ] 4.1 New `test/vault/CalleeGate.t.sol` (mirror `test/vault/SelectorGuard.t.sol`'s harness: vault behind a mock governor exposing `tierRegistry()`, real `TierRegistry`), covering every spec-delta scenario:
  - unknown-selector call (e.g. legacy `increaseApproval(address,uint256)` `0xd73dd623`) on a NON-allowlisted token ⇒ `DisallowedBatchCallee(token)`;
  - `setApprovalForAll(attacker, true)` on a non-allowlisted mock ERC-721 ⇒ `DisallowedBatchCallee(nft)` — the issue #18 witness;
  - empty-calldata call with `value > 0` to a random address ⇒ `DisallowedBatchCallee`;
  - `asset()` calls exempt from the callee gate but still recipient-guarded (`asset().approve(attacker, max)` ⇒ `DisallowedTransferTarget`);
  - allowlisted adapter callee passes; allowlisted TOKEN + non-allowlisted recipient still refused by the retained inner layer (`DisallowedTransferTarget`);
  - degrade-open: registry unset AND governor without the getter ⇒ callee gate skipped, batch proceeds under Parts 1/1b + meters (one test per degrade branch);
  - codehash drift: allowlist target, `vm.etch` different code ⇒ `DisallowedBatchCallee`; demotion (`demote`) severs callability.
- [ ] 4.2 Revert-ordering sweep: every existing registry-wired test that drives a guarded selector at a non-allowlisted, non-`asset()` token now hits `DisallowedBatchCallee` before `DisallowedTransferTarget`/`MalformedCall`. In `test/vault/SelectorGuard.t.sol` (and any other suite asserting those errors), add `setAdapterAllowed(token, true)` (or retarget to `asset()`) so each test still exercises the layer it pins; keep at least one un-allowlisted case per suite asserting the NEW error so the ordering itself is pinned.
- [ ] 4.3 Registry-wired flow sweep (design.md "Test impact"): `test/vault/OutflowMetering.t.sol`, `test/GovernorCoverageGates.t.sol`, `test/governor/TierResolution.t.sol`, `test/integration/TierEndToEnd.t.sol`, `test/integration/Robinhood*IntegrationTest.sol`, `test/integration/strategies/PortfolioMainnetFork.t.sol` — allowlist any legitimately-called mock/protocol target in setup. Registry-less suites need no edits.
- [ ] 4.4 Confirm untouched and green: `test/audit-fixes/Vault_batchQueueTargets.t.sol`, `Vault_batchQueueTargets_lifecycle.t.sol`, `test/audit-fixes/Governor_proposeTargetValidation.t.sol`, and the Part 1b source-guard tests. If any needs edits, the change regressed the unconditional layers — stop and revisit.

## 5. Migration / cross-issue follow-through (record, don't execute here)

- [ ] 5.1 Add the upgrade checklist to the deployment notes (wherever `script/`'s upgrade docs live): (a) pre-populate `setAdapterAllowed` for every non-`asset()` target live batches call; (b) upgrade each vault only with no open proposal, or after verifying the open proposal's stored call targets are `asset()`/allowlisted (one open proposal max per vault).
- [ ] 5.2 Draft (do not post as closure) the comment for issue #18 recommending it be closed as subsumed by this change, quoting design.md Decision 4's claim + residual. Also note on issue #115 / PR #157 that the deferred Option B follow-up is implemented here. Use `--body-file` for both — the bodies contain backticks.

## 6. Verify

- [ ] 6.1 `forge build` + full `forge test` in the FOREGROUND with a generous timeout, serialized behind any live build (`while pgrep -x forge >/dev/null; do sleep 30; done`; `pgrep -x solc` is inert — the binary is `solc-0.8.28`). Never judge a build through a piped exit code.
- [ ] 6.2 `forge fmt --check` on `src/`, `test/`, `script/` with a CI-matching forge.
- [ ] 6.3 `openspec validate target-based-batch-gating --strict`.
