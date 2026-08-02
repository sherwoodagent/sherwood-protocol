# Enforce haircut / Lane A exclusivity in PriceRouter's setters (issue #59, partial)

## Why

Issue #59: the realizability haircut is applied one-sided but consumed symmetrically. `PriceRouter._priceOne` discounts a position's value by `haircutBps[kind]` (`src/pricing/PriceRouter.sol:155`), and `SyndicateVault.totalAssets()` consumes that single discounted number for BOTH directions (`src/SyndicateVault.sol:901-908` via `_laneState` → `valueStrategy`, `src/SyndicateVault.sol:794`). On redemption the discount is conservative and correct; on deposit it inverts — the vault mints against an understated NAV, so a Lane A depositor receives more shares than the position is worth, a wealth transfer from existing holders.

Today nothing on-chain stops the unsafe combination `haircutBps[kind] != 0 && laneAEnabled[kind]`. `setHaircutBps` checks only the 10_000 bound and monotonicity (`src/pricing/PriceRouter.sol:190-195`); `setLaneAEnabled` is an unguarded assignment (`src/pricing/PriceRouter.sol:206-209`). The only guard is `DeployLaneA.s.sol`'s PRE-FLIGHT G2 — a script assert that binds exactly one deploy transaction and nothing the owner does afterwards. Worse, `HaircutCannotDecrease` makes the haircut a one-way door: reach the unsafe state once and it is PERMANENT short of a contract upgrade. PR #104 (`feat/lane-a-enablement`) makes this reachable in practice: it ships the first in-tree adapters and the script that enables Lane A, so a single owner transaction after enablement arms the transfer forever.

## What Changes

- `setHaircutBps(kind, bps)` SHALL revert when `bps != 0 && laneAEnabled[kind]` — a live Lane A kind cannot acquire a haircut.
- `setLaneAEnabled(kind, true)` SHALL revert when `haircutBps[kind] != 0` — a haircut kind cannot go live on Lane A. (Disabling, `enabled == false`, is never blocked — it is the de-escalation path.)
- Both guards are needed because the unsafe state is reachable from either order; guarding one setter is the compose-bypass the codebase already names as an anti-pattern (precedent: `TokenCourt.setChallengeGame` natspec; change `enforce-floor-invariant-in-setters`, issue #84).
- New error `HaircutLaneAConflict()` shared by both setters (see design.md D1 for why one selector, not two).
- Correct the stale "Currently dormant" natspec on `setHaircutBps` (`src/pricing/PriceRouter.sol:186-189`): PR #104 itself falsifies two of its three clauses (adapters now exist in-tree; `script/DeployLaneA.s.sol` registers them and can enable Lane A). Replace it with the actual guarantee: the unsafe combination is now refused on-chain.
- `DeployLaneA.s.sol` PRE-FLIGHT G2 is KEPT (see design.md D3) with its comment updated to state what it still uniquely covers.

**Explicitly NOT fixed here — issue #59 stays OPEN after this lands.** The underlying asymmetry (one quote consumed by two directions) is untouched: with the guards, the haircut simply cannot coexist with Lane A, which is a refusal, not a repair. The real fix is a two-sided quote — un-haircut "ask" for mints, haircut "bid" for redemptions — which is an `IPriceRouter` interface change with vault-side consumption changes, deferred to its own proposal (see design.md "Follow-up"). This change removes the wealth-transfer foot-gun so Lane A can ship on PR #104's haircut-0 parameterization without a latent one-way door.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `epoch-nav`: the requirement "Router pricing parameters are owner-gated with a one-way haircut" (openspec/specs/epoch-nav/spec.md:67-84) gains the mutual-exclusion invariant: `setHaircutBps` and `setLaneAEnabled` SHALL refuse to create the state `haircutBps[kind] != 0 && laneAEnabled[kind]`, from either direction, with `HaircutLaneAConflict`.

## Impact

- `src/pricing/PriceRouter.sol` — two revert branches + one new error + natspec correction. No storage change, no new state variables, `__gap` untouched; UUPS layout is unaffected (verified: guards read two existing mappings only).
- `script/DeployLaneA.s.sol` — PRE-FLIGHT G2 comment update only; behavior unchanged.
- `test/pricing/PriceRouter.t.sol` — new guard tests (both directions, both orders, honest paths, permanence). No existing test in the repo sets a nonzero haircut on a Lane-A-enabled kind, so no existing test breaks (full caller sweep in design.md).
- `openspec/specs/epoch-nav/spec.md` — delta in this change.

### Merge order — read before opening the PR

**PR #104 (`feat/lane-a-enablement`) MUST merge before this change.** This branch (`fix/issue-59-haircut-lane-invariant`) is deliberately stacked on `feat/lane-a-enablement` (PR #104 head, 9838149) because #104 owns `src/pricing/PriceRouter.sol` edits and ships the adapters/script this proposal's motivation cites. The PR for this change must be opened with base `feat/lane-a-enablement` and retargeted to `main` after #104 merges.

**CI warning:** `.github/workflows/ci.yml` filters `pull_request: branches: [main]`, so a PR based on `feat/lane-a-enablement` triggers ZERO checks and shows an EMPTY check list — which reads like "passing" but is nothing. Verification is local (`forge test`) until the PR is retargeted to `main`; re-confirm CI actually ran after retargeting.
