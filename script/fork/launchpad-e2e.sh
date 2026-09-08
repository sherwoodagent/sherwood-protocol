#!/usr/bin/env bash
# Drive a LaunchpadStrategy proposal end to end on a Robinhood-fork vnet.
#
# THIS IS A TEST HARNESS, like `guardian-review.sh` next to it, and for the same
# reason: everything below is a job for a live agent (clone + propose) or a live
# keeper (claim sweeps, `collectFees`), and shipping it as a CLI command would
# imply the launch lifecycle is someone's console chore. It signs nothing —
# every actor is `--unlocked` impersonation on the vnet ADMIN RPC.
#
# It is the companion to `guardian-review.sh`, not a replacement: the guardian
# half of the cycle is still that script's job, and `cycle` shells out to it.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE FIVE THINGS THAT MAKE A NAIVE RUN FAIL. All five were paid for once.
#
# 1. `VoteType.For` IS 0, NOT 1. `enum VoteType { For, Against, Abstain }`.
#    Passing 1 casts AGAINST, the whole float vetoes its own proposal, and the
#    result is a `Rejected` proposal whose only symptom at execute is
#    `ProposalNotApproved()` (0xcc6633c5) — which reads exactly like a timing
#    mistake. `getProposal(pid).votesAgainst` is the field that tells you.
#
# 2. THE PER-CALL CAP BELONGS ON `execute()`, NOT ON THE `approve`. Caps meter
#    the vault-asset OUTFLOW measured around each call. `USDG.approve(clone, x)`
#    moves nothing; the outflow happens inside `clone.execute()`, when the
#    strategy pulls. Caps of `[assetIn, 0]` therefore die at execute with
#    `CallCapExceeded(1, assetIn, 0)`, a full governance cycle after the
#    proposal was written. The correct shape is `[0, assetIn]`.
#
# 3. `BatchExecutorLib.Call` HAS THREE MEMBERS: `(address target, bytes data,
#    uint256 value)`. A two-member tuple in the `cast` signature computes a
#    DIFFERENT selector, and the governor answers an empty revert that names
#    nothing. Real signature:
#      propose(address,address,string,uint256,(uint256,uint16),
#              (address,bytes,uint256)[],uint256[],
#              (address,bytes,uint256)[],uint256[],(address,uint256)[])
#
# 4. THE CLONE MUST BE ATTESTED ON THE TIER REGISTRY BEFORE `propose`. The
#    governor batch is gated by TARGET, so the leading `USDG.approve(clone, …)`
#    is refused until the CLONE is `setAdapterAllowed`. Per-proposal and not
#    pre-seedable — see `guardian-review.sh attest-clone`, which this reuses.
#
# 5. THE CHAINLINK FEEDS ARE ALREADY DAYS STALE ON THIS VNET AND EVERY WARP
#    MAKES IT WORSE. `guardian-review.sh feed-maxdelay` only widens Sherwood's
#    OWN bound; the VENUE has its own. Sushi Launchpad V1 reverts
#    `StalePriceFeedRound(updatedAt, now, 259200)` — a 3-day bound this repo
#    does not own and cannot widen — so a launch cannot execute at all until
#    the aggregator answers fresh. `freshen` below rewrites the aggregator's
#    stored transmission timestamp in place. FORK-ONLY, and a real weakening of
#    a real control: it is forging an oracle round. Never anywhere but a vnet.
#
# ─────────────────────────────────────────────────────────────────────────────
# TWO MORE THAT COST REAL VALUE RATHER THAN A CYCLE.
#
#   `collectFees` NEEDS AN EXPLICIT `--gas-limit`. Both adapters wrap the venue
#   payout in a RAW CALL whose failure is swallowed and reported as `(0, 0)`.
#   Under `eth_estimateGas` the estimator can settle on a limit where the inner
#   call OOGs (63/64 rule) while the outer transaction still SUCCEEDS: status 1,
#   zero logs, zero fees moved, no error anywhere. Measured on this fork —
#   224_428 gas moved nothing, 227_388 moved 8.391340 USDG. Always pass a fat
#   `--gas-limit` and always assert the RECIPIENT's balance delta.
#
#   A USDG-QUOTED SUSHI LAUNCH STRANDS WETH ON THE CLONE. `_acquireFeeToken`
#   buys the venue's WETH fee with `settleSlippageBps` of headroom; the
#   overshoot stays. `sweep()` moves only `asset`, `launchToken` and `quoteToken
#   != asset`, so on a USDG-quoted launch WETH is none of the three and
#   `BaseStrategy` has no rescue. Measured: 15_002_662_640_967 wei, permanent.
#   Bounded by the fee (5e14 wei) times the slippage tolerance, so pennies —
#   but it is vault money that can never come back, and no view declares it.
#
# ─────────────────────────────────────────────────────────────────────────────
# Usage (RPC must be the vnet ADMIN endpoint — impersonation + cheats):
#
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh freshen <aggregator...>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh agent   <vault> <agent> [agentId]
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh clone   <vault> <agent> <initParamsHex>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh propose <vault> <agent> <clone> <assetIn> <duration> <uri>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh cycle   <vault> <pid> <owner> <guardian...>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh execute <vault> <pid> <agent>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh status  <clone>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh claim   <clone> <holder...>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh settle  <vault> <pid> <agent>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh sweep   <vault> <clone> <caller>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh fees    <adapter> <launchRef> <recipient> <token> <keeper>
#   RPC=<admin rpc> ./script/fork/launchpad-e2e.sh warp    <unix-ts>
#
# `initParamsHex` is `abi.encode(LaunchpadStrategy.InitParams)`; build it with
#   cast abi-encode 'f((address,address,uint256,address,uint256,bytes,bytes,\
#     uint256,uint256,uint256,uint256,uint64,uint256,string,string,bytes))' "(...)"
# and dry-run `clone` first — every init bound fails there, before a vote.
set -uo pipefail
: "${RPC:?set RPC to the vnet ADMIN endpoint (impersonation + cheats)}"

