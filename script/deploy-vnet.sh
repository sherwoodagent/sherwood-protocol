#!/usr/bin/env bash
# Full-stack Sherwood deploy to a Base-fork vnet (e.g. a Tenderly Virtual TestNet).
#
# Phases are ORDERED: Deploy writes the base address book, later phases patch
# into it. ScriptBase._writeAddresses now preserves existing keys, so re-runs
# and out-of-order static keys (ENS, templates) survive.
#
# Required env:
#   RPC_URL      vnet endpoint (Tenderly admin RPC)
#   DEPLOY_AUTH  forge auth flags, e.g.:
#                  --account deployer        (keystore)
#                  --private-key 0x...       (raw key)
#                  --unlocked --sender 0x... (vnet-funded unlocked account)
# Optional env:
#   WOOD_MINT    fixture WOOD minted to the deployer (default 100M)
#   LZ_ENDPOINT  LayerZero endpoint (default: canonical Base EndpointV2)
#
# Usage:
#   RPC_URL=https://virtual.base.rpc.tenderly.co/... \
#   DEPLOY_AUTH="--account deployer" \
#   ./script/deploy-vnet.sh
set -euo pipefail
: "${RPC_URL:?set RPC_URL to the vnet endpoint}"
: "${DEPLOY_AUTH:?set DEPLOY_AUTH (e.g. --account deployer, or --private-key 0x..)}"

cd "$(dirname "$0")/.." # -> contracts/

# Fork / beta posture: deployer keeps ownership (no multisig handoff) and the
# WOOD fixture is allowed. NEVER set these on a real mainnet deploy.
export SKIP_MULTISIG_HANDOFF=true ALLOW_FIXTURE_WOOD=true

run() {
  echo "──────── $1 ────────"
  # shellcheck disable=SC2086
  forge script "script/$1" --rpc-url "$RPC_URL" --broadcast --slow $DEPLOY_AUTH
}

run DeployWood.s.sol:DeployWood                       # fixture WOOD + mint
run Deploy.s.sol:DeploySherwood                       # core: factory/governor/registry/sWOOD/vault
run DeployPriceRouter.s.sol:DeployPriceRouter         # PriceRouter + Moonwell adapter + factory.setPriceRouter
run DeployTemplates.s.sol:DeployTemplates             # strategy templates
run DeployStrategyFactory.s.sol:DeployStrategyFactory # keyless-clone factory + template approvals

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo '<chainId>')"
echo
echo "Full stack deployed. Address book: contracts/chains/${CHAIN_ID}.json"
echo "Next: sync chains.json -> cli/src/lib/addresses.ts + sdk so the CLI/SDK can"
echo "      drive the vnet (STRATEGY_FACTORY, PRICE_ROUTER, STAKED_WOOD, WOOD_TOKEN)."
