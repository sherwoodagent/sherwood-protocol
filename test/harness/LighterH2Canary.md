# H2 canary — does `baseAmount = 0` no-op against a FLAT position?

> **RUN 2026-08-23 — VERDICT: `H2 = NOOP`.** Real 0.005 ETH long opened on
> account 623 (entry 2439.04, 5.000000 USDG margin at 10x), flattened by
> close #1 (`closeMarket(0, 1, 1)`), then close #2 (`closeMarket(0,
> 4294967295, 0)`) fired against the flat book: **size 0.0 across all 37
> samples over the 2-minute window** (20:10:31Z-20:12:29Z), zero resting
> orders, collateral 5.013100 untouched. `initiateReturn`'s both-side close
> is sound as written; the ship blocker is closed. Round-trip PnL +0.013100
> USDG (fees are zero on the venue).

**Chain:** Robinhood mainnet, id `4663`. **Real funds.** Every `cast send` is yours to run.

## The question

`LighterPerpStrategy.initiateReturn()` fires, per market, **in one tx**:

```solidity
ZK_LIGHTER.createOrder(acct, m, 0, MARKET_SELL_PRICE /* 1          */, SIDE_ASK /* 1 */, ORDER_MARKET);
ZK_LIGHTER.createOrder(acct, m, 0, MARKET_BUY_PRICE  /* 2**32 - 1  */, SIDE_BID /* 0 */, ORDER_MARKET);
```

with the standing assertion (`src/strategies/LighterPerpStrategy.sol`, `initiateReturn`):

> the one opposing the open position fills, the other no-ops against a flat/absent position

Nothing proves the no-op half. The fork can't: there is no sequencer, so nothing
ever fills, and both orders sit unmatched. Only a **real filled position on 4663**
answers it.

**H2:** after order #1 has filled and the account is FLAT, does order #2

- **(a)** no-op → `H2 = NOOP`, `initiateReturn` is sound as written; or
- **(b)** open a position → `H2 = OPENS_OPPOSITE`, `initiateReturn` *re-opens*
  instead of unwinding.

`LighterAccountOwner.closeMarket(uint16,uint32,uint8)` emits the identical venue
call (`createOrder(accountIndex(), market, 0, price, isAsk, ORDER_MARKET)`), so
the canary fires byte-identical calldata into the venue — only `accountIndex`
differs.

## Mainnet state read 2026-08-22 (block 43 546 406)

| Thing | Value |
|---|---|
| Harness `LighterAccountOwner` | `0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E` (3 358 B deployed) |
| `owner()` | `0xC37037e2A9c8Eb30cB9D8021C6c85D299f2B8b95` |
| `accountIndex()` | `623` — the contract still owns the account |
| `usdgBalance()` (harness) | `19 979 840` = **19.979840 USDG**, already swept back from the venue |
| `pendingBalance()` | `0` |
| Harness ETH | `0.003` |
| Owner ETH / USDG | `0.001902518043286` ETH / `5.000000` USDG |
| ZkLighter `desertMode()` | `false` |
| gas price | `0.02021 gwei` (a `cast send` costs ~4 µETH — gas is a non-issue) |
| L2 account 623 | flat, `collateral = 0.000000`, `available_balance = 0.000000`, 0 open/pending orders |
| L2 key @ `apiKeyIndex 2` | still registered: `af482d62d9635d91b169c8720a8d25ec476fb437eaae1ec90c185d56d66169c61ac54f76a03e6e9b` (nonce 1) |

If you still hold the matching L2 **private** key from the original canary run,
reuse it. If not, redo `keygen` + `registerKey` from `LighterCanary.md` step 4
before anything below.

## Budget math — 5 USDG cap

Every perp market on this venue has `min_quote_amount = 10.000000` USDG.
ETH (market `0`) additionally has `min_base_amount = 0.0050`, so the smallest
legal order is `max(0.0050, ceil(10 / mark))` = **0.0050 ETH ≈ 12.12 USDG
notional** at mark 2 423. That's the floor; there is no smaller position on 4663.

Margin required = notional × IMF. ETH: `default_initial_margin_fraction = 5000`
(50 % = 2×), `min_initial_margin_fraction = 200` (2 % = 50×),
`maintenance_margin_fraction = 120` (1.2 %), taker & maker fee **0.0000**.

| leverage | IMF | initial margin on 12.12 USDG notional | vs 5 USDG budget |
|---|---|---|---|
| 2× (account's current setting) | 5000 | **6.06 USDG** | **over** |
| 10× (chosen) | 1000 | 1.21 USDG | ok |
| 50× (venue max) | 200 | 0.24 USDG | ok |

**So the 5 USDG budget IS feasible — but only after raising the account's
leverage on market 0.** At the account's current 2× setting the smallest legal
ETH order needs 6.06 USDG and the order would be rejected. Every other perp is
worse or equal: ETH/BTC/QQQ/SPY are the only 50×-capable markets, everything
else caps at 25× or below, and the equity perps carry `trading_hours`. ETH is
also the deepest book ($42 M/24 h), which matters because both closes are
unbounded-price market orders.

**Chosen configuration**

- market `0` (ETH perp), leverage **10×**, deposit **5.000000 USDG**
- position 0.0050 ETH long ≈ 12.12 USDG notional → **effective leverage 2.42×**
- initial margin 1.21 USDG, free collateral 3.79 USDG, maintenance 0.15 USDG
- approx cross liquidation ≈ **−40 %** (~1 453) — a 40 % ETH crash inside a
  ~10-minute window is the only way to lose the deposit
- **worst case loss = the 5.00 USDG deposited.** Fees are zero on this venue.
- margin is not *consumed* by the test, so the same 5 USDG funds as many
  open/close repeats as you want (see Step 9 variants)

The 5 USDG comes out of the harness's **existing** 19.98 USDG — no transfer
needed, and your wallet's own 5 USDG stays untouched.

## Files

| File | Purpose |
|---|---|
| `test/harness/lighter_h2_driver.py` | this canary's driver (`preflight`/`leverage`/`open`/`snap`/`verdict`/`unwind`/`h2`) |
| `test/harness/lighter_canary_driver.py` | shared helpers + `keygen`; imported by the above |
| `test/harness/LighterAccountOwner.sol` | the deployed harness |
| `test/harness/LighterCanary.md` | the original lifecycle runbook (deploy / deposit / keygen) |

The driver **never sends an L1 tx and never touches the owner key.** It signs
only agent-side L2 txs with the API key, which it reads from `$LIGHTER_L2_PRIV`
— never argv (argv lands in `ps` and shell history), never printed.

---

## Runbook

### 0. Environment

```bash
export RPC=https://rpc.mainnet.chain.robinhood.com
export HARNESS=0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E
export USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
export WALLET=0xC37037e2A9c8Eb30cB9D8021C6c85D299f2B8b95
export DEPLOYER_PK=0x...            # owner key — used ONLY by cast, never by python
export IDX=623

