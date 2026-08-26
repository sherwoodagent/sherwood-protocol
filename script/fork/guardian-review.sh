#!/usr/bin/env bash
# Drive the guardian review path on a Robinhood-fork vnet.
#
# THIS IS A TEST HARNESS, AND DELIBERATELY NOT A CLI OR SDK COMMAND. Voting on
# a review is the job of a LIVE guardian component — see
# `openspec/changes/autonomous-guardian-agent`, which is specced and not yet
# built. Shipping a `sherwood guardian vote` would put the protocol's
# human-vetoable safety layer behind a manual command and imply the review path
# is someone's console chore. It is not: it is a service that must be running.
#
# Until that service exists, the review path is unproven outside unit tests —
# the agent spec says exactly that — and this script is how the fork exercises
# it in the meantime. It signs nothing: every guardian action goes through
# `--unlocked` impersonation on the vnet admin RPC, so no key ever exists.
#
# THE WINDOW ORDERING IS THE WHOLE TRICK, and the reason a naive run fails:
#
#   propose ─ votingPeriod (24h) ─┬─ reviewPeriod (24h) ─┬─ executionWindow
#                                 │                      │
#                          openReview possible     resolveReview
#                          guardians vote HERE
#
# A review can only be opened once `voteEnd` has passed, and votes are only
# accepted while it is open. Warping 48h in one jump — past voting AND review
# together — leaves a proposal that reached `Approved` on governance but booked
# ZERO coverage, and it then dies at execute with `InsufficientApproveCoverage`.
# That is not a bug; it is the coverage quorum doing its job against a cohort
# that never showed up. Warp to the review window, run this, then warp again.
#
# COHORT COLLATERAL SCALES WITH APPROVERS x PROPOSALS, NOT PROPOSALS.
#
# `recordApproval` books a RESERVATION, not an allocation: each approver commits
# "the MOST this guardian could ever carry — the whole proposal, if every other
# approver walks away". So backing P concurrent proposals with A approvers each
# demands roughly A x P x need of cohort bond, not P x need.
#
# Measured on this fork: five concurrent 500-USDG proposals with six approvers
# apiece needed ~3.45M WOOD (6 x 5 x $500 at $0.004347). A 350k cohort — which
# comfortably covers ONE proposal — silently covered only two, and the other
# three booked nothing at all. That is the failure mode to watch: capacity
# exhaustion looks exactly like a stale price, because both end in an approval
# that landed while booking zero.
#
# `stake` and `reaffirm` are the two levers: raise the bond, then re-book the
# proposals that got nothing, while their reviews are still OPEN.
#
# A LIVE CHALLENGE IS A THIRD WAY TO GET ZERO. `file` freezes the accused
# cohort's coverage, and frozen capacity is capacity the next proposal cannot
# book — so a cohort that comfortably covered a proposal yesterday books
# NOTHING today, with no stale price and no obvious change. Same symptom
# (`requireApproveQuorum` reverting `0xf7448092` /
# `InsufficientApproveCoverage`), same recovery: `stake`, then `reaffirm`.
# Check `liveChallengeOf` before concluding the feed is at fault.
#
# Usage:
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh status  <vault> <proposalId>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh approve <vault> <proposalId> <guardian...>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh stake   <wood-amount> <guardian...>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh block   <vault> <proposalId> <guardian...>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh outcome <vault> <proposalId>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh slash-report <guardian...>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh resolve <vault> <proposalId>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh flush   <vault> <proposalId>
#   RPC=<vnet ADMIN rpc> ./script/fork/guardian-review.sh feed-maxdelay <seconds>   # fork-only
set -uo pipefail
: "${RPC:?set RPC to the vnet ADMIN endpoint (impersonation + cheats)}"

cd "$(dirname "$0")/../.."
BOOK="chains/9994663.json"
[ -f "$BOOK" ] || { echo "missing $BOOK"; exit 1; }
a() { python3 -c "import json,sys;print(json.load(open('$BOOK')).get(sys.argv[1],''))" "$1"; }

