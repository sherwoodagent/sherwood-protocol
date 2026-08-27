# Lighter integration — testing on the Robinhood fork (chain 9994663)

> **Proven 2026-08-22** on vnet a3fb16, against the LIVE post-audit Sherwood
> stack (not a freshly-deployed one) and the real ZkLighter. Template
> `0x22F33B0328C5c6D80478f93eAAF798a8D4a4a560` deployed, approved, venue
> counterparty-allowlisted, and class-anchored on the INERT `name()` selector so
> `execute()` and `settle()` stay at the uncertified `(2, 10_000)` default (§4).
> The previous template `0x7F1D266828Cc5c88AA2ef1E99E8F5e5a1d56E6C7` is
> de-approved on the StrategyFactory, which retires its class without a
> `demoteClass` — see §4. `script/verify-robinhood-fork.sh`: **60/60**.
>
> Bench vault `0xB66C37361403CC98F9Ef74c38F989856BCCA9Be0` (10,000 USDG from two
> LPs), three proposals against the new template, each proposed → LP-voted →
> guardian-**approved** → executed → drained → settled → residue-swept:
>
> | pid | clone | declared | **deployed** | what it proves |
> |---|---|---|---|---|
> | 4 | `0xDd96868d1121596C6b92a94c117ffA42F351Dcd1` | 2,000e6 | **1,239,622,687** | the **coverage scaling**: `effectiveMaxCapital / maxCapital` was `6,507,989,262 / 10,499,951,846`, and `execute()` deployed the scaled figure instead of reverting `CallCapExceeded` |
> | 5 | `0xC9e2c616272D9daa38Dee6a1c53BD3FD2E048BC0` | 2,000e6 | **2,000,000,000** | **fully covered**: `deployedAmount == depositAmount`, `effective == declared` |
> | 6 | `0x99cCa5e63D8Ccd9f3769649B132156220b9c2F01` | 2,000e6 | **2,000,000,000** | the §6 **liveness** leg (below) |
>
> `executeStep` now asserts the law rather than narrating it — `deployedAmount ==
> mulDiv(depositAmount, effectiveMaxCapital, maxCapital)` — which is one
> statement covering both regimes, since a fully-covered proposal has
> `effective == declared`.
>
> **§6 liveness, on pid 6 and Executed.** The vault owner called
> `removeAgent(proposer)`, and both directions held:
> - the de-registered proposer lost everything — `updateParams`
>   **`ProposerNoLongerAgent()` (`0x4551e86a`)**, and `guardrailAction`,
>   `registerAgentKey`, `queueWithdraw` and `initiateReturn` all
>   **`NotAuthorized()` (`0xea8e4eb5`)**. `initiateReturn` gets there by FALLING
>   THROUGH to the permissionless branch, whose timing gate has not elapsed —
>   the demotion is "as much authority as anyone else, and no more".
> - the vault owner kept every one of them, each proven by the venue's own
>   `NewPriorityRequest` rather than by the call not reverting: `CANCEL_ALL` x1,
>   `registerAgentKey` x1, `initiateReturn` **x5** (one cancel + two markets x
>   two sides), `queueWithdraw` x1. An OUTSIDER then settled it.
>
> Every leg also carried the rest of §5: `registerAgentKey` from BOTH proposer
> and owner, `CANCEL_ALL`/`CLOSE_MARKET`/`ROTATE_KEY` through `updateParams` and
> `guardrailAction`, a retired action-4 refusal, an outsider refused on
> `guardrailAction` and `queueWithdraw`, settle SHUT with `WithdrawalInFlight`
> (`0xf0ccc8de`) while the drain was in flight, and the **C1** residue surface —
> post-`Settled` `queueWithdraw(500e6)` flipped `hasUnvaluedResidue()` true,
> `recoverResiduals()` claimed onto the clone WITHOUT pushing, `collectResidue`
> drained it through the single `sweep()` door, and a direct `sweep()` from a
> non-vault caller reverted `NotVault`.
>
> **Real vs simulated.** Everything above is real on-chain execution except
> withdrawal maturity, which the sequencer never delivers on a fork. That is
> simulated the HIGH-FIDELITY way — a `tenderly_setStorageAt` on the venue's own
> `pendingAssetBalances` slot (§2), not by crediting the clone's USDG — so
> `getPendingBalance` and `withdrawPendingBalance` both execute for real against
> the forked venue's real TVL. Order fills, funding and PnL remain out of scope
> on a fork by construction.
>
> **Read the settle deltas with the cheat in mind.** Each leg's C1 step matures
> 500e6 ticks that were never deposited, so the vault books a ~500 USDG gain it
> did not earn — and the NEXT settle charges a real ~100 USDG performance fee on
> it. That is why pid 5 returned 1,899,959,050 of 2,000,000,000 rather than the
> near-zero spread a true round-trip shows. The fee is correct; the gain is the
> fabrication.