cd "$(dirname "$0")/../.."
BOOK="chains/9994663.json"
[ -f "$BOOK" ] || { echo "missing $BOOK"; exit 1; }
a() { python3 -c "import json,sys;print(json.load(open('$BOOK')).get(sys.argv[1],''))" "$1"; }

SFAC=$(a STRATEGY_FACTORY); TIERS=$(a TIER_REGISTRY); DEPLOYER=$(a DEPLOYER)
SYNFAC=$(a SYNDICATE_FACTORY); USDG=$(a USDG); TPL="${LAUNCHPAD_TEMPLATE:-}"

num() { echo "$1" | sed 's/ .*//'; }
gov_of() { num "$(cast call "$SYNFAC" 'governorOf(address)(address)' "$1" --rpc-url "$RPC" 2>/dev/null)"; }
now_ts() { cast block latest --rpc-url "$RPC" -f timestamp; }
fund() { cast rpc tenderly_setBalance "$1" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null 2>&1; }

# The real `propose` signature. See gotcha 3 — the third `value` member is not
# optional, and omitting it produces a different selector, not a decode error.
PROPOSE_SIG='propose(address,address,string,uint256,(uint256,uint16),(address,bytes,uint256)[],uint256[],(address,bytes,uint256)[],uint256[],(address,uint256)[])'

# ── Forge a fresh Chainlink round on an AGGREGATOR. FORK-ONLY. ───────────────
#
# The vnet's clock has been warped days past the fork point and the feeds do not
# tick, so `updatedAt` is permanently in the past. Sherwood's own staleness
# bound is settable (`guardian-review.sh feed-maxdelay`); the VENUE's is not —
# Sushi Launchpad V1 carries its own 3-day bound and reverts
# `StalePriceFeedRound` inside the execute batch, which surfaces as an opaque
# 0x66c31723 several frames from the warp that caused it.
#
# This locates the aggregator's stored transmission for the CURRENT round by
# probing mapping bases 0..59 for a slot carrying the known timestamps, then
# rewrites the two packed uint32 clocks to `block.timestamp`, leaving the int192
# answer untouched. Answer-preserving on purpose: the point is to stop the read
# reverting, not to move a price. Re-run after EVERY warp.
cmd_freshen() {
  python3 - "$RPC" "$@" <<'PY'
import subprocess,sys
RPC=sys.argv[1]
def sh(*a): return subprocess.run(list(a),capture_output=True,text=True).stdout.strip()
for agg in sys.argv[2:]:
    out=sh('cast','call',agg,'latestRoundData()(uint80,int256,uint256,uint256,uint80)','--rpc-url',RPC).split('\n')
    if len(out)<5: print(f"  {agg}  UNREADABLE"); continue
    rid=int(out[0].split()[0]); started=int(out[2].split()[0]); updated=int(out[3].split()[0])
    now=int(sh('cast','block','latest','--rpc-url',RPC,'-f','timestamp'))
    for p in range(60):
        s=sh('cast','index','uint32',str(rid),str(p))
        v=sh('cast','storage',agg,s,'--rpc-url',RPC)
        if not v or int(v,16)==0: continue
        if hex(started)[2:] not in v and hex(updated)[2:] not in v: continue
        low=int(v,16) & ((1<<192)-1)
        w='0x'+format(low | ((now & 0xffffffff)<<192) | ((now & 0xffffffff)<<224),'064x')
        sh('cast','rpc','tenderly_setStorageAt',agg,s,w,'--rpc-url',RPC)
        chk=sh('cast','call',agg,'latestRoundData()(uint80,int256,uint256,uint256,uint80)','--rpc-url',RPC).split('\n')
        print(f"  {agg}  round {rid}  updatedAt {updated} -> {chk[3].split()[0]}")
        break
    else:
        print(f"  {agg}  round {rid}: transmission slot not found in bases 0..59 — layout differs")
PY
}

