#!/usr/bin/env python3
"""
lighter_h2_driver.py — the H2 canary: what does a `baseAmount = 0` market order
do against a FLAT position on Lighter?

WHY
---
`LighterPerpStrategy.initiateReturn()` fires, per market, in ONE tx:

    createOrder(acct, m, 0, MARKET_SELL_PRICE = 1,          SIDE_ASK = 1, ORDER_MARKET)
    createOrder(acct, m, 0, MARKET_BUY_PRICE  = 2**32 - 1,  SIDE_BID = 0, ORDER_MARKET)

The comment in the source asserts "the one opposing the open position fills, the
other no-ops against a flat/absent position". Nothing has ever proven the
no-op half. The fork cannot prove it (no sequencer, so nothing ever fills). Only
a real filled position on Robinhood mainnet (4663) can.

H2 asks exactly one question:

    After order #1 has FILLED and the account is FLAT, does order #2
      (a) no-op                                      -> H2 = NOOP
      (b) open a position in the opposite direction  -> H2 = OPENS_OPPOSITE

THIS SCRIPT NEVER SENDS AN L1 TRANSACTION AND NEVER SIGNS WITH THE OWNER KEY.
The two `closeMarket` calls are printed as `cast send` lines for the operator to
run. The only L2 txs it signs are the agent-side ones (open order / optional
leverage config / optional reduce-only unwind), with the L2 API key, which is
read from $LIGHTER_L2_PRIV — never from argv, never printed.

Subcommands
  preflight   Read-only: harness + account + market state, budget math, GO/NO-GO.
  leverage    Set the account's per-market leverage (an L2 config tx, not an
              order). REQUIRED: the default IMF is 50% and the smallest legal
              ETH order needs more margin than the 5 USDG budget at 2x.
  open        Open the minimal legal LONG and poll until it shows filled.
  snap        One position/balance snapshot with a timestamp and a label.
  verdict     Poll the position for ~2 min after `closeMarket` #2 and print the
              H2 verdict.
  unwind      Read the position, print the CORRECT close side + the withdraw
              ladder; with --execute also fires a reduce-only API close (which
              structurally cannot flip the position).
  h2          Guided end-to-end run: open -> gate on cast #1 -> snap ->
              gate on cast #2 -> verdict -> unwind plan.

Robinhood mainnet: URL=https://api.rh.lighter.xyz, chain_id=466324,
api_key_index=2, ETH perp = market 0, USDG 6dp.
"""

import argparse
import asyncio
import json
import math
import os
import sys
import time
from datetime import datetime, timezone

import aiohttp

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lighter import SignerClient  # noqa: E402

from lighter_canary_driver import (  # noqa: E402
    URL,
    CHAIN_ID,
    next_nonce,
    summarize,
)

# ── constants mirrored from the contracts (keep byte-identical) ──────────────
# src/strategies/LighterPerpStrategy.sol
MARKET_SELL_PRICE = 1  # uint32
MARKET_BUY_PRICE = 2**32 - 1  # uint32 == type(uint32).max == 4294967295
SIDE_BID = 0  # long / buy
SIDE_ASK = 1  # short / sell

# test/harness/LighterAccountOwner.sol  (4663 mainnet)
HARNESS = "0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
PROXY = "0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d"
RPC = "https://rpc.mainnet.chain.robinhood.com"

L2_ENV = "LIGHTER_L2_PRIV"
BUDGET_USDG = 5.0


def log(*a):
    print(*a, flush=True)


def now():
    t = time.time()
    return t, datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def l2_key():
    k = os.environ.get(L2_ENV, "").strip()
    if not k:
        log(f"ERROR: ${L2_ENV} is not set.")
        log(f"  export {L2_ENV}=0x...   # agent L2 api key registered at apiKeyIndex 2")
        log("  (never pass it on argv — it lands in `ps` and shell history)")
        sys.exit(2)
    return k


def signer(account_index, aki):
    return SignerClient(
        url=URL,
        account_index=account_index,
        api_private_keys={aki: l2_key()},
        chain_id=CHAIN_ID,
    )


