#!/usr/bin/env bash
# The Robinhood mainnet ceremony, one command per stage. Run it, read where it stopped,
# run it again: every step is idempotent and the stage is read back from the chain.
#
#   run 1  mints the core and WoodPoolFeed, stops at AwaitingWoodFeed
#   wait   24h later: rolls WoodPoolFeed.update() until the feed answers
#   run 2  mints the coverage stack, opens creation, then runs verify-robinhood.sh
#
# Each stage also verifies the sources of whatever was minted on Blockscout.
#
# The RPC is foundry.toml's `robinhood` alias (ROBINHOOD_RPC_URL, exported or in .env);
# the signer is the `sherwood-deployer` keystore.
#
# Usage:  script/robinhood-mainnet/deploy.sh
#   DRY_RUN=1               simulate the next DeployAll run, send nothing
#   ALLOW_MORPHO_MARKET=1   after run 2, allowlist the vetted USDG/spUSDG Morpho market
#   SYNC_PAIR=1             if the V2 pair is idle, call its permissionless sync() instead of
#                           waiting for a trade (the feed's own update() makes the same call)
set -euo pipefail
cd "$(dirname "$0")/../.."

ACCOUNT=sherwood-deployer
RPC=robinhood
CHAIN_ID=4663
BOOK="chains/$CHAIN_ID.json"
MORPHO_USDG_MARKET=0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114
MAX_PAIR_IDLE=240 # the pre-flight refuses above 300 s; leave room for the simulation

# forge loads .env by itself; cast and this shell do not.
if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${ROBINHOOD_RPC_URL:?set ROBINHOOD_RPC_URL: the robinhood alias in foundry.toml reads it}"

book() { python3 -c "import json,sys;print(json.load(open('$BOOK')).get(sys.argv[1],''))" "$1"; }
has_code() { [ -n "$1" ] && [ "$(cast code "$1" --rpc-url $RPC)" != "0x" ]; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

[ "$(cast chain-id --rpc-url $RPC)" = "$CHAIN_ID" ] || { echo "the robinhood alias is not chain $CHAIN_ID"; exit 1; }
DEPLOYER=$(book DEPLOYER)
[ "$(book OWNER_MULTISIG)" = "$DEPLOYER" ] || {
  echo "OWNER_MULTISIG != DEPLOYER in $BOOK: this run would hand the protocol off. Aborting."; exit 1; }

read -rsp "Password for the $ACCOUNT keystore: " PW; echo
signed() { "$@" --account $ACCOUNT --password-file <(printf '%s' "$PW"); }
[ "$(signed cast wallet address | tr 'A-Z' 'a-z')" = "$(echo "$DEPLOYER" | tr 'A-Z' 'a-z')" ] || {
  echo "$ACCOUNT is not the book's DEPLOYER ($DEPLOYER)"; exit 1; }
echo "deployer $DEPLOYER  balance $(cast balance "$DEPLOYER" --ether --rpc-url $RPC) ETH"

feed_answers() {
  cast call "$1" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $RPC >/dev/null 2>&1
}

# ── Between the runs: the feed is minted but does not answer yet ──
FEED=$(book WOOD_USD_FEED)
if has_code "$FEED" && ! feed_answers "$FEED"; then
  say "WoodPoolFeed $FEED does not answer yet: rolling update()"
  signed cast send "$FEED" 'update()' --rpc-url $RPC >/dev/null
  if ! feed_answers "$FEED"; then
    python3 script/verify-blockscout.py $CHAIN_ID || true
    echo; echo "Still warming up. Re-run this script 24h after run 1."
    exit 0
  fi
  echo "the feed answers: continuing to run 2"
fi

# ── DeployAll: run 1 or run 2, whichever the chain still owes ──
say "forge build"
forge build

# The pre-flight wants a V2 trade in the last 5 min, and this pair trades about every 20 min.
PAIR=$(book WOOD_WETH_V2_PAIR)
pair_idle() {
  local last
  last=$(cast call "$PAIR" 'getReserves()(uint112,uint112,uint32)' --rpc-url $RPC | sed -n 3p | awk '{print $1}')
  echo $(($(cast block latest -f timestamp --rpc-url $RPC) - last))
}
IDLE=$(pair_idle)
if [ "$IDLE" -gt "$MAX_PAIR_IDLE" ] && [ -n "${SYNC_PAIR:-}" ]; then
  say "pair idle ${IDLE}s: sending sync()"
  signed cast send "$PAIR" 'sync()' --rpc-url $RPC >/dev/null
  IDLE=$(pair_idle)
fi
if [ "$IDLE" -gt "$MAX_PAIR_IDLE" ]; then
  say "pair idle ${IDLE}s: waiting up to 3h for a trade (SYNC_PAIR=1 skips the wait)"
  for _ in $(seq 1 720); do
    IDLE=$(pair_idle)
    [ "$IDLE" -le "$MAX_PAIR_IDLE" ] && break
    printf '  idle %ss\r' "$IDLE"; sleep 15
  done
fi
[ "$IDLE" -le "$MAX_PAIR_IDLE" ] || { echo "no trade on the pair in 3h; re-run with SYNC_PAIR=1"; exit 1; }

if [ -n "${DRY_RUN:-}" ]; then
  say "DeployAll, dry run"
  signed forge script script/robinhood-mainnet/DeployAll.s.sol:DeployAll --rpc-url $RPC --sender "$DEPLOYER"
  exit 0
fi
say "DeployAll"
signed forge script script/robinhood-mainnet/DeployAll.s.sol:DeployAll \
  --rpc-url $RPC --sender "$DEPLOYER" --gas-estimate-multiplier 200 --broadcast --slow

say "Blockscout source verification"
VERIFIED=0
python3 script/verify-blockscout.py $CHAIN_ID || VERIFIED=1

if ! has_code "$(book EXPOSURE_LEDGER)"; then
  echo; echo "Run 1 done (AwaitingWoodFeed). Commit $BOOK, then re-run this script in 24h."
  exit $VERIFIED
fi

# ── Run 2 finished ──
say "verify-robinhood.sh"
RPC=$RPC ./script/verify-robinhood.sh $CHAIN_ID

FACTORY=$(book SYNDICATE_FACTORY)
say "launch posture"
echo "factory.owner        $(cast call "$FACTORY" 'owner()(address)' --rpc-url $RPC)"
echo "factory.creationFee  $(cast call "$FACTORY" 'creationFee()(uint256)' --rpc-url $RPC)"
echo "fee recipient        $(cast call "$FACTORY" 'creationFeeRecipient()(address)' --rpc-url $RPC)"

if [ -n "${ALLOW_MORPHO_MARKET:-}" ]; then
  TIERS=$(book TIER_REGISTRY)
  if [ "$(cast call "$TIERS" 'isMorphoMarketAllowed(bytes32)(bool)' $MORPHO_USDG_MARKET --rpc-url $RPC)" != "true" ]; then
    say "allowlisting the USDG/spUSDG Morpho market"
    signed cast send "$TIERS" 'setMorphoMarketAllowed(bytes32,bool)' $MORPHO_USDG_MARKET true --rpc-url $RPC >/dev/null
  fi
fi

echo; echo "Ceremony complete. Commit $BOOK. WoodPoolFeed.update() stays a 24-26h keeper job."
exit $VERIFIED
