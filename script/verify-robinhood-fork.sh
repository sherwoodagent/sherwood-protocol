#!/usr/bin/env bash
# Post-deploy validation for the Robinhood-fork ceremony (chain 9994663).
#
# Reads chains/9994663.json and asserts, on-chain, every invariant the
# deployment spec's "Post-deploy validation reads" scenario names, plus the
# Plan B / Plan D / TokenCourt wiring the later phases are supposed to leave
# behind. Read-only: it sends no transactions and needs no admin RPC.
#
# The point is that an operator can run this against a vnet MINUTES OR WEEKS
# after the ceremony and get the same answer. A deploy log scrolls past; this
# re-derives the state.
#
# Required env:
#   RPC   the vnet endpoint (public RPC is enough — every call here is a read)
#
# Usage:
#   RPC=https://virtual.robinhood-chain.eu.rpc.tenderly.co/... ./script/verify-robinhood-fork.sh
set -uo pipefail
: "${RPC:?set RPC to the fork endpoint}"

cd "$(dirname "$0")/.."
BOOK="chains/9994663.json"
[ -f "$BOOK" ] || { echo "missing $BOOK"; exit 1; }

a() { python3 -c "import json,sys;print(json.load(open('$BOOK')).get(sys.argv[1],''))" "$1"; }

PASS=0; FAIL=0
# check <label> <actual> <expected>
check() {
  if [ "$(echo "$2" | tr 'A-Z' 'a-z')" = "$(echo "$3" | tr 'A-Z' 'a-z')" ]; then
    printf '  \033[32mok\033[0m   %-46s %s\n' "$1" "$2"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m %-46s got %s want %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  fi
}
call() { cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }

FACTORY=$(a SYNDICATE_FACTORY); BEACON=$(a GOVERNOR_BEACON); CONFIG=$(a PROTOCOL_CONFIG)
REGISTRY=$(a GUARDIAN_REGISTRY); SWOOD=$(a STAKED_WOOD); TIERS=$(a TIER_REGISTRY)
WOOD=$(a WOOD_TOKEN); SFACTORY=$(a STRATEGY_FACTORY); LEDGER=$(a EXPOSURE_LEDGER)
ESCROW=$(a PROPOSER_BOND_ESCROW); GAME=$(a CHALLENGE_GAME); COURT=$(a TOKEN_COURT)
WFEED=$(a WOOD_USD_FEED); DEPLOYER=$(a DEPLOYER)
ZERO=0x0000000000000000000000000000000000000000

echo "chain id: $(cast chain-id --rpc-url "$RPC")  (expect 9994663)"
check "chain id" "$(cast chain-id --rpc-url "$RPC")" "9994663"

echo; echo "── Core ──"
check "factory.beacon"                "$(call "$FACTORY" 'beacon()(address)')"          "$BEACON"
check "factory.protocolConfig"        "$(call "$FACTORY" 'protocolConfig()(address)')"  "$CONFIG"
check "factory.tierRegistry"          "$(call "$FACTORY" 'tierRegistry()(address)')"    "$TIERS"
check "factory.guardianRegistry"      "$(call "$FACTORY" 'guardianRegistry()(address)')" "$REGISTRY"
# Robinhood has neither an ENS/Durin registrar nor an ERC-8004 registry, so
# identity + subname registration are disabled by construction.
check "factory.ensRegistrar (disabled)" "$(call "$FACTORY" 'ensRegistrar()(address)')"  "$ZERO"
check "factory.agentRegistry (disabled)" "$(call "$FACTORY" 'agentRegistry()(address)')" "$ZERO"
# A beacon serving address(0) mints governors that are pure fallback.
BIMPL=$(call "$BEACON" 'implementation()(address)')
if [ "$BIMPL" != "$ZERO" ] && [ -n "$BIMPL" ]; then
  printf '  \033[32mok\033[0m   %-46s %s\n' "beacon.implementation non-zero" "$BIMPL"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m %-46s %s\n' "beacon.implementation non-zero" "$BIMPL"; FAIL=$((FAIL+1))
fi
check "swood.wood"                    "$(call "$SWOOD" 'wood()(address)')"              "$WOOD"
check "swood.registry"                "$(call "$SWOOD" 'registry()(address)')"          "$REGISTRY"
check "registry.reviewPeriod == 24h"  "$(call "$REGISTRY" 'reviewPeriod()(uint256)')"   "86400"
check "registry.blockQuorumBps == 30%" "$(call "$REGISTRY" 'blockQuorumBps()(uint256)')" "3000"
check "governorImpl.MIN_VOTING_PERIOD" "$(call "$BIMPL" 'MIN_VOTING_PERIOD()(uint256)')" "86400"
check "governorImpl.MIN_COOLDOWN_PERIOD" "$(call "$BIMPL" 'MIN_COOLDOWN_PERIOD()(uint256)')" "3600"
check "swood.maxSlashBps == 100%"     "$(call "$SWOOD" 'maxSlashBps()(uint256)')"       "10000"
check "swood.minSlashBps == 10%"      "$(call "$SWOOD" 'minSlashBps()(uint256)')"       "1000"

echo; echo "── Fee recipients (both legs seated; a zero leg silently pays the proposer) ──"
check "config.protocolFeeRecipient"   "$(call "$CONFIG" 'protocolFeeRecipient()(address)')"  "$DEPLOYER"
check "config.guardiansFeeRecipient"  "$(call "$CONFIG" 'guardiansFeeRecipient()(address)')" "$DEPLOYER"

