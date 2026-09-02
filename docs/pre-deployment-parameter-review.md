# Pre-deployment parameter review — the three inert defaults

Three risk parameters ship with a default that **does not bind**. None of them
is seeded by any deploy script, because all three live on contracts the core
ceremony does not mint: `tier2CallCapBps` and `maxCapitalBps` are per-**governor**
and `minBufferBps` is per-**vault**, and both are minted by
`SyndicateFactory.createSyndicate` — after every deploy script has finished.

So the launch posture is: a syndicate is created, and until somebody makes three
owner calls it runs with no per-call tier-2 ceiling, no envelope ceiling, and no
idle-liquidity floor. That is a *live* configuration, not a broken one — other
bounds still apply (§5) — but two of the three are the only bound of their kind
in the system, and one of them is the configuration the permissionless-tier2
proposal itself calls out:

> `tier2CallCapBps` must be seeded to a real value — its inert default
> (`10_000` = 100% of TVL) makes sandbox funding unbounded, **which is the one
> configuration in which this change is strictly worse than today**.
> — `openspec/changes/permissionless-tier2-sandbox/proposal.md:41`

This document reviews each parameter against the code, and **recommends** a seed
value. The operator decides. Where the code does not justify a number, this says
so instead of inventing one.

Line references are against this commit; re-derive them if the contracts move.

---

## 0. The gate

`script/CheckSyndicateParams.s.sol` reads all three off a live governor + vault
and **reverts** if any is still at its inert default. Run it after
`createSyndicate` and again after seeding:

```bash
GOVERNOR=0x... VAULT=0x... \
  forge script script/CheckSyndicateParams.s.sol:CheckSyndicateParams --rpc-url robinhood
```

It broadcasts nothing (`run()` is `view`; there is no `vm.startBroadcast`). Each
parameter has a named, per-parameter waiver env var for the case where the inert
value *is* the decision — `ALLOW_INERT_TIER2_CALL_CAP`, `ALLOW_INERT_MAX_CAPITAL`,
`ALLOW_ZERO_MIN_BUFFER` — so a waiver is a written, greppable act and never a
silent omission. The rule is unit-tested in
`test/deploy/CheckSyndicateParams.t.sol`.

---

## 1. `tier2CallCapBps` — P0

| | |
|---|---|
| Lives on | `SyndicateGovernor` (via `GovernorParameters`), per governor |
| Storage | `GovernorParameters._tier2CallCapBps` (`src/GovernorParameters.sol:117`) |
| Reader | `tier2CallCapBps()` (`:317`) — `v == 0 ? 10_000 : v` |
| Setter | `setTier2CallCapBps(uint256)` (`:309`) — `onlyVaultOwner whenNoActiveProposal` |
| Accepts | `1 … 10_000`. `0` reverts `InvalidTier2CallCapBps`; `> 10_000` likewise |
| Live default | **10_000 = 100% of TVL** |

### Why it is inert

Stored `0` is the unset sentinel and the getter maps it to `10_000`, so the two
enforcement sites compute a ceiling equal to the vault's entire `totalAssets()`:

1. **Propose time**, `SyndicateGovernor._resolveTierAndCoverage` /`_scanCalls`
   (`src/SyndicateGovernor.sol:1886`, `:1923`): every call resolving to tier 2 —
   uncertified included — must declare `caps[i] <= tier2Ceiling`, else
   `Tier2CallCapExceedsCeiling(i)`. At 10_000 no declaration can exceed it.
2. **Execute time**, `SyndicateVault.runSandbox` (`src/SyndicateVault.sol:890`):
   `funding > (totalAssets() * tier2CallCapBps()) / 10_000` reverts
   `SandboxFundingExceedsCeiling`. At 10_000 the whole vault is fundable into a
   freshly-cloned sandbox running proposer-chosen calldata.

Note the two sites are not the same bound. Propose-time caps **each** tier-2
call; execute-time caps the sandbox's **total** funding in one number. A value
chosen for one is not automatically right for the other; the batch-wide
`maxCapital` (§2) is what stops *n* per-call ceilings from summing to the vault.

The execute-time read is deliberately **live**, not snapshotted, so tightening
this parameter binds proposals already in flight (see the comment above
`SyndicateVault.sol:890`). That is the recovery lever if a seed turns out wrong —
but `whenNoActiveProposal` means you cannot pull it while a proposal is open, so
the lever is unavailable exactly when you would reach for it. Seed before the
first `propose`.

### What breaks at each end

- **10_000 (default):** no tier-2-specific bound. Worst case is the loss the
  proposal's own envelope permits, delivered through a sandbox holding
  proposer-chosen calldata (bounded loss — the sandbox has no standing against
  the vault and `runSandbox` meters the vault's balance across the run — but the
  bound is "everything the envelope allows").