How to exercise the Lighter (zkLighter) integration against the **real** venue
contract on the Tenderly Robinhood-mainnet fork, before anything ships to 4663.
Companion to `robinhood-fork-deployment.md` (same vnet, same RPC aliases, same
cheats) and `test/harness/LighterCanary.md` (the mainnet canary this replays).

> Same RPC conventions as the deployment doc: admin RPC =
> `TENDERLY_ROBINHOOD_RPC_URL` in `contracts/.env` (foundry alias
> `robinhood_fork`, **secret**); public RPC = the CLI/app `robinhood-fork`
> default. Vnets are ephemeral — addresses below survive a re-mint, the RPC
> does not.

## 1. Why the fork works for Lighter

The fork replays Robinhood **mainnet** state, so the real ZkLighter rollup
contract is present and healthy:

| Fact | Value (verified on the fork) |
|---|---|
| ZkLighter proxy | `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d` |
| `desertMode()` | `false` |
| USDG asset index | `tokenToAssetIndex(USDG) = 3` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6 dp) |
| Mainnet canary harness | `0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E` (account 623, replayed) |

**The split that matters:** Lighter's off-chain sequencer does **not** watch the
fork. L1-side effects work for real; L2-side effects never arrive on their own.

| Works on the fork (real contract) | Never happens on the fork |
|---|---|
| `deposit` (pulls USDG, registers the account — `addressToAccountIndex` is synchronous) | order fills / positions / PnL |
| `changePubKey` (key registration enqueues) | L2 balance credits |
| `createOrder` / `cancelAllOrders` / `withdraw` (priority requests enqueue + emit) | `pendingBalance` maturing by itself |
| `withdrawPendingBalance` (real USDG transfer — the forked contract holds real TVL) | anything driven by the API/sequencer |

API-driven trading (the agent leg) is tested separately against the
`rh-testnet` Lighter domain (see `test/harness/LighterCanary.md` §keygen/trade)
— the fork is the bench for the **contract/custody** half.

## 2. Simulating withdrawal maturity (the one missing L2 effect)

A secure withdraw only becomes claimable when the sequencer's batch executes —
which never happens on the fork. Simulate it with the vnet's storage cheat:

- Pending claims live in `pendingAssetBalances[assetIndex][masterAccountIndex]
  .balanceToWithdraw` (`ExtendableStorage` in the verified ZkLighter source).
- **The base slot is 498, and `balanceToWithdraw` is at offset 0.** Derived, not
  guessed: `script/fork/LighterSlotProbe.s.sol` runs `vm.record()` around a real
  `getPendingBalance(owner, 3)` against the forked venue and prints the SLOADs;
  498 is the only base in `[0, 600)` that reproduces the observed key for a
  registered account. (`debug_traceCall` is **not supported** on this vnet —
  it answers `-32002 not supported` — which is why the probe uses `vm.record`.)

```
slot = keccak256( accountIndex || keccak256( assetIndex || 498 ) )
```

  `LighterForkBench.maturitySlot(salt)` computes it for a given clone:

```bash
cast rpc tenderly_setStorageAt $ZK_LIGHTER <slot> <ticksAsBytes32> \
  --rpc-url robinhood_fork      # params positional — never a JSON array
```

- After the write, `getPendingBalance(owner, 3)` returns the ticks and
  `withdrawPendingBalance(owner, 3, ticks)` pays real forked USDG — the full
  claim path executes for real.

## 3. Smoke test you can run today (no new code)

The mainnet canary harness is replayed on the fork with ~19.98 USDG and
account 623. The admin RPC accepts `eth_sendTransaction` from any sender, so
impersonate its owner and drive the real venue for free:

```bash
export RPC=<admin rpc>   # TENDERLY_ROBINHOOD_RPC_URL
H=0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E
OWNER=0xC37037e2A9c8Eb30cB9D8021C6c85D299f2B8b95

# gas for the impersonated owner
cast rpc tenderly_setBalance "[\"$OWNER\"]" 0xDE0B6B3A7640000 --rpc-url $RPC

# deposit the harness's replayed USDG back into its Lighter account (real venue call)
cast send $H "depositUSDG(uint256)" 19979840 --rpc-url $RPC --unlocked --from $OWNER
cast call $H "accountIndex()(uint48)" --rpc-url $RPC        # still 623
cast send $H "initiateWithdraw(uint64)" 19979840 --rpc-url $RPC --unlocked --from $OWNER
# -> priority request enqueued; then simulate maturity (§2) and claim:
cast send $H "claim(uint128)" <ticks> --rpc-url $RPC --unlocked --from $OWNER
cast call $H "usdgBalance()(uint256)" --rpc-url $RPC
```

Fresh deploys of the harness work the same way:
`forge script script/DeployLighterCanary.s.sol:DeployLighterCanary --rpc-url
robinhood_fork --unlocked --sender <funded addr> --broadcast`.

## 4. Registering `LIGHTER_PERP_TEMPLATE`

`script/DeployLighterTemplate.s.sol` does the whole ceremony. It has **two
entrypoints**, because `TierRegistry.certifyClass` cannot run until
`certifyDelay` (3 days by default) after the proposal — on the fork that wait is
`evm_increaseTime`, on 4663 it is three real days.

```bash
DEPLOYER=0x5A00afAecE9CF61A768E2AE2713084C8d354DF94   # fork StrategyFactory + TierRegistry owner

# Phase 1 — deploy, approve on the factory, allowlist the venue, propose the class.
# --slow IS MANDATORY under --unlocked. See the warning below.
forge script script/DeployLighterTemplate.s.sol:DeployLighterTemplate --sig 'run()' \
  --rpc-url robinhood_fork --unlocked --sender $DEPLOYER --broadcast --slow

# Skip the certify delay (params positional — never a JSON array).
# 0x3F480 is EXACTLY certifyDelay (259,200s) with no slack at all; 0x40000
# (262,144s) is the same three days with an hour to spare.
cast rpc evm_increaseTime 0x40000 --rpc-url robinhood_fork
cast rpc evm_mine --rpc-url robinhood_fork

# Phase 2 — certify the class and open the class axis.
forge script script/DeployLighterTemplate.s.sol:DeployLighterTemplate --sig 'finalize()' \
  --rpc-url robinhood_fork --unlocked --sender $DEPLOYER --broadcast --slow
```

> **`--slow` or the ceremony silently deploys to the wrong address.** Under
> `--unlocked` forge pipelines the batch into `eth_sendTransaction` and the NODE
> assigns nonces, so the CREATE need not land on the nonce the simulation
> assumed. Hit for real on 2026-08-22: the two owner calls took nonces 256/257
> and the CREATE took 258, so `setTemplateApproval` approved the **simulated**
> address (which holds no code), both `proposeClassCertification` calls reverted
> `NotAContract()` (`0x09ee12d5`), and `_patchAddressIfBook` wrote the phantom
> address into `chains/9994663.json`. Recovery is
> `setTemplateApproval(<phantom>, false)` then a re-run with `--slow`.
> `script/deploy-robinhood-fork.sh` has always passed `--slow`; only this runbook
> had omitted it.

