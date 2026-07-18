#!/usr/bin/env bash
# check-storage-parity.sh — delegatecall storage-seam guard for the LeveragedAero pair.
#
# LeveragedAerodromeCLStrategy delegatecalls LeveragedAeroManager, so both MUST resolve
# the exact same ERC-7201 `Layout` struct at the exact same STORAGE_SLOT — and that layout
# MUST stay compatible with the ALREADY-DEPLOYED clone lineages (field order is frozen;
# new fields are append-only). Three guard layers, each covering what the previous cannot:
#
#   compiler   — strategy↔manager identity (both import the one LeveragedAeroStorage.Layout;
#                step 1 diffs the probe layouts, which is empty by construction post-seam);
#   golden     — deployed-lineage compatibility (step 1b diffs the compiler-emitted
#                per-field layout against the committed snapshot in
#                script/leveraged-aero-layout.golden.json — field ORDER significant, so a
#                reorder/insert/retype that would corrupt live clones fails here);
#   backstops  — local re-declaration (step 4 rejects hand-copied structs / slot constants /
#                slot assembly creeping back into either file and dodging the probes).
#
# This script fails loudly (exit 1) if:
#   1.  the compiler-emitted member layout (slot/offset/type per field, incl. nested
#       RedeemRequest) of the strategy's effective Layout differs from the manager's
#       (compared via the StrategyLayoutProbe / ManagerLayoutProbe contracts in
#       test/LeveragedAeroLayoutParity.t.sol — `forge inspect storageLayout` cannot see a
#       7201 struct unless it is a probe's state variable);
#   1b. the live layout differs FIELD-BY-FIELD (label, slot, offset, type — order
#       significant) from script/leveraged-aero-layout.golden.json. After a legitimate
#       APPEND-ONLY addition, regenerate with `./script/check-storage-parity.sh
#       --update-golden` and commit the golden alongside the struct change;
#   2.  the effective STORAGE_SLOT constants of the two files diverge (each is resolved
#       from the file itself, falling back to the shared LeveragedAeroStorage.sol);
#   3.  the pinned slot does not match its ERC-7201 derivation
#       keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~0xff;
#   4.  either file re-declares a local Layout/RedeemRequest/STORAGE_SLOT, binds a storage
#       slot in assembly, or declares a 32-byte hex / large decimal constant (slot anchors
#       under any name). Comments are stripped first so prose can't false-positive.
#
# Run from anywhere; CI wires it in .github/workflows/contracts.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

STRAT_FILE=src/strategies/LeveragedAerodromeCLStrategy.sol
MGR_FILE=src/strategies/LeveragedAeroManager.sol
SHARED_FILE=src/strategies/LeveragedAeroStorage.sol
GOLDEN_FILE=script/leveraged-aero-layout.golden.json

fail() {
  echo "storage-parity: FAIL — $1" >&2
  exit 1
}

# ── 1. Compiler-grounded member-layout diff via the probe contracts ──────────────────
forge build >/dev/null

inspect_layout() {
  # Incremental builds can drop storageLayout from cached artifacts ("storage layout
  # missing from artifact" — spurious per forge itself); retry once with --force,
  # which repopulates the cache for the rest of this run.
  local out
  if ! out=$(forge inspect "$1" storageLayout --json 2>/dev/null) || [ -z "$out" ]; then
    out=$(forge inspect "$1" storageLayout --json --force 2>/dev/null) ||
      fail "forge inspect $1 storageLayout failed even with --force"
  fi
  printf '%s' "$out"
}

normalize_layout() {
  # Emit sorted "struct.member slot offset type bytes" lines with ast ids and
  # contract-name qualifiers stripped, so only genuine layout drift diffs.
  inspect_layout "$1" | python3 -c '
import json, re, sys

def norm(s):
    s = re.sub(r"\)\d+", ")", s)                         # strip ast ids in type names
    s = re.sub(r"struct [A-Za-z0-9_]+\.", "struct ", s)  # strip contract qualifier
    return s

d = json.load(sys.stdin)
lines = []
for tname, t in d["types"].items():
    if "members" not in t:
        continue
    sname = norm(t["label"])
    total = t["numberOfBytes"]
    lines.append(f"{sname} __totalBytes {total}")
    for m in t["members"]:
        label, slot, offset = m["label"], m["slot"], m["offset"]
        mtype = norm(m["type"])
        lines.append(f"{sname}.{label} slot={slot} offset={offset} type={mtype}")
for l in sorted(lines):
    print(l)
'
}