# ── read helpers ─────────────────────────────────────────────────────────────

async def _account_raw(session, account_index):
    async with session.get(
        URL + "/api/v1/account", params={"by": "index", "value": str(account_index)}
    ) as r:
        d = await r.json()
    return d["accounts"][0]


async def _detail_raw(session, market):
    async with session.get(URL + "/api/v1/orderBookDetails") as r:
        d = await r.json()
    for o in d.get("order_book_details", []):
        if int(o["market_id"]) == market:
            return o
    raise RuntimeError(f"market {market} not in orderBookDetails")


def pos_of(acct, market):
    """(signed_size_float, raw_dict_or_None) for `market` in a raw account read."""
    for p in acct.get("positions", []) or []:
        if int(p["market_id"]) == market:
            size = float(p.get("position") or 0.0)
            sign = int(p.get("sign", 1))
            return (size if sign >= 0 else -size), p
    return 0.0, None


def min_legal_base(det):
    """Smallest base amount (in ticks) satisfying BOTH min_base_amount and
    min_quote_amount. Returns (ticks, base_float, notional_usdg, mark)."""
    sdec = int(det["size_decimals"])
    mark = float(det["mark_price"])
    min_base_ticks = int(round(float(det["min_base_amount"]) * 10**sdec))
    min_quote = float(det["min_quote_amount"])
    ticks_from_quote = math.ceil(min_quote / mark * 10**sdec)
    ticks = max(min_base_ticks, ticks_from_quote)
    return ticks, ticks / 10**sdec, ticks / 10**sdec * mark, mark


async def snapshot(session, account_index, market, label):
    acct = await _account_raw(session, account_index)
    size, p = pos_of(acct, market)
    t, iso = now()
    rec = {
        "label": label,
        "t": round(t, 3),
        "utc": iso,
        "size": size,
        "sign": (p or {}).get("sign"),
        "avg_entry": (p or {}).get("avg_entry_price"),
        "position_value": (p or {}).get("position_value"),
        "uPnL": (p or {}).get("unrealized_pnl"),
        "imf_pct": (p or {}).get("initial_margin_fraction"),
        "collateral": acct.get("collateral"),
        "available_balance": acct.get("available_balance"),
        "open_orders": (p or {}).get("open_order_count"),
        "pending_orders": acct.get("pending_order_count"),
    }
    log("[snap] " + json.dumps(rec, default=str))
    return rec


# ── cast command rendering (printed only — never executed here) ──────────────

def cast_close(market, price, is_ask, note):
    return (
        f'cast send $HARNESS "closeMarket(uint16,uint32,uint8)" '
        f"{market} {price} {is_ask} \\\n"
        f"  --rpc-url $RPC --private-key $DEPLOYER_PK    # {note}"
    )


def print_cast_1(market):
    log("")
    log("=" * 78)
    log("  RUN THIS NOW — closeMarket #1  (market SELL close, price bound 1)")
    log("  byte-identical to LighterPerpStrategy.initiateReturn()'s FIRST venue call:")
    log("    createOrder(acct, m, 0, MARKET_SELL_PRICE=1, SIDE_ASK=1, ORDER_MARKET=1)")
    log("=" * 78)
    log(cast_close(market, MARKET_SELL_PRICE, SIDE_ASK, "SELL-close the LONG"))
    log("=" * 78)


def print_cast_2(market):
    log("")
    log("=" * 78)
    log("  RUN THIS NOW — closeMarket #2  (market BUY close, price bound 2**32-1)")
    log("  byte-identical to initiateReturn()'s SECOND venue call:")
    log("    createOrder(acct, m, 0, MARKET_BUY_PRICE=4294967295, SIDE_BID=0, ORDER_MARKET=1)")
    log("  >>> THIS is the call under test. The account is FLAT going in. <<<")
    log("=" * 78)
    log(cast_close(market, MARKET_BUY_PRICE, SIDE_BID, "the call H2 is about"))
    log("=" * 78)