`run()` asserts before it spends anything: the chain is 4663 or 9994663 (46630
is **not** valid — Lighter has no deployment there), `ZK_LIGHTER` holds code and
answers `tokenToAssetIndex(USDG) == 3`, and the template's runtime size is under
Robinhood's 98,304-byte `MaxCodeSize`. It patches `LIGHTER_PERP_TEMPLATE` into
`chains/{chainId}.json`; the key is already in `_templateKeys()` in
`DeployStrategyFactory.s.sol`, so a re-mint re-approves it automatically.

**Both TierRegistry axes are mandatory, and skipping either is silent.** Without
`setCounterpartyAllowed(ZK_LIGHTER, true)` every clone-init reverts
`CounterpartyNotAllowed`; without `setClassAllowed(template, true)` no proposal
can name a clone at all — `SyndicateVault._guardBatchCalls` PART 2a refuses it,
because a per-proposal clone has no address entry to fall back on. Any
owner-gated step the broadcaster cannot perform degrades to a `RUNBOOK:` console
line rather than a silent skip — read the log. `script/verify-robinhood-fork.sh`
checks all of it.

**What the ceremony certifies is `name()`, and that is deliberate.** The class
grant is keyed on `(clone codehash, selector)`, but the class **anchor** that
`setClassAllowed` requires is keyed on the codehash alone — so certifying one
inert selector opens the allowlist for every clone while leaving `execute()` and
`settle()` at the uncertified `(tier 2, 10_000 bps)` default. That is the
intended pricing: `execute()` moves the whole declared cap into an off-chain perp
venue, so a proposal's `requiredCoverage` is the **full notional** of every cap
across both legs — `2 x maxCapital` for the canonical one-mover-per-leg shape.
The registry cannot be asked for it directly (`proposeClassCertification` rejects
`tier >= 2` and a bound `>= 10_000`), which is why the ceremony reaches it by
*not* certifying. `finalize()` asserts `classTierOf(execute) == (2, 10000)` and
`classTierOf(settle) == (2, 10000)` before it finishes.

Verify by hand:

```bash
cast call "$TIERS" 'classTierOf(address,bytes4)(uint8,uint16)' "$TEMPLATE" 0x61461954  # execute() -> 2 10000
cast call "$TIERS" 'classTierOf(address,bytes4)(uint8,uint16)' "$TEMPLATE" 0x11da60b4  # settle()  -> 2 10000
cast call "$TIERS" 'classTierOf(address,bytes4)(uint8,uint16)' "$TEMPLATE" 0x06fdde03  # name()    -> 0 1 (the anchor)
cast call "$TIERS" 'isClassAllowed(address)(bool)'             "$TEMPLATE"             # -> true
```

An already-certified registry (the pre-2026-08-22 default certified `execute()`
and `settle()` at `(1, 9_999)`) migrates with `demoteClass` on both selectors,
then `setClassAllowed(template, true)` again — `_demoteClass` clears the funds
axis but deliberately leaves the callee axis standing so a live clone is never
stranded.

**But a REDEPLOY does not need that migration, and this is worth stating because
the instinct is to reach for `demoteClass` anyway.** A class is keyed on the
CLONE CODEHASH, and an ERC-1167 clone embeds its implementation address — so a
new template address is a new codehash is a **different class**. The old
template's `(1, 9_999)` grants describe a set of clones the new ceremony never
mints. What actually retires them is one call on the FACTORY:

```bash
cast send "$SFACTORY" 'setTemplateApproval(address,bool)' "$OLD_TEMPLATE" false ...
```

