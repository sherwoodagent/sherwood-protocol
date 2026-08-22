# Remove VeniceInferenceStrategy entirely

## Why

Ana has decided to delete `VeniceInferenceStrategy` from the repo outright — a
direct instruction, not tied to an issue. It is one of only two concrete
templates deriving `BaseStrategy` (the other is `PortfolioStrategy`), and it
carries its own live capability spec (`openspec/specs/venice-inference-strategy/`)
plus a dedicated test suite, integration harness, and deploy-script wiring.
Following this repo's own `retire-lane-a` precedent for a full capability
retirement (delete first, spec-sync second), this change removes the
contract, its tests, its deploy-script surface, and retires the spec.

**This is a whole-file deletion, not a neutralization.** Unlike `retire-lane-a`
(which deletes ~1,600 unreachable lines because a vault proxy is live and
storage-layout matters), `VeniceInferenceStrategy` is an ERC-1167 clonable
template with no proxy/UUPS storage-layout constraint of its own — clones are
minimal proxies, not upgradeable, so there is nothing to keep golden-pinned.
`./script/check-layout-goldens.sh` is unaffected (it only pins
`SyndicateFactory`; no vault/governor proxy is live in this repo at all — see
the `retire-lane-a` precedent's own "Deployment reality" section).

## What Changes

- **Delete `src/strategies/VeniceInferenceStrategy.sol`** whole.
- **Delete 3 dedicated test files**: `test/VeniceInferenceStrategy.t.sol`,
  `test/VeniceInferenceStrategyAdapterAllowlist.t.sol`,
  `test/integration/strategies/VeniceInferenceIntegration.t.sol`.
- **`test/integration/BaseIntegrationTest.sol`**: kept (generic fork-test
  harness reusable by a future strategy's integration suite — deploy stack,
  owner-bond, syndicate creation, LP funding, propose/vote/execute helpers are
  all protocol-agnostic), but its Venice-only dead weight is stripped: the
  unused `VVV_TOKEN`/`SVVV` constants (the sole importer that used them,
  `VeniceInferenceIntegration.t.sol`, is deleted above) and 3 comment
  mentions of Venice.
- **3 shared test files edited, not deleted** (they cover `PortfolioStrategy`
  too): `test/PortfolioStrategy.t.sol` (one comment citation reworded),
  `test/mocks/MockGovernorAlwaysActive.sol` (two doc-comment file lists
  trimmed), `test/audit-fixes/Strategy_init_frontrun.t.sol` (drops the
  `VeniceInferenceStrategy` import and its now-vacuous
  `test_venice_template_is_locked` "other concrete strategies" section —
  `PortfolioStrategy` was the only other one and is already covered above it
  in the same file).
- **`src/strategies/BaseStrategy.sol`**: the `IGovernorBinding` natspec cited
  `VeniceInferenceStrategy`'s `ITierBindingPath` (src/strategies/VeniceInferenceStrategy.sol:43)
  as precedent for "declared locally rather than imported". `PortfolioStrategy`
  declares the byte-for-byte identical `ITierBindingPath` interface
  (src/strategies/PortfolioStrategy.sol:37) for the same reason, so the
  citation is repointed there rather than deleted — the documented invariant
  (why this interface exists / isn't imported) is still true and still
  demonstrated in the surviving codebase.
- **`script/DeployTemplates.s.sol`**: removes the `VeniceInferenceStrategy`
  import, the `VENICE_KEY` constant, the `venice` field of `struct Templates`,
  its JSON read/save lines, its deploy-if-stale block, and its two validation
  checks — following the exact same lifecycle shape still used for
  `portfolio`/`uniswapSwapAdapter` in the same file. The per-chain-matrix
  doc comment is updated: chains without Uniswap V3 now deploy nothing via
  this script (Venice was the only unconditional template).
- **`script/DeployStrategyFactory.s.sol`**: drops `VENICE_INFERENCE_TEMPLATE`
  from `_templateKeys()` (6 → 5 entries). Found via re-verification grep, not
  in the original scope list, but the same allowlist-approval lifecycle as
  the other `*_TEMPLATE` keys.
- **`src/StrategyFactory.sol`**: drops "Venice" from the `approvedTemplate`
  natspec's example template list (comment only).
- **`README.md`**: drops the `VeniceInferenceStrategy.sol` row from the
  strategy templates table.
- **`openspec/specs/venice-inference-strategy/spec.md`**: retired via this
  change's delta spec (below) — its one requirement is removed with the
  contract it describes. Per the `retire-lane-a` precedent
  ("delete entirely rather than leaving an empty shell"), the main spec file
  is deleted at sync/archive time since zero requirements survive.

## NOT Changed (considered and left alone)

- **`chains/8453.json` / `chains/84532.json`**: still carry a
  `VENICE_INFERENCE_TEMPLATE` address. These are live/historical deployment
  records of contracts that genuinely exist on-chain at those addresses
  (Base mainnet / Base Sepolia) — deleting the Solidity source does not
  un-deploy the bytecode. Treated the same as `broadcast/` deployment
  artifacts: historical record, not code, out of scope for a source-deletion
  PR. `DeployTemplates.s.sol` and `DeployStrategyFactory.s.sol` no longer
  read this key, so it is inert, not actively misleading.
- **`openspec/changes/fix-strategy-clone-ratchet/`** and
  **`openspec/changes/portfolio-swap-adapter-allowlist/`**: both still
  under `openspec/changes/` (not archived), both mention Venice, but both
  mentions are incidental precedent citations in planning docs describing
  work already merged (`fix-strategy-clone-ratchet`'s tasks are all `[x]`;
  `portfolio-swap-adapter-allowlist` cites Venice only to note it as an
  out-of-scope follow-up). Neither change's own function depends on Venice
  existing. Left untouched per historical-accuracy convention.
- **`openspec/changes/retire-lane-a/`**: mentions
  `VeniceInferenceStrategy` twice (design.md, tasks.md), both incidental
  ("`PortfolioStrategy` and `VeniceInferenceStrategy` inherit the defaults
  and override nothing" / "Do not touch ... `VeniceInferenceStrategy.sol`").
  Not yet implemented (0/37 tasks done); when its implementer reaches that
  step, "do not touch" a file that no longer exists is trivially satisfied.
  Left untouched — out of scope for this change.
- **`openspec/changes/archive/2026-08-03-venice-inference-adapter-allowlist/`**:
  already-archived historical record. Never touched.

## Impact

- Affected spec: `venice-inference-strategy` (1 requirement removed; spec
  file deleted at archive since zero requirements remain).
- Affected code: `src/strategies/VeniceInferenceStrategy.sol` (deleted),
  `src/strategies/BaseStrategy.sol` (comment), `src/StrategyFactory.sol`
  (comment), `script/DeployTemplates.s.sol`, `script/DeployStrategyFactory.s.sol`,
  `README.md`.
- Affected tests: 3 files deleted, 4 files surgically edited (see above).
- No storage-layout impact: strategy clones are ERC-1167 minimal proxies, not
  UUPS/golden-pinned. `./script/check-layout-goldens.sh` is expected to show
  zero diff.
