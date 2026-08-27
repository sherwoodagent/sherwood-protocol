#!/usr/bin/env bash
#
# Verify the EAS deployment on Robinhood Chain via Blockscout's v2 API.
#
# `forge verify-contract --verifier blockscout` does NOT work reliably against
# this instance: it first fetches the contract ABI through the Etherscan-compat
# `/api` route, which is aggressively rate-limited (a Blockscout API key does not
# lift it — the limit appears to be IP-based), and it fails outright while the
# instance has not indexed the creation transaction. Contracts deployed via
# CREATE2 through the deterministic deployer are created in an INTERNAL
# transaction, so that indexing lag is the normal case for us.
#
# The v2 verification API has neither problem — it takes the standard-JSON input
# directly and does not need the address to be indexed first.
#
# Usage: script/verify-eas-blockscout.sh
set -euo pipefail

HOST=https://robinhoodchain.blockscout.com
EAS=0x7d70441Bb10AcE5d9771dc0b6205D89ddf63205B
REGISTRY=0xdd7521Ba10773e556Defa6D6c133cB2F663b5c26
# abi.encode(address schemaRegistry) — EAS's only constructor arg, unprefixed.
EAS_CTOR=000000000000000000000000dd7521ba10773e556defa6d6c133cb2f663b5c26
SOLC="v0.8.28+commit.7893614a"

verify() {
  local addr="$1" target="$2" name="$3" ctor="${4:-}"
  local json; json=$(mktemp)
  forge verify-contract "$addr" "$target" --compiler-version 0.8.28 --show-standard-json-input >"$json"

  local -a args=(
    -F "compiler_version=$SOLC"
    -F "contract_name=$name"          # bare contract name, NOT path:Name
    -F "license_type=mit"
    -F "files[0]=@$json;type=application/json"
  )
  if [ -n "$ctor" ]; then
    args+=(-F "autodetect_constructor_args=false" -F "constructor_args=$ctor")
  else
    args+=(-F "autodetect_constructor_args=false")
  fi

  echo "submitting $name ($addr)"
  curl -sS -m 120 -X POST "$HOST/api/v2/smart-contracts/$addr/verification/via/standard-input" \
    -H "Accept: application/json" "${args[@]}"
  echo
  rm -f "$json"
}

verify "$REGISTRY" lib/eas-contracts/contracts/SchemaRegistry.sol:SchemaRegistry SchemaRegistry
verify "$EAS"      lib/eas-contracts/contracts/EAS.sol:EAS                       EAS "$EAS_CTOR"

echo
echo "status (verification is async - re-run if still false):"
for a in "$REGISTRY" "$EAS"; do
  curl -sS -m 30 "$HOST/api/v2/smart-contracts/$a" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('  ',d.get('name'),'is_verified =',d.get('is_verified'))"
done
