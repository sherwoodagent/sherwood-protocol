# Lighter integration — testing on the Robinhood fork (chain 9994663)

> **Proven 2026-07-22.** The full lifecycle ran green on the fork against real
> Sherwood core + real ZkLighter: template deployed + approved
> (`0x7ffBd8D5…901AD4`), fund created + 50k USDG deposited, `lighter-perp` clone
> proposed → voted → executed (**deposited 40k USDG into ZkLighter, registered
> real account 843**) → `registerAgentKey` → `initiateReturn` (cancel +
> both-side closes + withdraw enqueued) → two-phase settle (**USDG round-tripped
> to the vault, ~0 PnL, proposal Settled**). Withdrawal maturity was simulated by
> crediting the clone's USDG (the `withdrawPendingBalance` claim itself is
> covered by unit tests + the real-4663 canary); a faithful
> `tenderly_setStorageAt` on `pendingAssetBalances` is the higher-fidelity option
> (§2). This closed the deposit-side of D4 (tick/decimal math against the real
> venue).

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
- Derive the concrete slot once at implementation time (`forge inspect` on the
  verified source, or `cast storage`-diff a real mainnet
  `withdrawPendingBalance` tx), then:

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

## 4. Registering a future `LIGHTER_PERP_TEMPLATE`

Mirrors §4 of the deployment doc (the fork deployer retains ownership, so
impersonation works):

```bash
DEPLOYER=0x5A00afAecE9CF61A768E2AE2713084C8d354DF94   # fork StrategyFactory owner
# 1. deploy the template, 2. approve it:
cast send $STRATEGY_FACTORY "setTemplateApproval(address,bool)" $TEMPLATE true \
  --rpc-url robinhood_fork --unlocked --from $DEPLOYER
# 3. record it in chains/9994663.json as LIGHTER_PERP_TEMPLATE and add the key
#    to _templateKeys() in DeployStrategyFactory.s.sol so re-mints re-approve.
```

## 5. Full strategy lifecycle test (once `LighterPerpStrategy` exists)

The end-to-end bench, all against real deployed Sherwood core + real ZkLighter:

1. Create a USDG fund (deployment doc §7), deposit LPs.
2. Clone the template via `cloneAndInitDeterministic`, propose with the clone.
3. `evm_increaseTime` past voting (24h) + review (24h); execute — the strategy
   pulls USDG and `deposit`s into ZkLighter; assert `accountIndex() != 0`.
4. `registerAgentKey()`; assert the `changePubKey` priority event.
5. Exercise guardrails (`CANCEL_ALL`, `CLOSE_MARKET`, `ROTATE_KEY`) — assert
   priority-queue events (no fills on a fork; encoding + auth is what's tested).
6. `initiateReturn()` → simulate maturity (§2) → settle: the strategy claims,
   pushes USDG to the vault, governor stamps the Lane-B price, queue claims pay.
7. Assert G-H1 accounting: PnL == vault USDG delta (fork round-trip is ~0).

What this bench cannot prove — real fills, funding, API-leg behavior — is
covered by the rh-testnet API loop and a small-notional 4663 canary at ship
time.