def gate(prompt):
    if not sys.stdin.isatty():
        log("")
        log(f"[gate] non-interactive stdin — run the command above, then continue with"
            f" the individual subcommands (`snap`, `verdict`, `unwind`).")
        sys.exit(0)
    input(f"\n[gate] {prompt} — press ENTER when the tx is MINED: ")


# ── preflight ────────────────────────────────────────────────────────────────

async def cmd_preflight(args):
    async with aiohttp.ClientSession() as session:
        det = await _detail_raw(session, args.market)
        acct = await _account_raw(session, args.account_index)

        ticks, base, notional, mark = min_legal_base(det)
        dimf = int(det["default_initial_margin_fraction"])
        mimf = int(det["min_initial_margin_fraction"])
        mmf = int(det["maintenance_margin_fraction"])
        size, p = pos_of(acct, args.market)
        acct_imf_pct = float((p or {}).get("initial_margin_fraction", dimf / 100))
        acct_imf = int(round(acct_imf_pct * 100))  # "50.00" -> 5000

        log(f"market {args.market} {det['symbol']}  mark={mark}  "
            f"size_dec={det['size_decimals']} price_dec={det['price_decimals']}")
        log(f"  min_base_amount = {det['min_base_amount']}  "
            f"min_quote_amount = {det['min_quote_amount']} USDG")
        log(f"  smallest legal order: {ticks} ticks = {base} {det['symbol']} "
            f"= {notional:.4f} USDG notional")
        log(f"  taker_fee={det['taker_fee']}  maker_fee={det['maker_fee']}  "
            f"liquidation_fee={det['liquidation_fee']}")
        log(f"  IMF: default={dimf} ({dimf/100:.2f}% = {10000/dimf:.1f}x)  "
            f"min={mimf} ({mimf/100:.2f}% = {10000/mimf:.1f}x)  "
            f"MMF={mmf} ({mmf/100:.2f}%)")
        log(f"  account 623's CURRENT IMF on this market: {acct_imf} "
            f"({acct_imf_pct:.2f}% = {10000/acct_imf:.1f}x)")

        log("")
        log("BUDGET MATH (cap = %.2f USDG of margin, total)" % BUDGET_USDG)
        for lev in (10000 / dimf, args.leverage, 10000 / mimf):
            lev = int(lev)
            imr = notional * (10000 / lev) / 10000
            verdict = "OK" if imr <= BUDGET_USDG else "OVER BUDGET"
            log(f"  at {lev:>3}x (IMF {int(10000/lev):>4}): initial margin required "
                f"= {imr:6.3f} USDG   [{verdict}]")
        lev = args.leverage
        imr = notional * (10000 / lev) / 10000
        mm = notional * mmf / 10000
        liq_drop = (args.deposit - mm) / notional if notional else 0
        log(f"  chosen: deposit {args.deposit:.2f} USDG, leverage {lev}x")
        log(f"    initial margin required : {imr:.3f} USDG")
        log(f"    free collateral left    : {args.deposit - imr:.3f} USDG")
        log(f"    effective leverage      : {notional/args.deposit:.2f}x")
        log(f"    maintenance margin      : {mm:.3f} USDG")
        log(f"    approx liquidation at   : -{liq_drop*100:.1f}% "
            f"(~{mark*(1-liq_drop):.2f}) — cross, ignores funding")
        log(f"    worst case loss         : the {args.deposit:.2f} USDG deposited")

        log("")
        log("ACCOUNT STATE")
        log(f"  index={acct['index']}  l1={acct['l1_address']}")
        log(f"  collateral={acct['collateral']}  available_balance={acct['available_balance']}")
        log(f"  position on market {args.market}: size={size}  "
            f"open_orders={(p or {}).get('open_order_count')}  "
            f"pending_orders={acct.get('pending_order_count')}")

        problems = []
        if acct["l1_address"].lower() != HARNESS.lower():
            problems.append(f"account {args.account_index} is NOT owned by {HARNESS}")
        if det["status"] != "active":
            problems.append(f"market status = {det['status']}")
        if det["market_config"].get("force_reduce_only"):
            problems.append("market is force_reduce_only — cannot open")
        if det["market_config"].get("trading_hours"):
            problems.append(f"market has trading_hours={det['market_config']['trading_hours']}")
        if size != 0.0:
            problems.append(f"position is NOT flat (size={size}) — H2 needs a clean start")
        if imr > BUDGET_USDG:
            problems.append(f"initial margin {imr:.3f} > budget {BUDGET_USDG}")
        if acct_imf > int(10000 / args.leverage):
            problems.append(
                f"account IMF is {acct_imf}; run `leverage --leverage {args.leverage}` first "
                f"(need <= {int(10000/args.leverage)})"
            )
        if float(acct["collateral"] or 0) < args.deposit:
            problems.append(
                f"L2 collateral {acct['collateral']} < {args.deposit} — "
                f"run: cast send $HARNESS \"depositUSDG(uint256)\" "
                f"{int(args.deposit*1e6)} --rpc-url $RPC --private-key $DEPLOYER_PK"
            )

        log("")
        if problems:
            log("NO-GO:")
            for x in problems:
                log("  - " + x)
        else:
            log("GO — everything H2 needs is in place.")