cmd_warp() {
  cast rpc evm_setNextBlockTimestamp "$1" --rpc-url "$RPC" >/dev/null 2>&1
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null 2>&1
  echo "  now $(now_ts)"
}

# Register an impersonated agent on the vault. `registerAgent` is owner-only and
# the ERC-8004 identity check is skipped where no agent registry is wired, so
# any `agentId` works on the fork.
cmd_agent() {
  local vault=$1 agent=$2 id=${3:-1001}
  fund "$agent"
  cast send "$vault" 'registerAgent(uint256,address)' "$id" "$agent" \
    --rpc-url "$RPC" --unlocked --from "$(num "$(cast call "$vault" 'owner()(address)' --rpc-url "$RPC")")" >/dev/null 2>&1
  echo "  isAgent($agent) = $(cast call "$vault" 'isAgent(address)(bool)' "$agent" --rpc-url "$RPC")"
}

# Clone + init, then ATTEST the clone (gotcha 4). Dry-runs first so an init
# bound (`ReserveTooLarge`, `InvalidClaimWindow`, `QuoteNotSupported`, …) is
# reported here rather than costing a governance cycle.
#
# `proposer` MUST equal `msg.sender`: `StrategyFactory.cloneAndInit` pins
# `_proposer` to the caller and the governor re-checks the binding at propose.
cmd_clone() {
  local vault=$1 agent=$2 init=$3
  : "${TPL:?set LAUNCHPAD_TEMPLATE to the approved template address}"
  local pre; pre=$(cast call "$SFAC" 'cloneAndInit(address,address,address,bytes)(address)' \
    "$TPL" "$vault" "$agent" "$init" --from "$agent" --rpc-url "$RPC" 2>&1)
  case "$pre" in 0x*) ;; *) echo "  init REFUSED: $pre"; return 1 ;; esac
  cast send "$SFAC" 'cloneAndInit(address,address,address,bytes)' "$TPL" "$vault" "$agent" "$init" \
    --rpc-url "$RPC" --unlocked --from "$agent" >/dev/null 2>&1
  local clone; clone=$(num "$pre")
  cast send "$TIERS" 'setAdapterAllowed(address,bool)' "$clone" true \
    --rpc-url "$RPC" --unlocked --from "$DEPLOYER" >/dev/null 2>&1
  echo "  clone     $clone"
  echo "  attested  $(cast call "$TIERS" 'isAdapterAllowed(address)(bool)' "$clone" --rpc-url "$RPC")"
}

# The two-call execute batch and the one-call settlement batch every proposal
# carrying this template uses. Caps are `[0, assetIn]` — see gotcha 2.
#
# The proposer needs WOOD for the risk-scaled bond and an allowance to the
# escrow; `lockBond` pulls it inside `propose`.
cmd_propose() {
  local vault=$1 agent=$2 clone=$3 amount=$4 duration=$5 uri=$6
  local gov; gov=$(gov_of "$vault")
  local asset; asset=$(num "$(cast call "$vault" 'asset()(address)' --rpc-url "$RPC")")
  local escrow; escrow=$(a PROPOSER_BOND_ESCROW)
  cast send "$(a WOOD_TOKEN)" 'approve(address,uint256)' "$escrow" "$(cast max-uint)" \
    --rpc-url "$RPC" --unlocked --from "$agent" >/dev/null 2>&1
  local approve_cd; approve_cd=$(cast calldata 'approve(address,uint256)' "$clone" "$amount")
  cast send "$gov" "$PROPOSE_SIG" "$vault" "$clone" "$uri" "$duration" "($amount,10000)" \
    "[($asset,$approve_cd,0),($clone,0x61461954,0)]" "[0,$amount]" \
    "[($clone,0x11da60b4,0)]" "[0]" "[]" \
    --rpc-url "$RPC" --unlocked --from "$agent" >/dev/null 2>&1
  local pid; pid=$(num "$(cast call "$gov" 'proposalCount()(uint256)' --rpc-url "$RPC")")
  echo "  proposal  #$pid"
  cast call "$gov" 'getProposalView(uint256)((uint256,uint256,address,uint256,uint256,uint256))' "$pid" --rpc-url "$RPC"
}

