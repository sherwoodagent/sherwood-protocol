#!/usr/bin/env bash
# The §5 Lighter lifecycle bench, end to end, against the LIVE Sherwood stack on
# the Tenderly Robinhood fork (chain 9994663) and the REAL ZkLighter.
#
# Drives `script/fork/LighterForkBench.s.sol` phase by phase, performing the
# `evm_increaseTime` waits and the `tenderly_*` cheats BETWEEN phases — neither
# is expressible inside a broadcast, which is why the bench is phased at all.
#
# Required env:
#   RPC        the vnet ADMIN endpoint (TENDERLY_ROBINHOOD_RPC_URL) — the cheats
#              and `--unlocked` impersonation both need admin.
#   GUARDIAN   an address with LIVE sWOOD stake at least `FLOOR_LOOKBACK`
#              (30 days) old at PROPOSE time. Younger stake makes
#              `_growthGatedVoteWeight` zero and `voteOnProposal` reverts
#              `NotActiveGuardian()` — see the warp in step 0.
#   SALT       clone salt (default 1). Use a fresh one per run.
#   TICKS      what `queueWithdraw` asks for (default = the full deposit).
#
# Usage:
#   set -a; source .env; set +a
#   RPC="$TENDERLY_ROBINHOOD_RPC_URL" GUARDIAN=0x571D47... ./script/fork/lighter-bench.sh
set -euo pipefail
: "${RPC:?set RPC to the vnet admin endpoint}"
: "${GUARDIAN:?set GUARDIAN to an address with live, 30d-old sWOOD stake}"
SALT="${SALT:-1}"
# Sized against the APPROVE COVERAGE the cohort can still raise, not against the
# vault. `LighterPerpStrategy._execute` pulls a pinned `depositAmount`, so a
# partially-covered proposal does not deploy less — it reverts `CallCapExceeded`
# at the execute batch. See `coveragePreflight`.
DEPLOY_AMOUNT="${LIGHTER_BENCH_DEPLOY_AMOUNT:-2000000000}"   # 2,000 USDG (6dp)
export LIGHTER_BENCH_DEPLOY_AMOUNT="$DEPLOY_AMOUNT"
TICKS="${TICKS:-$DEPLOY_AMOUNT}"

cd "$(dirname "$0")/../.."
SCRIPT=script/fork/LighterForkBench.s.sol:LighterForkBench
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WOOD=0xF8BC08092C06dB6148114DCf82AF881F1085f92b
ZKL=0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d
OWNER=0x1111111111111111111111111111111111111111
AGENT=0x2222222222222222222222222222222222222222
LP1=0x3333333333333333333333333333333333333333
LP2=0x4444444444444444444444444444444444444444
OUTSIDER=0x5555555555555555555555555555555555555555

[ "$(cast chain-id --rpc-url "$RPC")" = "9994663" ] || { echo "wrong chain"; exit 1; }
[ "$(cast block-number --rpc-url "$RPC")" -gt 21176749 ] || { echo "stale vnet"; exit 1; }

say() { printf '\n\033[1m══ %s\033[0m\n' "$*"; }
# `--slow` is MANDATORY under `--unlocked` — see DeployLighterTemplate's header.
run() { forge script "$SCRIPT" --sig "$1" "${@:2}" --rpc-url "$RPC" --unlocked \
          --sender "$SENDER" --broadcast --slow 2>&1 | sed -n '/== Logs ==/,/^$/p'; }
warp() { cast rpc evm_increaseTime "$(printf '0x%x' "$1")" --rpc-url "$RPC" >/dev/null
         cast rpc evm_mine --rpc-url "$RPC" >/dev/null; }
now() { cast block latest -f timestamp --rpc-url "$RPC"; }

say "0. fund the bench actors (tenderly cheats)"
for a in $OWNER $AGENT $LP1 $LP2 $OUTSIDER $GUARDIAN; do
  cast rpc tenderly_setBalance "$a" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
done
cast rpc tenderly_setErc20Balance $USDG $LP1 0x2540BE400 --rpc-url "$RPC" >/dev/null
cast rpc tenderly_setErc20Balance $USDG $LP2 0x2540BE400 --rpc-url "$RPC" >/dev/null
cast rpc tenderly_setErc20Balance $WOOD $OWNER 0x152D02C7E14AF6800000 --rpc-url "$RPC" >/dev/null
cast rpc tenderly_setErc20Balance $WOOD $AGENT 0x152D02C7E14AF6800000 --rpc-url "$RPC" >/dev/null
echo "funded."

say "1. create the fund + LP deposits"
SENDER=$OWNER run 'setup()'

say "1b. approve-coverage pre-flight"
SENDER=$OUTSIDER forge script "$SCRIPT" --sig 'coveragePreflight(address)' "$GUARDIAN" --rpc-url "$RPC" \
  --unlocked --sender $OUTSIDER 2>&1 | sed -n '/== Logs ==/,/^$/p'

say "2. clone + propose"
SENDER=$AGENT run 'cloneAndPropose(uint256)' "$SALT"

say "3. LP vote (needs the propose snapshot strictly in the past)"
warp 2
SENDER=$LP1 run 'lpVote()'

# THE REGISTRY WINDOW, NOT THE GOVERNOR'S. Both are written in the propose tx,
# but `openReview` / `voteOnProposal` gate on the REGISTRY's copy — and it is
# read live here rather than copied from an earlier log, because a re-run shifts
# it by however long the first attempt took.
SENDER=$OUTSIDER forge script "$SCRIPT" --sig 'wiring(uint256)' "$SALT" --rpc-url "$RPC" \
  --unlocked --sender $OUTSIDER 2>&1 | sed -n '/== Logs ==/,/^$/p' | tee /tmp/lighter-wiring.txt