# ── leverage ─────────────────────────────────────────────────────────────────

async def cmd_leverage(args):
    """L2 config tx (UpdateLeverage), signed with the AGENT key. Not an order:
    it changes the account's initial-margin fraction on one market so the
    smallest legal order fits inside the 5 USDG margin budget."""
    client = signer(args.account_index, args.api_key_index)
    log(f"[lev] check_client -> {client.check_client()}")
    imf = int(10000 / args.leverage)
    log(f"[lev] market {args.market}: leverage {args.leverage}x -> IMF {imf} "
        f"({imf/100:.2f}%), margin_mode=CROSS(0)")
    tx, resp, err = await client.update_leverage(
        market_index=args.market,
        margin_mode=SignerClient.CROSS_MARGIN_MODE,
        leverage=args.leverage,
        api_key_index=args.api_key_index,
    )
    log(f"[lev] update_leverage -> resp={summarize(resp)} err={err}")
    await client.close()
    async with aiohttp.ClientSession() as session:
        for _ in range(10):
            await asyncio.sleep(2)
            acct = await _account_raw(session, args.account_index)
            _, p = pos_of(acct, args.market)
            if p and abs(float(p["initial_margin_fraction"]) * 100 - imf) < 1:
                log(f"[lev] confirmed: account IMF now {p['initial_margin_fraction']}%")
                return
        log("[lev] not reflected yet — re-read /api/v1/account before opening")


# ── open ─────────────────────────────────────────────────────────────────────

async def cmd_open(args):
    aki = args.api_key_index
    client = signer(args.account_index, aki)
    async with aiohttp.ClientSession() as session:
        log(f"[open] check_client -> {client.check_client()}")
        det = await _detail_raw(session, args.market)
        ticks, base, notional, mark = min_legal_base(det)
        pdec = int(det["price_decimals"])

        pre = await snapshot(session, args.account_index, args.market, "pre-open")
        if pre["size"] != 0.0:
            log("[open] ABORT: position is not flat. H2 requires a clean start.")
            await client.close()
            sys.exit(1)

        # Default LONG (is_ask = 0): closeMarket #1 (SELL) is the closing side
        # and closeMarket #2 (BUY) fires against a flat book. --side short flips
        # it for the mirror half of H2: SELL fires FIRST against the OPEN short
        # (must not add exposure), BUY is the closing side.
        short = getattr(args, "side", "long") == "short"
        slip = args.slippage_bps / 10_000
        px = mark * (1 - slip) if short else mark * (1 + slip)
        avg_px = max(1, int(round(px * 10**pdec)))
        log(f"[open] {'SHORT' if short else 'LONG'} {ticks} ticks = {base} {det['symbol']} "
            f"(~{notional:.4f} USDG notional), bound {avg_px} ticks "
            f"(~{px:.2f}, {args.slippage_bps}bps)")

        nonce = await next_nonce(session, args.account_index, aki)
        tx, resp, err = await client.create_market_order(
            market_index=args.market,
            client_order_index=int(time.time()) % 1_000_000,
            base_amount=ticks,
            avg_execution_price=avg_px,
            is_ask=short,
            reduce_only=False,
            nonce=nonce,
            api_key_index=aki,
        )
        log(f"[open] create_market_order -> resp={summarize(resp)} err={err}")
        if err:
            await client.close()
            sys.exit(1)

        deadline = time.time() + args.fill_timeout
        while time.time() < deadline:
            await asyncio.sleep(2)
            rec = await snapshot(session, args.account_index, args.market, "post-open")
            filled = rec["size"] < 0 if short else rec["size"] > 0
            if filled:
                log(f"[open] FILLED: {'short' if short else 'long'} {rec['size']} @ {rec['avg_entry']}")
                await client.close()
                return rec
        log("[open] NOT FILLED within timeout — do NOT proceed to the cast steps.")
        await client.close()
        sys.exit(1)