`StrategyFactory._authTemplate` reverts `TemplateNotApproved` before
`cloneAndInitDeterministic` can create anything, so once the old template is
de-approved its class is unreachable: no new clone of it can exist, and the
already-settled ones are inert. Demoting the old class on top of that is
optional hygiene, not a correctness step — and it is the strictly WORSE default,
because `_demoteClass` also clears the callee axis, which is the one thing a
still-live old clone would need to be settled through. Verified on vnet a3fb16
on 2026-08-22: `0x7F1D…E6C7` was de-approved and its class left standing
(`isClassAllowed` still `true`, `classTierOf(execute)` still `(1, 9_999)`), and
the new template's class reads `(2, 10_000)` independently.

## 5. Full strategy lifecycle test

**Run it:** `script/fork/lighter-bench.sh` drives
`script/fork/LighterForkBench.s.sol` phase by phase, interleaving the
`evm_increaseTime` waits and the `tenderly_*` cheats that cannot live inside a
broadcast.

```bash
set -a; source .env; set +a

# The fully-covered leg. EXPECT_FULL turns a scaled-down execute into a failure.
RPC="$TENDERLY_ROBINHOOD_RPC_URL" \
GUARDIAN=0x571D47547f9c54Ec8D71afbF5b641484dA58cB05 \
SALT=1 LIGHTER_BENCH_EXPECT_FULL=1 ./script/fork/lighter-bench.sh

# The §6 liveness leg: removeAgent(proposer), then the OWNER unwinds and an
# OUTSIDER settles. Leaves the agent removed; step 13 re-seats it.
RPC="$TENDERLY_ROBINHOOD_RPC_URL" \
GUARDIAN=0x571D47547f9c54Ec8D71afbF5b641484dA58cB05 \
SALT=2 LIVENESS=1 ./script/fork/lighter-bench.sh
```

**One guardian underwrites one leg per epoch.** Each approve pledges
`2 x deployAmount`, so a second leg against the same guardian is under-covered
by construction. Between legs, warp past the booked bucket's expiry
(`genesis + (e+1)*L + W`) — step 1a then sweeps the dead pledge with
`retireApproval` and the next leg reserves and ALLOCATES the full figure. Skipping
either half gets you a silently scaled proposal; see gotcha 3 below.

No phase takes an address argument and none writes a state file: the vault is
found by its subdomain, the clone is the deterministic
`predictDeterministicAddress`, the proposal is the governor's latest. So any
phase is re-runnable on its own.

### Seven things about the FORK that will stop you, none of which are template bugs

1. **The guardian's stake must be 30 days old AT PROPOSE TIME.**
   `GuardianRegistry._growthGatedVoteWeight` takes the min of the voter's stake
   at `snapshotAt` and at `snapshotAt - FLOOR_LOOKBACK` (30 days), so a guardian
   who staked recently in fork-time has zero weight and `voteOnProposal` reverts
   `NotActiveGuardian()`. Warp the vnet past it BEFORE proposing — the snapshot
   is frozen at propose, so warping afterwards does nothing.
2. **The approve quorum SCALES rather than refusing.**
   `quorumTierThreshold == 0` here, so the bond-encumbered approve quorum is
   mandatory at every tier; when it comes up short
   `_deriveAndStoreEffectiveCapital` scales the per-call caps by
   `raised / required`. `LighterPerpStrategy._execute` now scales its pull by the
   same ratio, so an under-covered proposal DEPLOYS LESS rather than reverting
   `CallCapExceeded` — measured on pid 4, 1,239,622,687 of a declared
   2,000,000,000. Size with `LIGHTER_BENCH_DEPLOY_AMOUNT`, and set
   `LIGHTER_BENCH_EXPECT_FULL=1` when a leg is supposed to be fully covered so
   the scaling becomes a failure rather than a note.