canonical_layout() {
  # Canonical, ORDER-SIGNIFICANT JSON of every struct in the probe layout: members appear
  # in declaration order with (label, slot, offset, type). Ast ids and contract qualifiers
  # are stripped so only genuine layout drift diffs against the committed golden.
  inspect_layout "$1" | python3 -c '
import json, re, sys

def norm(s):
    s = re.sub(r"\)\d+", ")", s)                         # strip ast ids in type names
    s = re.sub(r"struct [A-Za-z0-9_]+\.", "struct ", s)  # strip contract qualifier
    return s

d = json.load(sys.stdin)
out = {}
for t in d["types"].values():
    if "members" not in t:
        continue
    out[norm(t["label"])] = {
        "numberOfBytes": t["numberOfBytes"],
        "members": [
            {"label": m["label"], "slot": m["slot"], "offset": m["offset"], "type": norm(m["type"])}
            for m in t["members"]
        ],
    }
print(json.dumps(out, indent=2, sort_keys=True))
'
}

STRAT_LAYOUT=$(normalize_layout StrategyLayoutProbe)
MGR_LAYOUT=$(normalize_layout ManagerLayoutProbe)

if ! diff <(echo "$STRAT_LAYOUT") <(echo "$MGR_LAYOUT") >/dev/null; then
  echo "storage-parity: Layout struct diverged between strategy and manager:" >&2
  diff <(echo "$STRAT_LAYOUT") <(echo "$MGR_LAYOUT") >&2 || true
  fail "member layout mismatch"
fi

# ── 1b. Golden per-field snapshot (deployed-lineage compatibility) ────────────────────
# Step 1 is empty by construction (both probes embed the SAME shared struct); THIS step
# is what pins the layout live clones already store. Field order significant.
LIVE_LAYOUT=$(canonical_layout StrategyLayoutProbe)

if [ "${1:-}" = "--update-golden" ]; then
  printf '%s\n' "$LIVE_LAYOUT" >"$GOLDEN_FILE"
  echo "storage-parity: wrote $GOLDEN_FILE — commit it with the (append-only) struct change"
fi

[ -f "$GOLDEN_FILE" ] || fail "missing $GOLDEN_FILE — run ./script/check-storage-parity.sh --update-golden and commit it"

if ! diff -u "$GOLDEN_FILE" <(printf '%s\n' "$LIVE_LAYOUT") >&2; then
  fail "Layout drifted from the committed golden snapshot ($GOLDEN_FILE).
  Live clones store state with the golden's exact field order — a reorder/insert/retype
  CORRUPTS them. If (and only if) the change is APPEND-ONLY, regenerate the golden with
  ./script/check-storage-parity.sh --update-golden and commit it in the same PR."
fi

# ── 2. Effective STORAGE_SLOT equality ────────────────────────────────────────────────
slot_of() {
  # The file's own constant wins; otherwise it must import the shared definition.
  local hex
  hex=$(grep -oE "STORAGE_SLOT = 0x[0-9a-fA-F]{64}" "$1" | grep -oE "0x[0-9a-fA-F]{64}" | head -1 || true)
  if [ -z "$hex" ] && [ -f "$SHARED_FILE" ]; then
    hex=$(grep -oE "STORAGE_SLOT = 0x[0-9a-fA-F]{64}" "$SHARED_FILE" | grep -oE "0x[0-9a-fA-F]{64}" | head -1 || true)
  fi
  echo "$hex"
}

STRAT_SLOT=$(slot_of "$STRAT_FILE")
MGR_SLOT=$(slot_of "$MGR_FILE")

[ -n "$STRAT_SLOT" ] || fail "could not resolve STORAGE_SLOT for $STRAT_FILE"
[ -n "$MGR_SLOT" ] || fail "could not resolve STORAGE_SLOT for $MGR_FILE"
[ "$STRAT_SLOT" = "$MGR_SLOT" ] || fail "STORAGE_SLOT diverged: strategy=$STRAT_SLOT manager=$MGR_SLOT"

