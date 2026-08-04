# Tasks

## 1. Delete Venice source and dedicated tests

- [x] 1.1 Delete `src/strategies/VeniceInferenceStrategy.sol`.
- [x] 1.2 Delete `test/VeniceInferenceStrategy.t.sol`.
- [x] 1.3 Delete `test/VeniceInferenceStrategyAdapterAllowlist.t.sol`.
- [x] 1.4 Delete `test/integration/strategies/VeniceInferenceIntegration.t.sol`.

## 2. Surgical edits — shared/generic files that also cover other strategies

- [x] 2.1 `src/strategies/BaseStrategy.sol` — repoint the `IGovernorBinding`
      natspec's `ITierBindingPath` precedent citation from
      `VeniceInferenceStrategy` (deleted) to `PortfolioStrategy`
      (`src/strategies/PortfolioStrategy.sol:37` — verified identical
      interface + identical "declared locally" rationale).
- [x] 2.2 `test/PortfolioStrategy.t.sol` — reword the
      `test_updateParams_slippageCannotBeLoosened` doc comment to drop the
      `VeniceInferenceStrategy` name while keeping the Sherlock #49 citation.
- [x] 2.3 `test/mocks/MockGovernorAlwaysActive.sol` — trim `VeniceInference*`
      out of both doc-comment file lists (`MockGovernorAlwaysActive` and
      `MockVaultGovernorStub`), keeping the surviving `PortfolioStrategy*`
      references intact.
- [x] 2.4 `test/audit-fixes/Strategy_init_frontrun.t.sol` — drop the
      `VeniceInferenceStrategy` import and the `test_venice_template_is_locked`
      test + its now-vacuous "other concrete strategies" section comment
      (Portfolio and Mock were already covered above it in the same file).
- [x] 2.5 `test/integration/BaseIntegrationTest.sol` — found via
      re-verification grep (not in original scope): its sole consumer
      (`VeniceInferenceIntegration.t.sol`) is deleted in 1.4, orphaning the
      `VVV_TOKEN`/`SVVV` constants. Removed both constants and reworded 3
      Venice mentions in comments (contract natspec, fork-gate comment,
      `managementFeeBps` comment). Kept the file itself — the deploy/bond/
      syndicate/fund/propose-vote-execute harness is fully generic and
      reusable by a future strategy's fork-test suite.

## 3. Deploy scripts

- [x] 3.1 `script/DeployTemplates.s.sol` — remove the `VeniceInferenceStrategy`
      import, `VENICE_KEY` constant, `venice` field of `struct Templates`,
      its JSON read/save lines, its deploy-if-stale block, and its two
      validation checks. Update the per-chain-matrix doc comment (Venice was
      the only template deployed unconditionally; chains without Uniswap V3
      now deploy nothing via this script). Portfolio/UniswapSwapAdapter
      blocks untouched.
- [x] 3.2 `script/DeployStrategyFactory.s.sol` — found via re-verification
      grep (not in original scope): drop `VENICE_INFERENCE_TEMPLATE` from
      `_templateKeys()` (array 6 → 5). Other 5 keys untouched.
- [x] 3.3 `src/StrategyFactory.sol` — drop "Venice" from the
      `approvedTemplate` natspec's example template list (comment only).

## 4. Docs

- [x] 4.1 `README.md` — drop the `VeniceInferenceStrategy.sol` row from the
      strategy templates table.

## 5. Do-NOT-touch guard (verified, left alone)

- [x] 5.1 `chains/8453.json` / `chains/84532.json` — live/historical
      deployment records (real on-chain addresses); left untouched, same
      treatment as `broadcast/` artifacts.
- [x] 5.2 `openspec/changes/fix-strategy-clone-ratchet/` — incidental Venice
      precedent citations in a fully-implemented (`[x]` all tasks) planning
      doc; left untouched.
- [x] 5.3 `openspec/changes/portfolio-swap-adapter-allowlist/` — incidental
      Venice mention (follow-up note); left untouched.
- [x] 5.4 `openspec/changes/retire-lane-a/` — incidental Venice mentions in
      an unimplemented (0/37 tasks) planning doc; left untouched.
- [x] 5.5 `openspec/changes/archive/2026-08-03-venice-inference-adapter-allowlist/` —
      already-archived historical record; never touched.
- [x] 5.6 `broadcast/DeployTemplates.s.sol/84532/*.json` — historical
      on-chain deployment records; never touched.

## 6. Spec retirement + validation

- [x] 6.1 Delta spec `specs/venice-inference-strategy/spec.md` in this change
      removes the capability's one requirement (below).
- [x] 6.2 `openspec validate remove-venice-inference-strategy --strict` passes.
- [x] 6.3 `forge build` clean — zero references to `VeniceInferenceStrategy`
      reachable from the build.
- [x] 6.4 `forge test --match-path test/PortfolioStrategy.t.sol` (54 passed)
      and `forge test --match-path test/audit-fixes/Strategy_init_frontrun.t.sol`
      (4 passed) both pass; `test/mocks/MockGovernorAlwaysActive.sol` compiles
      as part of the above. Full non-fork suite: 1795 passed, 9 failed (all in
      `test/integration/strategies/UniswapAdapterFork.t.sol`, which requires
      `--fork-url $BASE_RPC_URL` per its own doc comment and fails identically
      with no Venice changes present — unrelated to this change), 4 skipped
      (fork-gated harnesses self-skipping without a live fork, as designed).
- [x] 6.5 `forge fmt --check` clean.
- [x] 6.6 `./script/check-layout-goldens.sh` shows zero diff (confirms the
      no-storage-layout-impact claim in proposal.md).
- [x] 6.7 Archive this change (`openspec archive remove-venice-inference-strategy`)
      once 6.2–6.6 pass, syncing the delta into main specs and deleting
      `openspec/specs/venice-inference-strategy/spec.md` (zero requirements
      remain, per the `retire-lane-a` "no empty shell" precedent).
