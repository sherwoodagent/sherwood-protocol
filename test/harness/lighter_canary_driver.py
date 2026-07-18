#!/usr/bin/env python3
"""
lighter_canary_driver.py — agent-side driver for the Lighter contract-owned-account canary.

The whole custody point: this driver never needs the owner ETH key. It only ever
holds an L2 API key (registered on-chain by the contract via changePubKey). It
proves the agent can TRADE the contract-owned account, and nothing else.

Subcommands
  keygen
      Generate an L2 API keypair (lighter.create_api_key), validate the 40-byte
      Goldilocks-canonical pubkey, and print:
        PUBKEY  0x..40 bytes..   -> feed to the contract's registerKey(2, PUBKEY)
        PRIVKEY 0x............    -> the agent's trading secret (--l2-priv below)
      Moves no funds, hits no network. SAFE to run.

  trade --account-index N --l2-priv 0x.. [--side buy|sell] [--market 0]
        [--size TICKS] [--slippage-bps 500] [--api-key-index 2] [--close]
      Build a SignerClient holding ONLY the L2 api key and place a tiny ETH-perp
      MARKET order against the CONTRACT-owned account N, then poll & print the
      resulting position. --close does a reduce-only full close of the current
      position (backup to the contract's own closeMarket kill switch).

Robinhood mainnet defaults: URL=https://api.rh.lighter.xyz, chain_id=466324,
api_key_index=2, ETH perp = market 0.
"""

import argparse
import asyncio
import json
import math
import sys
import time

import aiohttp
import lighter
from lighter import SignerClient, create_api_key

URL = "https://api.rh.lighter.xyz"
CHAIN_ID = 466324
GOLDILOCKS = 0xFFFFFFFF00000001


def log(*a):
    print(*a, flush=True)


# ── keygen ────────────────────────────────────────────────────────────────

def goldilocks_ok(pub_hex: str):
    """5×uint64-LE, each nonzero and < 0xffffffff00000001, total 40 bytes."""
    h = pub_hex[2:] if pub_hex.startswith("0x") else pub_hex
    try:
        b = bytes.fromhex(h)
    except ValueError:
        return False, "not hex"
    if len(b) != 40:
        return False, f"len={len(b)} (want 40)"
    for i in range(5):
        limb = int.from_bytes(b[i * 8:(i + 1) * 8], "little")
        if not (0 < limb < GOLDILOCKS):
            return False, f"limb {i}={hex(limb)} out of Goldilocks range"
    return True, "ok"


def cmd_keygen(_args):
    priv, pub, err = create_api_key()
    if err:
        log(f"create_api_key error: {err}")
        sys.exit(1)
    ok, why = goldilocks_ok(pub)
    if not ok:
        log(f"GENERATED PUBKEY FAILED GOLDILOCKS CHECK: {why}\npub={pub}")
        sys.exit(1)
    log("Goldilocks canonical: OK (40 bytes, 5x u64-LE)")
    log(f"PUBKEY  {pub}")
    log(f"PRIVKEY {priv}")
    log("")
    log("Next: contract owner runs registerKey(2, PUBKEY); agent trades with --l2-priv PRIVKEY")


# ── trade ─────────────────────────────────────────────────────────────────

async def next_nonce(session, account_index, aki):
    async with session.get(
        URL + "/api/v1/nextNonce",
        params={"account_index": account_index, "api_key_index": aki},
    ) as r:
        d = await r.json()
        return d.get("nonce")


def summarize(x):
    return {"code": getattr(x, "code", None), "repr": str(x)[:400]}


async def market_detail(client, market):
    api = lighter.OrderApi(client.api_client)
    res = await api.order_book_details(market_id=market)
    for d in (res.order_book_details or []):
        if int(d.market_id) == market:
            return d
    raise RuntimeError(f"market {market} not found in order_book_details")


async def get_position(client, account_index, market):
    api = lighter.AccountApi(client.api_client)
    res = await api.account(by="index", value=str(account_index))
    acct = res.accounts[0]
    for p in (acct.positions or []):
        if int(p.market_id) == market:
            return p
    return None


