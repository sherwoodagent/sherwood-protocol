# Tasks

> Line references are against `origin/main` @ `00a264a`. No pending change edits
> `BaseStrategy.execute()`; no conflict with off-limits #35/#45/#115. Spec/planning
> only until this change is approved — src/ and test/ edits happen at apply time.

## 1. BaseStrategy — the binding check

- [x] 1.1 `src/strategies/BaseStrategy.sol`: add a one-member local interface `IGovernorBinding { function governor() external view returns (address); }` (precedent: `ITierBindingPath`, src/strategies/VeniceInferenceStrategy.sol:43) and import the existing `IProposalStatus` (src/interfaces/IProposalStatus.sol).
- [x] 1.2 Add error `NotActiveProposalStrategy()` alongside the existing errors (:29-36).
- [x] 1.3 In `execute()` (:86-90), after the `onlyVault` modifier and BEFORE the ratchet check/flip, add the binding check: resolve `gov = IGovernorBinding(_vault).governor()`, `pid = IProposalStatus(gov).getActiveProposal()`, and revert `NotActiveProposalStrategy()` unless `IProposalStatus(gov).strategyOf(pid) == address(this)`. Typed calls, no capability probe, no try/catch — fail-closed is the design (design.md Decision 2). `pid == 0` needs no special case (`strategyOf(0) == address(0)`).
- [x] 1.4 Natspec on `execute()` stating the adversary (house style): an unrelated proposal's batch reaching this clone with `msg.sender == vault` via `executeGovernorBatch`'s delegatecall, flipping the one-shot ratchet and bricking the owning proposal (issue #150). State that `settle()` is deliberately NOT guarded (transitive protection + orphaned-clone recovery — cite design.md) so a future symmetry refactor has to confront the argument.
- [x] 1.5 Do NOT add state variables, do NOT change `initialize`/`IStrategy`, do NOT touch `settle()`/`updateParams()`, do NOT modify governor/vault/factory. Zero storage delta is a review checkpoint, not an accident.

## 2. Tests — new coverage

- [x] 2.1 New `test/audit-fixes/Strategy_cloneRatchetBinding.t.sol` (harness modeled on `test/audit-fixes/Vault_batchQueueTargets_lifecycle.t.sol`): the #150 PoC shape inverted — pre-deploy clone B via `StrategyFactory`, run unrelated proposal P1 (strategy = clone A) whose `executeCalls` include `cloneB.execute()`, assert `executeProposal(P1)` reverts `NotActiveProposalStrategy`; then propose P2 (strategy = clone B) and assert full execute + settle succeeds. This test is the change's acceptance criterion.
- [x] 2.2 Happy-path pin: the owning proposal's batch executes its declared clone (check passes, ratchet flips), and a duplicate `clone.execute()` entry in the same batch still reverts `AlreadyExecuted` (ratchet semantics unchanged for the owner).
- [x] 2.3 Fail-closed pins: (a) direct `vm.prank(vault)` call with no active proposal reverts `NotActiveProposalStrategy`; (b) a vault stub without `governor()` ⇒ `execute()` reverts (any revert acceptable — typed-call failure); (c) a governor stub without the `IProposalStatus` views ⇒ same. Comment each as pinning DELIBERATE fail-closed behavior (design.md Decision 2), the inversion of #118's degrade-open.
- [x] 2.4 Orphan-recovery pin: drive a clone to `Executed`, terminate its proposal via the emergency path with owner-supplied calls that bypass the clone, then have a later proposal's batch call `clone.settle()` and assert the clone's balance returns to the vault. Pins the deliberate absence of a settle guard.

## 3. Tests — existing-harness sweep

- [x] 3.1 Enumerate affected sites: `grep -rn "\.execute()" test/` filtered to `BaseStrategy`-derived instances, plus every suite constructing `MockStrategy` (test/mocks/MockStrategy.sol:22) with a vault it later pranks.
- [x] 3.2 For each site: if the harness has a real governor+vault lifecycle, expect no change (the binding holds by construction — verify, don't assume). If it pranks the vault directly, wire the mock stack so `vault.governor()` answers and the governor answers `getActiveProposal()`/`strategyOf()` (reuse `MockProposalStatus`, referenced at src/interfaces/IProposalStatus.sol:10), or convert the test to assert `NotActiveProposalStrategy` where that is the more honest pin. Prefer one shared helper over N copies.
- [x] 3.3 `test/audit-fixes/Strategy_init_frontrun.t.sol` and `test/StrategyFactory.t.sol` exercise `initialize`, not `execute` — confirm untouched. If either needs edits, the change leaked beyond `execute()` — stop and revisit.

## 4. Deployment note (no migration)

- [x] 4.1 Confirm (re-run, don't trust this doc): no `cloneAndInit`/`StrategyCloned` in any `broadcast/**/run-*.json`, and no 4663 strategy broadcasts — i.e. still zero deployed clones in scope. If a clone appeared since, add its disposition to design.md Decision 4 before merging.
- [x] 4.2 Template rollout is ordinary deployment: new template deploys (`script/DeployTemplates.s.sol` and per-strategy deploy scripts) + `setTemplateApproval` on the factory. No dual-version window to manage; note in the PR description, no doc change owed.

## 5. Verify

- [x] 5.1 `forge build` + full `forge test` in the FOREGROUND with a generous timeout, serialized behind any live build (`while pgrep -x forge >/dev/null; do sleep 30; done`; `pgrep -x solc` is inert — the binary is `solc-0.8.28`). Never judge a build through a piped exit code.
- [x] 5.2 `forge fmt --check` on src/ and test/ with a CI-matching forge.
- [x] 5.3 Storage-layout goldens: run `script/check-layout-goldens.sh` and confirm it passes UNCHANGED (this change owes zero storage delta anywhere; the script does not cover strategies — design.md Decision 3).
- [x] 5.4 `openspec validate fix-strategy-clone-ratchet --strict`.
- [x] 5.5 Post-landing: comment on issue #150 that the PoC shape from the 2026-08-03 verification now reverts `NotActiveProposalStrategy` at the unrelated proposal's `executeProposal`, with the residual (self-declared foreign clone, governance-gated) explicitly restated so the issue closes against evidence, not vibes.