python3 -m venv /tmp/lighter-venv
/tmp/lighter-venv/bin/pip install "git+https://github.com/elliottech/lighter-python.git" eth_account aiohttp
export PY=/tmp/lighter-venv/bin/python
export DRV=test/harness/lighter_h2_driver.py

export LIGHTER_L2_PRIV=0x...        # agent key registered at apiKeyIndex 2
```

### 1. Sanity

```bash
cast call 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d "desertMode()(bool)" --rpc-url $RPC   # false
cast call $HARNESS "accountIndex()(uint48)" --rpc-url $RPC                                 # 623
cast call $HARNESS "usdgBalance()(uint256)" --rpc-url $RPC                                 # >= 5000000
```

`desertMode() == true` → **stop**, the exchange is in escape-hatch mode.

### 2. Preflight (read-only)

```bash
$PY $DRV preflight --account-index $IDX --market 0 --leverage 10 --deposit 5
```

Expected right now: the budget table above, `position on market 0: size=0.0`,
and a `NO-GO` listing exactly two items — account IMF is 5000, and L2 collateral
is 0. Steps 3 and 4 clear both. Any *other* NO-GO line (position not flat,
market not `active`, `force_reduce_only`, non-empty `trading_hours`) → stop.

### 3. Deposit exactly 5 USDG of margin

```bash
cast send $HARNESS "depositUSDG(uint256)" 5000000 --rpc-url $RPC --private-key $DEPLOYER_PK
```

`depositUSDG` does `forceApprove(5000000)` then `deposit(this, 3, Perps, 5000000)`.
The L2 credit lands a few seconds after the L1 tx. Poll:

```bash
$PY $DRV snap --account-index $IDX --label post-deposit
```

Expected: `"collateral": "5.000000"`, `"available_balance": "5.000000"`.

### 4. Raise leverage to 10× on market 0

This is an **L2 config tx (`UpdateLeverage`), not an order** — signed with the
agent key. It lowers the account's IMF on market 0 from 5000 to 1000 so the
smallest legal ETH order fits inside the 5 USDG budget.

```bash
$PY $DRV leverage --account-index $IDX --market 0 --leverage 10
```

Expected: `[lev] confirmed: account IMF now 10.00%`.

Re-run preflight — it must now print `GO`:

```bash
$PY $DRV preflight --account-index $IDX --market 0 --leverage 10 --deposit 5
```

### 5. Guided run

```bash
$PY $DRV h2 --account-index $IDX --market 0 --leverage 10 --deposit 5
```

It runs preflight, gates on you typing `go`, then:

1. **opens** the minimal legal LONG (50 ticks = 0.0050 ETH, market buy, 500 bps
   protective bound) and polls until the position shows filled;
2. prints **`cast send` #1** and waits for you to run it and press ENTER;
3. samples the position for 45 s and asserts **FLAT** — if #1 did not flatten,
   it stops and prints an unwind plan, because H2 is not answerable unless order
   #2 fires against a flat book;
4. prints **`cast send` #2** and waits again;
5. samples for 120 s and prints the verdict + the unwind plan.

The two commands it will print, verbatim:

```bash
# #1 — initiateReturn's FIRST venue call: SELL close, price bound 1
cast send $HARNESS "closeMarket(uint16,uint32,uint8)" 0 1 1 \
  --rpc-url $RPC --private-key $DEPLOYER_PK