FACTORY=$(a SYNDICATE_FACTORY); REGISTRY=$(a GUARDIAN_REGISTRY)
LEDGER=$(a EXPOSURE_LEDGER);   SWOOD=$(a STAKED_WOOD); WOOD=$(a WOOD_TOKEN)

# `GuardianVoteType { None, Approve, Block }` — Approve is 1. Ordering matters:
# passing 0 reverts, and 2 is a BLOCK vote that slashes approvers.
VOTE_APPROVE=1
VOTE_BLOCK=2

num() { echo "$1" | sed 's/ .*//'; }
governor_of() { num "$(cast call "$FACTORY" 'governorOf(address)(address)' "$1" --rpc-url "$RPC" 2>/dev/null)"; }

# Reports coverage RAISED vs REQUIRED. `requireApproveQuorum` is a view that
# returns both, so this asks the exact question execute will ask — rather than
# re-deriving it from stake and price and hoping the arithmetic matches.
quorum() {
  local gov=$1 pid=$2 asset=$3 req=$4
  cast call "$LEDGER" 'requireApproveQuorum(address,uint256,address,uint256)(uint256,uint256)' \
    "$gov" "$pid" "$asset" "$req" --rpc-url "$RPC" 2>&1
}

cmd_status() {
  local vault=$1 pid=$2
  local gov; gov=$(governor_of "$vault")
  local asset; asset=$(num "$(cast call "$vault" 'asset()(address)' --rpc-url "$RPC")")
  echo "  vault      $vault"
  echo "  governor   $gov"
  echo "  opened     $(cast call "$REGISTRY" 'reviewOpened(address,uint256)(bool)' "$gov" "$pid" --rpc-url "$RPC" 2>/dev/null || echo '(no view)')"
  local wp; wp=$(num "$(cast call "$LEDGER" 'woodPriceX8()(uint256)' --rpc-url "$RPC")")
  local tg; tg=$(num "$(cast call "$SWOOD" 'totalGuardianStake()(uint256)' --rpc-url "$RPC")")
  python3 -c "
wp=$wp/1e8; tg=$tg/1e18
print(f'  WOOD price \${wp:.6f} (post-haircut) | cohort {tg:,.0f} WOOD = \${tg*wp:,.2f}')"
  echo "  quorum(raised, required): $(quorum "$gov" "$pid" "$asset" 0 | tr '\n' ' ')"
}

cmd_stake() {
  local amount=$1; shift
  local wei; wei=$(cast to-wei "$amount" ether)
  for g in "$@"; do
    # Approve then stake, both impersonated. `stakeAsGuardian` pulls WOOD via
    # transferFrom, so the allowance is not optional.
    cast send "$WOOD" 'approve(address,uint256)' "$SWOOD" "$wei" \
      --rpc-url "$RPC" --unlocked --from "$g" >/dev/null 2>&1
    if cast send "$SWOOD" 'stakeAsGuardian(uint256,uint256)' "$wei" 0 \
      --rpc-url "$RPC" --unlocked --from "$g" >/dev/null 2>&1; then
      echo "  staked $amount WOOD  $g"
    else
      echo "  FAILED to stake      $g"
    fi
  done
  echo "  cohort now: $(python3 -c "print(f'{$(num "$(cast call "$SWOOD" 'totalGuardianStake()(uint256)' --rpc-url "$RPC")")/1e18:,.0f}')") WOOD"
}

cmd_approve() {
  local vault=$1 pid=$2; shift 2
  local gov; gov=$(governor_of "$vault")

  # Idempotent on-chain (`openReview` returns early when already opened), so
  # this is safe to re-run; it is called here rather than assumed because a
  # review does not open itself when the voting period ends.
  if cast send "$REGISTRY" 'openReview(address,uint256)' "$gov" "$pid" \
      --rpc-url "$RPC" --unlocked --from "$(a DEPLOYER)" >/dev/null 2>&1; then
    echo "  review opened (or already was)"
  else
    echo "  openReview REFUSED — voting period has not ended, or the review is resolved"
    return 1
  fi

  local ok=0 fail=0
  for g in "$@"; do
    if cast send "$REGISTRY" 'voteOnProposal(address,uint256,uint8)' "$gov" "$pid" "$VOTE_APPROVE" \
        --rpc-url "$RPC" --unlocked --from "$g" >/dev/null 2>&1; then
      echo "  approved  $g"; ok=$((ok+1))
    else
      echo "  FAILED    $g  (not an active guardian, outside the window, or already voted)"; fail=$((fail+1))
    fi
  done
  echo "  $ok approved, $fail failed"
}

