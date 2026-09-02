#!/usr/bin/env bash
# Shrink BOTH challenge windows (ExposureLedger + ChallengeGame) on a
# Robinhood-fork vnet, so a full propose -> execute -> settle -> challenge
# lifecycle fits a bench run instead of waiting out the 14-day production
# default.
#
# FORK-ONLY TOOLING. The game's owner action goes through `--unlocked`
# impersonation and the ledger write goes through `tenderly_setStorageAt` —
# both exist only on a vnet admin RPC, so running this against a real chain
# fails by construction.
#
# WHY THE LEDGER IS A STORAGE WRITE, NOT A SETTER CALL. The two windows are
# coupled one-way:
#
#   ChallengeGame.setChallengeWindow  requires  new <= ExposureLedger.challengeWindow()
#   ExposureLedger.setChallengeWindow requires  new >= reviewPeriod + 7d (MAX_GOVERNOR_EXECUTION_WINDOW)
#                                          and  new >= game.challengeWindow
#
# The ledger floor is a compile-time constant plus the registry's
# reviewPeriod — it protects the anti-batching property (a coverage bucket
# must outlive the proposal it backs) and structurally cannot reach minutes.
# `setGuardianRegistry` rejects address(0), so the floor cannot be dodged by
# detaching the registry either. On a fork we deliberately break that
# property for speed and write the slot directly. NOTE what that costs on
# the vnet: one guardian bond can back sequential proposals inside a single
# execution window, and `retireApproval`/unstake gates open near-instantly.
# Fine for a bench; never a mainnet shape.
#
# Order matters: the ledger is written FIRST so the game setter's live
# `new <= ledger` check passes against the final value (equal is allowed).
#
# Usage:
#   RPC=<vnet ADMIN rpc> ./script/fork/set-challenge-window.sh [seconds]
#
#   seconds defaults to 1200 (20 minutes); both windows land on it.
set -euo pipefail
: "${RPC:?set RPC to the vnet ADMIN endpoint}"

cd "$(dirname "$0")/../.." # -> repo root

WINDOW="${1:-1200}"
# forge inspect ExposureLedger storageLayout: `challengeWindow` is slot 3.
# The pre-write assertion below fails loudly if the layout ever drifts.
LEDGER_WINDOW_SLOT=3

ADDR_BOOK=chains/9994663.json
GAME=$(python3 -c "import json; print(json.load(open('$ADDR_BOOK'))['CHALLENGE_GAME'])")
LEDGER=$(python3 -c "import json; print(json.load(open('$ADDR_BOOK'))['EXPOSURE_LEDGER'])")

OWNER=$(cast call "$GAME" "owner()(address)" --rpc-url "$RPC")
GAME_BEFORE=$(cast call "$GAME" "challengeWindow()(uint256)" --rpc-url "$RPC")
LEDGER_BEFORE=$(cast call "$LEDGER" "challengeWindow()(uint256)" --rpc-url "$RPC")

echo "ChallengeGame   $GAME    window $GAME_BEFORE -> $WINDOW"
echo "ExposureLedger  $LEDGER  window $LEDGER_BEFORE -> $WINDOW"

if [ "$WINDOW" -eq 0 ]; then
  echo "refusing: zero would free coverage instantly and make filing undeadlined" >&2
  exit 1
fi

# ── Ledger: direct storage write (see header). Assert the slot really holds
# the window first, so a storage-layout drift aborts instead of corrupting
# an unrelated variable.
SLOT_RAW=$(cast storage "$LEDGER" "$LEDGER_WINDOW_SLOT" --rpc-url "$RPC")
if [ "$(cast to-dec "$SLOT_RAW")" != "${LEDGER_BEFORE%% *}" ]; then
  echo "abort: ledger slot $LEDGER_WINDOW_SLOT holds $SLOT_RAW, not challengeWindow ($LEDGER_BEFORE) — layout drifted" >&2
  exit 1
fi
cast rpc tenderly_setStorageAt "$LEDGER" \
  "$(cast to-uint256 "$LEDGER_WINDOW_SLOT")" \
  "$(cast to-uint256 "$WINDOW")" \
  --rpc-url "$RPC" > /dev/null

LEDGER_AFTER=$(cast call "$LEDGER" "challengeWindow()(uint256)" --rpc-url "$RPC")
[ "${LEDGER_AFTER%% *}" = "$WINDOW" ] || { echo "verify failed: ledger window is $LEDGER_AFTER" >&2; exit 1; }
echo "ledger window now $LEDGER_AFTER"

# ── Game: the real setter, impersonating the owner. Its `<= ledger` bound
# now reads the value written above (equal passes).
cast send "$GAME" "setChallengeWindow(uint256)" "$WINDOW" \
  --rpc-url "$RPC" --unlocked --from "$OWNER"

GAME_AFTER=$(cast call "$GAME" "challengeWindow()(uint256)" --rpc-url "$RPC")
[ "${GAME_AFTER%% *}" = "$WINDOW" ] || { echo "verify failed: game window is $GAME_AFTER" >&2; exit 1; }
echo "game window now $GAME_AFTER"
