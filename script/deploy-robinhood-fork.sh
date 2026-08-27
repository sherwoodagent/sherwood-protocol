#!/usr/bin/env bash
# Full Sherwood ceremony against a Robinhood-mainnet fork (Tenderly vnet, chain
# 9994663) — core, strategy templates, the WOOD price source, and the whole
# guardian-econ stack.
#
# The phases are ORDERED and each reads the address book the previous one wrote,
# so this exists mainly so the ordering cannot be got wrong by hand. Re-runnable:
# `ScriptBase._writeAddresses` patches core keys in place, so the pre-committed
# externals (WETH / USDG / Uniswap / Chainlink feeds / stock tokens) survive.
#
# THE WOOD PRICE IS THE PART THAT DIFFERS FROM MAINNET. A vnet cannot prime
# `WoodTwapOracle` — the WOOD/WETH pair stops trading at the fork point, the idle
# span grows without bound, and `update()` no-ops forever. So where the mainnet
# ceremony runs `DeployWoodTwapOracle`, this runs `DeployForkWoodUsdFeed` and
# hands `DeployPlanB` a `WOOD_USD_FEED` instead. The starting price is DERIVED
# from the fork's own pair reserves times its Chainlink ETH/USD answer, so bond
# valuations track mainnet rather than an invented number.
#
# Required env:
#   RPC   the vnet ADMIN RPC (needed for `tenderly_setBalance` and for
#         `--unlocked` impersonation of the deployer; the public RPC accepts
#         neither)
#
# Optional env:
#   DEPLOYER            impersonated deployer (default: the book's DEPLOYER)
#   FUND_ETH            native gas to mint the deployer, wei-hex (default 100 ETH)
#   WOOD_PRICE_CAP_MULT cap as a multiple of derived market, x100 (default 150)
#   COVERED_TVL_CAP_USD18, ASSET_FEED_MAX_DELAY  — see DeployPlanB
#
# Usage:
#   RPC=https://virtual.robinhood-chain.eu.rpc.tenderly.co/<admin-uuid> \
#     ./script/deploy-robinhood-fork.sh
set -euo pipefail
: "${RPC:?set RPC to the vnet ADMIN endpoint}"

cd "$(dirname "$0")/.."
BOOK="chains/9994663.json"
a() { python3 -c "import json,sys;print(json.load(open('$BOOK')).get(sys.argv[1],''))" "$1"; }

CHAIN=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN" = "9994663" ] || { echo "RPC reports chain $CHAIN, expected 9994663"; exit 1; }

export ROBINHOOD_FORK_CHAIN_ID=9994663
# Fork posture: the deployer keeps ownership of beacon / factory / registry /
# sWOOD / ProtocolConfig, because fork admin needs it. NEVER on real mainnet.
export SKIP_MULTISIG_HANDOFF=true
export WOOD_TOKEN="$(a WOOD_TOKEN)"
DEPLOYER="${DEPLOYER:-$(a DEPLOYER)}"
FUND_ETH="${FUND_ETH:-0x56BC75E2D63100000}"

run() {
  echo; echo "════════ $* ════════"
  forge script "$@" --rpc-url "$RPC" --broadcast --slow \
    --gas-estimate-multiplier 200 --unlocked --sender "$DEPLOYER"
}

# ── Gas. The deployer is impersonated, not keyed: the Tenderly admin RPC accepts
#    eth_sendTransaction from any sender, but it still needs a balance. ──
echo "funding $DEPLOYER"
cast rpc tenderly_setBalance "$DEPLOYER" "$FUND_ETH" --rpc-url "$RPC" >/dev/null
echo "  balance: $(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether) ETH"

# ── Phase 1-5: core + templates + the clone factory ──
# DeployWood is SKIPPED: WOOD is already live on the fork.
run script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet
run script/robinhood-mainnet/DeployPortfolioStrategy.s.sol
run script/robinhood-mainnet/DeployMorphoStrategy.s.sol
run script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol
run script/DeployStrategyFactory.s.sol