3. **"The reservation clears" is TWO counters, and only one of them has a
   clock.** This is the one that will silently mis-size a leg you thought was
   fully covered.
   - `_buckets` / `openExposureUsd` is the **budget**. Bucket `e` stops counting
     at `genesis + (e+1)*L + W` (28-day epochs, 14-day window here), so warping
     past that lets the guardian reserve the full `requiredCoverage` again.
   - `_livePledgedUsd` is the **denominator** `_sharedSlashableUsd` divides the
     bond by, and it has no clock at all. `releaseApproval` is gated on
     `block.timestamp < reviewEnd`, so once a review closes the only thing that
     decrements it is the permissionless `retireApproval`.

   So a guardian can read `openExposureUsd == 0`, reserve the whole $3,999.67 a
   proposal needs, and still allocate `bond * reserved / livePledged`. Measured
   2026-08-22 with two dead approvals worth $6,520.56 of pledge: `allocatedUsd`
   came out at $2,479.04 — 62% — and pid 4 deployed 1,239,622,687. Run
   `LighterForkBench.retireStale(guardian)` first; the driver does it at step 1a.
4. **`block.number` means two different things on this vnet, and the one
   contracts see is not on vnet time.** `LighterPerpStrategy._settle` guards on
   `block.number <= returnsInitiatedAt`. The NUMBER opcode here is neither the
   counter `evm_increaseTime` moves nor `eth_blockNumber`: measured 2026-08-22, a
   real `initiateReturn` stamped 25,814,189 while `eth_blockNumber` read
   21,178,183 — and a 7,300-second warp moved neither, so a settle probe fired
   right after the drain reverts `SettleTooSoon()` (`0xc9b4a873`) and never
   reaches the guard under test. It clears on REAL seconds. The driver's step 8
   retries for that reason; forge is worse off still, since it forks at
   `eth_blockNumber`, so drive settle and its refusal with `cast`.
5. **The LP vote needs its own transaction.** `vote` weighs
   `getPastVotes(voter, p.snapshotTimestamp)` and the snapshot is stamped inside
   `propose`, so a vote at the same timestamp weighs zero (`NoVotingPower()`).
   The fork-test harness hides this behind `vm.warp(+1)`; a broadcast script
   needs a real `evm_increaseTime` between the two.
6. **Even the proposer owes a wait before settling.** `settleProposal` gates on
   `msg.sender == proposer ? MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE (1h) :
   strategyDuration`, so a self-settle straight after `queueWithdraw` reverts
   `StrategyDurationNotElapsed()` (`0x418c8bb9`) and never reaches the strategy's
   own `WithdrawalInFlight` guard.
7. **The maturity cheat leaves a permanent mark on the vault's NAV.** §2 writes
   ticks the venue was never funded for, so the C1 top-up hands the vault a ~500
   USDG gain nobody deposited — and the next settle charges a real performance
   fee on it. Read a settle delta against the previous leg's fabrication, not
   against zero.

Read the REGISTRY's `reviewWindow(governor, pid)` for the vote/review deadlines,
never a figure copied from an earlier log — a re-run shifts them by however long
the first attempt took, and the registry's copy is the one `openReview` and
`voteOnProposal` gate on.

### The bench itself


1. Create a USDG fund (deployment doc §7), deposit LPs. The fund's ERC-4626
   asset **must be USDG** — `_initialize` reverts `AssetMismatch` otherwise.
2. Clone the template via `cloneAndInitDeterministic` with an **explicit**
   `depositAmount` (the `0` = dynamic-all mode is gone; init reverts
   `DepositTooSmall`). Propose with the clone. If §4 was skipped, this is where
   it surfaces: `CounterpartyNotAllowed` or `TierRegistryUnresolved` at
   clone-init.
3. `evm_increaseTime` past voting (24h) + review (24h); execute — the strategy
   pulls exactly `depositAmount` and `deposit`s into ZkLighter; assert
   `accountIndex() != 0` and that any surplus vault float is **untouched**.
4. `registerAgentKey()`; assert the `changePubKey` priority event. Repeat from
   the **vault owner** — the second key must work too.
