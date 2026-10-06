#!/usr/bin/env python3
"""Verify every contract a DeployAll broadcast minted, on Blockscout's v2 API.

Names and constructor args are DERIVED from the broadcast: each minted contract's
initcode is matched against the compiled artifacts in out/, and whatever follows the
creation bytecode is the constructor args. Nothing is hand-listed.

Usage: script/verify-blockscout.py <chainId> [--dry-run]
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HOST = os.environ.get("BLOCKSCOUT_URL", "https://robinhoodchain.blockscout.com")
SOLC = "v0.8.28+commit.7893614a"
CREATE2_DEPLOYER = "0x4e59b44847b379578588920ca78fbf26c0b4956c"
# Cloudflare 403s a browser UA sent without its client hints.
HEADERS = [
    "Accept: application/json",
    "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
    'sec-ch-ua: "Chromium";v="126", "Google Chrome";v="126", "Not-A.Brand";v="8"',
    "sec-ch-ua-mobile: ?0",
    'sec-ch-ua-platform: "macOS"',
]


def curl(args):
    cmd = ["curl", "-sS", "-m", "120"]
    for h in HEADERS:
        cmd += ["-H", h]
    return subprocess.run(cmd + args, capture_output=True, text=True).stdout


def minted(chain_id):
    """address -> initcode, plus the libraries forge linked, across every run."""
    found, libs = {}, set()
    runs = sorted(glob.glob(f"broadcast/DeployAll.s.sol/{chain_id}/run-[0-9]*.json"))
    if not runs:
        sys.exit(f"no broadcast under broadcast/DeployAll.s.sol/{chain_id}/")
    for path in runs:
        run = json.load(open(path))
        libs.update(run.get("libraries") or [])
        for tx in run["transactions"]:
            inner = tx.get("transaction", {})
            data = (inner.get("input") or inner.get("data") or "0x")[2:]
            if tx["transactionType"] == "CREATE" and tx.get("contractAddress"):
                found[tx["contractAddress"].lower()] = data
            elif tx["transactionType"] == "CREATE2" and tx.get("contractAddress"):
                # The deterministic deployer takes salt ++ initcode.
                strip = (inner.get("to") or "").lower() == CREATE2_DEPLOYER
                found[tx["contractAddress"].lower()] = data[64:] if strip else data
            for extra in tx.get("additionalContracts") or []:
                found[extra["address"].lower()] = extra["initCode"].removeprefix("0x")
    return found, sorted(libs)


def artifacts():
    """(regex over creation bytecode, source path, name), longest bytecode first."""
    out = []
    for path in glob.glob("out/**/*.json", recursive=True):
        if "/build-info/" in path:
            continue
        try:
            art = json.load(open(path))
        except ValueError:
            continue
        code = (art.get("bytecode") or {}).get("object", "").removeprefix("0x")
        target = (art.get("metadata") or {}).get("settings", {}).get("compilationTarget")
        if not code or not target:
            continue
        source, name = next(iter(target.items()))
        # An unlinked library reference is a 40-char placeholder; any address fills it.
        pattern = re.sub(r"__\$[0-9a-f]{34}\$__", "[0-9a-f]{40}", re.escape(code).replace(r"\$", "$"))
        rank = 0 if source.startswith("src/") else 1 if source.startswith("lib/") else 2
        out.append((len(code), rank, re.compile(pattern), source, name))
    out.sort(key=lambda a: (-a[0], a[1], a[3]))
    return out


def identify(initcode, arts):
    for _, _, pattern, source, name in arts:
        m = pattern.match(initcode)
        if m:
            return source, name, initcode[m.end() :]
    return None


def is_verified(addr):
    try:
        return bool(json.loads(curl([f"{HOST}/api/v2/smart-contracts/{addr}"])).get("is_verified"))
    except ValueError:
        return False


def standard_json(addr, source, name, libs):
    cmd = ["forge", "verify-contract", addr, f"{source}:{name}", "--compiler-version", "0.8.28",
           "--show-standard-json-input"]
    for attempt in range(3):
        run = subprocess.run(cmd, capture_output=True, text=True)
        if run.returncode == 0 and "{" in run.stdout:
            break
        time.sleep(5)
    else:
        raise RuntimeError(f"forge could not build the standard JSON: {run.stderr.strip()[-300:]}")
    raw = run.stdout
    doc = json.loads(raw[raw.index("{") :])
    linked = doc["settings"].setdefault("libraries", {})
    for lib in libs:
        path, lib_name, lib_addr = lib.split(":")
        linked.setdefault(path, {})[lib_name] = lib_addr
    return doc


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    chain_id, dry = sys.argv[1], "--dry-run" in sys.argv
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

    found, libs = minted(chain_id)
    arts = artifacts()
    todo, unknown = [], 0
    for addr, initcode in found.items():
        hit = identify(initcode, arts)
        if hit is None:
            # The CREATE3 trampoline (one per salt) has no source of its own.
            unknown += len(initcode) > 200
            if len(initcode) > 200:
                print(f"  UNMATCHED {addr} ({len(initcode) // 2} bytes of initcode)")
            continue
        todo.append((addr, *hit))
    print(f"{len(todo)} contracts identified, {unknown} unmatched, libraries: {libs or 'none'}")

    failed = unknown
    for addr, source, name, ctor in todo:
        if dry:
            print(f"  {addr} {source}:{name} ctor={len(ctor) // 2}B")
            continue
        if is_verified(addr):
            print(f"  ok       {name} {addr} (already verified)")
            continue
        try:
            doc = standard_json(addr, source, name, libs)
        except RuntimeError as err:
            # One contract failing must not stop the rest; it is reported as not verified below.
            print(f"  SKIPPED  {name} {addr}: {err}")
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(doc, f)
        reply = curl([
            "-X", "POST", f"{HOST}/api/v2/smart-contracts/{addr}/verification/via/standard-input",
            "-F", f"compiler_version={SOLC}", "-F", f"contract_name={name}", "-F", "license_type=mit",
            "-F", "autodetect_constructor_args=false", "-F", f"constructor_args={ctor}",
            "-F", f"files[0]=@{f.name};type=application/json",
        ])
        os.unlink(f.name)
        print(f"  submit   {name} {addr}: {reply.strip()[:120]}")
        time.sleep(2)

    if dry:
        sys.exit(1 if unknown else 0)

    # Verification is asynchronous; give the queue a moment before reading it back.
    pending = [(a, n) for a, _, n, _ in todo]
    for _ in range(12):
        pending = [(a, n) for a, n in pending if not is_verified(a)]
        if not pending:
            break
        time.sleep(10)
    for addr, name in pending:
        print(f"  NOT VERIFIED {name} {addr}")
    failed += len(pending)
    print(f"{len(todo) - len(pending)}/{len(todo)} verified on {HOST}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
