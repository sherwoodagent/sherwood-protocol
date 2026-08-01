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

# True when the layout carries no top-level storage variables. Every contract
# this gate guards is upgradeable and has state, so an empty read is always a
# tooling failure, never a legitimate answer.
_layout_is_empty() {
  [ -z "$1" ] && return 0
  printf '%s' "$1" | python3 -c 'import json,sys; sys.exit(0 if not json.load(sys.stdin).get("storage") else 1)' 2>/dev/null
}

inspect_layout() {
  # A degenerate read does NOT return the empty string — it returns valid JSON
  # with an EMPTY layout at rc 0 (`{"storage": [], "types": {}}`), so testing
  # only for `-z` let it through. Two ways to get there, and the second is the
  # one that matters:
  #
  #   - TRANSIENT: an artifact cached without its storageLayout. `--force`
  #     clears it, and on forge 1.7.1 a genuinely missing layout exits non-zero
  #     ("storage layout missing from artifact"), which the `!` half already
  #     caught — so this one is largely self-healing.
  #   - PERSISTENT: a name that resolves to a storage-less artifact. An
  #     interface, a library, a renamed contract, a typo:
  #         $ forge inspect IGuardianRegistry storageLayout --json
  #         { "storage": [], "types": {} }        # rc 0
  #     This does not clear on the next run. Left unguarded, a gate pointed at
  #     such a name pins NOTHING, indefinitely and silently — and
  #     `--update-golden` would bake the empty layout in, so the gate keeps
  #     agreeing with itself while the real contract's storage drifts freely.
  #
  # Hence: retry once with --force for the transient case, then hard-fail
  # rather than compare or bake a layout that pins nothing.
  local out
  if ! out=$(forge inspect "$1" storageLayout --json 2>/dev/null) || _layout_is_empty "$out"; then
    out=$(forge inspect "$1" storageLayout --json --force 2>/dev/null) ||
      fail "forge inspect $1 storageLayout failed even with --force"
  fi
  if _layout_is_empty "$out"; then
    fail "forge inspect $1 storageLayout returned an EMPTY layout even with --force — refusing to compare or bake a layout that pins nothing"
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
    """Strip solc ast ids from type names while PRESERVING array lengths.

        t_struct(Review)1234_storage   -> t_struct(Review)_storage    (ast id: noise)
        t_array(t_uint256)49_storage   -> unchanged                   (length: load-bearing)

    Both shapes are `)<digits>`, so the old `re.sub(r"\\)\\d+", ")")` canonicalised
    `uint256[49] __gap` and `uint256[42] __gap` to the SAME string and the gate went
    blind to a pure gap resize. A forgotten decrement on append still moves the gap`s
    own slot (caught by the `storage` half), but a resize with no other change is
    exactly the reserved-space accounting drift this gate exists to catch.

    Digits after `)` are an ast id UNLESS the group was opened by `t_array(`, so we
    track what opened each paren rather than pattern-matching (types nest:
    `t_array(t_struct(Review)1234_storage)49_storage` needs both rules at once).
    """
    out, stack, i = [], [], 0
    while i < len(s):
        c = s[i]
        if c == "(":
            j = len(out) - 1
            while j >= 0 and (out[j].isalnum() or out[j] == "_"):
                j -= 1
            stack.append("".join(out[j + 1:]))
            out.append(c)
            i += 1
        elif c == ")":
            kind = stack.pop() if stack else ""
            out.append(c)
            i += 1
            j = i
            while j < len(s) and s[j].isdigit():
                j += 1
            if j > i and kind != "t_array":
                i = j  # ast id -> drop. array length -> fall through and keep.
        else:
            out.append(c)
            i += 1
    return "".join(out)

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

# SyndicateGovernor sits behind a BEACON, so one `beacon.upgradeTo` re-points
# EVERY per-vault governor at once — the widest blast radius of the four.
#
# ITS GOLDEN WAS FULLY RE-BASELINED (proposal-lifecycle refactor, PR #56), the
# one exception to the append-only rule stated in the header above.
# `GovernorParameters` now inherits `ProposalLifecycle`, which C3 linearization
# PREPENDS, so its 15 slots come first and every governor field moved:
# `vault` 0 -> 15, `_guardianRegistry` 43 -> 0, `_tierRegistry` 48 -> 58.
#
# LEGITIMATE ONLY BECAUSE THIS IS A FRESH DEPLOYMENT — the same condition as
# GuardianRegistry and StakedWood below. chains/4663.json records no protocol
# addresses, so mainnet has no governor lineage to stay compatible with.
# test/governor/GovernorLayoutPins.t.sol pins the new baseline and states the
# rule this re-baseline must never be read as licensing: DO NOT cherry-pick the
# fold onto a beacon that already has live proxies — every governor would read
# garbage at every slot. Robinhood TESTNET (46630) is exactly such a chain: 9
# syndicates behind beacon 0x11B726c49E0bAc95bEafF8d648cf3030Dc11B73a. Those
# need a fresh factory + beacon, not an upgrade; DeployPlanB's pre-flight 5
# refuses that state rather than printing an instruction that would corrupt it.
#
# From this baseline forward the append-only rule applies again.
check_contract SyndicateGovernor script/syndicate-governor-layout.golden.json
check_contract SyndicateFactory script/syndicate-factory-layout.golden.json
# GuardianRegistry and StakedWood are UUPS, deployed on TESTNETS ONLY
# (46630 / 9994663 — both redeployable; chains/4663.json has neither, so there
# is no mainnet lineage). Their goldens were FULLY RE-BASELINED by the
# DPoS-delegation removal (2026-07-26): StakedWood lost its 22-slot delegation
# base contract, and GuardianRegistry lost `totalDelegatedAtOpen` mid-struct in
# `Review`/`EmergencyReview`. From the first MAINNET deploy onward these
# layouts are frozen and every change must be append-only against these
# goldens — which is exactly the class of change this guard exists to police.
check_contract GuardianRegistry script/guardian-registry-layout.golden.json
# StakedWood is UUPS and live, and custodies every WOOD bond in the protocol —
# the highest-consequence layout on this branch (review N7). Plan B carved
# `exposureLedger` out of its __gap, then Plan C carved `authorizedSlasher`
# and `_verdictSlashed` (`compensationEscrow` was carved too, and returned to
# the gap when slash proceeds moved to a burn); pinned here so the next append
# is checked automatically rather than by hand.
check_contract StakedWood script/staked-wood-layout.golden.json

[ "${UPDATE_GOLDEN:-0}" = "1" ] ||
  echo "layout-goldens: OK — SyndicateGovernor + SyndicateFactory + GuardianRegistry + StakedWood layouts match their goldens"