# Vote FOR, warp to the review window, run the guardian half, warp past it,
# resolve, and re-freshen the feeds the warps just aged.
#
# THE WARPS ARE SPLIT ON PURPOSE, exactly as `guardian-review.sh` documents: a
# review only opens once `voteEnd` has passed and only accepts votes while it is
# open, so one 30-hour jump lands on an Approved proposal with ZERO booked
# coverage and `InsufficientApproveCoverage` at execute.
cmd_cycle() {
  local vault=$1 pid=$2 owner=$3; shift 3
  local gov; gov=$(gov_of "$vault")
  fund "$owner"
  # VoteType.For == 0. See gotcha 1.
  cast send "$gov" 'vote(uint256,uint8)' "$pid" 0 --rpc-url "$RPC" --unlocked --from "$owner" >/dev/null 2>&1
  local v; v=$(cast call "$gov" 'getProposalView(uint256)((uint256,uint256,address,uint256,uint256,uint256))' "$pid" --rpc-url "$RPC")
  local voteEnd reviewEnd
  voteEnd=$(echo "$v" | sed 's/[(),]/ /g' | awk '{print $1}')
  reviewEnd=$(echo "$v" | sed 's/[(),]/ /g' | awk '{print $3}')
  cmd_warp $((voteEnd + 7))
  RPC="$RPC" ./script/fork/guardian-review.sh approve "$vault" "$pid" "$@" | tail -1
  cmd_warp $((reviewEnd + 7))
  RPC="$RPC" ./script/fork/guardian-review.sh resolve "$vault" "$pid"
  echo "  state     $(cast call "$gov" 'getProposalState(uint256)(uint8)' "$pid" --rpc-url "$RPC")  (3 = Approved)"
  echo "  NOTE: run 'freshen' for every aggregator the venue reads before 'execute'."
}

cmd_execute() {
  local vault=$1 pid=$2 agent=$3
  local gov; gov=$(gov_of "$vault")
  cast send "$gov" 'executeProposal(uint256)' "$pid" \
    --rpc-url "$RPC" --unlocked --from "$agent" --gas-limit 12000000 2>&1 | grep -E '^status|revert|Error' | head -3
}

cmd_settle() {
  local vault=$1 pid=$2 agent=$3
  local gov; gov=$(gov_of "$vault")
  cast send "$gov" 'settleProposal(uint256)' "$pid" \
    --rpc-url "$RPC" --unlocked --from "$agent" --gas-limit 6000000 2>&1 | grep -E '^status|revert|Error' | head -3
}

# Everything the template freezes at execute, plus the two custody legs the
# claim and the residue machinery actually read.
cmd_status() {
  local c=$1
  local token; token=$(num "$(cast call "$c" 'launchToken()(address)' --rpc-url "$RPC")")
  echo "  launchToken   $token"
  echo "  launchRef     $(num "$(cast call "$c" 'launchRef()(bytes32)' --rpc-url "$RPC")")"
  echo "  reserve       $(num "$(cast call "$c" 'reserve()(uint256)' --rpc-url "$RPC")")"
  echo "  totalClaimed  $(num "$(cast call "$c" 'totalClaimed()(uint256)' --rpc-url "$RPC")")"
  echo "  snap          $(num "$(cast call "$c" 'snap()(uint256)' --rpc-url "$RPC")")"
  echo "  windowEnd     $(num "$(cast call "$c" 'windowEnd()(uint256)' --rpc-url "$RPC")")   (clamped: executedAt + strategyDuration - 5m)"
  echo "  anyoneSettle  $(num "$(cast call "$c" 'anyoneSettleAt()(uint256)' --rpc-url "$RPC")")"
  echo "  now           $(now_ts)"
  [ "$token" != "0x0000000000000000000000000000000000000000" ] && \
  echo "  supply/held   $(num "$(cast call "$token" 'totalSupply()(uint256)' --rpc-url "$RPC")") / $(num "$(cast call "$token" 'balanceOf(address)(uint256)' "$c" --rpc-url "$RPC")")"
  echo "  unvalued      $(cast call "$c" 'hasUnvaluedResidue()(bool)' --rpc-url "$RPC")   latched $(cast call "$c" 'residueLatched()(bool)' --rpc-url "$RPC")"
  echo "  undelivered   $(num "$(cast call "$c" 'undeliveredValue()(uint256)' --rpc-url "$RPC")")"
}