# #2 — initiateReturn's SECOND venue call: BUY close, price bound 2**32-1.
#      THE CALL UNDER TEST. The account is FLAT going in.
cast send $HARNESS "closeMarket(uint16,uint32,uint8)" 0 4294967295 0 \
  --rpc-url $RPC --private-key $DEPLOYER_PK
```

If your shell isn't a TTY (or you'd rather drive it by hand), use the steps
individually — same reads, same verdict:

```bash
$PY $DRV open    --account-index $IDX --market 0
# run cast #1
$PY $DRV snap    --account-index $IDX --label after-close-1   # expect size 0.0
# run cast #2
$PY $DRV verdict --account-index $IDX --seconds 120
```

### 6. Expected output

**After `open`** — `[snap] {"label":"post-open", "size": 0.005, "sign": 1,
"avg_entry": "~2423.xx", "collateral": "5.000000", "available_balance":
"~3.79", ...}`.

**After cast #1** — `size` goes to `0.0` within a few seconds,
`available_balance` returns to ~5.00 (minus PnL; fees are 0). If it doesn't
flatten within 45 s, **stop** and unwind — see below.

**After cast #2** — one of:

```
#  H2 = NOOP
#  A baseAmount=0 market order against a FLAT position does nothing.
#  sizes observed: [0.0, 0.0, 0.0, ...]
```

```
#  H2 = OPENS_OPPOSITE
#  closeMarket #2 OPENED a position: peak |size| = 0.005, final size = 0.005 ...
```

The verdict line reports peak `|size|` over the whole window, not just the last
sample, so a position that opens and is then liquidated/auto-closed still trips
`OPENS_OPPOSITE`.

### 7. What each verdict means

**`H2 = NOOP`** — `initiateReturn` is sound as written. The both-side close does
exactly what its comment claims; the M2 gas note (2 venue calls per market,
`MAX_MARKETS = 16`) stands; `ACTION_CLOSE_MARKET`'s "baseAmount = 0 can only
CLOSE a position, never open one" stands. Record the block numbers of both
`cast send`s and the sample series as the evidence, and close H2.

**`H2 = OPENS_OPPOSITE`** — high severity, two findings, not one:

1. **`initiateReturn` re-opens instead of unwinding.** Whichever of the pair is
   not the closing side converts a just-flattened account into a fresh leveraged
   position, sized by whatever the venue reads `baseAmount = 0` as. The unwind
   then hands `queueWithdraw`/`_settle` a margin account that still has risk on
   it — strictly worse than the no-fill case the wide price bounds were chosen
   to avoid.
2. **`ACTION_CLOSE_MARKET` (updateParams action 2) becomes an OPEN primitive.**
   Its comment explicitly leans on `baseAmount = 0` being close-only to justify
   *not* checking `market` against `markets` (H1/M3). If that premise is false,
   a live proposer can open a position on any of the venue's 40 perps through
   the operator guardrail. The market whitelist decision has to be revisited
   alongside the close.

   **The contract change.** The both-side blind close must become a single,
   correctly-sided close per market:

   - **Preferred — reduce-only at the venue.** If the deployed ZkLighter
     implementation exposes a reduce-only flag or a close-position entrypoint
     on its L1 `createOrder` path, add it to `IZkLighter` and set it on both
     legs. That keeps `initiateReturn` permissionless and side-agnostic, which
     is the whole point of firing both. *Verify against the deployed
     implementation's ABI first* — the minimal interface in
     `src/lighter/IZkLighter.sol` was reverse-engineered and has no such
     parameter, so this may not exist.
   - **Fallback — caller-supplied side.** `initiateReturn(uint8[] calldata
     sides)`, one order per market: `createOrder(acct, markets[i], 0,
     sides[i] == SIDE_ASK ? MARKET_SELL_PRICE : MARKET_BUY_PRICE, sides[i],
     ORDER_MARKET)`. The sign is read off-chain (the contract cannot read a
     position). Consequences to carry through:
     - `sides.length` must equal `markets.length`, else revert.
     - A wrong side now *opens*, so the call must stay re-runnable — keep the
       `returnsInitiatedAt` latch (it only gates `_settle` timing) but do not
       let `AlreadyInitiated` lock out a corrective second call; the
       proposer-side `ACTION_CLOSE_MARKET` guardrail remains the fixer.
     - A griefing permissionless caller can pass all-wrong sides. Bound it: the
       positions are sized by the strategy's own margin, and the corrective call
       is one tx.
     - The M2 note halves: 1 venue call per market, so `MAX_MARKETS` can rise
       or the comment must be corrected.
   - **Not viable:** splitting the two legs across separate txs or blocks. The
     legs are already processed sequentially by the sequencer's priority queue,
     which is exactly the condition this canary reproduces — a gap changes
     nothing.

   Also update the `MARKET_SELL_PRICE`/`MARKET_BUY_PRICE` doc comment (the
   "an unwind that silently no-fills is strictly worse than a bad fill"
   rationale) and `docs/LighterPerpStrategy.md`'s unwind section.

### 8. Unwind / abort

The driver prints a plan computed from the **observed** position. The rule it
encodes, and the one to follow if you're doing it by hand:

| residual | correct close | **do not** |
|---|---|---|
| LONG (`sign = 1`, size > 0) | `closeMarket(0, 1, 1)` — market SELL | re-run `closeMarket(0, 4294967295, 0)`; a BUY against a long no-ops at best, **adds to it** at worst |
| SHORT (`sign = -1`) | `closeMarket(0, 4294967295, 0)` — market BUY | re-run `closeMarket(0, 1, 1)` |
| flat | nothing | — |

If the contract-side close does not flatten it, fall back to the agent-side
**reduce-only** close — `reduce_only = true` structurally cannot flip a
position, which is why it's the safe hatch:

```bash
$PY $DRV unwind --account-index $IDX --market 0 --execute
```

Then drain the margin (identical to `LighterCanary.md` step 7–8):

```bash
curl -s "https://api.rh.lighter.xyz/api/v1/account?by=index&value=$IDX" | \
  python3 -c 'import sys,json;a=json.load(sys.stdin)["accounts"][0];print(a["available_balance"],a["collateral"])'
