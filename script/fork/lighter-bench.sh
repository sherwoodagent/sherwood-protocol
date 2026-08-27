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
#   LIGHTER_BENCH_EXPECT_FULL
#              1 to FAIL the run if the execute leg was scaled down. Set it for
#              the fully-covered leg; leave it off for the deliberate
#              under-coverage leg.
#   LIVENESS   1 to run the §6 liveness leg in place of the plain unwind:
#              `removeAgent(proposer)`, prove every proposer-gated door is shut
#              with its NAMED error, then drive the whole unwind from the vault
#              owner. Leaves the agent removed; step 13 re-seats it.
#   TICKS      what `queueWithdraw` asks for (default = whatever the clone
#              actually deployed, read off `deployedAmount()` after execute —
#              which is BELOW `LIGHTER_BENCH_DEPLOY_AMOUNT` on an under-covered
#              proposal).
#
# Usage:
#   set -a; source .env; set +a
#   RPC="$TENDERLY_ROBINHOOD_RPC_URL" GUARDIAN=0x571D47... ./script/fork/lighter-bench.sh
set -euo pipefail
: "${RPC:?set RPC to the vnet admin endpoint}"
: "${GUARDIAN:?set GUARDIAN to an address with live, 30d-old sWOOD stake}"
SALT="${SALT:-1}"
# Sized against the APPROVE COVERAGE the cohort can still raise, not against the
# vault. This is the DECLARED ceiling: `LighterPerpStrategy._execute` scales it
# by `effectiveMaxCapital / maxCapital`, so a partially-covered proposal deploys
# LESS rather than reverting `CallCapExceeded`. Every size assertion downstream
# therefore reads the clone's `deployedAmount()`, not this. See
# `coveragePreflight` for sizing it so no scaling happens at all.
DEPLOY_AMOUNT="${LIGHTER_BENCH_DEPLOY_AMOUNT:-2000000000}"   # 2,000 USDG (6dp)
export LIGHTER_BENCH_DEPLOY_AMOUNT="$DEPLOY_AMOUNT"

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

# SWEEP THE DEAD PLEDGES BEFORE SIZING ANYTHING. An approval whose epoch bucket
# has expired still sits on `_livePledgedUsd`, the denominator the guardian's
# bond is shared across — so a proposal nothing is competing for still allocates
# `bond * reserved / livePledged` and deploys a scaled-down amount. Only the
# permissionless `retireApproval` clears it. See `LighterForkBench.retireStale`.
say "1a. retire the guardian's DEAD approvals (frees the shared-stake denominator)"
SENDER=$OUTSIDER run 'retireStale(address)' "$GUARDIAN"

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

# THE DRAIN IS SIZED OFF THE CLONE, NOT OFF THE DECLARATION. Under a short
# approve quorum `_execute` deployed the scaled figure, and asking the venue for
# the declared one would revert venue-side on a balance that was never there.
DEPLOYED=$(cast call "$CLONE" 'deployedAmount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
TICKS="${TICKS:-$DEPLOYED}"
echo "declared $DEPLOY_AMOUNT / deployed $DEPLOYED / draining $TICKS"

# THE UNWIND HAS TWO SHAPES AND ONLY ONE OF THEM IS THE DEFAULT.
# LIVENESS=1 runs the §6 leg instead: the OWNER de-registers the proposer and
# then drives the whole unwind himself, which also proves the drain never
# depended on the agent. Everything downstream — the settle, the C1 queueRest —
# therefore has to stop addressing AGENT, so the settler is a variable.
if [ "${LIVENESS:-0}" = "1" ]; then
  say "7. LIVENESS (§6): removeAgent(proposer), then the OWNER unwinds"
  SENDER=$OWNER run 'liveness(uint256,uint64)' "$SALT" "$TICKS"
  SETTLER=$OUTSIDER   # permissionless once strategyDuration has elapsed
else
  say "7. initiateReturn + queueWithdraw($TICKS)"
  SENDER=$AGENT run 'unwind(uint256,uint64)' "$SALT" "$TICKS"
  SETTLER=$AGENT
fi

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
#
# AND IT NEEDS A WALL-CLOCK WAIT, WHICH NO WARP ABOVE CAN SUBSTITUTE FOR.
# `_settle`'s first guard is `block.number <= returnsInitiatedAt`, and on this
# vnet the NUMBER opcode is NOT the counter `evm_increaseTime` moves and NOT the
# one `eth_blockNumber` reports — it tracks the FORKED CHAIN'S HEAD, which
# advances with REAL time at Robinhood's ~2s block rate. Measured 2026-08-22:
# `initiateReturn` stamped 25,814,189 while `eth_blockNumber` read 21,178,183,
# and the 7,300-VNET-second warp in step 7b moved neither. So a settle probe
# fired immediately after the drain reverts `SettleTooSoon()` (0xc9b4a873) and
# never reaches `WithdrawalInFlight` — the guard this step exists to prove — for
# a reason that has nothing to do with the drain. Retry on real seconds until
# the head ticks; anything other than those two selectors is a real failure.
SETTLE_PROBE_TRIES=${SETTLE_PROBE_TRIES:-30}
for _i in $(seq 1 "$SETTLE_PROBE_TRIES"); do
  OUT=$(cast call "$GOVERNOR" 'settleProposal(uint256)' "$PID" --from $SETTLER --rpc-url "$RPC" 2>&1 || true)
  case "$OUT" in
    *f0ccc8de*) echo "ok: settleProposal reverts WithdrawalInFlight(0xf0ccc8de)"; echo "   $OUT"; break ;;
    *c9b4a873*) echo "   SettleTooSoon - the forked head has not ticked past returnsInitiatedAt yet ($_i)"; sleep 3 ;;
    *) echo "FAIL: expected WithdrawalInFlight, got: $OUT"; exit 1 ;;
  esac
done
case "$OUT" in
  *f0ccc8de*) : ;;
  *) echo "FAIL: still SettleTooSoon after $SETTLE_PROBE_TRIES tries - is the vnet's head advancing?"; exit 1 ;;
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
cast send "$GOVERNOR" 'settleProposal(uint256)' "$PID" --rpc-url "$RPC" --unlocked --from $SETTLER \
  | egrep '^(status|transactionHash)'
AFTER=$(cast call $USDG 'balanceOf(address)(uint256)' "$VAULT" --rpc-url "$RPC" | awk '{print $1}')
echo "vault USDG delta on settle: $((AFTER-BEFORE))  (deployed was $DEPLOYED; the gap is the settlement fee)"
forge script "$SCRIPT" --sig 'assertSettled(uint256)' "$SALT" --rpc-url "$RPC" \
  --unlocked --sender $AGENT 2>&1 | sed -n '/== Logs ==/,/^$/p'

say "11. C1 regression: queue the REST after the proposal is Settled"
REST="${REST:-500000000}"
SENDER=$SETTLER run 'queueRest(uint256,uint64)' "$SALT" "$REST"
cast rpc tenderly_setStorageAt $ZKL "$SLOT" "$(printf '0x%064x' "$REST")" --rpc-url "$RPC" >/dev/null
echo "matured $REST more ticks"

say "12. residue: sweep auth, claim-only recoverResiduals, collectResidue"
SENDER=$OUTSIDER run 'residue(uint256)' "$SALT"

if [ "${LIVENESS:-0}" = "1" ]; then
  say "13. re-seat the bench agent (the §6 leg left it removed)"
  SENDER=$OWNER run 'reseatAgent()'
fi

say "done."