- **Very low (single-digit bps):** liveness. Any legitimate uncertified call
  declaring a larger cap reverts at propose with
  `Tier2CallCapExceedsCeiling(i)`, and a sandbox that needs real capital cannot
  be funded. The failure is loud and at propose time, which is the safe
  direction, but a value below what any real strategy needs makes the tier-2
  path decorative.
- **`0`:** rejected by the setter. There is no "disable tier 2 entirely" value
  here; use tier certification for that.

### Recommendation: **200 bps (2% of TVL)**

Justified from the repo, not invented: `script/DeployPlanB.s.sol:327` already
pins `TIER2_CALL_CAP_BPS = 200` as the policy value it instructs operators to
seat, with a pre-flight (`:672`) refusing anything outside the approved
`1–200 bps` band from issue #43 / `design.md` D2. Seeding 200 makes the deployed
state match the policy the repo already ships.

**This contradicts a recorded decision, and that is deliberate.**
`openspec/changes/permissionless-tier2-sandbox/tasks.md` §6.2 (Ana, 2026-08-14)
decided "no cap — `tier2CallCapBps` stays at its `10_000` default", and
`openspec/specs/deployment-docs/spec.md:103` records it. That decision is sound
about the *ceremony* (there is no governor instance at deploy time, so the core
script genuinely cannot seed it) and the same spec line already says a
deployment wanting a tighter bound "SHALL set it per vault via
`setTier2CallCapBps`". This review's position is that a launch vault SHOULD be
such a deployment. Re-affirming 10_000 is a legitimate answer — it just has to
be an answer, which is what `ALLOW_INERT_TIER2_CALL_CAP=true` records.

---

## 2. `maxCapitalBps`

| | |
|---|---|
| Lives on | `SyndicateGovernor` (via `GovernorParameters`), per governor |
| Storage | `GovernorParameters._maxCapitalBps` (`src/GovernorParameters.sol:110`) |
| Reader | `maxCapitalBps()` (`:303`) — `v == 0 ? 10_000 : v` |
| Setter | `setMaxCapitalBps(uint256)` (`:295`) — `onlyVaultOwner whenNoActiveProposal` |
| Accepts | `1 … 10_000`. `0` reverts `InvalidMaxCapitalBps` |
| Live default | **10_000 = 100% of TVL** |

### Why it is inert

Same 0-sentinel shape as §1 — the two are written to mirror each other exactly
(`GovernorParameters.sol:115-117`). `_capitalCeiling()`
(`src/SyndicateGovernor.sol:1631`) returns `totalAssets() * maxCapitalBps() /
10_000`, and a proposal declaring `envelope.maxCapital` above it is REJECTED,
not silently clamped: `_checkMaxCapitalCeiling`
(`src/SyndicateGovernor.sol:1648`) reverts `MaxCapitalExceedsCeiling`, and
`executeProposal` re-runs the same ratio against live totals (`:818`,
`MaxCapitalCeilingRegressed`). At 10_000 a proposer can declare
`maxCapital == totalAssets()`, so the vault's batch-wide net-outflow check (`SyndicateVault.sol:836`) permits a
batch to move the entire float.

It is **not** as dangerous as §1 in the same way: a proposal still has to clear
the vote, the guardian review period and the coverage quorum, and coverage is
priced against exactly this declared notional. Inert `maxCapitalBps` does not
open a new path; it removes the per-proposal size limit on the existing one.

### What breaks at each end

- **10_000 (default):** a single approved proposal may declare the whole vault
  as its envelope. Guardian coverage scales with the declaration, so the
  economic bound holds — the missing piece is a *hard* cap that does not depend
  on the guardian layer being correctly funded.
- **Too low:** propose-time revert on `envelope.maxCapital` (`_snapshotTierAndGate`).
  Also note `_capitalCeiling()` reads **live** `totalAssets()`, so a vault that
  shrinks between propose and execute tightens the ceiling underneath a
  proposal — a floor set close to a strategy's real requirement will fail
  intermittently on redemptions.
- **`0`:** rejected by the setter.

### Recommendation: **no code-derived number exists — seed 8_000 (80%) as a judgement call**

Nothing in `src/` or in any deploy script pins a value for this, and nothing in
the spec set argues for one. Unlike §1 there is no repo precedent to point at, so
treat the number below as a starting point for the operator's own decision, not
as a derived result.

The reasoning behind 8_000: it keeps at least a fifth of TVL outside any single
proposal's declared envelope, which bounds a single bad-but-approved proposal to
a survivable fraction while staying far enough above realistic strategy sizing
that the live-`totalAssets()` re-read (above) does not turn ordinary redemption
flow into propose-time reverts. It does **not** compose additively with
`minBufferBps` — the two measure different bases (`totalAssets()` vs the
pre-batch `asset()` balance), so do not read "80% + 5% buffer" as a partition.

---

## 3. `minBufferBps`