# ── Phase 6: the WOOD price source (fork substitute for DeployWoodTwapOracle) ──
# Derived from live fork state so the fork prices WOOD the way mainnet does.
read -r WOOD_USD_PRICE_X8 CAP_X8 <<EOF
$(python3 - "$(cast call "$(a WOOD_WETH_V2_PAIR)" 'getReserves()(uint112,uint112,uint32)' --rpc-url "$RPC" | tr '\n' ' ')" \
            "$(cast call "$(a CHAINLINK_ETH_USD_FEED)" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | sed -n '2p')" \
            "${WOOD_PRICE_CAP_MULT:-150}" <<'PY'
import sys
vals=[int(p.split('[')[0].strip()) for p in sys.argv[1].split(']') if p.split('[')[0].strip().isdigit()]
r_weth, r_wood = vals[0], vals[1]
eth = int(sys.argv[2].split('[')[0].strip())/1e8
price = eth / ((r_wood/1e18)/(r_weth/1e18))
x8 = round(price*1e8)
print(x8, round(x8*int(sys.argv[3])/100))
PY
)
EOF
echo "derived WOOD/USD X8: $WOOD_USD_PRICE_X8   cap: $CAP_X8"
export WOOD_USD_PRICE_X8
run script/fork/DeployForkWoodUsdFeed.s.sol:DeployForkWoodUsdFeed

# ── Phase 7: Plan B (ExposureLedger + ProposerBondEscrow) ──
export STAKED_WOOD="$(a STAKED_WOOD)" SYNDICATE_FACTORY="$(a SYNDICATE_FACTORY)"
export GUARDIAN_REGISTRY="$(a GUARDIAN_REGISTRY)" PROTOCOL_CONFIG="$(a PROTOCOL_CONFIG)"
export USDG="$(a USDG)" CHAINLINK_USDG_USD_FEED="$(a CHAINLINK_USDG_USD_FEED)"
export WOOD_USD_FEED="$(a WOOD_USD_FEED)" WOOD_PRICE_CAP_X8="$CAP_X8"
# Sized against the governor's ACTUAL lifecycle — votingPeriod 24h + reviewPeriod
# 24h + executionWindow 24h = 72h — plus heartbeat margin, because the §3.3a
# approve quorum re-reads this feed at EXECUTE time. Not a habitual `1 days`.
export ASSET_FEED_MAX_DELAY="${ASSET_FEED_MAX_DELAY:-345600}"
export WOOD_FEED_MAX_DELAY="${WOOD_FEED_MAX_DELAY:-3600}"
export COVERED_TVL_CAP_USD18="${COVERED_TVL_CAP_USD18:-10000000000000000000000000}"
# The vnet has no Safe and its deployer is an impersonated EOA, so pre-flight 10
# would make the fork ceremony unrunnable. GATED, not deleted — the mainnet
# ceremony must not set this, and keeps the refusal.
export ALLOW_EOA_LEDGER_OWNER=true
run script/DeployPlanB.s.sol:DeployPlanB

# ── Phase 8: Plan D (ChallengeGame + its three roles) ──
export EXPOSURE_LEDGER="$(a EXPOSURE_LEDGER)" TIER_REGISTRY="$(a TIER_REGISTRY)"
run script/DeployPlanD.s.sol:DeployPlanD

# ── Phase 9-10: the token court, deployed and wired as two transactions so
#    every pre-flight runs against the finished pair before `game.court` is
#    touched. The fail-safe if wiring refuses is benign: an unwired game times
#    disputed challenges out in favour of the accused. ──
export CHALLENGE_GAME="$(a CHALLENGE_GAME)" PROTOCOL_OWNER="${PROTOCOL_OWNER:-$DEPLOYER}"
run script/DeployTokenCourt.s.sol:DeployTokenCourt
export COURT="$(a TOKEN_COURT)"
run script/DeployTokenCourt.s.sol:WireTokenCourt

echo; echo "════════ verifying ════════"
RPC="$RPC" ./script/verify-robinhood-fork.sh

cat <<EOF

Ceremony complete. Address book: $BOOK

NEXT (not done by this script):
  - Seed the Slash Appeal Reserve: approve + registry.fundSlashAppealReserve.
    Until it is funded, refundSlash cannot pay an appeal.
  - Fund operator wallets and stake >= 50,000 WOOD of guardian cohort
    (MIN_COHORT_STAKE_AT_OPEN) if you intend to exercise real blocking rather
    than the cold-start bypass.
  - Sync the new core addresses into cli/src/lib/addresses.ts,
    app/src/lib/contracts.ts and the SDK.
EOF