# Flush a proposal whose COMPUTED state is terminal but whose STORAGE still
# counts it as open. The governor resolves terminal states LAZILY — an expired
# proposal reads `Expired` from `proposalState` while `_openProposalCount` is
# still 1, so the vault refuses every new proposal with `VaultHasOpenProposal`
# and the campaign silently stalls with nothing obviously wrong. This is the
# call that reconciles the two.
#
# A GUARDIAN-BLOCKED PROPOSAL NEEDS THIS TOO. `Rejected` is terminal by the same
# lazy rule as `Expired`, so a review that resolves BLOCKED leaves the vault
# wedged exactly as an expiry does: the next `propose` reverts
# `VaultHasOpenProposal()` and nothing in that error names the block as the
# cause. Blocking a proposal is therefore two steps, not one — resolve, then
# flush — and the second is easy to forget precisely because the first
# succeeded.
# Re-book coverage for guardians who already voted Approve.
#
# WHY THIS IS NEEDED. `recordApproval` SWALLOWS a price failure by design — a
# `coverageUsd` revert must not take the approve vote down with it, or an
# unpriceable moment would make every review block-only. The cost is that the
# vote LANDS while booking nothing, and re-casting the same Approve is a no-op:
# the approval is spent, not deferred. A proposal can therefore carry a full
# slate of approvals and still die at execute with `InsufficientApproveCoverage`
# — which is exactly what a stale asset feed produces on a warped fork.
#
# The recovery is the vote-CHANGE path: Approve -> Block -> Approve. The
# Block->Approve leg calls `recordApproval` again, and with the price now
# readable it books. Both legs must land before the late-vote lockout (the final
# 10% of the review window).
#
# ONE GUARDIAN AT A TIME, deliberately: flipping the cohort to Block together
# would accumulate real block weight against `blockQuorumBps` and could resolve
# the review as BLOCKED, slashing the approvers this is trying to help.
cmd_reaffirm() {
  local vault=$1 pid=$2; shift 2
  local gov; gov=$(governor_of "$vault")
  local ok=0
  for g in "$@"; do
    cast send "$REGISTRY" 'voteOnProposal(address,uint256,uint8)' "$gov" "$pid" 2 \
      --rpc-url "$RPC" --unlocked --from "$g" >/dev/null 2>&1
    if cast send "$REGISTRY" 'voteOnProposal(address,uint256,uint8)' "$gov" "$pid" "$VOTE_APPROVE" \
        --rpc-url "$RPC" --unlocked --from "$g" >/dev/null 2>&1; then
      echo "  re-booked  $g"; ok=$((ok+1))
    else
      echo "  FAILED     $g  — may now be stuck on Block; check before the window closes"
    fi
  done
  echo "  $ok re-booked"
}

# Attest a freshly-minted strategy clone on the TierRegistry.
#
# THE BATCH IS GATED BY TARGET, NOT SELECTOR (issue #166). Every governor-batch
# sub-call is checked against `isAdapterAllowed` for the address it would reach
# with the vault's identity — so a portfolio proposal's leading
# `USDG.approve(clone, amount)` is refused as
# `DisallowedTransferTarget(USDG, 0x095ea7b3, clone)` until the CLONE is
# attested. Nothing about that names the clone as the missing piece, and it
# surfaces at EXECUTE, a full governance cycle after the proposal was written.
#
# THIS IS PER-PROPOSAL AND CANNOT BE PRE-SEEDED. A clone's address does not
# exist until the agent creates it, which is why `Deploy.s.sol` leaves
# per-clone `setAdapterAllowed` as a manual step. On a live chain it is a
# TierRegistry-owner transaction for every proposal — an operational
# commitment, not a one-time launch chore.
cmd_attest_clone() {
  local clone=$1
  local tiers; tiers=$(a TIER_REGISTRY)
  cast send "$tiers" 'setAdapterAllowed(address,bool)' "$clone" true \
    --rpc-url "$RPC" --unlocked --from "$(a DEPLOYER)" >/dev/null 2>&1 \
    && echo "  attested clone $clone" || echo "  FAILED to attest $clone"
}

