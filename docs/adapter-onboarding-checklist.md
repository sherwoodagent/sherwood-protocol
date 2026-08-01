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

`TierRegistry.certify(address target, bytes4 selector, uint8 tier, uint16 extractableBoundBps, address submitter)`
— `onlyOwner`, [`src/TierRegistry.sol:198`](../src/TierRegistry.sol#L198).

Keyed on **(target, selector)** — `key()` is `keccak256(target, selector)`
([`:89`](../src/TierRegistry.sol#L89)). It answers *"how much can this call
extract?"*. `tierOf` ([`:95`](../src/TierRegistry.sol#L95)) returns the
certified `(tier, boundBps)`, or `(TIER_ARBITRARY=2, FULL_NOTIONAL_BPS=10_000)`
([`:55-56`](../src/TierRegistry.sol#L55)) for anything uncertified — or whose
live `EXTCODEHASH` no longer matches the hash snapshotted at certification
([`:97`](../src/TierRegistry.sol#L97)).

Consumed by the governor: `_resolveTierAndCoverage` / `_scanCalls`
([`src/SyndicateGovernor.sol:1020`](../src/SyndicateGovernor.sol#L1020),
[`:1036`](../src/SyndicateGovernor.sol#L1036)) sums `boundBps` across a
proposal's execute + settle calls to size guardian coverage. With no registry
wired the governor returns `(2, maxCapital)` — the safe default.

Certification is **rejected** for `tier >= 2` (`InvalidTier`,
[`:202`](../src/TierRegistry.sol#L202)), for `extractableBoundBps == 0` or
`>= 10_000` (`BoundRequired`, [`:203`](../src/TierRegistry.sol#L203)), and for
a target with no code (`NotAContract`, [`:205`](../src/TierRegistry.sol#L205)).

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

`certify` snapshots `target.codehash`
([`TierRegistry.sol:204`](../src/TierRegistry.sol#L204)) and `tierOf`
re-checks it on every read ([`:97`](../src/TierRegistry.sol#L97)). That catches
**metamorphic redeploys only** (CREATE2 + SELFDESTRUCT at the same address).

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

Both `certify` and `setAdapterAllowed` are `onlyOwner` on the *same* contract,
so a single owner batch can carry both — there is no cross-contract
coordination excuse for splitting them. In production the owner is the
multisig, reached through the two-step `Ownable2Step` handoff in
[`script/Deploy.s.sol:176`](../script/Deploy.s.sol#L176) (the multisig must
call `acceptOwnership()`).

Order within the session does not matter; *splitting across sessions* does. A
session that lands only Gate B leaves an allowlisted address that nobody has
priced. A session that lands only Gate A ships a certification that reverts in
production.

### [ ] 2.5 Verify both gates on-chain after execution

Read both back. See §3 for the commands. Do not close the onboarding on the
transaction receipt alone — `certify` succeeding does not tell you the codehash
still matches at read time, and it says nothing at all about the allowlist.

### [ ] 2.6 Record the de-onboarding plan

Write down, at onboarding time, the (target, selector) pairs and the adapter
address that a de-onboarding will have to reverse (§4). The bond-release
timelock makes this slow — plan it before you need it, not during an incident.

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

# 3. Gate B. Expect true only for adapters that passed §2.1.
cast call $REG "isAdapterAllowed(address)(bool)" $ADAPTER --rpc-url $RPC

# 4. Proxy check (§2.3). All three EIP-1967 slots must read as zero.
#    implementation / beacon / admin:
cast storage $ADAPTER 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC
cast storage $ADAPTER 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50 --rpc-url $RPC
cast storage $ADAPTER 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103 --rpc-url $RPC
# Non-standard proxies exist — a zero read is necessary, not sufficient.
# Read the deployed source before certifying.

# 5. Bond state, if submitter bonds are configured. A non-zero `releasableAt`
#    means this key is mid-release and `certify` will revert BondPendingRelease
#    (TierRegistry.sol:212).
cast call $REG "bondOf(address,bytes4)((address,uint96,uint64))" $ADAPTER $SEL --rpc-url $RPC
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
1. setAdapterAllowed(adapter, false)      # funds can no longer reach it
2. demote(target, selector)               # per certified pair
3. (bondReleaseDelay later) claimSubmitterBond(target, selector)
```

`demote` ([`TierRegistry.sol:265`](../src/TierRegistry.sol#L265)) is
`onlyOwner` and routes to `_demote` ([`:287`](../src/TierRegistry.sol#L287)),
which deletes the `TierConfig` and starts the submitter-bond release timer
(`bondReleaseDelay`, default 14 days, [`:80`](../src/TierRegistry.sol#L80),
bounded to [1 day, 365 days] by [`:61-62`](../src/TierRegistry.sol#L61)).

Decertifying first opens a window in which the adapter is **allowlisted but
uncertified**: governance has withdrawn its statement about what the target
does, while the guard still lets vault funds be approved to it. Turning the
allowlist off first closes the funds path immediately; the certification can
then be withdrawn at whatever pace the bond mechanics require.

### `_demote` does not touch the allowlist — and you are not the only caller

`_demote` deletes `_configs[k]` and nothing else
([`:287-297`](../src/TierRegistry.sol#L287)). `_adapterAllowed` is a separate
mapping ([`:76`](../src/TierRegistry.sol#L76)) that only `setAdapterAllowed`
writes. Three paths can therefore drop an adapter to tier 2 **without any owner
action**, leaving Gate B open behind it:

- `poke(target, selector)` — **permissionless**
  ([`:280`](../src/TierRegistry.sol#L280)), callable by anyone the moment the
  live codehash diverges from the certified one;
- `demoteByChallenge` — the ChallengeGame's role
  ([`:273`](../src/TierRegistry.sol#L273)), on a passed challenge;
- `tierOf` reporting tier 2 lazily on a codehash mismatch
  ([`:97`](../src/TierRegistry.sol#L97)) with no state write at all — the
  registry's *stored* config still says certified.

The ChallengeGame's demotion is additionally **best-effort**: if the registry's
`authorizedDemoter` role has been rotated away, `_settle` catches the revert
and emits `AdapterDemotionFailed` rather than blocking the verdict
([`src/ChallengeGame.sol:1471`](../src/ChallengeGame.sol#L1471)). A challenge
can therefore pass, with an adapter judged bad, and the certification survive.

**Operational consequence:** treat `TierDemoted` and `AdapterDemotionFailed` as
allowlist alarms. On either, call `setAdapterAllowed(adapter, false)` — the
protocol will not do it for you.

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
- **The guard covers ERC20 only.** ERC721/ERC1155/LP-NFT approvals are
  unguarded ([`SyndicateVault.sol:495-501`](../src/SyndicateVault.sol#L495)).
- **An unwired registry means an unguarded batch.** If the governor returns
  `address(0)` (or lacks the getter), `_guardBatchCalls` returns early and the
  batch runs unguarded by design
  ([`SyndicateVault.sol:503-514`](../src/SyndicateVault.sol#L503)). Read §3
  step 0 before assuming Gate B is live.

### Candidate follow-ups (tracked, not committed)

- **#45 — timelock `certify`.** A delay on grant would give this checklist an
  actual review window: the selector inventory (§2.2) and the proxy check
  (§2.3) could be performed by third parties against a queued certification
  rather than only by the submitter before the fact.
- **CI invariant for allowlisted-but-generic targets** (from issue #17): flag
  any address with `isAdapterAllowed == true` whose bytecode exposes an
  arbitrary-call entry point, or which has no certified (target, selector)
  pair behind it. This would mechanize §2.1 and the §3 drift sweep.
  Feasibility is unestablished — bytecode-level detection of "can forward to an
  arbitrary destination" is not a solved problem.

Neither is a commitment; both are the reasons this document exists in the
interim.
