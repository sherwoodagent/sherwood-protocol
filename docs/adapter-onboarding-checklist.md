# Adapter onboarding checklist — the dual-gate

Onboarding an adapter takes **two independent governance writes**, both
`onlyOwner` on `TierRegistry`. Nothing on-chain requires you to do both, or
checks that you did them consistently. Getting one without the other fails
silently, in opposite directions. This document is the procedure that stands
in for the missing check.

Every line reference below is against `src/TierRegistry.sol`,
`src/SyndicateVault.sol` and `src/SyndicateGovernor.sol` as of this commit.
Re-verify them if the contracts move.

---

## 1. The dual-gate

### Gate A — tier certification (pricing)

**Two-step since issue #45.** Certification is announce-then-execute, not a
single write:

1. `TierRegistry.proposeCertification(address target, bytes4 selector, uint8 tier, uint16 extractableBoundBps, address submitter)`
   — `onlyOwner`, [`src/TierRegistry.sol:246`](../src/TierRegistry.sol#L246).
   Runs every input guard below and records a pending grant: the target's
   current `EXTCODEHASH`, the current `submitterBondWood` as the pinned bond
   amount, and `readyAt = block.timestamp + certifyDelay` (default 3 days,
   bounded `[1, 30]` days by `setCertifyDelay`,
   [`:380`](../src/TierRegistry.sol#L380)). Emits `CertificationProposed` with
   every one of those fields — this is the queue to watch (§2.2/§2.3 below can
   now be done by a third party against the ANNOUNCEMENT, not just by the
   submitter before the fact).
2. `TierRegistry.certify(address target, bytes4 selector)` —
   **permissionless**, [`src/TierRegistry.sol:312`](../src/TierRegistry.sol#L312).
   Callable by anyone once `readyAt` has passed, and only if the target's live
   codehash still matches the snapshot from step 1 (a code change during the
   window voids the pending grant — `CodehashChanged`,
   re-`proposeCertification` against the new code to recover). Pulls the
   PINNED bond amount (if any) at this point — not at step 1 — and writes the
   certification.
3. `TierRegistry.cancelCertification(address target, bytes4 selector)` —
   `onlyOwner`, withdraws a pending grant before it executes
   ([`:344`](../src/TierRegistry.sol#L344)).

Keyed on **(target, selector)** — `key()` is `keccak256(target, selector)`
([`:120`](../src/TierRegistry.sol#L120)). It answers *"how much can this call
extract?"*. `tierOf` ([`:126`](../src/TierRegistry.sol#L126)) returns the
certified `(tier, boundBps)`, or `(TIER_ARBITRARY=2, FULL_NOTIONAL_BPS=10_000)`
([`:78-79`](../src/TierRegistry.sol#L78)) for anything uncertified, PENDING
(not yet executed), or whose live `EXTCODEHASH` no longer matches the hash
snapshotted at certification.

Consumed by the governor: `_resolveTierAndCoverage` / `_scanCalls`
([`src/SyndicateGovernor.sol:1020`](../src/SyndicateGovernor.sol#L1020),
[`:1036`](../src/SyndicateGovernor.sol#L1036)) sums `boundBps` across a
proposal's execute + settle calls to size guardian coverage. With no registry
wired the governor returns `(2, maxCapital)` — the safe default.

`proposeCertification` **rejects** `tier >= 2` (`InvalidTier`,
[`:253`](../src/TierRegistry.sol#L253)), `extractableBoundBps == 0` or
`>= 10_000` (`BoundRequired`, [`:254`](../src/TierRegistry.sol#L254)), and a
target with no code (`NotAContract`). `certify` separately rejects execution
before `readyAt` (`CertifyDelayNotElapsed`), with no pending record
(`NoPendingCertification`), and against a mismatched live codehash
(`CodehashChanged`).

### Gate B — transfer allowlist (reachability)

`TierRegistry.setAdapterAllowed(address adapter, bool allowed)` — `onlyOwner`,
[`src/TierRegistry.sol:328`](../src/TierRegistry.sol#L328); read back via
`isAdapterAllowed(address)` [`:335`](../src/TierRegistry.sol#L335).

Keyed on a **bare address**, not on (target, selector). It answers *"may vault
funds be approved to, or sent to, this address at all?"*.

Consumed by the vault's selector guard `_guardBatchCalls`
([`src/SyndicateVault.sol:508`](../src/SyndicateVault.sol#L508)), which runs on
**every** governor batch, before the executor delegatecall
([`:430`](../src/SyndicateVault.sol#L430)). For these four value-moving ERC20
selectors ([`:92-95`](../src/SyndicateVault.sol#L92)):

| selector | sig | guarded arg | calldata bytes |
| --- | --- | --- | --- |
| `0x095ea7b3` | `approve(address,uint256)` | arg 1 (spender) | `4:36` |
| `0x39509351` | `increaseAllowance(address,uint256)` | arg 1 (spender) | `4:36` |
| `0xa9059cbb` | `transfer(address,uint256)` | arg 1 (to) | `4:36` |
| `0x23b872dd` | `transferFrom(address,address,uint256)` | arg 2 (`to`) | `36:68` |

the guarded address must be the vault itself
([`:530`](../src/SyndicateVault.sol#L530)) or allowlisted, else the batch
reverts `DisallowedTransferTarget(target, selector, recipient)`
([`:531`](../src/SyndicateVault.sol#L531)). Truncated calldata reverts
`MalformedCall` ([`:522`](../src/SyndicateVault.sol#L522),
[`:525`](../src/SyndicateVault.sol#L525)). Any other selector is skipped
([`:527`](../src/SyndicateVault.sol#L527)).

**Issue #166 — Gate B now also gates callability itself, not only recipients.**
`_guardBatchCalls` PART 2a checks `isAdapterAllowed(target)` on EVERY batch
call, before any selector is inspected: a target that is neither `asset()` nor
allowlisted is refused outright with `DisallowedBatchCallee(target)`, whatever
its selector or calldata length (including empty-calldata, `value`-only calls
— previously invisible to every check above). This is the SAME mapping and
the SAME `setAdapterAllowed` write as the recipient-side table above — not a
second allowlist — so onboarding is unchanged in mechanics: allowlist the
adapter once, and it is both a legal recipient and a legal callee. See
`openspec/changes/target-based-batch-gating/design.md` for the full design.
The selector table above is retained underneath as defense-in-depth (an
allowlisted TOKEN can still be handed a non-allowlisted spender/recipient in
its calldata, which only the table above catches).

### Gate B is codehash-bound (issue #137)

`setAdapterAllowed(adapter, true)` snapshots the adapter's effective codehash
at grant time into a dedicated mapping, and `isAdapterAllowed` answers `true`
only while the adapter's live code still matches that snapshot — a lazy,
read-side self-heal mirroring `tierOf`'s codehash check (§2.3), with no state
write in the hot path. Consequences for onboarding:

- **Grant only after the adapter's final code is deployed and verified.** The
  grant snapshots whatever code is live at that moment. Granting against a
  predicted (counterfactual) CREATE2 address snapshots "no code"; the funds
  path closes the instant code appears there, and stays closed until the
  owner re-attests it.
- **A legitimate bytecode change at the adapter's address closes the funds
  path** on the very next read, without waiting for `poke`, until the owner
  re-attests the new code with a fresh `setAdapterAllowed(adapter, true)` —
  the designed recovery ceremony, mirroring the demote → re-certify cycle for
  tiers (§4).
- **The binding does not cover proxy implementation swaps**, for the same
  reason `tierOf`'s does not (§2.3): a proxy's own runtime bytecode is
  constant across upgrades. The §2.3 proxied-adapter prohibition covers Gate
  B for the same reason it covers Gate A.
- Non-existent and existing-but-codeless addresses (EIP-1052:
  `EXTCODEHASH == bytes32(0)` vs `keccak256("")`) both normalize to one "no
  code" value for the snapshot and the comparison — so allowlisting a plain
  codeless payout address and later merely funding it with native currency
  cannot, by itself, close the funds path.

### Gate B has a second consumer (issue #147)

`isAdapterAllowed` is no longer read only by the vault's batch guard.
`PortfolioStrategy._initialize` resolves the same registry through
`vault() → governor() → tierRegistry()` and reverts `AdapterNotAllowed` unless
the proposer-supplied `swapAdapter_` is allowlisted — closing a gap the batch
guard structurally cannot see: the strategy's own `forceApprove(swapAdapter,
…)` calls happen one frame deeper than anything in the governor's batch
calldata, after `strategy.execute()` has already been dispatched.

Consequences for onboarding:

- **Allowlisting must precede strategy clone+init, not just batch execution.**
  A proposer creates and initializes a `PortfolioStrategy` clone in their own
  transaction, before `propose()`. On a wired stack (governor's
  `tierRegistry()` resolves), init reverts `AdapterNotAllowed` if the swap
  adapter is not yet on the allowlist — the same one-line `setAdapterAllowed`
  action this checklist already requires before the strategy clone itself can
  receive `asset.approve(strategy, amount)` in a batch (§1 Gate B).
- **The check degrades the same way the batch guard does.** If the walk
  cannot resolve a registry — codeless vault, no `governor()` surface, a
  governor predating the `tierRegistry()` getter, or `tierRegistry() == 0` —
  the strategy skips the check rather than reverting, mirroring
  `_guardBatchCalls`'s own "UNSET REGISTRY" degrade (§5). This is not a new
  gap: with no registry wired, a governor batch could already approve vault
  funds to any address, so the strategy's internal re-approval grants nothing
  not already grantable.
- **A demotion's auto-clear (§4) now also blocks new strategy bindings.**
  Because `_demote` clears `_adapterAllowed[adapter]`, a demoted adapter is
  simultaneously refused by both consumers — existing batches cannot fund it
  AND no new `PortfolioStrategy` clone can bind to it — with no additional
  wiring. The check is init-time only: a strategy already initialized and
  executed against an adapter that is later demoted is not re-checked at
  settle (by design — see
  `openspec/changes/portfolio-swap-adapter-allowlist/design.md` decision 3).
- **This does not change §2.1–§2.3.** The adapter still must not be a generic
  executor, still needs a written selector inventory, and still must not be a
  proxy — the strategy-side check only enforces the SAME allowlist bit, one
  more place.

### Why they do not imply each other

The keys are different objects. A call like `USDC.approve(adapter, x)` has
`target == USDC` and `recipient == adapter`: Gate A is consulted for
`(USDC, 0x095ea7b3)`, Gate B for `adapter`. Certifying an adapter's own
selectors never populates the allowlist, and allowlisting an adapter never
certifies anything.

### Failure direction 1 — certified, not allowlisted (loud on-chain, silent at review)

The adapter prices correctly, coverage is computed, guardians approve — and
then every batch that funds it reverts `DisallowedTransferTarget` at
[`SyndicateVault.sol:531`](../src/SyndicateVault.sol#L531). Nothing warns you
at certification time; the failure surfaces only when a real proposal executes,
i.e. after the vote and the guardian review window have been spent.

### Failure direction 2 — allowlisted, over-broad or uncertified (silent, and the dangerous one)

`isAdapterAllowed` is the *only* thing standing between a governor batch and
`token.approve(X, type(uint256).max)`. The net-outflow meter does not see it:
an approval moves no balance, so it meters zero
([`SyndicateVault.sol:474-479`](../src/SyndicateVault.sol#L474)). If `X` is an
adapter that can forward funds on to an arbitrary destination, the guard is
satisfied and the funds leave in a later transaction with no vault-side event
to notice. **The allowlist bounds where funds may go only if the allowlisted
address itself cannot re-forward them.**

---

## 2. Checklist

Work top to bottom. Every box must be satisfiable from an on-chain read or a
written artifact — nothing on this list is "I remember doing it".

### [ ] 2.1 The target is not a generic or arbitrary-call executor

Do **not** allowlist any address that can be made to call an arbitrary target
with arbitrary calldata, or to move tokens to an arbitrary destination:
multicall/aggregator contracts, `Executor`/`Router`-style forwarders, generic
swap routers that accept an arbitrary `to`, `Permit2`-style universal
approvers, DSProxy/Safe-module executors, or anything with a
`call(address,bytes)`-shaped entry point.

Allowlisting one of these converts Gate B from a bound into a formality: the
guard checks the immediate recipient, and the immediate recipient then does
whatever the calldata says. This is failure direction 2, and it is the reason
"allowlist the router, it's the standard one" is not an acceptable answer.

An adapter qualifies only if the set of destinations it can pay out to is
fixed by its own code — not by its calldata.

### [ ] 2.2 Written selector inventory, with reviewer sign-off

Before either write, produce a written answer to: **what value-moving
selectors can this adapter emit, and to whom?**

The inventory must list, for the adapter's full external surface:

- every call it can make that emits `approve` / `increaseAllowance` /
  `transfer` / `transferFrom` on any token the vault holds, and the possible
  recipients of each;
- every path by which a destination address is taken from *calldata* rather
  than from immutable/constant storage (each such path is a 2.1 failure);
- the ERC721/ERC1155 surface, if any — `setApprovalForAll` (`0xa22cb465`),
  ERC721 `approve`, LP-position NFTs. These are **not guarded** today
  ([`SyndicateVault.sol:495-501`](../src/SyndicateVault.sol#L495)); an adapter
  that touches them is relying on tier-2 pricing alone, and that must be a
  stated, accepted risk rather than an oversight;
- the (target, selector) pairs being certified and the `extractableBoundBps`
  claimed for each, with the argument for the bound.

A reviewer who is not the submitter signs off on the inventory. Attach it to
the governance proposal. A loose `extractableBoundBps` on a tier-0
certification is worse than refusing to certify, because it looks safe — see
[`docs/superpowers/specs/2026-07-27-tier-policy-v1.md`](superpowers/specs/2026-07-27-tier-policy-v1.md)
consequence 5.

### [ ] 2.3 The target is not a proxy

`proposeCertification` snapshots `target.codehash` at announcement time, and
`certify` re-checks it against the LIVE codehash at execution time
(`CodehashChanged` on mismatch); `tierOf` then re-checks the certified hash on
every read. That catches **metamorphic redeploys only** (CREATE2 +
SELFDESTRUCT at the same address).

It does **not** catch proxy implementation swaps. For EIP-1967 / UUPS /
transparent / beacon proxies the proxy's own runtime bytecode is constant
across upgrades, so the certified hash keeps matching while the behaviour
behind it changes arbitrarily. There is no reliable on-chain proxy detector — a
contract cannot read another contract's storage slots — so this is a governance
obligation, spelled out at
[`TierRegistry.sol:24-33`](../src/TierRegistry.sol#L24) and
[`:174-180`](../src/TierRegistry.sol#L174), and restated in the tier-policy ADR
(consequence 4), which says the whole ADR rests on this discipline.

**Governance MUST NOT certify proxied adapters at tier 0/1.** Leave them at the
tier-2 default. Check the three EIP-1967 slots before certifying (§3).

### [ ] 2.4 Flip both gates in the same governance session

`proposeCertification` and `setAdapterAllowed` are `onlyOwner` on the *same*
contract, so a single owner batch can carry both — there is no cross-contract
coordination excuse for splitting them. In production the owner is the
multisig, reached through the two-step `Ownable2Step` handoff in
[`script/Deploy.s.sol:176`](../script/Deploy.s.sol#L176) (the multisig must
call `acceptOwnership()`).

Order within the session does not matter for the PROPOSAL; *splitting across
sessions* does. A session that lands only Gate B leaves an allowlisted address
that nobody has priced. A session that lands only Gate A's proposal ships an
announcement whose bound nobody reviewed — that is now the point (§2.2/§2.3
happen against the queue), but the allowlist write should still land in the
same session as the certification proposal, not drift apart from it.

`certify` itself is a SEPARATE, later, permissionless step — it executes once
`certifyDelay` has elapsed (default 3 days) and may be called by anyone, not
just the owner. Do not treat `proposeCertification` landing as the adapter
being live: `tierOf` still reports tier 2 until `certify` actually executes.

### [ ] 2.5 Verify both gates on-chain after execution

Read both back. See §3 for the commands. Do not close the onboarding on the
`proposeCertification` receipt, or even the `certify` receipt, alone —
`certify` succeeding does not tell you the codehash still matches at read
time, and it says nothing at all about the allowlist.

### [ ] 2.6 Record the de-onboarding plan

Write down, at onboarding time, the (target, selector) pairs and the adapter
address that a de-onboarding will have to reverse (§4). The bond-release
timelock makes this slow — plan it before you need it, not during an incident.

### [ ] 2.7 Strategy clones: allowlist per proposal, and mind the mid-period selector

Strategy clones are not adapters in the usual sense, but Gate B still binds
them: `SyndicateVault._guardBatchCalls` rejects any batch target that is not an
allowlisted adapter (`asset()` is the sole exemption), so **each clone needs its
own owner `setAdapterAllowed(clone, true)` before its batch can execute**. A
clone is a fresh address per proposal, so this is a per-proposal step, not a
one-off template step. The template being approved on `StrategyFactory` gates
*cloning*; it does not make the clone reachable from a batch.

`ConcentratedLiquidityStrategy` adds a wrinkle worth stating explicitly, because
it is the first template where the allowlist window is not just "execute and
settle":

- Its `rerange()` is **permissionless and batch-reachable**, and it is expected
  to be called repeatedly during the strategy period rather than at the two
  lifecycle endpoints. The clone must therefore **stay allowlisted for the whole
  strategy period**, not only across `execute()` and `settle()`.
- De-allowlisting a clone mid-period does NOT freeze the position: `rerange()`
  moves no vault funds — it burns and re-mints the clone's own Uniswap position
  — so a keeper calling it **directly** is unaffected by the batch guard. What
  de-allowlisting stops is the governor batch route. Do not treat it as a kill
  switch for reranging.
- The clone is uncertified and therefore reads as **tier 2** (`TIER_ARBITRARY`,
  full notional), like every other strategy clone. That is admissible, but it
  means guardian coverage is priced at full notional, so these proposals consume
  maximum coverage capacity per dollar deployed. Plan capacity, not permission.

Certifying clones at tier 0/1 is not the answer: certification is owner-only,
bonded, and keys on address, so it would mean one certification per clone per
proposal. Clones of one template share a codehash, but tiering does not key on
codehash, so there is nothing to amortize.

---

## 3. Verification reads

```bash
RPC=https://rpc.mainnet.chain.robinhood.com     # or the chain you deployed to
REG=<TierRegistry address>
GOV=<SyndicateGovernor address>
ADAPTER=<adapter address>

# 0. The registry the vault guard will actually consult is read off the
#    governor (SyndicateVault.sol:511 staticcalls `tierRegistry()`).
#    Confirm it is the registry you are writing to.
cast call $GOV "tierRegistry()(address)" --rpc-url $RPC

# 1. Who can flip the gates. After the multisig handoff `owner()` must be the
#    multisig and `pendingOwner()` must be the zero address — a non-zero
#    pendingOwner means acceptOwnership() was never called.
cast call $REG "owner()(address)" --rpc-url $RPC
cast call $REG "pendingOwner()(address)" --rpc-url $RPC

# 2. Gate A. Compute the selector, then read the effective tier.
#    Expect (0|1, <bound>) for a certified pair; (2, 10000) means uncertified,
#    demoted, OR codehash-mismatched — tierOf cannot distinguish them.
SEL=$(cast sig "deposit(uint256,address)")
cast call $REG "tierOf(address,bytes4)(uint8,uint16)" $ADAPTER $SEL --rpc-url $RPC

# 3. Gate B, FUNDS axis. Expect true only for adapters that passed §2.1.
cast call $REG "isAdapterAllowed(address)(bool)" $ADAPTER --rpc-url $RPC

# 3b. Gate B, CALLEE axis. Read BOTH — since finding #14 they diverge, and a
#     demoted adapter answers false above while still answering true here.
#     Confirming a de-onboarding means confirming this one is false too.
cast call $REG "isCallableTarget(address)(bool)" $ADAPTER --rpc-url $RPC

# 4. Proxy check (§2.3). All three EIP-1967 slots must read as zero.
#    implementation / beacon / admin:
cast storage $ADAPTER 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC
cast storage $ADAPTER 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50 --rpc-url $RPC
cast storage $ADAPTER 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 --rpc-url $RPC
# Non-standard proxies exist — a zero read is necessary, not sufficient.
# Read the deployed source before certifying.

# 5. Bond state, if submitter bonds are configured. A non-zero `releasableAt`
#    means this key is mid-release and `certify` will revert BondPendingRelease.
cast call $REG "bondOf(address,bytes4)((address,uint96,uint64))" $ADAPTER $SEL --rpc-url $RPC

# 6. Pending certification queue (issue #45). A non-zero `readyAt` means a
#    grant is announced but not yet live -- `tierOf` still reports tier 2.
#    `readyAt` is a unix timestamp; `certify` reverts CertifyDelayNotElapsed
#    before it and CodehashChanged if the live codehash no longer matches
#    the `codehash` field snapshotted here.
cast call $REG "pendingCertificationOf(address,bytes4)((uint8,uint16,address,uint64,uint96,bytes32))" $ADAPTER $SEL --rpc-url $RPC
```

**Sweep for drift.** `AdapterAllowedSet(address indexed adapter, bool allowed)`
([`TierRegistry.sol:107`](../src/TierRegistry.sol#L107)) and
`TierDemoted(address indexed target, bytes4 indexed selector)`
([`:106`](../src/TierRegistry.sol#L106)) are the two events to reconcile. Every
address with a live `allowed == true` should have a certified,
current-codehash pair behind it; anything else is the §4 gap.

---

## 4. De-onboarding: allowlist off **before** decertification

```
1. setAdapterAllowed(adapter, false)      # closes BOTH axes: funds AND callee
2. demote(target, selector)               # per certified pair; funds axis only
3. (bondReleaseDelay later) claimSubmitterBond(target, selector)
```

`demote` ([`TierRegistry.sol:255`](../src/TierRegistry.sol#L255)) is
`onlyOwner` and routes to `_demote` ([`:296`](../src/TierRegistry.sol#L296)),
which deletes the `TierConfig`, starts the submitter-bond release timer
(`bondReleaseDelay`, default 14 days, [`:78`](../src/TierRegistry.sol#L78),
bounded to [1 day, 365 days] by [`:59-60`](../src/TierRegistry.sol#L59)), and
**also clears the adapter's funds-axis allowlist entry on-chain** (see below).

**STEP 1 IS NOT REDUNDANT, and since pashov finding #14 it is the load-bearing
call.** An earlier version of this section said step 1 merely duplicated step 2
for a single adapter and stayed only as belt-and-suspenders. That is no longer
true. `_demote` now clears the FUNDS axis and deliberately leaves the CALLEE
axis (`_calleeAllowed`,
[`:167`](../src/TierRegistry.sol#L167)) standing, so `setAdapterAllowed(adapter,
false)` is the **only** call that closes the callee axis — it is what sets
`_calleeRevoked` ([`:186`](../src/TierRegistry.sol#L186)). Skip step 1 and the
address remains a legal batch callee indefinitely, priced at tier 2 but
reachable, no matter how many times you demote it.

Decertifying first opens a window in which the adapter is **allowlisted but
uncertified**: governance has withdrawn its statement about what the target
does, while the guard still lets vault funds be approved to it. Turning the
allowlist off first closes the funds path immediately; the certification can
then be withdrawn at whatever pace the bond mechanics require.

### `_demote` clears the FUNDS axis only — the callee axis survives by design

Since pashov finding #14, "the allowlist" is two axes and demotion moves only
one of them. Read this before the subsection below, which describes the funds
axis:

| axis | read via | cleared by `_demote`? |
|---|---|---|
| funds — may RECEIVE vault money | `isAdapterAllowed` | **yes** |
| callee — may BE CALLED in a batch | `isCallableTarget` ([`:947`](../src/TierRegistry.sol#L947)) | **no, on purpose** |

The asymmetry is the fix, not an oversight. Demotion is reachable
permissionlessly — `ChallengeGame.file` only needs the `(target, selector)` pair
to appear in the executed proposal's calldata, and every execute batch names
`(clone, execute())` — so clearing the callee axis on demotion let anyone
revoke the vault's ability to CALL the strategy clone **holding its capital**.
`settleProposal`, `unstick` and `finalizeEmergencySettle` all reverted
`DisallowedBatchCallee`, the proposal pinned in `Executed`,
`redemptionsLocked()` stayed true, and every LP exit shut until the registry
multisig re-granted standing. Revoking the right to be PAID must not revoke the
vault's ability to RECLAIM.

Operationally: **a convicted adapter is reachable but not fundable.** To close
the callee axis as well, an explicit owner `setAdapterAllowed(adapter, false)`
is required (step 1 of §4) — and see §4b Rollback for the ordering constraint,
because closing it too early re-creates the freeze described above.

### `_demote` clears the funds-axis allowlist too — over-broad by design, one-way

Every persisted demotion routes through `_demote`
([`:296-310`](../src/TierRegistry.sol#L296)), which deletes `_configs[k]`
**and**, when the target was allowlisted, clears `_adapterAllowed[target]`
([`:74`](../src/TierRegistry.sol#L74)), emitting the existing
`AdapterAllowedSet(target, false)` ([`:105`](../src/TierRegistry.sol#L105)
declared, [`:307`](../src/TierRegistry.sol#L307) emitted here) — the same
event `setAdapterAllowed` itself emits
([`:348`](../src/TierRegistry.sol#L348)), so there is no new indexer channel
to wire. All three demotion paths get this atomically with the demotion, for
free:

- owner `demote` ([`:255`](../src/TierRegistry.sol#L255));
- `demoteByChallenge` — the ChallengeGame's role
  ([`:263`](../src/TierRegistry.sol#L263)), on a passed challenge;
- `poke(target, selector)` — **permissionless**
  ([`:270`](../src/TierRegistry.sol#L270)), callable by anyone the moment the
  live codehash diverges from the certified one.

The clear is **deliberately over-broad**: certification is keyed (target,
selector), the allowlist by bare address, so demoting *one* selector
de-allowlists the *whole* adapter even if its other selectors remain
certified — the conservative, accepted direction of error. Recovery is a
single owner `setAdapterAllowed(adapter, true)` call. Re-certifying never
restores it: neither `proposeCertification` nor `certify`
([`:246`](../src/TierRegistry.sol#L246),
[`:312`](../src/TierRegistry.sol#L312)) ever sets or restores
`_adapterAllowed`, so re-allowlisting after any clear is always this explicit,
separate owner decision — never a side effect of re-certification.

**What still needs the watcher.** Two paths leave `_adapterAllowed` untouched
because they either don't run `_demote`, or don't persist at all:

- The ChallengeGame calls `demoteByChallenge` **best-effort**, inside a
  `try/catch` ([`src/ChallengeGame.sol:1141`](../src/ChallengeGame.sol#L1141)).
  If that call reverts — e.g. `authorizedDemoter` was rotated away
  mid-challenge — no `_demote` runs, so nothing is cleared; the only signal is
  `AdapterDemotionFailed`. This case is structurally uncoverable on-chain: the
  clear is a side effect of a demotion that never happened.
- `tierOf` reporting tier 2 lazily on a codehash mismatch
  ([`:95`](../src/TierRegistry.sol#L95)) writes no state until someone calls
  `poke` — until then the stored `_configs`/`_adapterAllowed` entries survive
  untouched. As of issue #137, `isAdapterAllowed` self-heals the same way on
  the same read: it cross-checks the adapter's live codehash against the
  snapshot taken at the last grant and answers `false` on a mismatch, with no
  state write. **This is now a hygiene gap, not a funds-path hazard**: on a
  codehash mismatch both `tierOf` AND `isAdapterAllowed` already report the
  safe answer before anyone calls `poke`, so a governor batch cannot fund a
  code-changed adapter regardless of whether `poke` has ever run. What
  survives un-`poke`d is stale STORAGE and stale indexer state only —
  `AdapterAllowedSet` history still says `allowed`, while the live read
  already says `false`.

**Operational consequence:** `TierDemoted` alone no longer needs a manual
allowlist reaction for `demote`, `demoteByChallenge`, or `poke` — the clear
already happened on-chain, atomically. The allowlist alarms that remain: (a)
`AdapterDemotionFailed` — apply the lost demotion via owner `demote` (which
itself clears the allowlist) or call `setAdapterAllowed(adapter, false)`
directly; (b) an un-`poke`d codehash drift — now storage/indexer hygiene
only, since the funds path is already closed on read; keep running the §3
drift sweep to persist the demotion via `poke` where a certification exists,
and to owner-clear the allowlist-only entries `poke` cannot reach (it reverts
`NotCertified` for an uncertified pair).

---

## 4a. Vault-implementation upgrade checklist (issue #166 callee gate)

`_guardBatchCalls` validates stored calldata at USE time, not at store time —
so upgrading a vault to a `SyndicateVault` implementation carrying the callee
gate changes the rule for proposals ALREADY in flight, not just future ones.
Before rolling the implementation to any vault:

1. **Pre-populate the registry.** Run `setAdapterAllowed(t, true)` (§2.4) for
   every non-`asset()` target that the vault's LIVE or QUEUED batches
   legitimately call. Every live strategy adapter already qualifies via the
   existing Gate B requirement above — the new burden is only for any
   direct-to-protocol call that bypasses an adapter.
2. **Upgrade only while the vault has no open proposal** — `_openProposalCount`
   caps a vault at one open proposal, so this is a single on-chain read per
   vault (`governor.getActiveProposal() == 0` / the vault's own open-proposal
   accounting) — **or**, if a proposal IS open, read its stored
   `executeCalls`/`settlementCalls` targets first and confirm each one is
   already `asset()` or allowlisted before upgrading that vault.
3. **If the checklist is skipped, the failure is loud and recoverable, not
   silent.** A stored call whose target fails the new gate reverts
   `DisallowedBatchCallee(target)` naming the exact missing target — fixed by
   running §2.4 for that target, then re-driving the normal `unstick` /
   `emergencySettleWithCalls` recovery path. No lifecycle state is
   grandfathered in code; this checklist is what makes the honest set of
   "will this proposal still execute after the upgrade" answers empty at
   upgrade time.

See `openspec/changes/target-based-batch-gating/design.md` Decision 3 for the
full in-flight-proposal asymmetry analysis (an `Approved` proposal self-heals
to `Expired`; an `Executed` proposal's settlement failing is terminal without
an owner rescue).

---

## 4b. Class certification (strategy templates)

Everything above is keyed by **address**. Strategy clones defeat that: every
proposal deploys a fresh ERC-1167 clone at a fresh address, so the dual-gate
would have to be run once per proposal, forever.

Class certification keys by **code** instead. All clones of one template are
byte-identical, so they share one `EXTCODEHASH`, and that hash identifies the
template. Certify it once and every clone that will ever exist inherits both
gates with no per-clone write.

### Eligibility — check this before certifying anything

A class certification asserts the bound holds under **every** initialization,
not just one deployment's configuration. Only certify a template where:

1. Every external address it touches is either `immutable` in the template's
   own bytecode, or bound to the registry at `initialize`. A template that
   accepts an external protocol address and then validates it *by asking that
   address* is disqualified — see `MorphoSupplyStrategy`, which does exactly
   that and stays address-certifiable only.
2. Price sources are bound to the tokens they price, not merely allowlisted.
3. It is cloned with `Clones.clone` / `cloneDeterministic` only. Any
   clone-with-immutable-args variant gives each clone distinct bytecode, which
   dissolves the class **silently** — proposals keep working, they just fall
   back to tier 2 with the per-call cap reinstated, and nothing reverts.
4. It is not itself a proxy. A proxy's runtime bytecode is static across
   implementation swaps, so neither membership level can see the change.

### The writes

| step | call | notes |
|---|---|---|
| 1 | `proposeClassCertification(template, selector, tier, boundBps, submitter, expectedTemplateCodehash)` | `onlyOwner`. Same `certifyDelay` and bond machinery as the address path. Reverts `CodehashChanged` if the template's code drifted since you reviewed it. |
| 2 | `certifyClass(template, selector)` | After `readyAt`. Permissionless with no bond, submitter-only with one. Re-verifies the **template's** codehash. |
| 3 | `setClassAllowed(template, true)` | `onlyOwner`. Separate axis, exactly like `setAdapterAllowed`. Requires the class to be certified first. |

Step 3 is what **replaces `setAdapterAllowed(clone, true)` per proposal**.

### Verification reads

```
cast call $REGISTRY "classOf(address)(bytes32)"        $CLONE     # non-zero => live member
cast call $REGISTRY "tierOf(address,bytes4)(uint8,uint16)" $CLONE $SEL
cast call $REGISTRY "isAdapterAllowed(address)(bool)"  $CLONE     # funds axis
cast call $REGISTRY "isCallableTarget(address)(bool)"  $CLONE     # callee axis
```

Read both axes. After a class conviction the expected answers **differ** —
`isAdapterAllowed` false, `isCallableTarget` still true — and that is correct
until step 4 of Rollback below has run. Both false is the finished
de-onboarding; both true is a live class.

A clone reading `(2, 10000)` while the class is certified means the membership
check failed — either it is not a clone of that template, or the template's own
code changed since certification.

### Rollback

`demoteClass(template, selector)` returns every clone to the tier-2 default and
clears the class **funds** axis (`_classAllowed`). It does **not** clear the
class **callee** axis (`_classCalleeAllowed`,
[`:199`](../src/TierRegistry.sol#L199)) — `_demoteClass`
([`:1407`](../src/TierRegistry.sol#L1407)) leaves that standing deliberately, for
the same reason `_demote` does on the address path: a class conviction must not
strand the capital a live clone is holding. Existing per-clone address grants
keep working throughout, because the address path always wins over the class.

**Closing the class callee axis is a SEQUENCED step, not an immediate one.**
`setClassAllowed(template, false)` ([`:1347`](../src/TierRegistry.sol#L1347)) is
the only call that closes it. Running it straight after the conviction
re-creates exactly the freeze finding #14 fixed — the live clone becomes
unreachable and every LP exit shuts. Correct order:

```
1. demoteClass(template, selector)        # funds axis closed, tier -> 2
                                          # callee axis intentionally still open
2. <settle the open proposal>             # uses the still-open callee axis to
                                          # reclaim capital from the live clone
3. <confirm nothing outstanding>          # vault.redemptionsLocked() == false
                                          # governor openProposalCount == 0
                                          # no proposal for this template in Executed
4. setClassAllowed(template, false)       # NOW close the callee axis
```

Step 4 is the one the contract no longer does for you, and the one that gets
skipped. Two mechanics make it safe whenever you reach it: the
`ClassNotCertified` guard is scoped to the `allowed == true` branch, so
revocation works on a demoted, uncertified or drifted class; and
`cloneCodehashOf` is `pure`, deriving the fingerprint from the template ADDRESS,
so it resolves even after the template's bytecode drifted.

If step 4 is skipped, every clone of that template stays a legal batch callee
indefinitely — **including clones deployed after the conviction**, since class
membership is computed live from bytecode and anyone may permissionlessly deploy
an ERC-1167 clone of the template to become a member. They cannot receive vault
funds (the funds axis is closed), and reaching them still requires a passed
proposal, so this is a boundary-widening rather than a funds path. It is
nonetheless unbounded and permanent until step 4 runs.

`_demoteClass` emits `ClassDemoted(template, selector, cch)`. A watchtower that
alerts when a `ClassDemoted` is not followed by
`ClassAllowedSet(template, cch, false)` once `openProposalCount` reaches zero
turns step 4 from "remember" into "get paged".

Re-certifying does **not** restore allowlist standing. That is deliberate and
matters more here than on the address path: the blast radius is every clone of
the template at once.

### Deploy order is load-bearing

`PortfolioStrategy._initialize` is fail-closed on registry resolution. The tier
registry must be wired and reachable through `vault() → governor() →
tierRegistry()` **before any clone is initialized**, or every clone deploy
reverts `TierRegistryUnresolved`.

**This is per-vault, not a one-time global step.** Each vault's governor holds
its own `_tierRegistry`. `SyndicateFactory.setTierRegistry` stamps the value
into governors created *after* the call; an existing governor is rewired with
`pushWiring(governor)`. So a vault created while the factory's `tierRegistry`
was unset cannot run portfolio strategies until that vault's governor is
rewired — even if every other vault is fine.

A governor's registry can no longer be zeroed (pashov finding #1):
`SyndicateGovernor.setTierRegistry` rejects `address(0)` and codeless
addresses, and `SyndicateFactory.createSyndicate` reverts `TierRegistryNotWired`
while the factory itself has none. Zero on the **factory** setter is still
legal, but it is a kill switch on new syndicates only — it cannot reach a
governor that already exists. Re-pointing to a different real registry stays
legal on both.

### MANDATORY PRE-MAINNET: rewire every pre-fix governor

Any governor created **before** finding #1 was fixed may be permanently
registry-less, because `createSyndicate` used to skip the wiring push instead of
refusing. In that state `SyndicateVault._guardBatchCalls` returns early and
drops the callee allowlist and the spender gate, so `asset.approve(attacker,
max)` passes every meter (it moves zero balance) and licenses an unbounded pull
later. The fix is forward-only; it does not heal these.

Before mainnet, for every governor the factory has ever deployed:

1. Enumerate them. There is no on-chain enumeration — read `GovernorDeployed`
   logs from the factory (`vault`, `governor`) from its deployment block.
2. `cast call <governor> "tierRegistry()(address)"` on each. Anything returning
   `0x0` is affected. As of writing that means checking the ~9 syndicates on
   Robinhood testnet (46630); mainnet has none yet.
3. `SyndicateFactory.pushWiring(governor)` (factory-owner only) for each hit.
   It pushes the factory's current registry / ledger / escrow and never writes
   zero, so it is safe to run on unaffected governors too.
4. Re-read `tierRegistry()` and confirm non-zero before treating the vault as
   guarded.

### Token↔price-source pairing

`setPriceSourceForToken(token, priceSource, true)` attests that a feed prices a
given token. Required by any template that derives swap floors from an oracle:
the allowlist alone says "this feed may be used", not "…for this token", and a
valuable token paired with a cheap asset's allowlisted feed produces a floor
computed off the wrong reference while every slippage check still passes.

Pass the **bare** aggregator address widened to `bytes32` (push mode) or the
feed id verbatim (Data Streams). Do not include any packed max-age — one
attestation is meant to cover every staleness variant of the same aggregator.

---

## 5. What is *not* enforced

Stated plainly, because the checklist above is only as good as the reader's
awareness of what it is substituting for:

- **Nothing on-chain enforces the pairing.** No contract requires an
  allowlisted address to be certified, or a certified target to be
  allowlisted. `certify` and `setAdapterAllowed` are two unrelated writes to
  two unrelated mappings on the same contract.
- **No contract can tell a generic executor from a bounded adapter.** §2.1 is a
  human judgment, and there is no code path that will catch you getting it
  wrong.
- **The codehash snapshot does not cover proxies** (§2.3).
- **The guard covers ERC20 only** for the SELECTOR-level checks (recipient of
  `approve`/`transfer`/etc). As of issue #166, ERC721/ERC1155/LP-NFT contracts
  are refused as batch CALLEES by default (they are never `asset()` and are
  not meant to be allowlisted — see the governance-discipline note below), so
  the old `setApprovalForAll`-shaped gap is closed as a class. The residual is
  narrower and now a governance-discipline requirement rather than a
  mechanical one: **exotic-asset contracts MUST NOT be allowlisted as batch
  callees** — if one ever were, its non-ERC20 selectors would still pass this
  selector table unexamined. Batches reach such positions through allowlisted
  adapters instead, never direct calldata against the position contract.
- **An unwired registry means an unguarded batch — and an unguarded strategy
  init.** If the governor returns `address(0)` (or lacks the getter),
  `_guardBatchCalls` returns early and the batch runs unguarded by design
  ([`SyndicateVault.sol:503-514`](../src/SyndicateVault.sol#L503)); the same
  unresolved walk makes `PortfolioStrategy._initialize` skip its swap-adapter
  check (issue #147). Read §3 step 0 before assuming Gate B is live for
  either consumer.

### Candidate follow-ups (tracked, not committed)

- **CI invariant for allowlisted-but-generic targets** (from issue #17): flag
  any address with `isAdapterAllowed == true` whose bytecode exposes an
  arbitrary-call entry point, or which has no certified (target, selector)
  pair behind it. This would mechanize §2.1 and the §3 drift sweep.
  Feasibility is unestablished — bytecode-level detection of "can forward to an
  arbitrary destination" is not a solved problem.

Not a commitment; it is the reason this document exists in the interim.
