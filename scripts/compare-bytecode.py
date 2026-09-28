#!/usr/bin/env python3
"""Compare forge artifacts in two out/ dirs, ignoring the CBOR metadata tail."""
import json, sys, pathlib

def strip_cbor(hexcode):
    if not hexcode or hexcode == "0x":
        return hexcode
    h = hexcode[2:] if hexcode.startswith("0x") else hexcode
    if len(h) < 4:
        return h
    cbor_len = int(h[-4:], 16)
    cut = (cbor_len + 2) * 2
    return h[:-cut] if cut <= len(h) else h

def load(outdir):
    res = {}
    for p in pathlib.Path(outdir).rglob("*.json"):
        if "build-info" in p.parts:
            continue
        try:
            j = json.load(open(p))
        except Exception:
            continue
        if "bytecode" not in j:
            continue
        key = str(p.relative_to(outdir))
        res[key] = (strip_cbor(j["bytecode"].get("object", "")),
                    strip_cbor(j.get("deployedBytecode", {}).get("object", "")))
    return res

a, b = load(sys.argv[1]), load(sys.argv[2])
only_a = sorted(set(a) - set(b)); only_b = sorted(set(b) - set(a))
diff = sorted(k for k in a if k in b and a[k] != b[k])
same = sum(1 for k in a if k in b and a[k] == b[k])
print(f"identical={same} differ={len(diff)} only_before={len(only_a)} only_after={len(only_b)}")
for k in diff: print("DIFF", k)
for k in only_a: print("ONLY_BEFORE", k)
for k in only_b: print("ONLY_AFTER", k)
sys.exit(1 if diff else 0)