# ── 3. ERC-7201 derivation of the pinned slot ────────────────────────────────────────
INNER=$(cast keccak "leveraged.aero.cl.storage")
INNER_MINUS_1=$(python3 -c "print(format(int('$INNER', 16) - 1, '064x'))")
OUTER=$(cast keccak "0x$INNER_MINUS_1")
DERIVED="${OUTER:0:64}00" # "0x" + first 62 nibbles + masked low byte

[ "$(echo "$STRAT_SLOT" | tr '[:upper:]' '[:lower:]')" = "$(echo "$DERIVED" | tr '[:upper:]' '[:lower:]')" ] ||
  fail "STORAGE_SLOT $STRAT_SLOT != ERC-7201 derivation $DERIVED"

# ── 4. No re-declared local duplicates once the shared seam exists ───────────────────
# With LeveragedAeroStorage as the single owner, a hand-copied duplicate creeping back
# into either file would silently bypass the compiler's identity guarantee (steps 1-2
# would compare a probe against the shared struct, not the local copy). Reject it.
# Comments are stripped first (prose mentioning e.g. "STORAGE_SLOT = 0x..." must not
# false-positive), and the checks run on whitespace-flattened source so a forge-fmt
# line wrap can't split a declaration across the grep.

strip_comments() {
  # String-literal-aware Solidity comment stripper (line + block), newline-preserving.
  python3 - "$1" <<'PY'
import sys

src = open(sys.argv[1]).read()
out = []
i, n, state = 0, len(src), 0  # 0 code, 1 //, 2 /* */, 3 "str", 4 'str'
while i < n:
    c, two = src[i], src[i : i + 2]
    if state == 0:
        if two == "//":
            state, i = 1, i + 2
        elif two == "/*":
            state, i = 2, i + 2
        else:
            if c == '"':
                state = 3
            elif c == "'":
                state = 4
            out.append(c)
            i += 1
    elif state == 1:
        if c == "\n":
            state = 0
            out.append(c)
        i += 1
    elif state == 2:
        if two == "*/":
            state, i = 0, i + 2
            out.append(" ")
        else:
            if c == "\n":
                out.append(c)
            i += 1
    else:
        if c == "\\" and i + 1 < n:
            out.append(two)
            i += 2
            continue
        if (state == 3 and c == '"') or (state == 4 and c == "'"):
            state = 0
        out.append(c)
        i += 1
sys.stdout.write("".join(out))
PY
}

if [ -f "$SHARED_FILE" ]; then
  for f in "$STRAT_FILE" "$MGR_FILE"; do
    FLAT=$(strip_comments "$f" | tr '\n\t' '  ' | tr -s ' ')

    grep -qE "struct[[:space:]]+(Layout|RedeemRequest)[[:space:]]*\{" <<<"$FLAT" &&
      fail "$f re-declares a local Layout/RedeemRequest — LeveragedAeroStorage is the single owner"
    grep -qE "STORAGE_SLOT[[:space:]]*=[[:space:]]*0x" <<<"$FLAT" &&
      fail "$f re-declares a local STORAGE_SLOT — use LeveragedAeroStorage.STORAGE_SLOT"
    # Name-agnostic backstops: a renamed hand-copied struct would dodge the greps above,
    # but it still needs its own slot anchor — inline assembly binding a slot, a 32-byte
    # hex constant, or a large decimal-literal constant (a keccak slot in base 10).
    # None of these may exist outside LeveragedAeroStorage.
    grep -qE "\.slot[[:space:]]*:=" <<<"$FLAT" &&
      fail "$f contains inline storage-slot assembly — slot binding lives only in LeveragedAeroStorage.layout()"
    grep -qE "constant[^=;]*=[[:space:]]*0x[0-9a-fA-F]{64}" <<<"$FLAT" &&
      fail "$f declares a bytes32 hex constant — storage-slot constants live only in LeveragedAeroStorage"
    grep -qE "constant[^=;]*=[[:space:]]*[0-9][0-9_]{9,}" <<<"$FLAT" &&
      fail "$f declares a large decimal-literal constant (possible slot anchor in base 10) — storage-slot constants live only in LeveragedAeroStorage"
  done
fi

echo "storage-parity: OK — Layout members identical + match golden snapshot, STORAGE_SLOT=$STRAT_SLOT matches ERC-7201 derivation"
