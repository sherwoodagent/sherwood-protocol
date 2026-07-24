#!/usr/bin/env bash
# check-layout-goldens.sh — storage-layout golden guard for the beacon/proxy-upgraded
# governance contracts (SyndicateGovernor, SyndicateFactory).
#
# Both contracts live behind upgradeable proxies (governor: beacon; factory: UUPS), so
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
  # Canonical, ORDER-SIGNIFICANT JSON of the contract's top-level storage: every
  # variable in slot order with (label, slot, offset, type). Ast ids and the declaring
  # contract qualifier are stripped so only genuine layout drift diffs.
  inspect_layout "$1" | python3 -c '
import json, re, sys

def norm(s):
    return re.sub(r"\)\d+", ")", s)  # strip ast ids in type names

d = json.load(sys.stdin)
out = [
    {"label": v["label"], "slot": v["slot"], "offset": v["offset"], "type": norm(v["type"])}
    for v in d["storage"]
]
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

[ "${UPDATE_GOLDEN:-0}" = "1" ] ||
  echo "layout-goldens: OK — SyndicateGovernor + SyndicateFactory layouts match their goldens"