# ── snap / verdict ───────────────────────────────────────────────────────────

async def cmd_snap(args):
    async with aiohttp.ClientSession() as session:
        await snapshot(session, args.account_index, args.market, args.label)


async def watch(session, account_index, market, seconds, label, every=3):
    """Sample the position for `seconds`; return (samples, max_abs_size)."""
    samples = []
    peak = 0.0
    deadline = time.time() + seconds
    while time.time() < deadline:
        rec = await snapshot(session, account_index, market, label)
        samples.append(rec)
        peak = max(peak, abs(rec["size"]))
        await asyncio.sleep(every)
    return samples, peak


def print_verdict(samples, peak):
    final = samples[-1]
    log("")
    log("#" * 78)
    if peak == 0.0:
        log("#  H2 = NOOP")
        log("#  A baseAmount=0 market order against a FLAT position does nothing.")
        log("#  LighterPerpStrategy.initiateReturn()'s both-side close is SOUND:")
        log("#  the opposing order fills, the other is a no-op.")
    else:
        log("#  H2 = OPENS_OPPOSITE")
        log(f"#  closeMarket #2 OPENED a position: peak |size| = {peak}, "
            f"final size = {final['size']} (sign={final['sign']}, "
            f"entry={final['avg_entry']}).")
        log("#  initiateReturn() does NOT unwind — it re-opens. The both-side close")
        log("#  MUST be replaced by a single reduce-only close. See LighterH2Canary.md.")
    log(f"#  window: {samples[0]['utc']} -> {final['utc']} "
        f"({len(samples)} samples)")
    log(f"#  sizes observed: {[s['size'] for s in samples]}")
    log("#" * 78)


async def cmd_verdict(args):
    async with aiohttp.ClientSession() as session:
        samples, peak = await watch(
            session, args.account_index, args.market, args.seconds, "post-close2"
        )
        print_verdict(samples, peak)
        return peak, samples


# ── unwind ───────────────────────────────────────────────────────────────────