# `claimFor` pays the HOLDER, never the caller, so one keeper can sweep every
# holder in before the window shuts. Reads `claimable` first because that view
# is the only place a zero entitlement is visible without a revert — EXCEPT in
# the execute block, where `claimable` itself bubbles OZ's `ERC5805FutureLookup`
# (the guard that gives `claim()` its own `SnapshotNotFinal` is not on the view).
cmd_claim() {
  local c=$1; shift
  for h in "$@"; do
    local before; before=$(cast call "$c" 'claimable(address)(uint256)' "$h" --rpc-url "$RPC" 2>&1)
    if cast send "$c" 'claimFor(address)' "$h" --rpc-url "$RPC" --unlocked --from "$DEPLOYER" >/dev/null 2>&1; then
      echo "  claimed $(num "$before")  ->  $h"
    else
      echo "  REFUSED  $h  (claimable read: $before)"
    fi
  done
  echo "  totalClaimed $(num "$(cast call "$c" 'totalClaimed()(uint256)' --rpc-url "$RPC")") / reserve $(num "$(cast call "$c" 'reserve()(uint256)' --rpc-url "$RPC")")"
}

# `sweep()` is `onlyVault`; the vault drives it from `collectResidue`, which is
# permissionless and is also what credits the exited redeem cohort. Calling the
# clone's `sweep()` directly would push the same value and mis-account it.
cmd_sweep() {
  local vault=$1 clone=$2 caller=$3
  fund "$caller"
  cast send "$vault" 'collectResidue(address)' "$clone" \
    --rpc-url "$RPC" --unlocked --from "$caller" --gas-limit 3000000 2>&1 | grep -E '^status' | head -1
  echo "  latched       $(cast call "$clone" 'residueLatched()(bool)' --rpc-url "$RPC")"
  echo "  depositsLocked $(cast call "$vault" 'depositsLocked()(bool)' --rpc-url "$RPC")"
}

# Push accrued venue fees. PERMISSIONLESS and pays the launch's `feeRecipient`
# — the VAULT — whoever calls, so this asserts the RECIPIENT's delta and the
# caller's, not the return value: see the gas gotcha at the top, where a
# swallowed OOG reports success while moving nothing.
cmd_fees() {
  local adapter=$1 ref=$2 recipient=$3 token=$4 keeper=$5
  fund "$keeper"
  local r0 k0 r1 k1
  r0=$(num "$(cast call "$token" 'balanceOf(address)(uint256)' "$recipient" --rpc-url "$RPC")")
  k0=$(num "$(cast call "$token" 'balanceOf(address)(uint256)' "$keeper" --rpc-url "$RPC")")
  cast send "$adapter" 'collectFees(bytes32)' "$ref" \
    --rpc-url "$RPC" --unlocked --from "$keeper" --gas-limit 3000000 >/dev/null 2>&1
  r1=$(num "$(cast call "$token" 'balanceOf(address)(uint256)' "$recipient" --rpc-url "$RPC")")
  k1=$(num "$(cast call "$token" 'balanceOf(address)(uint256)' "$keeper" --rpc-url "$RPC")")
  echo "  recipient +$((r1 - r0))    keeper +$((k1 - k0))   (keeper MUST be 0)"
}

case "${1:-}" in
  freshen) shift; cmd_freshen "$@" ;;
  warp)    shift; cmd_warp "$@" ;;
  agent)   shift; cmd_agent "$@" ;;
  clone)   shift; cmd_clone "$@" ;;
  propose) shift; cmd_propose "$@" ;;
  cycle)   shift; cmd_cycle "$@" ;;
  execute) shift; cmd_execute "$@" ;;
  status)  shift; cmd_status "$@" ;;
  claim)   shift; cmd_claim "$@" ;;
  settle)  shift; cmd_settle "$@" ;;
  sweep)   shift; cmd_sweep "$@" ;;
  fees)    shift; cmd_fees "$@" ;;
  *) sed -n '2,95p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
