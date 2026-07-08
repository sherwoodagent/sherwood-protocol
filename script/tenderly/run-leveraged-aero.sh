#!/usr/bin/env bash
# ==============================================================================
# run-leveraged-aero.sh — Tenderly vnet integration runner for the
#                   Leveraged Aerodrome CL strategy (PR #388)
# ==============================================================================
# The leveraged-strategy fork suite is already vnet-aware: LeveragedAeroForkBase
# reads TENDERLY_FORK_RPC_URL, forks it (unique chainId 9998453), funds via
# `vm.rpc("tenderly_setErc20Balance", …)`, and drives the FULL protocol lifecycle in
# `LeveragedAeroCL.e2e.fork.t.sol` (deploy governor+factory → create vault → clone+init
# strategy → propose/vote/execute → deposit/deployIdle/compound/rerange/deleverage/redeem
# → settle). So the "vnet harness" here is: stand up a clean Base-fork vnet and run
# that suite against it — the same empirical "does the deployed protocol behave on infra that
# mirrors mainnet" signal the mamo LPV2 broadcast harness gives, reusing the PR's own tests.
#
# This mirrors mamo-contracts/script/tenderly: a fresh vnet by default (deterministic — fresh
# feeds, no clock drift), torn down at the end; `--reuse` uses TENDERLY_FORK_RPC_URL from .env.
#
# Usage (from anywhere):
#   ./contracts/script/tenderly/run-leveraged-aero.sh                # fresh vnet if creds present, else reuse
#   ./contracts/script/tenderly/run-leveraged-aero.sh --reuse        # force reuse TENDERLY_FORK_RPC_URL
#   ./contracts/script/tenderly/run-leveraged-aero.sh --keep         # keep a freshly-created vnet
#   ./contracts/script/tenderly/run-leveraged-aero.sh --match '<glob>'  # narrow the test path
#
# Fresh-vnet mode needs TENDERLY_ACCESS_KEY in contracts/.env (account/project slugs are
# derived from TENDERLY_FORK_RPC_URL). Reuse-mode needs only TENDERLY_FORK_RPC_URL.
# Requires: forge, cast, jq, curl.
# ==============================================================================
set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # the contracts/ foundry root
cd "$ROOT"
RESULTS="${LEVERAGED_AERO_RESULTS:-$SCRIPT_DIR/leveraged-aero-harness.log}"
: > "$RESULTS"
TENDERLY_API="https://api.tenderly.co/api/v1"
MATCH_DEFAULT='test/integration/strategies/LeveragedAero*.fork.t.sol'

c_blue='\033[0;34m'; c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_off='\033[0m'
section() { printf "\n${c_blue}━━━ %s ━━━${c_off}\n" "$1" | tee -a "$RESULTS"; }
info()    { printf "  %s\n" "$1" | tee -a "$RESULTS"; }
ok()      { printf "  ${c_grn}✓ %s${c_off}\n" "$1" | tee -a "$RESULTS"; }
warn()    { printf "  ${c_yel}! %s${c_off}\n" "$1" | tee -a "$RESULTS"; }
die()     { printf "  ${c_red}✗ %s${c_off}\n" "$1" | tee -a "$RESULTS"; teardown; exit 1; }

# ── args ────────────────────────────────────────────────────────────────────
REUSE=0; KEEP=0; MATCH="$MATCH_DEFAULT"
while [ $# -gt 0 ]; do
  case "$1" in
    --reuse) REUSE=1; shift ;;
    --keep)  KEEP=1; shift ;;
    --match) MATCH="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

# ── env ─────────────────────────────────────────────────────────────────────
[ -f .env ] && { set -a; . ./.env; set +a; }

# derive account/project slugs from the fork RPC URL (…/rpc.tenderly.co/<acct>/<proj>/<uuid>)
if [ -z "${TENDERLY_ACCOUNT_SLUG:-}" ] || [ -z "${TENDERLY_PROJECT_SLUG:-}" ]; then
  if [ -n "${TENDERLY_FORK_RPC_URL:-}" ]; then
    _p="${TENDERLY_FORK_RPC_URL#*rpc.tenderly.co/}"
    if [ "$(printf '%s' "$_p" | awk -F/ '{print NF}')" -ge 3 ]; then
      TENDERLY_ACCOUNT_SLUG="${TENDERLY_ACCOUNT_SLUG:-$(printf '%s' "$_p" | cut -d/ -f1)}"
      TENDERLY_PROJECT_SLUG="${TENDERLY_PROJECT_SLUG:-$(printf '%s' "$_p" | cut -d/ -f2)}"
    fi
  fi
fi