def print_unwind_plan(size, market, ticks_hint=None):
    log("")
    log("─" * 78)
    log("UNWIND PLAN")
    log("─" * 78)
    if size == 0.0:
        log("  Position is FLAT — no close needed. Go straight to the withdraw ladder.")
    elif size > 0:
        log(f"  Residual LONG {size}. The correct close is a market SELL.")
        log("  DO NOT re-run closeMarket(m, 4294967295, 0) — a BUY against a long")
        log("  either no-ops or ADDS to it. Run:")
        log("")
        log("    " + cast_close(market, MARKET_SELL_PRICE, SIDE_ASK, "SELL-close the residual LONG"))
    else:
        log(f"  Residual SHORT {size}. The correct close is a market BUY.")
        log("  DO NOT re-run closeMarket(m, 1, 1) — a SELL against a short")
        log("  either no-ops or ADDS to it. Run:")
        log("")
        log("    " + cast_close(market, MARKET_BUY_PRICE, SIDE_BID, "BUY-close the residual SHORT"))
    if size != 0.0:
        log("")
        log("  If that contract call does NOT flatten it, fall back to the agent-side")
        log("  reduce-only close (reduce_only=True structurally cannot flip a position):")
        log("")
        log(f"    export {L2_ENV}=0x...")
        log(f"    $PY test/harness/lighter_h2_driver.py unwind \\")
        log(f"      --account-index $IDX --market {market} --execute")
    log("")
    log("  Then drain the margin back to the harness and out to your wallet:")
    log("")
    log("    # 1) read what is actually free (fees/PnL move it off the deposit)")
    log('    curl -s "https://api.rh.lighter.xyz/api/v1/account?by=index&value=$IDX" | \\')
    log("      python3 -c 'import sys,json;a=json.load(sys.stdin)[\"accounts\"][0];"
        "print(a[\"available_balance\"], a[\"collateral\"])'")
    log("    export TICKS=<floor(available_balance * 1e6)>")
    log("")
    log("    # 2) queue it (async, matures after ~515 s)")
    log('    cast send $HARNESS "initiateWithdraw(uint64)" $TICKS \\')
    log("      --rpc-url $RPC --private-key $DEPLOYER_PK")
    log("")
    log("    # 3) poll every ~30 s until nonzero (~9 min)")
    log("    watch -n30 'cast call '\"$HARNESS\"' \"pendingBalance()(uint128)\" --rpc-url '\"$RPC\"")
    log("")
    log("    # 4) claim it back INTO the harness")
    log('    export PENDING=$(cast call $HARNESS "pendingBalance()(uint128)" --rpc-url $RPC)')
    log('    cast send $HARNESS "claim(uint128)" $PENDING \\')
    log("      --rpc-url $RPC --private-key $DEPLOYER_PK")
    log("")
    log("    # 5) sweep the harness back to your wallet")
    log('    export BAL=$(cast call $HARNESS "usdgBalance()(uint256)" --rpc-url $RPC)')
    log('    cast send $HARNESS "rescueERC20(address,address,uint256)" $USDG $WALLET $BAL \\')
    log("      --rpc-url $RPC --private-key $DEPLOYER_PK")
    log("─" * 78)


async def cmd_unwind(args):
    async with aiohttp.ClientSession() as session:
        rec = await snapshot(session, args.account_index, args.market, "unwind-read")
        size = rec["size"]
        det = await _detail_raw(session, args.market)
        sdec = int(det["size_decimals"])
        pdec = int(det["price_decimals"])
        mark = float(det["mark_price"])

        if args.execute and size != 0.0:
            aki = args.api_key_index
            client = signer(args.account_index, aki)
            log(f"[unwind] check_client -> {client.check_client()}")
            is_ask = size > 0  # long -> sell, short -> buy
            base_amount = max(1, int(round(abs(size) * 10**sdec)))
            slip = args.slippage_bps / 10_000
            bound = mark * (1 - slip) if is_ask else mark * (1 + slip)
            avg_px = max(1, int(round(bound * 10**pdec)))
            log(f"[unwind] reduce-only {'SELL' if is_ask else 'BUY'} "
                f"base={base_amount} bound={avg_px}")
            nonce = await next_nonce(session, args.account_index, aki)
            tx, resp, err = await client.create_market_order(
                market_index=args.market,
                client_order_index=int(time.time()) % 1_000_000,
                base_amount=base_amount,
                avg_execution_price=avg_px,
                is_ask=is_ask,
                reduce_only=True,
                nonce=nonce,
                api_key_index=aki,
            )
            log(f"[unwind] create_market_order -> resp={summarize(resp)} err={err}")
            await client.close()
            for _ in range(15):
                await asyncio.sleep(2)
                rec = await snapshot(session, args.account_index, args.market, "post-unwind")
                if rec["size"] == 0.0:
                    log("[unwind] FLAT")
                    break
            size = rec["size"]

        print_unwind_plan(size, args.market)


# ── guided end-to-end ────────────────────────────────────────────────────────