5. Exercise guardrails (`CANCEL_ALL`, `CLOSE_MARKET`, `ROTATE_KEY`) through both
   `updateParams` (proposer) and `guardrailAction` (proposer or vault owner) —
   assert priority-queue events (no fills on a fork; encoding + auth is what's
   tested).
6. **Liveness check** — `LighterForkBench.liveness(salt, ticks)`, run by the
   driver as `LIVENESS=1 ./script/fork/lighter-bench.sh`. The vault owner calls
   `removeAgent(proposer)` on an **Executed** proposal, and then BOTH directions
   are asserted on the same clone, because testing either alone proves the wrong
   thing:
   - the revocation **bites** — `updateParams` reverts `ProposerNoLongerAgent`
     (`BaseStrategy.onlyProposer` re-reads the live agent set), and
     `guardrailAction` / `registerAgentKey` / `queueWithdraw` revert
     `NotAuthorized` (`_requireProposerOrOwner`). `initiateReturn` also reverts
     `NotAuthorized` but for a different and deliberate reason: it has no
     proposer modifier, it FALLS THROUGH to the permissionless branch, where
     `executedAt + strategyDuration` has not elapsed. The demotion is exactly
     "as much authority as anyone else, and no more".
   - the revocation does **not strand** — the owner still drives
     `guardrailAction(CANCEL_ALL)`, `registerAgentKey`, `initiateReturn` and
     `queueWithdraw`, and each is proven by the venue's OWN `NewPriorityRequest`
     rather than by the call not reverting. On a fork a no-op and a success are
     indistinguishable from the return value, so the leg counts events: 1 for
     `CANCEL_ALL`, 1 for `changePubKey`, `1 + 2 x markets` for `initiateReturn`,
     1 for the drain. Settlement is then driven by an OUTSIDER, which is the
     whole point — nothing about the exit path depended on the agent.

   This is the hole that pinned settlement until `strategyDuration`. The leg
   leaves the agent REMOVED; `setup()` re-seats it on the next run (and the
   driver's step 13 does it immediately), so the bench stays re-runnable.
7. `initiateReturn()` — cancel + both-side closes only, nothing queued.
8. Read the post-close L2 balance from the API, then `queueWithdraw(ticks)`.
   Assert `queuedTicks()` and that a non-proposer/non-owner cannot call it.
9. Simulate maturity (§2) → settle: the strategy claims, pushes USDG to the
   vault, governor stamps the Lane-B price, queue claims pay. Assert that a
   settle attempted before maturity reverts `WithdrawalInFlight`.
10. Assert G-H1 accounting: PnL == vault USDG delta (fork round-trip is ~0).
11. **Residue probes:** after a clean settle assert `hasUndeliveredValue()`,
    `undeliveredValue()` and `hasUnvaluedResidue()` all read empty, so
    `vault.depositsLocked()` is false. Then queue a top-up drain and assert
    `hasUnvaluedResidue()` flips true until it comes back.
12. Under-withdraw regression: repeat with `queueWithdraw(1)`, settle, then prove
    the residue still drains **after** the proposal is Settled via
    `queueWithdraw(rest)` followed by `vault.collectResidue(clone)`. Note the
    renamed door: `sweepToVault()` is gone, `sweep()` is `onlyVault`, and
    `recoverResiduals()` now only **claims** onto the clone. A direct
    `clone.sweep()` from an EOA must revert `NotVault`.

What this bench cannot prove — real fills, funding, API-leg behavior — is
covered by the rh-testnet API loop and the small-notional 4663 canaries.
**H2 is CLOSED, both directions (2026-08-23 long, 2026-08-26 short):** the 4663
canary (`test/harness/LighterH2Canary.md`) proved every cell of the ordered
pair on real filled positions on account 623 — SELL fills against a long,
no-ops against an open short (position exactly unchanged) and against a flat
book; BUY closes a short and no-ops against a flat book. BUY-vs-long cannot
occur (SELL fires first). The both-side close is sound as written.
