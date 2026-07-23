# Lighter contract-owned-account canary — runbook

Proves, on **Robinhood mainnet (chain 4663)**, that a **smart contract** can own a
Lighter (zkLighter) perp account and run the full lifecycle:

> deposit USDG → get a contract-owned account → register an agent L2 trading key →
> (agent trades via API) → contract force-closes → contract withdraws USDG back to itself.

Custody proof: the on-chain lifecycle (deposit / register-key / close / withdraw) is
driven **only** by the contract owner's L1 key. The agent that trades holds **only** an
L2 API key — never the owner key, and it can never move funds off the account.

> **This runbook moves real funds on mainnet.** Every `cast send` is yours to run with
> your own key. Nothing here is automated. Amounts are small (~20 USDG, ~0.002 ETH gas).

## Files

| File | Purpose |
|---|---|
| `src/lighter/IZkLighter.sol` | Minimal venue interface (reused by the future strategy) |
| `test/harness/LighterAccountOwner.sol` | The `Ownable` account-owner harness (3,358 B) |
| `script/DeployLighterCanary.s.sol` | Deploy script (owner = broadcaster) |
| `test/harness/lighter_canary_driver.py` | Agent-side driver (keygen + trade), runs on a venv |

## Verified 4663 constants

| Thing | Value |
|---|---|
| ZkLighter proxy (all calls) | `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d` |
| USDG token (6 decimals) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| USDG asset index | `3` |
| RouteType | `Perps = 0`, `Spot = 1` (perp margin uses `0`) |
| OrderType | `Limit = 0`, `Market = 1` |
| isAsk | `0 = bid/long`, `1 = ask/sell` |
| ETH perp market | index `0` (size_decimals 4, min order ≈ 10 USDG notional) |
| USDG ticks | `1 USDG = 1_000_000 ticks` (= token base units; tickSize 1) |
| API (agent) | `https://api.rh.lighter.xyz`, chain_id `466324`, api_key_index `2` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` |

## Prereqs

- A funded 4663 wallet: **~20 USDG** + **~0.002 ETH** (gas token = ETH, ~0.07 gwei).
- `forge` + `cast` installed (Foundry).
- A Python venv with the Lighter SDK:
  `python3 -m venv /tmp/lighter-venv && /tmp/lighter-venv/bin/pip install "git+https://github.com/elliottech/lighter-python.git" eth_account`
  (the signer is a Go shared lib the SDK ships).
- Env vars (set once):

```bash
export RPC=https://rpc.mainnet.chain.robinhood.com
export DEPLOYER_PK=0x...            # your 4663 wallet key (owner of the harness)
export WALLET=0x...                 # its address
export PROXY=0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d
export USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
export PY=/tmp/lighter-venv/bin/python
export DRV=test/harness/lighter_canary_driver.py
```

> **Do not** paste the L2 private key (Step 4/5) onto a shared shell — it appears in
> `ps`/history. It only trades; it can't withdraw to a foreign address, but treat it as
> a hot secret anyway.

Every step below is an **async priority request** on Lighter (except deposit's
account-index write and `withdrawPendingBalance`). **Poll between steps — do not chain.**

---

### Step 0 — sanity

```bash
cast call $PROXY "desertMode()(bool)" --rpc-url $RPC          # must be: false
cast call $USDG  "balanceOf(address)(uint256)" $WALLET --rpc-url $RPC   # ≥ 20000000
cast balance $WALLET --rpc-url $RPC                            # ≥ ~2e15 (0.002 ETH)
cast call $PROXY "tokenToAssetIndex(address)(uint16)" $USDG --rpc-url $RPC  # must be: 3
```

If `desertMode()` is `true`, **stop** — the exchange is in escape-hatch mode.

### Step 1 — deploy the harness

```bash
# (sherwood-protocol root IS the contracts dir)
forge script script/DeployLighterCanary.s.sol:DeployLighterCanary \
  --rpc-url $RPC --private-key $DEPLOYER_PK --broadcast
# copy the logged "LighterAccountOwner:" address
export HARNESS=0x...
```

### Step 2 — fund the harness (~20 USDG + ~0.002 ETH)

```bash
cast send $USDG "transfer(address,uint256)" $HARNESS 20000000 \
  --rpc-url $RPC --private-key $DEPLOYER_PK
cast send $HARNESS --value 0.002ether \
  --rpc-url $RPC --private-key $DEPLOYER_PK
# verify
cast call $HARNESS "usdgBalance()(uint256)" --rpc-url $RPC     # 20000000
cast balance $HARNESS --rpc-url $RPC                           # ~2e15
```

### Step 3 — deposit → the contract now owns an account  ★ key proof

```bash
cast send $HARNESS "depositUSDG(uint256)" 20000000 \
  --rpc-url $RPC --private-key $DEPLOYER_PK

# accountIndex populates in the deposit tx on L1 — poll until nonzero:
watch -n2 'cast call '"$HARNESS"' "accountIndex()(uint48)" --rpc-url '"$RPC"
export IDX=<the nonzero index>      # e.g. 4123
```

`accountIndex() != 0` means **a smart contract owns Lighter account `IDX`.** The L2 margin
balance is credited by the sequencer a few seconds later (needed before trading).

### Step 4 — keygen + register the agent L2 key

```bash
# offline, safe: generates + validates a 40-byte Goldilocks pubkey
$PY $DRV keygen
# copy PUBKEY (0x..80 hex) and PRIVKEY from the output
export L2_PUB=0x...
export L2_PRIV=0x...

