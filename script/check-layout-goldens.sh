#!/usr/bin/env bash
# check-layout-goldens.sh — storage-layout golden guard for the beacon/proxy-upgraded
# governance contracts (SyndicateGovernor, SyndicateFactory, GuardianRegistry).
#
# All three live behind upgradeable proxies (governor: beacon; factory + registry: UUPS), so
# their storage layouts are FROZEN for deployed lineages: fields are append-only, gaps
# shrink only from the front, and any reorder/insert/retype corrupts live state on the
# next upgrade. This script pins the compiler-emitted layout (label, slot, offset, type
# per variable — order significant) against committed golden JSON snapshots, mirroring
# script/check-storage-parity.sh (the LeveragedAero seam guard).
#
# Fails loudly (exit 1) if either contract's live layout differs from its golden. After
# a legitimate APPEND-ONLY change (e.g. a new param carved from a __gap), regenerate
# with `./script/check-layout-goldens.sh --update-golden` and commit the goldens in the
# same PR as the storage change.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  echo "layout-goldens: FAIL — $1" >&2
  exit 1
}

forge build >/dev/null

inspect_layout() {
  # Incremental builds can drop storageLayout from cached artifacts; retry with --force.
  local out
  if ! out=$(forge inspect "$1" storageLayout --json 2>/dev/null) || [ -z "$out" ]; then
    out=$(forge inspect "$1" storageLayout --json --force 2>/dev/null) ||
      fail "forge inspect $1 storageLayout failed even with --force"
  fi
  printf '%s' "$out"
}

canonical_layout() {
  # Canonical, ORDER-SIGNIFICANT JSON of the contract's storage:
  #
  #   "storage" — every top-level variable in slot order with (label, slot, offset,
  #               type).
  #   "types"   — the INTERNAL layout of every struct reachable from those variables
  #               (transitively, through mapping values and array bases), each with its
  #               members in slot order.
  #
  # The `types` half is not optional. Top-level slots alone cannot see inside a struct:
  # appending a member to a struct held in a mapping is a safe, invisible-to-`storage`
  # change, but REORDERING two members of that same struct silently retypes every live
  # record on the next upgrade and would pass a storage-only gate. (Concretely: the
  # proposal-lifecycle branch grew `Review` from 3 slots to 4; safe as an append, and
  # the gate could not have told the difference had it been a reorder.)
  #
  # Ast ids and the declaring contract qualifier are stripped so only genuine layout
  # drift diffs.
  inspect_layout "$1" | python3 -c '
import json, re, sys

def norm(s):
    return re.sub(r"\)\d+", ")", s)  # strip ast ids in type names

d = json.load(sys.stdin)
types = d.get("types") or {}

# Transitive closure over the type graph, starting from the top-level variables.
# Structs contribute their members; mappings their key/value; arrays their base.
seen, stack = set(), [v["type"] for v in d["storage"]]
while stack:
    t = stack.pop()
    if t in seen or t not in types:
        continue
    seen.add(t)
    info = types[t]
    for m in info.get("members") or []:
        stack.append(m["type"])
    for edge in ("key", "value", "base"):
        if info.get(edge):
            stack.append(info[edge])

structs = {}
for t in seen:
    members = types[t].get("members")
    if not members:  # only structs carry an internal slot assignment
        continue
    structs[norm(t)] = [
        {"label": m["label"], "slot": m["slot"], "offset": m["offset"], "type": norm(m["type"])}
        for m in members
    ]

out = {
    "storage": [
        {"label": v["label"], "slot": v["slot"], "offset": v["offset"], "type": norm(v["type"])}
        for v in d["storage"]
    ],
    "types": dict(sorted(structs.items())),
}
print(json.dumps(out, indent=2))
'
}

check_contract() {
  local contract="$1" golden="$2"
  local live
  live=$(canonical_layout "$contract")

  if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
    printf '%s\n' "$live" >"$golden"
    echo "layout-goldens: wrote $golden — commit it with the (append-only) storage change"
    return
  fi

  [ -f "$golden" ] || fail "missing $golden — run ./script/check-layout-goldens.sh --update-golden and commit it"

  if ! diff -u "$golden" <(printf '%s\n' "$live") >&2; then
    fail "$contract layout drifted from $golden.
  Deployed proxies store state with the golden's exact slot assignment — a
  reorder/insert/retype CORRUPTS them on upgrade. If (and only if) the change is
  APPEND-ONLY (new fields carved from the front of a __gap), regenerate with
  ./script/check-layout-goldens.sh --update-golden and commit the golden in the same PR."
  fi
}

[ "${1:-}" = "--update-golden" ] && UPDATE_GOLDEN=1

check_contract SyndicateGovernor script/syndicate-governor-layout.golden.json
check_contract SyndicateFactory script/syndicate-factory-layout.golden.json
# GuardianRegistry is UUPS and live: Plan B carved `exposureLedger` out of the
# front of its __gap (50 -> 49), which is exactly the class of change this guard
# exists to police. Pinned here so the next append is checked automatically
# rather than by hand.
check_contract GuardianRegistry script/guardian-registry-layout.golden.json
# StakedWood is UUPS and live, and custodies every WOOD bond in the protocol —
# the highest-consequence layout on this branch. Plan C carved
# `authorizedSlasher` (9 -> 8) and then `compensationEscrow` (8 -> 7) out of the
# front of its __gap; pinned here so the next append is checked automatically
# rather than by hand.
check_contract StakedWood script/staked-wood-layout.golden.json

[ "${UPDATE_GOLDEN:-0}" = "1" ] ||
  echo "layout-goldens: OK — SyndicateGovernor + SyndicateFactory + GuardianRegistry + StakedWood layouts match their goldens"