cmd_flush() {
  local vault=$1 pid=$2
  local gov; gov=$(governor_of "$vault")
  cast send "$gov" 'resolveProposalState(uint256)' "$pid" \
    --rpc-url "$RPC" --unlocked --from "$(a DEPLOYER)" >/dev/null 2>&1 \
    && echo "  flushed #$pid on $vault" || echo "  flush refused for #$pid (not terminal yet?)"
}

# Widen the ledger's asset-feed staleness bound. FORK-ONLY, and a real
# weakening of a production control — stated plainly rather than buried.
#
# A fork traverses 24h vote + 24h review + 24h execute windows with
# `evm_increaseTime`, which ages every Chainlink answer by the same jump while
# the feeds themselves do not tick. Two or three cycles and `block.timestamp`
# runs days ahead of `updatedAt`, so `coverageUsd` reverts `StalePrice` and the
# approve quorum cannot even be READ, let alone met. The failure surfaces as an
# opaque 0x19abf40e from a view, several layers from the warp that caused it.
#
# On a live chain the feeds tick and this bound is a genuine safety property:
# `ASSET_FEED_MAX_DELAY` is sized against the governor's real lifecycle so a
# plausible outage pushes reads past staleness. Never widen it there.
cmd_feed_maxdelay() {
  local seconds=$1
  local usdg; usdg=$(a USDG)
  local feed; feed=$(a CHAINLINK_USDG_USD_FEED)
  cast send "$LEDGER" 'setAssetFeed(address,address,uint256)' "$usdg" "$feed" "$seconds" \
    --rpc-url "$RPC" --unlocked --from "$(a DEPLOYER)" >/dev/null 2>&1 \
    && echo "  asset-feed maxDelay -> ${seconds}s (fork accommodation)" \
    || echo "  FAILED to widen the asset-feed bound"
}

cmd_resolve() {
  local vault=$1 pid=$2
  local gov; gov=$(governor_of "$vault")
  cast send "$REGISTRY" 'resolveReview(address,uint256)' "$gov" "$pid" \
    --rpc-url "$RPC" --unlocked --from "$(a DEPLOYER)" >/dev/null 2>&1 \
    && echo "  resolved" || echo "  resolve refused (review window may not have ended)"
}

# Cast BLOCK votes, the half of the review path `approve` cannot reach.
#
# `GuardianVoteType.Block` is 2. Structurally it is the same call as approve —
# same open-review requirement, same late-vote lockout — but it accumulates
# `blockStakeWeight` instead of booking coverage, and the review resolves as
# BLOCKED once
#
#     blockStakeWeight * 10_000 >= blockQuorumBpsAtOpen * totalStakeAtOpen
#
# with both the quorum and the denominator read from the AT-OPEN envelope, not
# the live slots. So a cohort that stakes MORE after the review opens does not
# dilute the blockers, and an owner cannot move the bar mid-review.
#
# WHAT A BLOCK COSTS THE APPROVERS. On resolve, `slashGuardians` slashes every
# approver and BURNS the proceeds — WOOD `totalSupply` falls and nobody is paid.
# Blockers gain nothing on-chain; their reward is epoch-level, emitted as
# `BlockerAttributed` for Merkl to pick up off-chain.
#
# SEVERITY IS NOT VOTED. It is a deterministic quadratic ramp of block-side
# decisiveness, from `minSlashBps` at a bare-scraped quorum to `maxSlashBps` at
# `SUPERMAJORITY_BPS` — `_severityBps` in GuardianRegistry. The winning side
# does not choose the losers' penalty, so there is no severity to pass here and
# no median to compute.
#
# ORDER MATTERS AGAINST `reaffirm`. Both drive vote type 2. `reaffirm` flips one
# guardian at a time PRECISELY so accumulated block weight never crosses the
# quorum by accident; this command is the deliberate opposite. Do not mix them
# on the same review.
cmd_block() {
  local vault=$1 pid=$2; shift 2
  local gov; gov=$(governor_of "$vault")

  if cast send "$REGISTRY" 'openReview(address,uint256)' "$gov" "$pid" \
      --rpc-url "$RPC" --unlocked --from "$(a DEPLOYER)" >/dev/null 2>&1; then
    echo "  review opened (or already was)"
  else
    echo "  openReview REFUSED — voting period has not ended, or the review is resolved"
    return 1
  fi

  local ok=0 fail=0
  for g in "$@"; do
    if cast send "$REGISTRY" 'voteOnProposal(address,uint256,uint8)' "$gov" "$pid" "$VOTE_BLOCK" \
        --rpc-url "$RPC" --unlocked --from "$g" >/dev/null 2>&1; then
      echo "  BLOCKED   $g"; ok=$((ok+1))
    else
      echo "  FAILED    $g  (not an active guardian, outside the window, or already voted)"; fail=$((fail+1))
    fi
  done
  echo "  $ok blocked, $fail failed"
}