echo; echo "── Strategy templates (the allowlist IS _templateKeys) ──"
for t in PORTFOLIO_TEMPLATE MORPHO_SUPPLY_TEMPLATE CONCENTRATED_LIQUIDITY_TEMPLATE; do
  check "strategyFactory.approved($t)" \
    "$(cast call "$SFACTORY" 'approvedTemplate(address)(bool)' "$(a $t)" --rpc-url "$RPC" 2>/dev/null)" "true"
done

echo; echo "── TierRegistry launch set (empty registry ⇒ every clone-init reverts) ──"
for c in UNISWAP_V3_POSITION_MANAGER UNISWAP_V3_FACTORY MORPHO_BLUE; do
  check "tiers.counterpartyAllowed($c)" \
    "$(cast call "$TIERS" 'isCounterpartyAllowed(address)(bool)' "$(a $c)" --rpc-url "$RPC" 2>/dev/null)" "true"
done

echo; echo "── Plan B ──"
check "swood.exposureLedger (exit gate armed)" "$(call "$SWOOD" 'exposureLedger()(address)')" "$LEDGER"
check "factory.exposureLedger"        "$(call "$FACTORY" 'exposureLedger()(address)')"   "$LEDGER"
check "factory.bondEscrow"            "$(call "$FACTORY" 'bondEscrow()(address)')"       "$ESCROW"
check "registry.exposureLedger"       "$(call "$REGISTRY" 'exposureLedger()(address)')"  "$LEDGER"
check "ledger.quorumTierThreshold == 0" "$(call "$LEDGER" 'quorumTierThreshold()(uint256)')" "0"
check "ledger.challengeWindow == 14d" "$(call "$LEDGER" 'challengeWindow()(uint256)')"   "1209600"
check "ledger.woodHaircutBps == 7000" "$(call "$LEDGER" 'woodHaircutBps()(uint256)')"    "7000"
# Delegation is deferred to v2 and the `StakedWoodDelegation` base was REMOVED
# pre-mainnet, so the shipped sWOOD carries no such selector at all. An absent
# selector is the passing state — code that does not exist cannot be enabled —
# so this asserts the call finds nothing, exactly as DeployPlanB's own
# `_delegationIsOn` probe does. A non-empty answer means a pre-removal impl is
# behind the proxy, which reopens the delegator-walkout hole.
DELEG=$(cast call "$SWOOD" 'delegationEnabled()(uint256)' --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}')
if [ -z "$DELEG" ] || [ "$DELEG" = "0" ]; then
  printf '  \033[32mok\033[0m   %-46s %s\n' "delegation off (selector absent)" "${DELEG:-no selector}"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m %-46s %s (delegator-walkout hole OPEN)\n' "delegation off" "$DELEG"; FAIL=$((FAIL+1))
fi
WPRICE=$(call "$LEDGER" 'woodPriceX8()(uint256)')
if [ -n "$WPRICE" ] && [ "$WPRICE" != "0" ]; then
  printf '  \033[32mok\033[0m   %-46s %s\n' "ledger.woodPriceX8 resolves" "$WPRICE"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m %-46s reverts or zero (NoWoodPrice)\n' "ledger.woodPriceX8 resolves"; FAIL=$((FAIL+1))
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

echo; echo "── TokenCourt ──"
check "game.court (ruling authority)" "$(call "$GAME" 'court()(address)')"               "$COURT"
check "court.challengeGame"           "$(call "$COURT" 'challengeGame()(address)')"      "$GAME"
check "court.stakedWood"              "$(call "$COURT" 'stakedWood()(address)')"         "$SWOOD"
# The referral window must be POSITIVE or every disputed challenge free-wins
# for the accused: autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout.
AS=$(call "$GAME" 'autoSlashDelay()(uint256)'); VW=$(call "$COURT" 'voteWindow()(uint256)')
FB=$(call "$COURT" 'FINALIZE_BUFFER()(uint256)'); DT=$(call "$GAME" 'disputeTimeout()(uint256)')
if [ $((AS+VW+FB)) -le "$DT" ]; then
  printf '  \033[32mok\033[0m   %-46s %s + %s + %s <= %s\n' "referral window positive" "$AS" "$VW" "$FB" "$DT"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m %-46s %s + %s + %s > %s\n' "referral window positive" "$AS" "$VW" "$FB" "$DT"; FAIL=$((FAIL+1))
fi
# Turnout is AGED weight while the floor's base is RAW stake, so a floor at or
# above the age floor is unclearable with all stake young.
PF=$(call "$COURT" 'participationFloorBps()(uint256)'); AF=$(call "$SWOOD" 'ageFloorBps()(uint256)')
if [ "$PF" -lt "$AF" ]; then
  printf '  \033[32mok\033[0m   %-46s %s < %s\n' "participationFloor < ageFloor" "$PF" "$AF"; PASS=$((PASS+1))
else
  printf '  \033[31mFAIL\033[0m %-46s %s >= %s (unclearable at launch)\n' "participationFloor < ageFloor" "$PF" "$AF"; FAIL=$((FAIL+1))
fi

echo; echo "── WOOD price source ──"
check "fork feed decimals == 8"       "$(call "$WFEED" 'decimals()(uint8)')"             "8"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%s checks passed, 0 failed\033[0m\n' "$PASS"
else
  printf '\033[31m%s passed, %s FAILED\033[0m\n' "$PASS" "$FAIL"; exit 1
fi
