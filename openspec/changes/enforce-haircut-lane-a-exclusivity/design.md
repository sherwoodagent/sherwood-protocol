# Design — enforce haircut / Lane A exclusivity in PriceRouter's setters

## Context

See proposal.md — Why. Verified current state on THIS branch (`fix/issue-59-haircut-lane-invariant` @ 9838149, head of PR #104's `feat/lane-a-enablement` — NOT main):

- `_priceOne` applies the one-sided haircut: `(raw * (MAX_HAIRCUT_BPS - haircutBps[p.kind])) / MAX_HAIRCUT_BPS` — `src/pricing/PriceRouter.sol:155`. Both `valuePosition` (`:94-96`) and `valueStrategy` (`:113`) route through it.
- `SyndicateVault.totalAssets()` consumes the single haircut value in both directions: `_laneState` calls `IPriceRouter.valueStrategy(active)` (`src/SyndicateVault.sol:794`) and `totalAssets()` adds the result to the idle float (`src/SyndicateVault.sol:901-908`). The same `totalAssets()` prices deposits (share mint) and instant exits (share burn) — the asymmetry issue #59 describes.
- `setHaircutBps`'s only checks are `bps > MAX_HAIRCUT_BPS → HaircutTooHigh` (`src/pricing/PriceRouter.sol:191`) and `bps < haircutBps[kind] → HaircutCannotDecrease` (`:192`). It never reads `laneAEnabled`.
- `setLaneAEnabled` is an unguarded owner assignment (`src/pricing/PriceRouter.sol:206-209`).
- `HaircutCannotDecrease` (`:192`) makes a nonzero haircut IRREVERSIBLE at the setter level (the interface natspec says so explicitly: "lowering requires a contract upgrade", `src/interfaces/IPriceRouter.sol:47-50`). Consequence: without the `setHaircutBps` guard, one owner transaction on a live Lane A kind creates a PERMANENT unsafe state — every subsequent Lane A deposit on that kind mints against understated NAV until a UUPS upgrade ships.
- The only existing defense is deploy-time: `DeployLaneA.s.sol` PRE-FLIGHT G2 documents the hazard (`script/DeployLaneA.s.sol:79-87`), asserts `haircutBps == 0` for both Lane-A kinds before any wiring (`:301-302` → `checkHaircutsZero`, `:503-527`), and re-asserts against live chain state immediately before the enable switch (`:425-428`). All of that binds ONE broadcast of ONE script. It cannot see a `setHaircutBps` the owner sends next week: the setters are `onlyOwner` calls on a live contract, and nothing routes them through the script. A deploy gate constrains how the state is created; only a runtime guard constrains every transition thereafter.
- Stale natspec: `src/pricing/PriceRouter.sol:186-189` still reads "Currently dormant: no `IPriceAdapter` implementation exists in-tree, no deploy script registers one or enables Lane A, and this mapping defaults to 0." On this branch, PR #104 adds `src/pricing/Erc20SpotAdapter.sol`, `src/pricing/MorphoSupplyAdapter.sol`, and `script/DeployLaneA.s.sol` (which registers both and can enable Lane A) — two of the three clauses are false the moment #104 merges. Only "this mapping defaults to 0" survives.

Constraint: this change stacks on PR #104, which owns `src/pricing/PriceRouter.sol`. Base branch is `feat/lane-a-enablement`; see proposal.md — Merge order (including the empty-CI-check-list trap for stacked PRs).

## Goals / Non-Goals

**Goals:**
- Make `haircutBps[kind] != 0 && laneAEnabled[kind]` unreachable through the setters, from both orders.
- Replace the falsified "Currently dormant" natspec with the true post-change guarantee.
- Keep PRE-FLIGHT G2 and update its comment to state what it still uniquely covers (D3).

**Non-Goals:**
- No fix to the underlying one-sided-quote asymmetry — see Follow-up. Issue #59 stays open.
- No change to `_priceOne`, `valueStrategy`, `HaircutCannotDecrease`, `IPriceRouter`, or any vault code.
- No owner override / escape hatch on the enable-side guard (D2 argues why).
- No storage changes of any kind.

## Decisions

### D1 — One shared error, `HaircutLaneAConflict()`

One selector, not two directional ones (`HaircutOnLaneAKind` / `LaneAOnHaircutKind` rejected):

- It is ONE invariant — "nonzero haircut and enabled Lane A are mutually exclusive" — enforced at its two write sites. Two selectors would suggest two different rules.
- The caller already knows which guard fired without a selector telling them: the revert carries the function they called. `setHaircutBps` reverting `HaircutLaneAConflict` can only mean "this kind is Lane-A-enabled"; `setLaneAEnabled` reverting it can only mean "this kind carries a haircut". There is no call site where the selector alone must disambiguate.
- Precedent: #84 (`enforce-floor-invariant-in-setters`, D7) added ONE `FloorInvariantViolated()` shared by `setParticipationFloorBps` and `setStakedWood` — the same two-setters-one-invariant shape. A distinct selector per direction would be the first of its kind in the repo.
- Distinct from reusing an existing error: `HaircutTooHigh`/`HaircutCannotDecrease` describe bounds on the value; this describes a cross-parameter state conflict. A distinct selector tells the operator which OTHER parameter to look at, matching #84's `FloorInvariantViolated` vs `InvalidParameter` reasoning.

Declared in `PriceRouter` beside the existing errors (`src/pricing/PriceRouter.sol:68-70`). Not added to `IPriceRouter` — the router's existing errors live in the contract, not the interface (`IPriceRouter` declares none), and this change does not touch the interface.

### D2 — No escape hatch on guard 2: permanent refusal is correct

If a kind somehow carries a nonzero haircut, guard 2 blocks `setLaneAEnabled(kind, true)` forever — the haircut cannot be lowered (`HaircutCannotDecrease`), so the kind's instant lane is closed until a contract upgrade. Is that acceptable? Yes, argued from what the alternative permits:

- **The blocked action is a known wealth transfer, not a liveness need.** Enabling Lane A on a haircut kind means every Lane A deposit on that kind mints excess shares against understated NAV (`src/pricing/PriceRouter.sol:171-185`'s own analysis). An override would exist solely to authorize that transfer "knowingly" — but the owner's knowledge does not compensate the existing holders who fund it. There is no configuration in which the combined state is correct under the current one-sided quote; an override is a switch whose only honest label is "harm LPs".
- **The failure mode is liveness-degraded, not funds-wedged.** A haircut kind simply stays Lane B: deposits and exits still work through the async queue at settlement prices (`valueStrategy` returns `(0,false)` for disabled kinds and the vault degrades to float-only NAV, `src/SyndicateVault.sol:794-799, 901-908`). Nothing is locked; the vault's whole pre-Lane-A operating mode remains available. Fail-safe states that degrade to a working slow path do not need escape hatches.
- **The upgrade path IS the escape hatch, with the right friction.** `PriceRouter` is UUPS (`_authorizeUpgrade`, `src/pricing/PriceRouter.sol:211`) and `HaircutCannotDecrease`'s documented remedy is already "a contract upgrade (which itself inherits the owner multisig's delay)" (`src/interfaces/IPriceRouter.sol:48-49`). The legitimate way out — shipping the two-sided quote, after which haircut+Lane A is safe by construction — arrives as an upgrade anyway. Reaching the state "haircut set by mistake" also has upgrade as its documented remedy today; this change does not make that worse.
- **An override would gut guard 1's value.** The scenario guard 2 exists for (haircut first, enable second) is exactly the one PRE-FLIGHT G2 refuses at deploy; an owner override would recreate the "one transaction arms it permanently" hazard with an extra step, and the extra step is not a real cost to a compromised or careless owner — the adversary both guards assume.

Consistency check: `setLaneAEnabled(kind, false)` must never be guarded — de-escalation stays a single unconditional owner action (the spec delta pins this).

### D3 — PRE-FLIGHT G2: KEEP, with an updated comment

The #84 precedent (its design D6) kept the deploy pre-flight after adding setter guards because the script sees state the setters never do. Checked against this contract, the strongest #84 reason does NOT transfer, but three others do:

1. **No constructor/initializer bypass here — checked and ruled out.** Unlike TokenCourt (deploy default written at declaration, never through the setter), `PriceRouter`'s constructor only calls `_disableInitializers()` (`src/pricing/PriceRouter.sol:77-79`) and `initialize` only sets the owner (`:81-84`). `haircutBps` and `laneAEnabled` have no write path except the two guarded setters. So the "setters never saw this state" argument does not apply to a router running the guarded implementation.
2. **The script cannot assume the guarded implementation.** `DeployLaneA` wires an EXISTING router by address (`cfg.router`) — including proxies still running the pre-guard implementation (the guard ships as a UUPS upgrade for anything already deployed, and #104's Base-legacy caveat means some routers may never be upgradable). Against a pre-guard router, G2 is the only check standing between a poisoned haircut and `setLaneAEnabled(kind, true)` at `script/DeployLaneA.s.sol:437-438`. The runtime guard only protects routers that run it.
3. **G2 fails BEFORE anything is deployed; the guard fails mid-broadcast.** The pre-flight at `:301-302` aborts before adapters are deployed and registered (proven by `test/integration/LaneAWiring.t.sol:493-510`: "the refusal is total: nothing was registered"). Relying on the runtime guard instead would deploy two adapters, seed the feed registry, register kinds, set caps and fees, and then revert at the enable step — a partially-wired, harder-to-reason-about broadcast failure. Failing early with G2's four-line diagnostic beats failing late with a bare `HaircutLaneAConflict`.
4. **It is a free script assert; removing it buys nothing** (verbatim from #84 D6.3, equally true here).

Comment update mirrors how #84 updated PRE-FLIGHT 4's comment: state that both setters now enforce the exclusion on-chain (`HaircutLaneAConflict`), and that what G2 still uniquely covers is (a) routers running a pre-guard implementation and (b) failing before the broadcast deploys anything. Do not change `checkHaircutsZero`'s behavior or its revert strings — `test/integration/LaneAWiring.t.sol:493-517` pins them (`_assertPrefix(reason, "PRE-FLIGHT G2")`) and both tests stay green as-is (see sweep).

### D4 — No legitimate configuration is forbidden (full sweep)

Searched every `setHaircutBps` call in the repo for one that sets a nonzero haircut on a Lane-A-enabled kind (`grep -rn "setHaircutBps\|setLaneAEnabled" src/ test/ script/`):

- `test/pricing/PriceRouter.t.sol:76,148-152,159,177` — all on `KIND` with Lane A never enabled in those tests (the enable calls at `:222,232,242,264,275` are in separate `valueStrategy` tests that never set a haircut). No conflict.
- `test/integration/LaneAWiring.t.sol:496,515` — nonzero haircuts set on FRESH routers (`poisoned = _newRouter(...)`) whose kinds were never enabled, precisely to prove G2 refuses them. No conflict; these tests are the deploy-gate documentation and remain valid.
- `script/DeployLaneA.s.sol` — never calls `setHaircutBps` at all (haircut-0 is the shipped parameterization; G2 enforces it).
- `src/` — no caller besides the setter itself.

Nothing in the repo wants the forbidden state. The two `LaneAWiring` "poisoned" tests set haircuts on DISABLED kinds — exactly the configuration the guards still permit — so they are neither pinning unsafe behavior nor a use case that changes the design. The one configuration the guards remove that anyone could argue for — "haircut the kind AND leave Lane A on, accepting the deposit-side transfer as the price of a conservative exit mark" — is the wealth transfer #59 exists to prevent; the honest version of that posture is `laneAEnabled = false` (queue-only), which remains fully available.

### D5 — Guard placement and natspec

- In `setHaircutBps`, the conflict check sits after the existing bounds/monotonicity checks: `if (bps != 0 && laneAEnabled[kind]) revert HaircutLaneAConflict();`. Ordering rationale: `HaircutTooHigh`/`HaircutCannotDecrease` remain the errors for out-of-domain values so existing tests (`test/pricing/PriceRouter.t.sol:146-160`) keep their exact selectors; the conflict error fires only for values that would otherwise have been accepted.
- In `setLaneAEnabled`: `if (enabled && haircutBps[kind] != 0) revert HaircutLaneAConflict();` before the assignment. `enabled == false` short-circuits — disabling never reads the haircut.
- The `setHaircutBps` natspec keeps its one-sided-asymmetry analysis (`src/pricing/PriceRouter.sol:171-185` — still true and still the motivation) but replaces the "Until then, keep the haircut at 0…" advisory and the falsified "Currently dormant" paragraph (`:184-189`) with: the combination is now refused on-chain in both setters (`HaircutLaneAConflict`); adapters exist in-tree and `DeployLaneA` registers them; a kind that needs a haircut therefore stays Lane B until the two-sided quote ships. House style: the guard states its adversary (the Lane A depositor minting against understated NAV).
- `setLaneAEnabled`'s natspec gains the enable-side half: enabling requires a zero haircut, disabling is never blocked.

### D6 — Storage / UUPS: no implication (verified)

The guards add two `revert` branches reading two EXISTING mappings (`haircutBps`, `laneAEnabled`) and one new custom error (errors are ABI artifacts, not storage). No new state variable, no reordering, `uint256[46] private __gap` (`src/pricing/PriceRouter.sol:66`) untouched, no new initializer and no reinitializer needed — the guard is pure code, so existing proxies pick it up on their next `upgradeToAndCall` with no migration call. `_authorizeUpgrade` (`:211`) unchanged.

One honest caveat, recorded rather than solved: an already-deployed proxy that is ALREADY in the unsafe state (nonzero haircut + enabled) is not repaired by upgrading to the guarded implementation — the guards constrain transitions, not standing state. No such deployment exists (Lane A has never been enabled anywhere; #104 is the enablement change), and G2 refuses to wire one.

## Affected callers and tests (full sweep)

From `grep -rn "setHaircutBps\|setLaneAEnabled" test/ script/ src/`:

| Site | Today | After the guards | Action |
|---|---|---|---|
| `test/pricing/PriceRouter.t.sol:76` (`test_valuePosition_appliesHaircut`) | haircut 100 on never-enabled KIND | passes — guard 1 needs `laneAEnabled == true` to fire | none |
| `test/pricing/PriceRouter.t.sol:148-152` (`test_setHaircut_monotoneIncreaseOnly`) | passes | passes — KIND never enabled | none |
| `test/pricing/PriceRouter.t.sol:159,177` (bounds / onlyOwner) | pass | pass — bounds and owner checks fire before/without the conflict check | none |
| `test/pricing/PriceRouter.t.sol:222,232,242,264` (`setLaneAEnabled(KIND, true)` in valueStrategy tests) | pass | pass — haircut is 0 in every one | none |
| `test/pricing/PriceRouter.t.sol:275` (`test_setLaneAEnabled_onlyOwner`) | passes | passes — owner check fires first | none |
| `test/integration/LaneAWiring.t.sol:372,380,386-387` (disable/re-enable ladder b) | pass | pass — haircuts are 0 throughout | none |
| `test/integration/LaneAWiring.t.sol:404-405` (bare router enable, ladder c) | pass | pass — fresh router, haircut 0 | none |
| `test/integration/LaneAWiring.t.sol:496,515` (poisoned routers, ladders g) | set nonzero haircut on fresh, never-enabled routers | pass — guard 1 permits haircuts on disabled kinds | none |
| `test/integration/LaneAWiring.t.sol:642-664` (`test_wiring_enableSwitchIsLast`) | passes | passes — script path sets no haircut | none |
| `test/integration/LaneAEndToEnd.t.sol:86` (`setLaneAEnabled(ERC20_SPOT, true)` in setUp) | passes | passes — haircut 0 | none |
| `test/helpers/LaneAFixture.sol:28` (`_registerKind` optional enable) | passes | passes — no fixture sets a haircut | none |
| `script/DeployLaneA.s.sol:437-438` (enable inside broadcast) | G2 already proved haircuts 0 at `:428` | passes; the runtime guard is now a second, on-chain enforcement of the same fact | comment update only (D3) |

**No existing test needs updating.** New tests (tasks.md) all land in `test/pricing/PriceRouter.t.sol`.

## Risks / Trade-offs

- [A future kind genuinely needs both a haircut and instant pricing] → that is the two-sided-quote world; the Follow-up interface change removes the need for a one-sided haircut entirely. Until then the kind runs Lane B — degraded liveness, zero incorrectness.
- [Stacked-PR verification gap: empty CI check list reads as passing] → stated in proposal.md; implementer runs `forge test` locally (serialized behind the build lockfile) and re-checks CI after retargeting to `main`.
- [PR #104 force-pushes/rebases under this branch] → this change touches `PriceRouter.sol:186-209` (natspec + two setters), `DeployLaneA.s.sol:79-87` comment block, and adds tests at the end of `PriceRouter.t.sol` — small, re-appliable regions; rebase is mechanical.
- [Guarded upgrade does not repair a pre-existing unsafe pair] → recorded in D6; no such deployment exists and G2 refuses to create one.

## Migration Plan

Additive-revert-only change to an upgradeable contract. New deployments get it automatically; existing proxies get it at their next UUPS upgrade (no reinitializer, no storage migration — D6). Deploy scripts unchanged in behavior. Rollback = upgrade back to the previous implementation (none expected).

Merge order is part of the migration: PR #104 first, then this (see proposal.md — Merge order).

## Follow-up (NOT this change): the real #59 fix

Issue #59 remains OPEN after this lands. The permanent fix is a two-sided quote so the haircut can exist without the deposit-side transfer:

- `IPriceRouter` interface change: `valueStrategy` (and `valuePosition`) return, or are joined by, a bid/ask pair — un-haircut "ask" consumed by the deposit/mint path, haircut "bid" consumed by the redemption path.
- `SyndicateVault` consumption change: `_laneState`/`totalAssets()` currently thread ONE `liveNav` into every consumer (`src/SyndicateVault.sol:783-800, 901-908`); the vault would need direction-aware NAV (deposit-side previews and mint math on the ask, withdrawal/redeem previews and `maxWithdraw` sizing on the bid) — a share-price-surface change that touches preview functions, the fee marks that read `totalAssets()`, and the EIP-4626 invariants, hence its own proposal with its own analysis.
- Once that exists, the exclusivity guards added here are RELAXED by the same change (the guarded state stops being unsafe) — a deliberate, specced decision at that time, not a reason to soften the guards now.
