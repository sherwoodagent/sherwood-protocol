# Tasks

Sequenced so the tree compiles at every step — the build lock is contended and
a wasted `via_ir` compile is expensive. Steps 1, 7 and 8 need no build at all;
step 2 is the only production-code edit and lands as ONE pass over ONE file.

Build discipline for every forge invocation below: serialize with
`while pgrep -x forge >/dev/null; do sleep 30; done` (or
`pgrep -f 'solc-[0-9]'` — NEVER `pgrep -x solc`, the binary is named
`solc-0.8.28` and that guard is inert), run forge in the FOREGROUND, and never
pipe its output through `tail`/`head` (a SIGKILLed solc reads as success
through a pipe).

- [ ] 1. **Capture the reference implementation before #104 closes** (no
  build). `gh pr diff 104 > <scratchpad>/pr104.diff` and extract ONLY the
  PortfolioStrategy allowlist/floor hunks: the file-level `ITierBindingPath`
  interface (`governor()` / `tierRegistry()` / `isAdapterAllowed(address)`,
  selectors-only), `error AdapterNotAllowed(address swapAdapter, address
  registry)`, `uint256 public constant MIN_SLIPPAGE_BPS = 50`, the
  `_requireAllowedAdapter(swapAdapter_)` call in `_initialize`, the two
  slippage-bound edits, and the three private helpers
  (`_requireAllowedAdapter`, `_isAdapterAllowed`, `_readAddress`). Everything
  else in that diff is Lane-A-only and stays out (see proposal "What does NOT
  change"): pricing adapters, `MorphoSupplyStrategy`, `_spotFeedRegistry` /
  `_registeredFeed`, `_legMinOut`, `withdrawTo`, `DeployLaneA.s.sol`, and the
  `MAX_SLIPPAGE_CEILING_BPS` natspec rewrite that references `_legMinOut`.

- [ ] 2. **Edit `src/strategies/PortfolioStrategy.sol` in one pass** (single
  file, single compile unit — do not split this across builds):
  - `ITierBindingPath` interface at file level (alongside the existing
    `ChainlinkReport` struct at `:29`).
  - `error AdapterNotAllowed(address swapAdapter, address registry);` and
    `uint256 public constant MIN_SLIPPAGE_BPS = 50;` (a constant — no storage
    layout change; PortfolioStrategy has no layout golden and must not gain
    storage here).
  - In `_initialize`: call `_requireAllowedAdapter(swapAdapter_)` immediately
    after the existing `ZeroAddress` check (`:232`), before any state write;
    change `:240` to
    `if (maxSlippageBps_ < MIN_SLIPPAGE_BPS || maxSlippageBps_ > MAX_SLIPPAGE_CEILING_BPS) revert InvalidSlippage();`
    (the `== 0` rejection is subsumed, error unchanged).
  - In `_updateParams`' tighten path (`:360-361`): inside the existing
    `if (newMaxSlippageBps > 0)` wrapper, extend to
    `if (newMaxSlippageBps > maxSlippageBps || newMaxSlippageBps < MIN_SLIPPAGE_BPS) revert InvalidSlippage();`
    The `== 0` "keep current" sentinel MUST stay outside the floor check.
  - The three private view helpers, per PR #104: `_requireAllowedAdapter`
    (walk `vault() → governor() → tierRegistry()`, return early on any
    `address(0)` hop, revert `AdapterNotAllowed(swapAdapter_, registry)` when
    a resolved registry does not vouch); `_isAdapterAllowed` (codeless → false,
    revert → false, `ret.length != 32` → false); `_readAddress` (codeless
    target, revert, `ret.length < 32`, or dirty upper bits → `address(0)`).
  - Natspec: keep PR #104's binding/degrade rationale on
    `_requireAllowedAdapter`, but re-justify `MIN_SLIPPAGE_BPS` against `main`
    — `rebalanceDelta`'s oracle-anchored `minOut` floors plus the tighten-only
    irreversibility — NOT against `_legMinOut`/`_sellForUnwind`, which do not
    exist here. Likewise trim `_readAddress`'s comment about `feedOf`'s
    multi-field return; on `main` its only callers read single-word getters
    (keep the `>= 32` length bound, adjust the justification).

- [ ] 3. **Build gate.** `forge build` (foreground, serialized as above).
  Nothing else changed yet, so a failure localizes to step 2.

- [ ] 4. **New unit tests — mock walk, no fork dependency** (one new test
  file, e.g. `test/PortfolioStrategyAdapterAllowlist.t.sol`). One test per
  spec scenario:
  - non-allowlisted adapter refused at init with
    `AdapterNotAllowed(adapter, registry)` (assert both args);
  - allowlisted adapter accepted;
  - unresolved walk skips: codeless vault; vault whose `governor()` returns 0;
    governor without a `tierRegistry()` getter; `tierRegistry() == 0`;
  - resolved-but-unreadable registry fails closed: `isAdapterAllowed` reverts;
    wrong return length;
  - init below the floor refused (49 and 0 → `InvalidSlippage`); init above
    the ceiling still refused (existing behavior);
  - tighten below the floor refused, stored value unchanged;
  - zero sentinel keeps current slippage alongside a valid weights update;
  - floor bottoms without trapping: init at exactly 50, re-assert 50 succeeds
    (equality passes the tighten-only `>` check), 49 refused;
  - demotion after init does not brick settlement: allowlist, init, execute,
    clear the allowlist entry, `settle()` completes (no allowlist read after
    init).
  PR #104's tests (`AdapterNotAllowed` expectations in its diff) are a
  starting point but were written against Lane A code — adapt, don't copy.
  Repo gotchas: hoist any argument-position call before `vm.prank` (a call in
  argument position consumes the pending prank); use `vm.getBlockTimestamp()`
  across warps; warps are forward-only.

- [ ] 5. **Targeted test run** (serialized, foreground): the new file plus the
  suites design.md predicts are UNAFFECTED — `test/PortfolioStrategy.t.sol`
  and `test/audit-fixes/Strategy_init_frontrun.t.sol` (codeless `makeAddr`
  vaults → hop-1 skip; all slippage fixtures 100 bps). If either breaks, the
  design's blast-radius analysis was wrong — stop and re-check before touching
  more files.

- [ ] 6. **Fork-suite setUp fixes** —
  `test/integration/strategies/PortfolioIntegration.t.sol` and
  `test/integration/strategies/PortfolioMainnetFork.t.sol`. In each setUp,
  pranked as the TierRegistry owner: (a) `setAdapterAllowed(swapAdapter, true)`
  — required by THIS change; (b) `setAdapterAllowed(<strategy clone>, true)` —
  a PRE-EXISTING fix: at head these suites' `asset.approve(strategy, amount)`
  batch calls already violate `_guardBatchCalls` (guard wiring `9fafa00`
  post-dates the suites; RPC gating hid it). Record (b) as pre-existing in the
  commit/PR notes, not as fallout of this change. Both suites are RPC-gated
  (`vm.envOr` → `vm.skip`): compile them in any case; actually run them only
  if the fork URL env vars are set locally.

- [ ] 7. **Verify the #137/#149 interaction — do not assume** (no build).
  PR #149 (open, codehash-aware `isAdapterAllowed`) keeps the signature
  `isAdapterAllowed(address) external view returns (bool)` — verified against
  its diff at spec time, which is why design.md records "no ordering
  constraint either way". Before merge, re-check: if #149 has landed on
  `main`, re-run steps 4-6's tests on the rebased tree and confirm (a) the
  mock-registry unit tests still pass (they stub the selector, not the
  implementation) and (b) the fork setUps' `setAdapterAllowed(adapter, true)`
  still vouches under #149's semantics (it records the codehash at allow time;
  the suites' adapters do not change code mid-test, so it should). If #149
  changed the external signature after all, stop and update design.md
  decision 1/3 before proceeding.

- [ ] 8. **Docs + follow-up** (no build):
  - `docs/adapter-onboarding-checklist.md`: the allowlist gate
    (`setAdapterAllowed`) now has a SECOND consumer —
    `PortfolioStrategy._initialize` refuses a non-allowlisted swap adapter on
    a wired stack — so allowlisting must precede any proposer clone+init
    against that adapter, and a demotion's auto-clear now also blocks new
    strategy bindings. Fold into the existing dual-gate narrative.
  - File the follow-up issue for `VeniceInferenceStrategy` (same gap class:
    proposer-supplied `aeroRouter`/`sVVV` receive `forceApprove`/stakes at
    `src/strategies/VeniceInferenceStrategy.sol:150,171`). Reference it from
    the PR body; do NOT widen this change.

- [ ] 9. **Full gate** (serialized, foreground): `forge build`, non-fork
  `forge test`, `forge fmt --check src test script` — with a forge matching
  CI's, since fmt rules differ across versions. `openspec validate
  portfolio-swap-adapter-allowlist --strict` once tasks are checked off.

- [ ] 10. **Ship.** Commit, push, open the PR against `main` (a PR based on
  any other branch gets ZERO CI in this repo — empty check list, not a
  failure). Reference issue #147 and this change; note the pre-existing
  fork-suite guard fix (task 6b) separately in the PR body. Operational
  follow-through for live stacks, in the PR body or a linked ops note: this
  ships as NEW TEMPLATE bytecode — deploy the new PortfolioStrategy template
  and approve it via `StrategyFactory` (existing clones keep old code and
  semantics forever; no migration), and owners must `setAdapterAllowed` each
  Portfolio swap adapter before proposers can init against it.

- [ ] 11. **Pashov audit remediation on PR #165** (issue #147 follow-up; see
  design.md section 7 and the new `portfolio-strategy` spec requirement).
  Scope: `src/strategies/PortfolioStrategy.sol`,
  `test/PortfolioStrategyAdapterAllowlist.t.sol`, and this change's docs only
  — not a broader refactor.
  - Add `_requireAllowedAdapter(address(swapAdapter))` as the first thing
    `rebalance()` and `rebalanceDelta(bytes[])` do (ahead of the
    `_rebalancing` flip and any `forceApprove`), reusing the existing
    private helper unchanged — no new allowlist logic, only two new call
    sites. Fail-closed on a resolved-but-demoted adapter; degrade-open on an
    unresolved walk is unchanged (same as decision 2's table).
  - New tests: demoted adapter reverts `AdapterNotAllowed` from `rebalance()`;
    same from `rebalanceDelta()`; both still succeed unchanged when the
    adapter remains allowlisted (regression guard).
  - `forge build`, `forge test --match-path
    "test/PortfolioStrategyAdapterAllowlist.t.sol"`, `forge test --match-path
    "test/PortfolioStrategy.t.sol"` (regression guard on the existing
    happy-path rebalance/rebalanceDelta suites), `forge fmt --check src/
    test/`, `openspec validate portfolio-swap-adapter-allowlist --strict`.
