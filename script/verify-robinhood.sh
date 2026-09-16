#!/usr/bin/env bash
# Post-deploy validation for the Robinhood ceremony, either posture.
#
# Re-DERIVES every protocol address from the CREATE3 factory
# (`addressOf(keccak256("sherwood.robinhood.v1.<name>"))`) instead of trusting
# chains/<chainid>.json, then asserts on-chain every invariant the deployment
# spec's "Post-deploy validation reads" scenario names, plus the Plan B / Plan D
# / TokenCourt wiring. A book key that disagrees with the derivation is itself a
# failure: the book is a record, the salts are the truth.
#
# Read-only: it sends no transactions and needs no admin RPC. An operator can
# run it MINUTES OR WEEKS after the ceremony and get the same answer.
#
# Posture comes from the chain id: 4663 is mainnet (owners are the Safe, the
# two-step half may still be pending acceptance), anything else is a fork
# (owners stay with the deployer and nothing is pending).
#
# Required env:
#   RPC   the endpoint (a public RPC is enough — every call here is a read)
#
# Usage:
#   RPC=https://rpc.mainnet.chain.robinhood.com ./script/verify-robinhood.sh 4663
#   RPC=https://virtual...tenderly.co/...       ./script/verify-robinhood.sh 9994663
set -uo pipefail
: "${RPC:?set RPC to the chain endpoint}"
CHAIN_ID="${1:?usage: RPC=<url> $0 <chainId>}"

cd "$(dirname "$0")/.."
BOOK="chains/$CHAIN_ID.json"
[ -f "$BOOK" ] || { echo "missing $BOOK"; exit 1; }

NS="sherwood.robinhood.v1."
ZERO=0x0000000000000000000000000000000000000000

a() { python3 -c "import json,sys;print(json.load(open('$BOOK')).get(sys.argv[1],''))" "$1"; }