GOVERNOR=$(grep -o 'BENCH_GOVERNOR=0x[0-9a-fA-F]*' /tmp/lighter-wiring.txt | cut -d= -f2)
CLONE=$(grep -o 'BENCH_CLONE=0x[0-9a-fA-F]*' /tmp/lighter-wiring.txt | cut -d= -f2)
VAULT=$(grep -o 'BENCH_VAULT=0x[0-9a-fA-F]*' /tmp/lighter-wiring.txt | cut -d= -f2)
GR=$(python3 -c "import json;print(json.load(open('chains/9994663.json'))['GUARDIAN_REGISTRY'])")
PID=$(cast call "$GOVERNOR" 'proposalCount()(uint256)' --rpc-url "$RPC")
VOTE_END=$(cast call "$GR" 'reviewWindow(address,uint256)(uint64,uint64)' "$GOVERNOR" "$PID" --rpc-url "$RPC" | sed -n 1p | awk '{print $1}')
REVIEW_END=$(cast call "$GR" 'reviewWindow(address,uint256)(uint64,uint64)' "$GOVERNOR" "$PID" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')
echo "governor=$GOVERNOR clone=$CLONE pid=$PID voteEnd=$VOTE_END reviewEnd=$REVIEW_END"

say "4. warp past voteEnd, open the review, guardian APPROVES"
warp $(( VOTE_END - $(now) + 60 ))
SENDER=$OUTSIDER run 'openReviewAndApprove(address)' "$GUARDIAN"

say "5. warp past reviewEnd, resolve + EXECUTE (real USDG into ZkLighter)"
warp $(( REVIEW_END - $(now) + 60 ))
SENDER=$OUTSIDER run 'executeStep(uint256)' "$SALT"

say "6. guardrails"
SENDER=$AGENT run 'guardrails(uint256)' "$SALT"

say "7. initiateReturn + queueWithdraw($TICKS)"
SENDER=$AGENT run 'unwind(uint256,uint64)' "$SALT" "$TICKS"

# EVEN THE PROPOSER OWES A WAIT. `settleProposal`'s gate is
# `msg.sender == proposer ? MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE (1h)
# : strategyDuration` — so a self-settle straight after `queueWithdraw` reverts
# `StrategyDurationNotElapsed()` (0x418c8bb9) and never reaches the STRATEGY's
# own `WithdrawalInFlight` guard, which is what step 8 is actually testing.
say "7b. warp past the settle timing gate"
warp 7300

say "8. settle must be SHUT while the drain is in flight"
# `cast call`, NOT a forge simulation. Forge forks at `eth_blockNumber`, which on
# this vnet lags the number contracts actually see by millions of blocks (see
# LighterForkBench.assertSettled), so a simulated settle always reports
# `SettleTooSoon()` and never reaches the guard under test. On the node the
# refusal is the real one.
OUT=$(cast call "$GOVERNOR" 'settleProposal(uint256)' "$PID" --from $AGENT --rpc-url "$RPC" 2>&1 || true)
case "$OUT" in
  *f0ccc8de*) echo "ok: settleProposal reverts WithdrawalInFlight(0xf0ccc8de)"; echo "   $OUT" ;;
  *) echo "FAIL: expected WithdrawalInFlight, got: $OUT"; exit 1 ;;
esac

say "9. simulate withdrawal maturity (§2: the real pendingAssetBalances slot)"
forge script "$SCRIPT" --sig "maturitySlot(uint256)" "$SALT" --rpc-url "$RPC" \
  --unlocked --sender $AGENT 2>&1 | sed -n '/== Logs ==/,/^$/p' | tee /tmp/lighter-slot.txt
SLOT=$(grep -o 'BENCH_MATURITY_SLOT=0x[0-9a-fA-F]*' /tmp/lighter-slot.txt | cut -d= -f2)
# positional params — NEVER a JSON array
cast rpc tenderly_setStorageAt $ZKL "$SLOT" "$(printf '0x%064x' "$TICKS")" --rpc-url "$RPC" >/dev/null
echo "wrote $TICKS ticks to $SLOT; getPendingBalance now: $(cast call "$CLONE" 'pendingBalance()(uint128)' --rpc-url "$RPC")"

say "10. settle (cast, for the block-number reason in step 8)"
BEFORE=$(cast call $USDG 'balanceOf(address)(uint256)' "$VAULT" --rpc-url "$RPC" | awk '{print $1}')
cast send "$GOVERNOR" 'settleProposal(uint256)' "$PID" --rpc-url "$RPC" --unlocked --from $AGENT \
  | egrep '^(status|transactionHash)'
AFTER=$(cast call $USDG 'balanceOf(address)(uint256)' "$VAULT" --rpc-url "$RPC" | awk '{print $1}')
echo "vault USDG delta on settle: $((AFTER-BEFORE))  (deposit was $DEPLOY_AMOUNT; the gap is the settlement fee)"
forge script "$SCRIPT" --sig 'assertSettled(uint256)' "$SALT" --rpc-url "$RPC" \
  --unlocked --sender $AGENT 2>&1 | sed -n '/== Logs ==/,/^$/p'

say "11. C1 regression: queue the REST after the proposal is Settled"
REST="${REST:-500000000}"
SENDER=$AGENT run 'queueRest(uint256,uint64)' "$SALT" "$REST"
cast rpc tenderly_setStorageAt $ZKL "$SLOT" "$(printf '0x%064x' "$REST")" --rpc-url "$RPC" >/dev/null
echo "matured $REST more ticks"

say "12. residue: sweep auth, claim-only recoverResiduals, collectResidue"
SENDER=$OUTSIDER run 'residue(uint256)' "$SALT"

say "done."