async def cmd_h2(args):
    log("=" * 78)
    log("  H2 CANARY — does a baseAmount=0 market order no-op against a FLAT book?")
    log(f"  account {args.account_index} (owned by {HARNESS}) / market {args.market}")
    log("  This script sends NO L1 tx. You run the two `cast send` lines yourself.")
    log("=" * 78)

    await cmd_preflight(args)
    if sys.stdin.isatty():
        if input("\n[gate] preflight says GO? type 'go' to continue: ").strip() != "go":
            log("aborted")
            return

    opened = await cmd_open(args)

    async with aiohttp.ClientSession() as session:
        print_cast_1(args.market)
        gate("closeMarket #1 (SELL close)")

        log("\n[h2] watching after closeMarket #1 …")
        s1, peak1 = await watch(session, args.account_index, args.market,
                                args.after1_seconds, "post-close1")
        final1 = s1[-1]
        if final1["size"] != 0.0:
            log("")
            log("!" * 78)
            log(f"! closeMarket #1 did NOT flatten (size still {final1['size']}).")
            log("! STOP. H2 is not answerable from here — order #2 would not be firing")
            log("! against a flat book. Unwind and re-try with a wider fill window.")
            log("!" * 78)
            print_unwind_plan(final1["size"], args.market)
            return
        log(f"[h2] FLAT after #1 (opened {opened['size']} @ {opened['avg_entry']}, "
            f"closed by {final1['utc']}). Order #2 will fire against a flat book.")

        print_cast_2(args.market)
        gate("closeMarket #2 (BUY close against a FLAT position)")

        log(f"\n[h2] watching for {args.seconds}s after closeMarket #2 …")
        s2, peak2 = await watch(session, args.account_index, args.market,
                                args.seconds, "post-close2")
        print_verdict(s2, peak2)
        print_unwind_plan(s2[-1]["size"], args.market)


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--account-index", type=int, default=623)
        sp.add_argument("--market", type=int, default=0, help="perp market index (ETH=0)")
        sp.add_argument("--api-key-index", type=int, default=2)
        return sp

    pf = common(sub.add_parser("preflight", help="read-only state + budget math"))
    pf.add_argument("--leverage", type=int, default=10)
    pf.add_argument("--deposit", type=float, default=5.0, help="USDG of margin (budget cap 5)")

    lv = common(sub.add_parser("leverage", help="set per-market leverage (L2 config tx)"))
    lv.add_argument("--leverage", type=int, required=True)

    op = common(sub.add_parser("open", help="open the minimal legal position (long by default)"))
    op.add_argument("--side", choices=["long", "short"], default="long",
                    help="short = the H2 mirror half: SELL then fires against the OPEN short")
    op.add_argument("--slippage-bps", type=int, default=500)
    op.add_argument("--fill-timeout", type=int, default=90)

    sn = common(sub.add_parser("snap", help="one labelled position snapshot"))
    sn.add_argument("--label", default="snap")

    vd = common(sub.add_parser("verdict", help="poll after closeMarket #2 and rule"))
    vd.add_argument("--seconds", type=int, default=120)

    uw = common(sub.add_parser("unwind", help="print the correct close + withdraw ladder"))
    uw.add_argument("--execute", action="store_true",
                    help="also fire a reduce-only API close (cannot flip the position)")
    uw.add_argument("--slippage-bps", type=int, default=500)

    h2 = common(sub.add_parser("h2", help="guided end-to-end run"))
    h2.add_argument("--leverage", type=int, default=10)
    h2.add_argument("--deposit", type=float, default=5.0)
    h2.add_argument("--slippage-bps", type=int, default=500)
    h2.add_argument("--fill-timeout", type=int, default=90)
    h2.add_argument("--after1-seconds", type=int, default=45)
    h2.add_argument("--seconds", type=int, default=120)

    args = p.parse_args()
    asyncio.run({
        "preflight": cmd_preflight,
        "leverage": cmd_leverage,
        "open": cmd_open,
        "snap": cmd_snap,
        "verdict": cmd_verdict,
        "unwind": cmd_unwind,
        "h2": cmd_h2,
    }[args.cmd](args))


if __name__ == "__main__":
    main()