export TICKS=<floor(available_balance * 1e6)>

cast send $HARNESS "initiateWithdraw(uint64)" $TICKS --rpc-url $RPC --private-key $DEPLOYER_PK
watch -n30 'cast call '"$HARNESS"' "pendingBalance()(uint128)" --rpc-url '"$RPC"   # ~515 s
export PENDING=$(cast call $HARNESS "pendingBalance()(uint128)" --rpc-url $RPC)
cast send $HARNESS "claim(uint128)" $PENDING --rpc-url $RPC --private-key $DEPLOYER_PK

export BAL=$(cast call $HARNESS "usdgBalance()(uint256)" --rpc-url $RPC)
cast send $HARNESS "rescueERC20(address,address,uint256)" $USDG $WALLET $BAL --rpc-url $RPC --private-key $DEPLOYER_PK
```

**Hard abort at any point:** `cast send $HARNESS "cancelAll()"` kills resting
orders, then the reduce-only close, then the withdraw ladder. The owner key
alone drives all of it; the agent key can never move funds off the account.

### 9. Optional follow-ups (same 5 USDG — margin is reused, not spent)

- **Wrong-side-close half.** Open a **SHORT** instead and run the same pair.
  That tests the other half of the assumption: does `closeMarket(0, 1, 1)`
  (a SELL against an existing SHORT) no-op, or double the short? Both halves
  have to hold for the both-side close to be correct.
  (`$PY $DRV open` opens long by design; for the short leg use
  `lighter_canary_driver.py trade --side sell --size 50`.)
- **Same-tx fidelity.** The strategy fires both legs in one L1 tx; the canary
  fires two. The sequencer processes priority requests in queue order either
  way, so the observable should match — but if the verdict is `NOOP`, sending
  the two `cast send`s back-to-back with no pause (both landing in adjacent
  blocks) is a cheap confirmation that nothing depends on the 45 s gap.

### 10. When you're done

Leave the harness holding its USDG or sweep it; either is fine. Record in the
PR: the two `cast send` tx hashes, the sample series, the verdict line, and the
final `usdgBalance()`.