# contract registers the key at apiKeyIndex 2 (owner-auth, msg.sender == harness):
cast send $HARNESS "registerKey(uint8,bytes)" 2 $L2_PUB \
  --rpc-url $RPC --private-key $DEPLOYER_PK
```

Confirm it landed (poll ~10s):

```bash
curl -s "https://api.rh.lighter.xyz/api/v1/apikeys?account_index=$IDX&api_key_index=255" | \
  $PY -c 'import sys,json; d=json.load(sys.stdin); print([k for k in d.get("api_keys",[]) if k.get("api_key_index")==2])'
```

### Step 5 — agent trade leg (API key only)  ★ proves agent trades the contract's account

```bash
# tiny ETH-perp market BUY on account IDX, using ONLY the L2 key (no owner key):
$PY $DRV trade --account-index $IDX --l2-priv $L2_PRIV --side buy --market 0
# auto-sizes to ~1.2x the min notional (~12 USDG). Override with --size <ticks> if wanted
# (ETH size_decimals 4: 0.006 ETH = 60 ticks). Prints the resulting position.
```

A nonzero position on market 0 proves the agent, holding only the registered L2 key,
trades the **contract-owned** account.

### Step 6 — contract force-closes  ★ on-chain kill switch

```bash
# market SELL full-close (baseAmount 0, price bound 1) — driven by the CONTRACT, not the agent:
cast send $HARNESS "closeMarket(uint16,uint32,uint8)" 0 1 1 \
  --rpc-url $RPC --private-key $DEPLOYER_PK

# confirm flat via API (poll a few seconds):
$PY $DRV trade --account-index $IDX --l2-priv $L2_PRIV --close   # prints "already flat" once settled
```

(If the position is short instead of long, close with `closeMarket 0 4294967295 0` — market
BUY, price bound `2^32-1`, isAsk 0.)

### Step 7 — withdraw USDG back to the contract  ★ custody sink returns to the contract

Read the actual available L2 USDG (trade fees/PnL shift it off exactly 20):

```bash
curl -s "https://api.rh.lighter.xyz/api/v1/account?by=index&value=$IDX" | \
  $PY -c 'import sys,json; a=json.load(sys.stdin)["accounts"][0]; print("available_balance USDG:", a.get("available_balance"), "collateral:", a.get("collateral"))'
# convert to ticks: floor(available_balance * 1e6). e.g. 19.87 USDG -> 19870000
export TICKS=<floor(available_balance*1e6)>
```

Queue the withdrawal, then poll `pendingBalance()` (matures after ~515s = withdrawalDelay):

```bash
cast send $HARNESS "initiateWithdraw(uint64)" $TICKS \
  --rpc-url $RPC --private-key $DEPLOYER_PK

# poll every ~30s until nonzero (~9 min):
watch -n30 'cast call '"$HARNESS"' "pendingBalance()(uint128)" --rpc-url '"$RPC"

# once nonzero, claim it back into the harness (permissionless, sends to address(this)):
export PENDING=$(cast call $HARNESS "pendingBalance()(uint128)" --rpc-url $RPC)
cast send $HARNESS "claim(uint128)" $PENDING \
  --rpc-url $RPC --private-key $DEPLOYER_PK

# confirm USDG is back in the contract:
cast call $HARNESS "usdgBalance()(uint256)" --rpc-url $RPC
```

USDG landing back in `HARNESS` closes the loop: the contract is the custody sink.

### Step 8 — sweep everything back to your wallet

```bash
BAL=$(cast call $HARNESS "usdgBalance()(uint256)" --rpc-url $RPC)
cast send $HARNESS "rescueERC20(address,address,uint256)" $USDG $WALLET $BAL \
  --rpc-url $RPC --private-key $DEPLOYER_PK

ETH=$(cast balance $HARNESS --rpc-url $RPC)
cast send $HARNESS "rescueETH(address,uint256)" $WALLET $ETH \
  --rpc-url $RPC --private-key $DEPLOYER_PK
```

---

## Notes / gotchas before you run

- **Sizing:** min *deposit* is 1 USDG, but an ETH order needs **≥ 10 USDG notional** —
  deposit **~20 USDG** so the agent order clears the minimum with margin to spare.
- **Async everywhere:** account-index write is instant in the deposit tx; the tradeable L2
  balance lands a few seconds later; `changePubKey`/`createOrder`/`withdraw` are priority
  requests (poll, don't chain); withdrawal maturity is **~515s**.
- **Gas:** the harness sends its own txs, so it needs its own ETH (Step 2). Keep ~0.002 ETH;
  sweep the remainder in Step 8.
- **`IDX`** must be captured from Step 3 and reused in every later step.
- **`apiKeyIndex` must be 2..254** — the harness passes whatever you give `registerKey`; use `2`.
- **L2 key is a hot secret** — it can trade the account but cannot withdraw to a foreign
  address (withdraw returns funds to the account owner only). Still, don't leak it.
- **Withdraw amount:** always read `available_balance` first (Step 7) — withdrawing more
  than is free will revert; leftover dust is fine (swept via a second withdraw or ignored).