# Snapshot what a slash is supposed to move: each guardian's own stake, the
# cohort total, and the burn sink. Run it either side of `resolve`.
#
# WATCH THE SINK, NOT `totalSupply`. "Burned" here is a TRANSFER to
# `BURN_ADDRESS` (0x…dEaD), not an ERC20 `burn()` — `_burnWood` in StakedWood
# does `wood.transfer(BURN_ADDRESS, amount)` inside a try/catch, falling back to
# `_pendingBurn` if the token refuses. So `totalSupply` is UNCHANGED across a
# slash, and reading it is the natural way to conclude, wrongly, that no burn
# happened. The sink balance is the number that moves, and it should move by
# exactly the cohort-total drop.
cmd_slash_report() {
  local burn=0x000000000000000000000000000000000000dEaD
  echo "  burn sink         $(python3 -c "print(f'{$(num "$(cast call "$WOOD" 'balanceOf(address)(uint256)' "$burn" --rpc-url "$RPC")")/1e18:,.4f}')")"
  echo "  cohort total      $(python3 -c "print(f'{$(num "$(cast call "$SWOOD" 'totalGuardianStake()(uint256)' --rpc-url "$RPC")")/1e18:,.4f}')")"
  echo "  slash envelope    min $(num "$(cast call "$SWOOD" 'minSlashBps()(uint256)' --rpc-url "$RPC")") bps / max $(num "$(cast call "$SWOOD" 'maxSlashBps()(uint256)' --rpc-url "$RPC")") bps"
  for g in "$@"; do
    printf '  %s  own %s\n' "$g" \
      "$(python3 -c "print(f'{$(num "$(cast call "$SWOOD" 'guardianStake(address)(uint256)' "$g" --rpc-url "$RPC")")/1e18:,.4f}')")"
  done
}

# Read the review's committed outcome: 0 Unresolved, 1 Cleared, 2 Blocked.
cmd_outcome() {
  local vault=$1 pid=$2
  local gov; gov=$(governor_of "$vault")
  local o; o=$(num "$(cast call "$REGISTRY" 'outcomeOf(address,uint256)(uint8)' "$gov" "$pid" --rpc-url "$RPC" 2>&1)")
  case "$o" in
    0) echo "  outcome: Unresolved" ;;
    1) echo "  outcome: Cleared" ;;
    2) echo "  outcome: BLOCKED" ;;
    *) echo "  outcome: unreadable ($o)" ;;
  esac
}

case "${1:-}" in
  status)  shift; cmd_status "$@" ;;
  stake)   shift; cmd_stake "$@" ;;
  approve) shift; cmd_approve "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  flush)   shift; cmd_flush "$@" ;;
  block)   shift; cmd_block "$@" ;;
  outcome) shift; cmd_outcome "$@" ;;
  slash-report) shift; cmd_slash_report "$@" ;;
  reaffirm) shift; cmd_reaffirm "$@" ;;
  attest-clone) shift; cmd_attest_clone "$@" ;;
  feed-maxdelay) shift; cmd_feed_maxdelay "$@" ;;
  *) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