PASS=0; FAIL=0
lc() { echo "$1" | tr 'A-Z' 'a-z'; }
ok()   { printf '  \033[32mok\033[0m   %-46s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %-46s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
# check <label> <actual> <expected>
check() {
  if [ "$(lc "$2")" = "$(lc "$3")" ]; then ok "$1" "$2"; else bad "$1" "got $2 want $3"; fi
}
call() { cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }
call1() { cast call "$1" "$2" "$3" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }

C3=$(a CREATE3_FACTORY)
[ -n "$C3" ] || { echo "$BOOK carries no CREATE3_FACTORY — nothing to derive from"; exit 1; }
# derive <salt name> — the ceremony's address for that salt, straight from the factory.
derive() { call1 "$C3" 'addressOf(bytes32)(address)' "$(cast keccak "${NS}$1")"; }
# book_matches <label> <bookKey> <derived> — a recorded key must equal the derivation.
book_matches() {
  local got; got=$(a "$2")
  if [ -z "$got" ]; then ok "$1 (not recorded)" "$3"; else check "$1" "$got" "$3"; fi
}

echo "chain id: $(cast chain-id --rpc-url "$RPC")  (expect $CHAIN_ID)"
check "chain id" "$(cast chain-id --rpc-url "$RPC")" "$CHAIN_ID"

if [ "$CHAIN_ID" = "4663" ]; then
  POSTURE=mainnet; FINAL=$(a OWNER_MULTISIG)
  [ -n "$FINAL" ] || { echo "mainnet posture needs OWNER_MULTISIG in $BOOK"; exit 1; }
else
  POSTURE=fork; FINAL=$(a DEPLOYER)
  [ -n "$FINAL" ] || { echo "fork posture needs DEPLOYER in $BOOK"; exit 1; }
fi
echo "posture: $POSTURE   final owner: $FINAL"

echo; echo "── Addresses re-derived from CREATE3 (book keys must agree) ──"
EXECUTOR=$(derive batch-executor-lib);      book_matches "BATCH_EXECUTOR_LIB"   BATCH_EXECUTOR_LIB   "$EXECUTOR"
VAULTIMPL=$(derive vault-impl);             book_matches "SYNDICATE_VAULT_IMPL" SYNDICATE_VAULT_IMPL "$VAULTIMPL"
CONFIG=$(derive protocol-config);           book_matches "PROTOCOL_CONFIG"      PROTOCOL_CONFIG      "$CONFIG"
BEACON=$(derive governor-beacon);           book_matches "GOVERNOR_BEACON"      GOVERNOR_BEACON      "$BEACON"
SWOOD=$(derive staked-wood-proxy);          book_matches "STAKED_WOOD"          STAKED_WOOD          "$SWOOD"
REGISTRY=$(derive guardian-registry-proxy); book_matches "GUARDIAN_REGISTRY"    GUARDIAN_REGISTRY    "$REGISTRY"
TIERS=$(derive tier-registry);              book_matches "TIER_REGISTRY"        TIER_REGISTRY        "$TIERS"
FACTORY=$(derive factory-proxy);            book_matches "SYNDICATE_FACTORY"    SYNDICATE_FACTORY    "$FACTORY"
ADAPTER=$(derive uniswap-swap-adapter);     book_matches "UNISWAP_SWAP_ADAPTER" UNISWAP_SWAP_ADAPTER "$ADAPTER"
PORTFOLIO=$(derive portfolio-template);     book_matches "PORTFOLIO_TEMPLATE"   PORTFOLIO_TEMPLATE   "$PORTFOLIO"
MORPHOT=$(derive morpho-supply-template);   book_matches "MORPHO_SUPPLY_TEMPLATE" MORPHO_SUPPLY_TEMPLATE "$MORPHOT"
CLT=$(derive concentrated-liquidity-template); book_matches "CONCENTRATED_LIQUIDITY_TEMPLATE" CONCENTRATED_LIQUIDITY_TEMPLATE "$CLT"
SFACTORY=$(derive strategy-factory);        book_matches "STRATEGY_FACTORY"     STRATEGY_FACTORY     "$SFACTORY"
LEDGER=$(derive exposure-ledger);           book_matches "EXPOSURE_LEDGER"      EXPOSURE_LEDGER      "$LEDGER"
ESCROW=$(derive proposer-bond-escrow);      book_matches "PROPOSER_BOND_ESCROW" PROPOSER_BOND_ESCROW "$ESCROW"
GAME=$(derive challenge-game);              book_matches "CHALLENGE_GAME"       CHALLENGE_GAME       "$GAME"
# Distinct salts, so a fork fixture can never be read as the mainnet feed.
if [ "$POSTURE" = "mainnet" ]; then WFEED=$(derive wood-pool-feed); else WFEED=$(derive fork-wood-feed-fixture); fi
book_matches "WOOD_USD_FEED" WOOD_USD_FEED "$WFEED"
# TokenCourt is a branch-specific mixin: an unrecorded court means it never shipped here.
COURT=$(a TOKEN_COURT)
[ -z "$COURT" ] || check "TOKEN_COURT" "$COURT" "$(derive token-court)"

WOOD=$(a WOOD_TOKEN)

echo; echo "── Core ──"
check "factory.beacon"                "$(call "$FACTORY" 'beacon()(address)')"          "$BEACON"
check "factory.protocolConfig"        "$(call "$FACTORY" 'protocolConfig()(address)')"  "$CONFIG"
check "factory.tierRegistry"          "$(call "$FACTORY" 'tierRegistry()(address)')"    "$TIERS"
check "factory.guardianRegistry"      "$(call "$FACTORY" 'guardianRegistry()(address)')" "$REGISTRY"
# v1 ships with identity gating OFF: both registrars are deliberately address(0).
check "factory.ensRegistrar (off in v1)" "$(call "$FACTORY" 'ensRegistrar()(address)')"  "$ZERO"
check "factory.agentRegistry (off in v1)" "$(call "$FACTORY" 'agentRegistry()(address)')" "$ZERO"
# A beacon serving address(0) mints governors that are pure fallback.
BIMPL=$(call "$BEACON" 'implementation()(address)')
if [ "$BIMPL" != "$ZERO" ] && [ -n "$BIMPL" ]; then
  ok "beacon.implementation non-zero" "$BIMPL"
else
  bad "beacon.implementation non-zero" "$BIMPL"
fi
check "swood.wood"                    "$(call "$SWOOD" 'wood()(address)')"              "$WOOD"
check "swood.registry"                "$(call "$SWOOD" 'registry()(address)')"          "$REGISTRY"
check "registry.reviewPeriod == 24h"  "$(call "$REGISTRY" 'reviewPeriod()(uint256)')"   "86400"
check "registry.blockQuorumBps == 30%" "$(call "$REGISTRY" 'blockQuorumBps()(uint256)')" "3000"
check "governorImpl.MIN_VOTING_PERIOD" "$(call "$BIMPL" 'MIN_VOTING_PERIOD()(uint256)')" "86400"
check "governorImpl.MIN_COOLDOWN_PERIOD" "$(call "$BIMPL" 'MIN_COOLDOWN_PERIOD()(uint256)')" "3600"
check "swood.maxSlashBps == 100%"     "$(call "$SWOOD" 'maxSlashBps()(uint256)')"       "10000"
check "swood.minSlashBps == 10%"      "$(call "$SWOOD" 'minSlashBps()(uint256)')"       "1000"

echo; echo "── Ownership ($POSTURE) ──"
# One-step Ownable: the transfer is final the moment the ceremony sends it.
for pair in "beacon:$BEACON" "factory:$FACTORY" "registry:$REGISTRY" "swood:$SWOOD" "strategyFactory:$SFACTORY"; do
  check "${pair%%:*}.owner" "$(call "${pair#*:}" 'owner()(address)')" "$FINAL"
done
# Ownable2Step: `transferOwnership` only ARMS the move; the Safe must accept. Either
# state is a pass on mainnet — armed-but-unaccepted is exactly where a fresh ceremony
# ends — but on a fork nothing may be pending at all.
two_step() {
  local label="$1" target="$2" own pend
  own=$(call "$target" 'owner()(address)'); pend=$(call "$target" 'pendingOwner()(address)')
  if [ "$POSTURE" = "mainnet" ]; then
    if [ "$(lc "$own")" = "$(lc "$FINAL")" ]; then ok "$label.owner (accepted)" "$own"
    elif [ "$(lc "$pend")" = "$(lc "$FINAL")" ]; then ok "$label.pendingOwner (awaiting accept)" "$pend"
    else bad "$label ownership" "owner $own pending $pend want $FINAL"; fi
  else
    check "$label.owner" "$own" "$FINAL"
    check "$label.pendingOwner (none)" "$pend" "$ZERO"
  fi
}
two_step "config" "$CONFIG"
two_step "tiers" "$TIERS"
two_step "ledger" "$LEDGER"
two_step "game" "$GAME"
[ -z "$COURT" ] || two_step "court" "$COURT"

echo; echo "── Fee recipients (both legs seated; a zero leg silently pays the proposer) ──"
for leg in protocolFeeRecipient guardiansFeeRecipient; do
  R=$(call "$CONFIG" "$leg()(address)")
  if [ -n "$R" ] && [ "$R" != "$ZERO" ]; then ok "config.$leg non-zero" "$R"; else bad "config.$leg non-zero" "$R"; fi
done

echo; echo "── Strategy templates (the allowlist IS _templateKeys) ──"
APPROVED=0
for t in "$PORTFOLIO" "$MORPHOT" "$CLT"; do
  [ "$(call1 "$SFACTORY" 'approvedTemplate(address)(bool)' "$t")" = "true" ] && APPROVED=$((APPROVED+1))
done
check "strategyFactory approvals == 3" "$APPROVED" "3"
check "tiers.strategyFactory"         "$(call "$TIERS" 'strategyFactory()(address)')"   "$SFACTORY"
check "tiers.counterpartyAllowed(adapter)" "$(call1 "$TIERS" 'isCounterpartyAllowed(address)(bool)' "$ADAPTER")" "true"

echo; echo "── TierRegistry launch set (empty registry ⇒ every clone-init reverts) ──"
for c in UNISWAP_V3_POSITION_MANAGER UNISWAP_V3_FACTORY MORPHO_BLUE; do
  check "tiers.counterpartyAllowed($c)" "$(call1 "$TIERS" 'isCounterpartyAllowed(address)(bool)' "$(a $c)")" "true"
done

echo; echo "── Plan B ──"
check "swood.exposureLedger (exit gate armed)" "$(call "$SWOOD" 'exposureLedger()(address)')" "$LEDGER"
check "factory.exposureLedger"        "$(call "$FACTORY" 'exposureLedger()(address)')"   "$LEDGER"
check "factory.bondEscrow"            "$(call "$FACTORY" 'bondEscrow()(address)')"       "$ESCROW"
check "registry.exposureLedger"       "$(call "$REGISTRY" 'exposureLedger()(address)')"  "$LEDGER"
check "ledger.challengeWindow == 14d" "$(call "$LEDGER" 'challengeWindow()(uint256)')"   "1209600"
check "ledger.woodHaircutBps == 5000" "$(call "$LEDGER" 'woodHaircutBps()(uint256)')"    "5000"
# Delegation is deferred to v2 and the `StakedWoodDelegation` base was REMOVED
# pre-mainnet, so the shipped sWOOD carries no such selector at all. An absent
# selector is the passing state — code that does not exist cannot be enabled —
# so this asserts the call finds nothing, exactly as DeployPlanB's own
# `_delegationIsOn` probe does. A non-empty answer means a pre-removal impl is
# behind the proxy, which reopens the delegator-walkout hole.
DELEG=$(call "$SWOOD" 'delegationEnabled()(uint256)')
if [ -z "$DELEG" ] || [ "$DELEG" = "0" ]; then
  ok "delegation off (selector absent)" "${DELEG:-no selector}"
else
  bad "delegation off" "$DELEG (delegator-walkout hole OPEN)"
fi
WPRICE=$(call "$LEDGER" 'woodPriceX8()(uint256)')
if [ -n "$WPRICE" ] && [ "$WPRICE" != "0" ]; then
  ok "ledger.woodPriceX8 resolves" "$WPRICE"
else
  bad "ledger.woodPriceX8 resolves" "reverts or zero (NoWoodPrice)"
fi
check "ledger.protocolConfig.maxStrategyDuration" "$(call "$CONFIG" 'maxStrategyDuration()(uint256)')" "2592000"

echo; echo "── Plan D: the three roles, all on THIS game ──"
check "ledger.coverageFreezer"        "$(call "$LEDGER" 'coverageFreezer()(address)')"   "$GAME"
check "tiers.authorizedDemoter"       "$(call "$TIERS" 'authorizedDemoter()(address)')"  "$GAME"
check "swood.authorizedSlasher"       "$(call "$SWOOD" 'authorizedSlasher()(address)')"  "$GAME"
check "game.stakedWood (reciprocal)"  "$(call "$GAME" 'stakedWood()(address)')"          "$SWOOD"
check "game.exposureLedger"           "$(call "$GAME" 'exposureLedger()(address)')"      "$LEDGER"
check "game.tierRegistry"             "$(call "$GAME" 'tierRegistry()(address)')"        "$TIERS"
check "game.challengeWindow == ledger" "$(call "$GAME" 'challengeWindow()(uint256)')"    "$(call "$LEDGER" 'challengeWindow()(uint256)')"

if [ -n "$COURT" ]; then
echo; echo "── TokenCourt ──"
check "game.court (ruling authority)" "$(call "$GAME" 'court()(address)')"               "$COURT"
check "court.challengeGame"           "$(call "$COURT" 'challengeGame()(address)')"      "$GAME"
check "court.stakedWood"              "$(call "$COURT" 'stakedWood()(address)')"         "$SWOOD"
# The referral window must be POSITIVE or every disputed challenge free-wins
# for the accused: autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout.
AS=$(call "$GAME" 'autoSlashDelay()(uint256)'); VW=$(call "$COURT" 'voteWindow()(uint256)')
FB=$(call "$COURT" 'FINALIZE_BUFFER()(uint256)'); DT=$(call "$GAME" 'disputeTimeout()(uint256)')
if [ $((AS+VW+FB)) -le "$DT" ]; then
  ok "referral window positive" "$AS + $VW + $FB <= $DT"
else
  bad "referral window positive" "$AS + $VW + $FB > $DT"
fi
# Turnout is AGED weight while the floor's base is RAW stake, so a floor at or
# above the age floor is unclearable with all stake young.
PF=$(call "$COURT" 'participationFloorBps()(uint256)'); AF=$(call "$SWOOD" 'ageFloorBps()(uint256)')
if [ "$PF" -lt "$AF" ]; then
  ok "participationFloor < ageFloor" "$PF < $AF"
else
  bad "participationFloor < ageFloor" "$PF >= $AF (unclearable at launch)"
fi
fi

echo; echo "── WOOD price source ──"
check "feed decimals == 8"            "$(call "$WFEED" 'decimals()(uint8)')"             "8"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%s checks passed, 0 failed\033[0m\n' "$PASS"
else
  printf '\033[31m%s passed, %s FAILED\033[0m\n' "$PASS" "$FAIL"; exit 1
fi