async def cmd_trade(args):
    aki = args.api_key_index
    client = SignerClient(
        url=URL,
        account_index=args.account_index,
        api_private_keys={aki: args.l2_priv},
        chain_id=CHAIN_ID,
    )
    async with aiohttp.ClientSession() as session:
        cc = client.check_client()
        log(f"[driver] check_client (api key matches on-chain?) -> {cc}")

        d = await market_detail(client, args.market)
        mark = float(d.last_trade_price)
        pdec = int(d.price_decimals)
        sdec = int(d.size_decimals)
        min_notional = float(d.min_quote_amount)
        log(f"[driver] market {args.market} {d.symbol}: mark={mark} "
            f"price_dec={pdec} size_dec={sdec} min_notional={min_notional} USDG")

        if args.close:
            pos = await get_position(client, args.account_index, args.market)
            size = float(pos.position) if pos else 0.0
            if size == 0.0:
                log("[driver] position already flat — nothing to close")
                await client.close()
                return
            is_long = int(getattr(pos, "sign", 1)) >= 0
            side = "sell" if is_long else "buy"
            base_amount = max(1, int(round(size * 10 ** sdec)))
            reduce_only = True
            log(f"[driver] closing {'LONG' if is_long else 'SHORT'} size={size} "
                f"-> reduce-only {side} base={base_amount}")
        else:
            side = args.side
            reduce_only = False
            if args.size:
                base_amount = args.size
            else:
                size_eth = (min_notional * 1.2) / mark
                base_amount = max(1, int(math.ceil(size_eth * 10 ** sdec)))
            notional = base_amount / 10 ** sdec * mark
            log(f"[driver] {side} base={base_amount} (~{base_amount / 10 ** sdec} base, "
                f"~{notional:.2f} USDG notional)")

        is_ask = side == "sell"
        slip = args.slippage_bps / 10_000
        bound = mark * (1 + slip) if not is_ask else mark * (1 - slip)
        avg_px = max(1, int(round(bound * 10 ** pdec)))
        log(f"[driver] avg_execution_price bound = {avg_px} ticks "
            f"(~{bound:.2f} USDG, slippage {args.slippage_bps}bps)")

        nonce = await next_nonce(session, args.account_index, aki)
        coi = int(time.time()) % 1_000_000
        tx, resp, err = await client.create_market_order(
            market_index=args.market,
            client_order_index=coi,
            base_amount=base_amount,
            avg_execution_price=avg_px,
            is_ask=is_ask,
            reduce_only=reduce_only,
            nonce=nonce,
            api_key_index=aki,
        )
        log(f"[driver] create_market_order -> resp={summarize(resp)} err={err}")

        # poll the resulting position a few times
        for _ in range(8):
            await asyncio.sleep(2)
            pos = await get_position(client, args.account_index, args.market)
            if pos:
                log("[driver] position: " + json.dumps({
                    "market_id": int(pos.market_id),
                    "sign": getattr(pos, "sign", None),
                    "size": pos.position,
                    "avg_entry": pos.avg_entry_price,
                    "value": pos.position_value,
                    "uPnL": pos.unrealized_pnl,
                }, default=str))
                break
        else:
            log("[driver] no position visible yet (sequencer lag) — re-poll account manually")

        await client.close()


# ── main ──────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("keygen", help="generate + validate an L2 API keypair (offline, safe)")

    t = sub.add_parser("trade", help="place a market order on the contract-owned account")
    t.add_argument("--account-index", type=int, required=True, help="contract's Lighter account index")
    t.add_argument("--l2-priv", required=True, help="agent L2 api private key (0x..)")
    t.add_argument("--side", choices=["buy", "sell"], default="buy")
    t.add_argument("--market", type=int, default=0, help="perp market index (ETH=0)")
    t.add_argument("--size", type=int, default=0, help="base amount in ticks (0 = auto, ~1.2x min notional)")
    t.add_argument("--slippage-bps", type=int, default=500, help="protective bound slippage in bps (default 500)")
    t.add_argument("--api-key-index", type=int, default=2, help="registered api key index (default 2)")
    t.add_argument("--close", action="store_true", help="reduce-only full close of current position")

    args = p.parse_args()
    if args.cmd == "keygen":
        cmd_keygen(args)
    elif args.cmd == "trade":
        asyncio.run(cmd_trade(args))


if __name__ == "__main__":
    main()