| | |
|---|---|
| Lives on | `SyndicateVault`, per vault |
| Storage | `SyndicateVault.minBufferBps` (`src/SyndicateVault.sol:211`), `uint16`, public |
| Setter | `setMinBufferBps(uint16)` (`:1436`) — `onlyOwner`, **no proposal freeze** |
| Accepts | `0 … 5_000` (`MAX_MIN_BUFFER_BPS`, `:90`). Above reverts `BufferTooHigh` |
| Live default | **0 = off** |

### Why it is inert

Plain zero-initialised storage, with no sentinel indirection — the natspec says
so outright ("0 = off"). Both enforcement sites,
`_guardBatchCalls`/net-outflow (`:841`) and `runSandbox` (`:912`), compute
`reserve + (balanceBefore * minBufferBps) / 10_000`; at 0 the term vanishes and
the check degenerates to the `balanceAfter >= reserve` queue-reserve check
immediately above it.

**Unlike §1 and §2 this parameter has no unset/explicit distinction.** A
deliberate `setMinBufferBps(0)` is byte-identical to never having been called, so
no on-chain read can tell a decision from an omission. That is precisely why the
gate in §0 requires a *written* waiver for this one.

### What breaks at each end

- **0 (default):** a batch may deploy the entire unreserved float. The
  withdrawal queue is still protected — `reservedQueueAssets()` is subtracted
  first and `QueueReserveBreached` fires independently — so this is not a
  solvency hole. What is lost is headroom for demand that has *not yet* been
  queued: instant exits and the next redemption cycle have to wait for a
  settlement rather than being served from idle float.
- **5_000 (max):** half the pre-batch float is undeployable, so capital
  efficiency halves and any batch sized against full float reverts
  `BufferBreached` at execute — i.e. after the vote and review have already been
  spent.
- **Above 5_000:** rejected (`BufferTooHigh`).

Operational note: this setter has **no** `whenNoActiveProposal` guard, so the
vault owner can raise the buffer between propose and execute and turn an
approved proposal into a `BufferBreached` revert. That makes it the one lever of
the three you can pull mid-flight — and also an owner-side griefing surface
worth knowing about.

### Recommendation: **no code-derived number exists — seed 500 (5%) as a judgement call**

The correct value is a function of redemption behaviour (queue arrival rate,
settlement cadence, instant-exit demand), and none of that is in this repo. The
code gives only the bounds and the two failure modes above.

500 bps is offered as a conservative starting point: small enough that capital
efficiency is essentially unaffected, large enough that the floor is non-zero
and therefore *visible* — a vault that has never breached its buffer at 5% will
tell you whether the parameter is doing anything before you raise it. Revisit
once real redemption data exists; the setter is unrestricted-by-lifecycle, so
this is the cheapest of the three to change.

---

## 4. Seeding order

Both governor setters are `whenNoActiveProposal`, so all three calls belong in
the same session as `createSyndicate`, before the first `propose`:

1. `createSyndicate(...)` → note the vault and its governor (`factory.governorOf`).
2. `governor.setTier2CallCapBps(200)` — vault owner.
3. `governor.setMaxCapitalBps(8000)` — vault owner.
4. `vault.setMinBufferBps(500)` — vault owner.
5. `GOVERNOR=… VAULT=… forge script script/CheckSyndicateParams.s.sol:CheckSyndicateParams --rpc-url …`
   → must print `OK` and exit 0.

Read-back verification without the script:

```bash
cast call $GOVERNOR "tier2CallCapBps()(uint256)" --rpc-url $RPC   # expect 200
cast call $GOVERNOR "maxCapitalBps()(uint256)"    --rpc-url $RPC   # expect 8000
cast call $VAULT    "minBufferBps()(uint16)"      --rpc-url $RPC   # expect 500
```

**TierRegistry precondition (SHE-209).** `governor.setTierRegistry` validates
only that the target has code. The vault's recipient guard makes a *typed*
`classOf(address)` call on every batch that pays an allowed recipient, so a
registry lacking that selector (any pre-class build) reverts every such batch
— fail closed, by design. Before wiring or upgrading a registry:

```bash
cast call $REGISTRY "classOf(address)(bytes32)" 0x0000000000000000000000000000000000000001 --rpc-url $RPC
# must return 0x00…00 (a zero class), not revert
```

---

## 5. What still bounds a payload if you seed nothing

Stated so the risk is not overstated. With all three inert, a payload is still
bounded by: the proposal's declared `envelope.maxCapital` and the vault's
net-outflow check against it; guardian coverage priced on that declaration; the
tier system's per-call `extractableBoundBps`; the queue-reserve check
(`QueueReserveBreached`); the vote, the guardian review window and the coverage
quorum; and — for the sandbox path specifically — the fact that a sandbox holds
no standing against the vault and `runSandbox` meters the vault's balance across
the whole run.

What is *missing* is a hard, guardian-independent ceiling on how much of one
vault a single approved proposal can put at risk. That is what §1 and §2 are.