CREATED=0; VNET_ID=""
teardown() {
  if [ "$CREATED" = "1" ] && [ "$KEEP" = "0" ] && [ -n "$VNET_ID" ]; then
    section "Teardown: deleting created vnet $VNET_ID"
    curl -s -X DELETE "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets/$VNET_ID" \
      -H "X-Access-Key: $TENDERLY_ACCESS_KEY" >/dev/null && ok "vnet deleted" || warn "vnet delete failed (delete manually)"
  elif [ "$CREATED" = "1" ]; then
    warn "created vnet $VNET_ID kept (--keep)"
  fi
}
trap teardown EXIT

# ── resolve the vnet RPC ────────────────────────────────────────────────────
section "1. Resolve Tenderly vnet"
have_creds=0
[ -n "${TENDERLY_ACCESS_KEY:-}" ] && [ -n "${TENDERLY_ACCOUNT_SLUG:-}" ] && [ -n "${TENDERLY_PROJECT_SLUG:-}" ] && have_creds=1

if [ "$have_creds" = "1" ] && [ "$REUSE" = "0" ]; then
  info "mode (a): creating a fresh Base-fork vnet (acct=$TENDERLY_ACCOUNT_SLUG proj=$TENDERLY_PROJECT_SLUG)"
  resp="$(curl -s -X POST "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets" \
    -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "{\"slug\":\"leveraged-aero-$(date +%s)\",\"display_name\":\"Leveraged Aerodrome CL PR#388 harness\",\"fork_config\":{\"network_id\":8453},\"virtual_network_config\":{\"chain_config\":{\"chain_id\":9998453}},\"sync_state_config\":{\"enabled\":false},\"explorer_page_config\":{\"enabled\":false,\"verification_visibility\":\"bytecode\"}}")"
  VNET_ID="$(echo "$resp" | jq -r '.id // empty')"
  RPC="$(echo "$resp" | jq -r '.rpcs[]? | select(.name=="Admin RPC") | .url')"
  [ -n "$RPC" ] || die "vnet create failed: $resp"
  CREATED=1
  ok "created vnet $VNET_ID"
else
  info "mode (b): reusing TENDERLY_FORK_RPC_URL ($([ "$have_creds" = "1" ] && echo '--reuse' || echo 'no TENDERLY_ACCESS_KEY in .env → add it to enable fresh vnets'))"
  RPC="${TENDERLY_FORK_RPC_URL:-}"
  [ -n "$RPC" ] || die "no TENDERLY_FORK_RPC_URL and no creds to create a vnet"
fi

CHAIN="$(cast chain-id --rpc-url "$RPC" 2>/dev/null)"
[ -n "$CHAIN" ] || die "vnet RPC unreachable"
ok "vnet reachable — chainId $CHAIN, block $(cast block-number --rpc-url "$RPC" 2>/dev/null)"

# The fork suite reads TENDERLY_FORK_RPC_URL; point it at the resolved vnet.
export TENDERLY_FORK_RPC_URL="$RPC"

# ── run the leveraged-strategy fork suite ────────────────────────────────────
section "2. Run leveraged Aerodrome CL fork suite (PR #388) against the vnet"
info "match: $MATCH"
FULL="$SCRIPT_DIR/.leveraged-aero-forge.log"
forge test --match-path "$MATCH" -vv > "$FULL" 2>&1
rc=$?
# surface per-suite results + any failures
grep -E "Ran .* test suite|Suite result|\[PASS\]|\[FAIL\]" "$FULL" | tee -a "$RESULTS" >/dev/null
grep -E "Suite result|Ran .* test suites" "$FULL" | tee -a "$RESULTS"

if [ "$rc" != "0" ]; then
  warn "forge test exited $rc — failures:"
  grep -E "\[FAIL\]|revert|Error" "$FULL" | grep -viE "nightly|preprocess" | head -30 | tee -a "$RESULTS"
fi

# ── summary ─────────────────────────────────────────────────────────────────
section "Summary"
TOTALS="$(grep -oE '[0-9]+ tests passed, [0-9]+ failed' "$FULL" | tail -1)"
info "${TOTALS:-no totals parsed}"
# a few headline gas numbers for the PR review table (best-effort)
grep -E "test_e2e_fullLifecycle|test_execute_opensLeveredPositionWithinBounds|test_nav_invariantUnderTickShove|test_deleverage_restoresHealthWhenUnhealthy" "$FULL" \
  | sed -E 's/^\s*\[(PASS|FAIL)\]/  \1/' | tee -a "$RESULTS" >/dev/null || true
echo
if [ "$rc" = "0" ]; then
  ok "Leveraged-aero fork suite GREEN on the vnet. Full log: $FULL"
  [ "$CREATED" = "1" ] && [ "$KEEP" = "1" ] && info "vnet kept: $RPC"
else
  die "fork suite FAILED (rc=$rc) — see $FULL"
fi
echo
