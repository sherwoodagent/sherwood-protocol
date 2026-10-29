#!/usr/bin/env bash
# Post-deploy validation for the Robinhood ceremony.
#
# Re-DERIVES every protocol address — the CREATE3 factory from its CREATE2 initcode,
# everything else from `addressOf(keccak256("sherwood.robinhood.v1.<name>"))` — instead
# of trusting chains/<chainid>.json, then asserts on-chain every invariant the deployment
# spec's "Post-deploy validation reads" scenario names, plus the Plan B / Plan D
# / TokenCourt wiring. A book key that disagrees with the derivation is itself a
# failure: the book is a record, the salts are the truth.
#
# Expected VALUES are read from the repo, never typed here: numbers from
# RobinhoodParams.sol, defaults the ceremony never sets from their src/ initialisers,
# the TierRegistry launch set from RobinhoodParams.launchSetSymbols() and
# script/Deploy.s.sol, external addresses from the book. A value that cannot be read
# or parsed is a FAILURE, never a skip.
#
# Read-only: every chain read is `cast call`, `cast storage` or `cast code`. It sends no
# transactions, needs no key and no admin RPC. An operator can run it MINUTES OR WEEKS
# after the ceremony and get the same answer.
#
# MODE is required: who SHOULD own the protocol is not something the chain can say.
#   deferred  the v1 launch posture. The deployer key still owns every contract, nothing
#             is armed, filings are paused, and the book's OWNER_MULTISIG is the deployer.
#   done      the handoff is finished. The book's OWNER_MULTISIG is a contract (the Safe),
#             not the deployer; it owns every contract, every two-step transfer has been
#             ACCEPTED, and neither fee leg pays the deployer.
# A fork (any chain id but 4663) owns itself and runs `deferred` only.
#
# Required env:
#   RPC   the endpoint (a public RPC is enough — every call here is a read)
#
# Needs `forge` and `python3` on PATH, run from a built repo: the CREATE3 factory's
# address is derived from its compiled initcode, and the ledger's feed slots from the
# compiled storage layout.
#
# Usage:
#   RPC=https://rpc.mainnet.chain.robinhood.com ./script/verify-robinhood.sh 4663 deferred
#   RPC=https://rpc.mainnet.chain.robinhood.com ./script/verify-robinhood.sh 4663 done
#   RPC=https://virtual...tenderly.co/...       ./script/verify-robinhood.sh 9994663 deferred
set -uo pipefail

usage() {
  echo "usage: RPC=<url> $0 <chainId> <deferred|done>" >&2
  echo "  deferred  the deployer still owns everything (the v1 launch posture)" >&2
  echo "  done      the Safe owns everything and every two-step handoff is accepted" >&2
  exit 2
}
: "${RPC:?set RPC to the chain endpoint}"
CHAIN_ID="${1:-}"
MODE="${2:-}"
[ -n "$CHAIN_ID" ] || usage
case "$MODE" in deferred | done) ;; *) usage ;; esac
if [ "$CHAIN_ID" = "4663" ]; then POSTURE=mainnet; else POSTURE=fork; fi
if [ "$POSTURE" = "fork" ] && [ "$MODE" = "done" ]; then
  echo "chain $CHAIN_ID is a fork: it owns itself and never hands off, so only 'deferred' applies" >&2
  exit 2
fi

cd "$(dirname "$0")/.." || exit 1
BOOK="chains/$CHAIN_ID.json"
[ -f "$BOOK" ] || { echo "missing $BOOK"; exit 1; }
PARAMS_SOL=script/robinhood-mainnet/RobinhoodParams.sol
CORE_SOL=script/Deploy.s.sol

NS="sherwood.robinhood.v1."
ZERO=0x0000000000000000000000000000000000000000
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

# Source readers. Every one exits non-zero (and prints nothing on stdout) when the shape
# it parses has moved, so a refactor of the Solidity turns the dependent checks red.
PYHELP=$(
  cat <<'PY'
import ast, json, re, sys

UNITS = {"seconds": 1, "minutes": 60, "hours": 3600, "days": 86400, "weeks": 604800}
OPS = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
       ast.Div: lambda a, b: a // b, ast.Pow: lambda a, b: a ** b}

def src(path):
    text = re.sub(r"/\*.*?\*/", "", open(path).read(), flags=re.S)
    return re.sub(r"//[^\n]*", "", text)

def ev(expr, names):
    """A Solidity integer constant expression: literals, units, other constants, + - * / **."""
    e = re.sub(r"(?<=\d)_(?=\d)", "", expr.strip())
    e = re.sub(r"\b(\d+)e(\d+)\b", r"(\1*10**\2)", e)
    e = re.sub(r"\b(\d+)\s+(seconds|minutes|hours|days|weeks)\b",
               lambda m: "(%s*%d)" % (m.group(1), UNITS[m.group(2)]), e)
    def walk(n):
        if isinstance(n, ast.Constant) and type(n.value) is int:
            return n.value
        if isinstance(n, ast.Name) and type(names.get(n.id)) is int:
            return names[n.id]
        if isinstance(n, ast.BinOp) and type(n.op) in OPS:
            return OPS[type(n.op)](walk(n.left), walk(n.right))
        raise ValueError("cannot evaluate %r" % expr)
    return walk(ast.parse(e, mode="eval").body)

def params(path):
    names = {}
    decl = r"\b(uint\d*|address)\s+internal\s+constant\s+([A-Za-z0-9_]+)\s*=\s*([^;]+);"
    for typ, name, expr in re.findall(decl, src(path)):
        expr = expr.strip()
        if typ == "address":
            if re.fullmatch(r"0x[0-9a-fA-F]{40}", expr):
                names[name] = expr
            continue
        try:
            names[name] = ev(expr, names)
        except (ValueError, SyntaxError):
            pass
    if not names:
        sys.exit("no constants parsed from " + path)
    for k, v in names.items():
        print("%s=%s" % (k, v))

def default(path, var):
    m = re.search(r"\b(?:uint\d*|bool)\s+public\s+%s\s*=\s*([^;]+);" % re.escape(var), src(path))
    if not m:
        sys.exit("no initialiser for %s in %s" % (var, path))
    print(ev(m.group(1), {}))

def launchset(path):
    m = re.search(r"function\s+launchSetSymbols\b.*?string\[(\d+)\].*?return\s*\[(.*?)\]\s*;", src(path), re.S)
    if not m:
        sys.exit("launchSetSymbols() not found in " + path)
    syms = re.findall(r'"([A-Za-z0-9]+)"', m.group(2))
    if len(syms) != int(m.group(1)) or len(set(syms)) != len(syms):
        sys.exit("launchSetSymbols(): %d symbols for string[%s]" % (len(syms), m.group(1)))
    print("\n".join(syms))

def notoken(path):
    m = re.search(r"function\s+_hasNoTokenOnRobinhood\b[^{]*\{(.*?)\n\s*\}", src(path), re.S)
    syms = re.findall(r'keccak256\("([A-Za-z0-9]+)"\)', m.group(1)) if m else []
    if not syms:
        sys.exit("_hasNoTokenOnRobinhood() not found in " + path)
    print("\n".join(syms))

def counterparties(path):
    keys = re.findall(r'_seedCounterparty\(\s*tierRegistry\s*,\s*"([A-Z0-9_]+)"\s*\)', src(path))
    if not keys:
        sys.exit("no _seedCounterparty calls in " + path)
    print("\n".join(keys))

def layout():
    """`forge inspect ExposureLedger storageLayout --json` on stdin -> the two feed slots."""
    d = json.load(sys.stdin)
    st = {s["label"]: s for s in d["storage"]}
    wf, af = st["_woodFeed"], st["_assetFeeds"]
    if wf["offset"] != 0 or d["types"][af["type"]].get("value") != wf["type"]:
        sys.exit("_woodFeed / _assetFeeds no longer share the AssetFeed struct")
    mem = {m["label"]: m for m in d["types"][wf["type"]]["members"]}
    out = [wf["slot"], af["slot"]]
    for label in ("feed", "maxDelay"):
        m = mem[label]
        if m["slot"] != "0":
            sys.exit("AssetFeed.%s left the first word" % label)
        out += [str(m["offset"]), d["types"][m["type"]]["numberOfBytes"]]
    print(" ".join(out))

def unpack(word, *spec):
    """A 32-byte word -> fields, given (offset bytes, size bytes, address|uint) triples."""
    v = int(word, 16)
    out = []
    for off, size, kind in zip(spec[0::3], spec[1::3], spec[2::3]):
        x = (v >> (8 * int(off))) & ((1 << (8 * int(size))) - 1)
        out.append("0x%040x" % x if kind == "address" else str(x))
    print(" ".join(out))

cmd = sys.argv[1]
fns = {"params": params, "default": default, "launchset": launchset, "notoken": notoken,
       "counterparties": counterparties, "layout": layout, "unpack": unpack}
try:
    fns[cmd](*sys.argv[2:])
except (KeyError, ValueError, OSError, IndexError, TypeError) as e:
    sys.exit("%s: %r" % (cmd, e))
PY
)
py() { python3 -c "$PYHELP" "$@"; }

a() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$BOOK" "$1"; }
PARAMS=$(py params "$PARAMS_SOL") || { echo "could not parse $PARAMS_SOL"; exit 1; }
# param <NAME> — a RobinhoodParams constant, evaluated; empty when absent (and then every
# check comparing against it fails).
param() { printf '%s\n' "$PARAMS" | sed -n "s/^$1=//p"; }
# src_default <file> <var> — the initialiser of a state variable the ceremony never sets.
src_default() { py default "$1" "$2" 2>/dev/null; }

if [ -t 1 ]; then GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; OFF=$'\033[0m'; else GRN=; RED=; YEL=; OFF=; fi
PASS=0; FAIL=0; WARN=0
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
ok()   { printf '  %sok%s   %-52s %s\n' "$GRN" "$OFF" "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s %-52s %s\n' "$RED" "$OFF" "$1" "$2"; FAIL=$((FAIL+1)); }
warn() { printf '  %sWARN%s %-52s %s\n' "$YEL" "$OFF" "$1" "$2"; WARN=$((WARN+1)); }
info() { printf '  info %-52s %s\n' "$1" "$2"; }
is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
# same <a> <b> — both non-empty and equal, case-insensitively.
same() { [ -n "$1" ] && [ -n "$2" ] && [ "$(lc "$1")" = "$(lc "$2")" ]; }
# check <label> <actual> <expected>. An unreadable EXPECTED value is a failure too:
# two empty strings are equal, and that equality would score a missing source as a pass.
check() {
  if [ -z "$3" ]; then bad "$1" "got '$2', expected value unreadable"
  elif same "$2" "$3"; then ok "$1" "$2"
  else bad "$1" "got ${2:-<unread>} want $3"; fi
}
# check_range <label> <actual> <lo> <hi> — inclusive, for an OPERATING value the owner
# tunes. Pinning a literal here goes stale the first time the owner moves it, and a check
# that is always red gets ignored; the bound is what the contract itself enforces.
check_range() {
  for n in "$2" "$3" "$4"; do
    is_uint "$n" || { bad "$1" "unread (got '$2', bounds '$3'..'$4')"; return; }
  done
  if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then ok "$1" "$2 (in $3..$4)"; else bad "$1" "$2 outside $3..$4"; fi
}
call() { cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }
call1() { cast call "$1" "$2" "$3" --rpc-url "$RPC" 2>/dev/null | head -1 | awk '{print $1}'; }
# Each code is read once; output that is not 0x-hex is a failed read and scores as a failure, never a pass.
code_of() { local c; c=$(cast code "$1" --rpc-url "$RPC" 2>/dev/null); [[ "$c" =~ ^0x[0-9a-fA-F]*$ ]] && echo "$c"; }
has_code() { local c; c=$(code_of "$1"); [ -n "$c" ] && [ "$c" != "0x" ]; }
# impl_of <proxy> — the ERC-1967 implementation slot, as an address.
impl_of() {
  local w; w=$(cast storage "$1" "$IMPL_SLOT" --rpc-url "$RPC" 2>/dev/null)
  [[ "$w" =~ ^0x[0-9a-fA-F]{64}$ ]] && echo "0x${w:26}"
}
# answer_of <aggregator> — latestRoundData's answer, empty when it reverts.
answer_of() {
  cast call "$1" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" 2>/dev/null \
    | sed -n 2p | awk '{print $1}'
}
# in_list <word> <newline- or space-separated list>
in_list() { case " $(echo "$2" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac; return 1; }

# The factory address is DERIVED, not read: taking it from the book would make every
# derivation below self-consistent against whatever factory the book happens to name.
# initcode = Create3Factory creationCode ++ abi.encode(DEPLOYER), minted through CREATE2.
DEPLOYER=$(a DEPLOYER)
[ -n "$DEPLOYER" ] || { echo "$BOOK carries no DEPLOYER — the factory address cannot be derived"; exit 1; }
CREATE2_DEPLOYER=0x4e59b44847b379578588920cA78FbF26c0B4956C
C3_INIT=$(cast concat-hex \
  "$(forge inspect Create3Factory bytecode 2>/dev/null)" \
  "$(cast abi-encode 'x(address)' "$DEPLOYER")")
[ "${#C3_INIT}" -gt 100 ] || { echo "could not compile Create3Factory — run this from a built repo"; exit 1; }
C3_SALT=$(cast keccak "${NS}create3-factory")
C3="0x$(cast keccak "$(cast concat-hex 0xff "$CREATE2_DEPLOYER" "$C3_SALT" "$(cast keccak "$C3_INIT")")" | cut -c27-)"
echo "create3 factory (derived): $C3"
# derive <salt name> — the ceremony's address for that salt, straight from the factory.
derive() { call1 "$C3" 'addressOf(bytes32)(address)' "$(cast keccak "${NS}$1")"; }
# book_matches <label> <bookKey> <derived> — a recorded key must equal the derivation. An
# ABSENT key is a FAILURE: `_persist` writes every one of them, so a gap means the book is
# not the book this deployment wrote, and scoring it a pass made an empty book all-green.
book_matches() {
  local got; got=$(a "$2")
  if [ -z "$got" ]; then bad "$1" "not recorded in $BOOK (expected ${3:-<underivable>})"; else check "$1" "$got" "$3"; fi
}

echo "chain id: $(cast chain-id --rpc-url "$RPC")  (expect $CHAIN_ID)"
check "chain id" "$(cast chain-id --rpc-url "$RPC")" "$CHAIN_ID"
book_matches "CREATE3_FACTORY (book == derived)" CREATE3_FACTORY "$C3"

echo; echo "── Mode: $MODE ($POSTURE) ──"
BOOK_OWNER=$(a OWNER_MULTISIG)
if [ "$MODE" = "deferred" ]; then
  FINAL=$DEPLOYER
  # The deferred-handoff marker deploy.sh itself requires. A book naming a Safe says the
  # handoff ran, which is `done` mode's question, not this one's.
  if same "$BOOK_OWNER" "$DEPLOYER" || { [ "$POSTURE" = "fork" ] && [ -z "$BOOK_OWNER" ]; }; then
    ok "book OWNER_MULTISIG is the deployer (deferred)" "${BOOK_OWNER:-absent (fork)}"
  else
    bad "book OWNER_MULTISIG is the deployer (deferred)" "book names '${BOOK_OWNER:-<absent>}': handed off? run 'done'"
  fi
else
  FINAL=$BOOK_OWNER
  if [ -z "$FINAL" ]; then
    bad "book OWNER_MULTISIG recorded" "absent"; FINAL=$ZERO
  elif same "$FINAL" "$DEPLOYER"; then
    bad "OWNER_MULTISIG != DEPLOYER" "the book names the deployer: nothing was handed off"
  else
    ok "OWNER_MULTISIG != DEPLOYER" "$FINAL"
  fi
  if has_code "$FINAL"; then
    ok "OWNER_MULTISIG holds code (a Safe, not an EOA)" "$FINAL"
  else
    bad "OWNER_MULTISIG holds code (a Safe, not an EOA)" "no code at $FINAL"
  fi
fi
echo "  expected owner of every admin role: $FINAL"

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
# Fail closed: `_persist` writes TOKEN_COURT on every completed run, so an absent key is a
# broken book, not a court that "never shipped". The court checks below run either way.
COURT=$(derive token-court);                book_matches "TOKEN_COURT"          TOKEN_COURT          "$COURT"
# Distinct salts, so a fork fixture can never be read as the mainnet feed.
if [ "$POSTURE" = "mainnet" ]; then WFEED=$(derive wood-pool-feed); else WFEED=$(derive fork-wood-feed-fixture); fi
book_matches "WOOD_USD_FEED" WOOD_USD_FEED "$WFEED"
# SHE-398: the V3 TWAP feed replaces WOOD_USD_FEED at the ledger once minted. Code at its
# salt with no book key is as much a broken book as the reverse.
TWAP_FEED=$(derive wood-v3-twap-feed)
if [ -n "$(a WOOD_USD_TWAP_FEED)" ] || has_code "$TWAP_FEED"; then
  HAS_TWAP=1; book_matches "WOOD_USD_TWAP_FEED" WOOD_USD_TWAP_FEED "$TWAP_FEED"
else
  HAS_TWAP=0
fi

WOOD=$(a WOOD_TOKEN)

echo; echo "── Implementations (ERC-1967 slot / beacon == the derived impl salt) ──"
# The registry and the beacon serve the `-30m` impls `LowerTimingFloors` minted (2026-10-14):
# RobinhoodParams' 30-minute floors live only there, so the original `governor-impl` /
# `guardian-registry-impl` behind either proxy is a rollback, and a FAILURE.
BIMPL=$(call "$BEACON" 'implementation()(address)')
check "beacon.implementation == governor-impl-30m"  "$BIMPL"                "$(derive governor-impl-30m)"
check "swood impl == staked-wood-impl"              "$(impl_of "$SWOOD")"    "$(derive staked-wood-impl)"
check "registry impl == guardian-registry-impl-30m" "$(impl_of "$REGISTRY")" "$(derive guardian-registry-impl-30m)"
check "factory impl == factory-impl"                "$(impl_of "$FACTORY")"  "$(derive factory-impl)"

echo; echo "── Core ──"
check "factory.beacon"                "$(call "$FACTORY" 'beacon()(address)')"          "$BEACON"
check "factory.protocolConfig"        "$(call "$FACTORY" 'protocolConfig()(address)')"  "$CONFIG"
check "factory.tierRegistry"          "$(call "$FACTORY" 'tierRegistry()(address)')"    "$TIERS"
check "factory.guardianRegistry"      "$(call "$FACTORY" 'guardianRegistry()(address)')" "$REGISTRY"
check "factory.executorImpl"          "$(call "$FACTORY" 'executorImpl()(address)')"    "$EXECUTOR"
check "factory.vaultImpl"             "$(call "$FACTORY" 'vaultImpl()(address)')"       "$VAULTIMPL"
check "factory.managementFeeBps"      "$(call "$FACTORY" 'managementFeeBps()(uint256)')" "$(param MANAGEMENT_FEE_BPS)"
# Identity gating: the factory's registry is whatever the BOOK says, so the runbook's
# ERC-8004 incident remedy (setAgentRegistry(0), with the book key set to zero alongside)
# stays green; the book drifting from RobinhoodParams is loud but not red.
AGENT_REG=$(a AGENT_REGISTRY)
if [ -z "$AGENT_REG" ]; then
  bad "factory.agentRegistry == book AGENT_REGISTRY" "AGENT_REGISTRY not recorded in $BOOK"
else
  check "factory.agentRegistry == book AGENT_REGISTRY" "$(call "$FACTORY" 'agentRegistry()(address)')" "$AGENT_REG"
  same "$AGENT_REG" "$(param AGENT_REGISTRY)" \
    || warn "book AGENT_REGISTRY == RobinhoodParams" "book $AGENT_REG, params $(param AGENT_REGISTRY) (incident remedy?)"
fi
# Limited-launch posture, set in run 1. These fail once the Safe opens the launch — update them then.
check "factory.depositsRestricted"    "$(call "$FACTORY" 'depositsRestricted()(bool)')"  "true"
check "factory.ownerOnlyProposals"    "$(call "$FACTORY" 'ownerOnlyProposals()(bool)')"  "true"
check "factory.creationFee == INVITE_ONLY_CREATION_FEE" "$(call "$FACTORY" 'creationFee()(uint256)')" "$(param INVITE_ONLY_CREATION_FEE)"
check "factory.creationFeeToken == WOOD" "$(call "$FACTORY" 'creationFeeToken()(address)')" "$WOOD"
check "factory.creationFeeRecipient"  "$(call "$FACTORY" 'creationFeeRecipient()(address)')" "$FINAL"
# Vault upgrades are off at launch; nothing in the ceremony turns them on.
check "factory.upgradesEnabled (off)" "$(call "$FACTORY" 'upgradesEnabled()(bool)')"     "false"
# The sponsorship mapping cannot be enumerated. What can be asserted: the getter answers
# (an impl without the sponsorship path reads empty, which fails), and no admin key holds
# an unspent single-use fee waiver.
check "factory.creationSponsored(deployer) (none)" "$(call1 "$FACTORY" 'creationSponsored(address)(bool)' "$DEPLOYER")" "false"
if [ "$MODE" = "done" ]; then
  check "factory.creationSponsored(Safe) (none)" "$(call1 "$FACTORY" 'creationSponsored(address)(bool)' "$FINAL")" "false"
fi
check "registry.factory"              "$(call "$REGISTRY" 'factory()(address)')"        "$FACTORY"
check "registry.swood"                "$(call "$REGISTRY" 'swood()(address)')"          "$SWOOD"
check "swood.wood"                    "$(call "$SWOOD" 'wood()(address)')"              "$WOOD"
check "swood.registry"                "$(call "$SWOOD" 'registry()(address)')"          "$REGISTRY"
check "registry.minReviewPeriod == MIN_REVIEW_PERIOD" "$(call "$REGISTRY" 'minReviewPeriod()(uint256)')" "$(param MIN_REVIEW_PERIOD)"
# The operating window, bounded by what `setReviewPeriod` enforces: the impl's floor below,
# and sWOOD's guardian cooldown (capped at the 3d ceiling) above, so an approver can never
# unstake and escape the slash before `resolveReview`.
REVIEW_FLOOR=$(call "$REGISTRY" 'minReviewPeriod()(uint256)')
REVIEW_COOLDOWN=$(call "$SWOOD" 'coolDownPeriod()(uint256)')
REVIEW_CEIL=259200
if is_uint "$REVIEW_COOLDOWN" && [ "$REVIEW_COOLDOWN" -lt "$REVIEW_CEIL" ]; then REVIEW_CEIL="$REVIEW_COOLDOWN"; fi
check_range "registry.reviewPeriod within bounds" "$(call "$REGISTRY" 'reviewPeriod()(uint256)')" "$REVIEW_FLOOR" "$REVIEW_CEIL"
check "registry.blockQuorumBps == BLOCK_QUORUM_BPS" "$(call "$REGISTRY" 'blockQuorumBps()(uint256)')" "$(param BLOCK_QUORUM_BPS)"
check "governorImpl.MIN_VOTING_PERIOD"   "$(call "$BIMPL" 'MIN_VOTING_PERIOD()(uint256)')"   "$(param MIN_VOTING_PERIOD)"
check "governorImpl.MIN_COOLDOWN_PERIOD" "$(call "$BIMPL" 'MIN_COOLDOWN_PERIOD()(uint256)')" "$(param MIN_COOLDOWN_PERIOD)"
check "swood.maxSlashBps == MAX_SLASH_BPS" "$(call "$SWOOD" 'maxSlashBps()(uint256)')"       "$(param MAX_SLASH_BPS)"
check "swood.minSlashBps == MIN_SLASH_BPS" "$(call "$SWOOD" 'minSlashBps()(uint256)')"       "$(param MIN_SLASH_BPS)"
check "swood.coolDownPeriod == COOLDOWN"   "$REVIEW_COOLDOWN"                                "$(param COOLDOWN)"
check "swood.maturationPeriod == MATURATION" "$(call "$SWOOD" 'maturationPeriod()(uint256)')" "$(param MATURATION)"
check "swood.minGuardianStake == MIN_GUARDIAN_STAKE" "$(call "$SWOOD" 'minGuardianStake()(uint256)')" "$(param MIN_GUARDIAN_STAKE)"
check "swood.ageFloorBps == AGE_FLOOR_BPS" "$(call "$SWOOD" 'ageFloorBps()(uint256)')"       "$(param AGE_FLOOR_BPS)"
# An operating value with a deliberate 0 sentinel (open onboarding), so printed, not pinned.
info "swood.minOwnerStake (0 = open onboarding)" "$(call "$SWOOD" 'minOwnerStake()(uint256)') (seeded $(param MIN_OWNER_STAKE))"

echo; echo "── Ownership ($MODE: every admin role names $FINAL) ──"
# One-step Ownable: the transfer is final the moment it is sent.
for pair in "beacon:$BEACON" "factory:$FACTORY" "registry:$REGISTRY" "swood:$SWOOD" "strategyFactory:$SFACTORY"; do
  check "${pair%%:*}.owner" "$(call "${pair#*:}" 'owner()(address)')" "$FINAL"
done
# Ownable2Step: `transferOwnership` only ARMS the move. Neither mode leaves one armed:
# deferred has sent nothing, and done means the Safe has ACCEPTED every one.
two_step() {
  local label="$1" target="$2" own pend
  own=$(call "$target" 'owner()(address)'); pend=$(call "$target" 'pendingOwner()(address)')
  check "$label.owner" "$own" "$FINAL"
  if same "$pend" "$ZERO"; then ok "$label.pendingOwner (none)" "$pend"
  elif [ -n "$pend" ]; then bad "$label.pendingOwner (none)" "$pend is armed and has not called acceptOwnership()"
  else bad "$label.pendingOwner (none)" "unread"; fi
}
two_step "config" "$CONFIG"
two_step "tiers" "$TIERS"
two_step "ledger" "$LEDGER"
two_step "game" "$GAME"
two_step "court" "$COURT"
# NOT handed off by design (runbook): the deployer keeps the Create3Factory, in both modes.
check "create3Factory.owner (deployer keeps it)" "$(call "$C3" 'owner()(address)')" "$DEPLOYER"

echo; echo "── Fee recipients (seated, and not the deployer key) ──"
# A zero leg silently pays the proposer; a deployer leg pays a team key.
for leg in protocolFeeRecipient guardiansFeeRecipient; do
  R=$(call "$CONFIG" "$leg()(address)")
  if [ -z "$R" ] || same "$R" "$ZERO"; then
    bad "config.$leg seated" "${R:-unread}"
  elif ! same "$R" "$DEPLOYER"; then
    ok "config.$leg seated, not the deployer" "$R"
  elif [ "$MODE" = "deferred" ] && [ "$leg" = "guardiansFeeRecipient" ]; then
    # The ceremony seeds both legs to the deployer as a placeholder and the runbook moves
    # this one in the Safe's turn, which the deferred handoff skips. Loud, not red, here.
    warn "config.$leg not the deployer" "$R is the deployer placeholder (FAIL in done mode)"
  else
    bad "config.$leg not the deployer" "$R is the deployer key"
  fi
done

echo; echo "── Protocol fee router (SHE-239: the protocol leg must not pay a team key) ──"
ROUTER=$(derive protocol-fee-router)
PFR=$(call "$CONFIG" 'protocolFeeRecipient()(address)')
RCODE=""; [ -z "$ROUTER" ] || RCODE=$(code_of "$ROUTER")
if [ -z "$RCODE" ]; then
  bad "PROTOCOL_FEE_ROUTER code read" "derive or cast code failed for '$ROUTER'"
elif [ "$RCODE" = "0x" ]; then
  if [ -n "$(a PROTOCOL_FEE_ROUTER)" ]; then
    bad "PROTOCOL_FEE_ROUTER holds code" "book names $(a PROTOCOL_FEE_ROUTER), nothing at $ROUTER"
  elif [ "$POSTURE" = "mainnet" ]; then
    bad "fee router minted and seated" "nothing at $ROUTER; protocol leg pays $PFR"
  else
    warn "fee router not deployed (fork)" "protocol leg pays $PFR"
  fi
else
  book_matches "PROTOCOL_FEE_ROUTER" PROTOCOL_FEE_ROUTER "$ROUTER"
  RHASH=$(cast keccak "$RCODE")
  PINNED=$(grep -A1 'PROTOCOL_FEE_ROUTER_RUNTIME_HASH =' script/DeploySalts.sol | grep -o '0x[0-9a-f]\{64\}')
  check "router codehash == DeploySalts pin" "$RHASH" "$PINNED"
  check "router codehash == forge inspect" "$RHASH" \
    "$(cast keccak "$(forge inspect ProtocolFeeRouter deployedBytecode 2>/dev/null | tail -1)")"
  check "config.protocolFeeRecipient == router" "$PFR" "$ROUTER"
  RO=$(call "$ROUTER" 'owner()(address)')
  if [ -n "$RO" ] && has_code "$RO" && ! same "$RO" "$DEPLOYER"; then
    ok "router.owner is a contract, not the deployer" "$RO"
  else
    bad "router.owner is a contract, not the deployer" "owner '$RO'"
  fi
  # The router is minted straight to the Safe, so once the handoff is done the two agree.
  if [ "$MODE" = "done" ]; then check "router.owner == OWNER_MULTISIG" "$RO" "$FINAL"; fi
  check "router.pendingOwner (none)" "$(call "$ROUTER" 'pendingOwner()(address)')" "$ZERO"
fi

echo; echo "── Strategy templates (the allowlist IS _templateKeys) ──"
APPROVED=0
for t in "$PORTFOLIO" "$MORPHOT" "$CLT"; do
  [ "$(call1 "$SFACTORY" 'approvedTemplate(address)(bool)' "$t")" = "true" ] && APPROVED=$((APPROVED+1))
done
check "strategyFactory approvals == 3" "$APPROVED" "3"
check "tiers.strategyFactory"         "$(call "$TIERS" 'strategyFactory()(address)')"   "$SFACTORY"
check "tiers.counterpartyAllowed(adapter)" "$(call1 "$TIERS" 'isCounterpartyAllowed(address)(bool)' "$ADAPTER")" "true"

echo; echo "── TierRegistry launch set (from $CORE_SOL + launchSetSymbols(); empty ⇒ every clone-init reverts) ──"
CPS=$(py counterparties "$CORE_SOL") || bad "launch-set counterparties parsed" "no _seedCounterparty calls in $CORE_SOL"
for c in $CPS; do
  check "tiers.counterpartyAllowed($c)" "$(call1 "$TIERS" 'isCounterpartyAllowed(address)(bool)' "$(a "$c")")" "true"
done
# The pairing `_seedPriceSource` makes, symbol by symbol: the feed allowlisted, and paired
# to its token as the bare aggregator widened to bytes32. A symbol with no token in the
# book is tolerated only when `_hasNoTokenOnRobinhood` names it, exactly as the seed does.
NOTOKEN=$(py notoken "$CORE_SOL") || bad "no-token symbols parsed" "_hasNoTokenOnRobinhood not found in $CORE_SOL"
if SYMS=$(py launchset "$PARAMS_SOL"); then
  ok "launch set parsed from RobinhoodParams" "$(echo "$SYMS" | wc -l | tr -d ' ') symbols"
else
  bad "launch set parsed from RobinhoodParams" "launchSetSymbols() unreadable"; SYMS=""
fi
for s in $SYMS; do
  feed=$(a "CHAINLINK_${s}_USD_FEED")
  if [ -z "$feed" ]; then bad "launch set $s" "CHAINLINK_${s}_USD_FEED not in $BOOK"; continue; fi
  tk=$s; [ "$s" = "ETH" ] && tk=WETH
  token=$(a "$tk")
  allowed=$(call1 "$TIERS" 'isCounterpartyAllowed(address)(bool)' "$feed")
  if [ -z "$token" ]; then
    if in_list "$s" "$NOTOKEN"; then check "launch set $s: feed allowlisted (no token here)" "$allowed" "true"
    else bad "launch set $s" "$tk not in $BOOK and not a _hasNoTokenOnRobinhood symbol"; fi
    continue
  fi
  paired=$(cast call "$TIERS" 'isPriceSourceForToken(address,bytes32)(bool)' "$token" \
    "$(cast abi-encode 'x(address)' "$feed")" --rpc-url "$RPC" 2>/dev/null | head -1)
  if [ "$allowed" = "true" ] && [ "$paired" = "true" ]; then
    ok "launch set $s: feed allowlisted + paired" "$feed -> $tk"
  else
    bad "launch set $s: feed allowlisted + paired" "allowed '${allowed:-unread}' paired '${paired:-unread}'"
  fi
done
# Mainnet only: the vetted USDG/spUSDG market deploy.sh allowlists after run 2. Without
# it the approved Morpho template has nothing it may supply into.
if [ "$POSTURE" = "mainnet" ]; then
  MARKET=$(sed -n 's/^MORPHO_USDG_MARKET=\(0x[0-9a-fA-F]\{64\}\).*/\1/p' script/robinhood-mainnet/deploy.sh)
  if [ -z "$MARKET" ]; then
    bad "Morpho market id parsed" "no MORPHO_USDG_MARKET in script/robinhood-mainnet/deploy.sh"
  else
    check "tiers.isMorphoMarketAllowed(USDG/spUSDG)" "$(call1 "$TIERS" 'isMorphoMarketAllowed(bytes32)(bool)' "$MARKET")" "true"
  fi
fi

echo; echo "── Plan B ──"
check "swood.exposureLedger (exit gate armed)" "$(call "$SWOOD" 'exposureLedger()(address)')" "$LEDGER"
check "factory.exposureLedger"        "$(call "$FACTORY" 'exposureLedger()(address)')"   "$LEDGER"
check "factory.bondEscrow"            "$(call "$FACTORY" 'bondEscrow()(address)')"       "$ESCROW"
check "registry.exposureLedger"       "$(call "$REGISTRY" 'exposureLedger()(address)')"  "$LEDGER"
check "ledger.guardianRegistry"       "$(call "$LEDGER" 'guardianRegistry()(address)')"  "$REGISTRY"
check "ledger.epochLength == EPOCH_LENGTH" "$(call "$LEDGER" 'epochLength()(uint256)')"  "$(param EPOCH_LENGTH)"
check "ledger.challengeWindow == EXPECTED_CHALLENGE_WINDOW" "$(call "$LEDGER" 'challengeWindow()(uint256)')" "$(param EXPECTED_CHALLENGE_WINDOW)"
check "ledger.woodHaircutBps == WOOD_HAIRCUT_BPS" "$(call "$LEDGER" 'woodHaircutBps()(uint256)')" "$(param WOOD_HAIRCUT_BPS)"
check "ledger.coveredTvlCapUsd == COVERED_TVL_CAP_USD18" "$(call "$LEDGER" 'coveredTvlCapUsd()(uint256)')" "$(param COVERED_TVL_CAP_USD18)"
# Never set by the ceremony, so the contract's own default is the expected value.
check "ledger.kNumerator (src default)" "$(call "$LEDGER" 'kNumerator()(uint256)')" "$(src_default src/ExposureLedger.sol kNumerator)"
check "ledger.proposerBondBps (src default)" "$(call "$LEDGER" 'proposerBondBps()(uint256)')" "$(src_default src/ExposureLedger.sol proposerBondBps)"
# The feeds have no getter: read both AssetFeed words straight from storage, at the slots
# and offsets the compiled layout names.
LAYOUT=$(forge inspect ExposureLedger storageLayout --json 2>/dev/null | py layout)
read -r WF_SLOT AF_SLOT FEED_OFF FEED_LEN DELAY_OFF DELAY_LEN <<<"$LAYOUT"
# feed_cfg <slot> — "<feed> <maxDelay>" from one AssetFeed word, empty on a failed read.
feed_cfg() {
  local w
  is_uint "${DELAY_LEN:-}" && [ -n "$1" ] || return 0
  w=$(cast storage "$LEDGER" "$1" --rpc-url "$RPC" 2>/dev/null)
  [[ "$w" =~ ^0x[0-9a-fA-F]{64}$ ]] || return 0
  py unpack "$w" "$FEED_OFF" "$FEED_LEN" address "$DELAY_OFF" "$DELAY_LEN" uint
}
[ -n "$LAYOUT" ] || bad "ExposureLedger storage layout" "forge inspect failed: the feed checks below cannot pass"
if [ "$HAS_TWAP" = 1 ]; then
  WANT_WF=$TWAP_FEED; WANT_WD=$(param WOOD_TWAP_FEED_MAX_DELAY); WF_KEY=WOOD_USD_TWAP_FEED
else
  WANT_WF=$WFEED; WANT_WD=$(param WOOD_FEED_MAX_DELAY); WF_KEY=WOOD_USD_FEED
fi
read -r GOT_WF GOT_WD <<<"$(feed_cfg "${WF_SLOT:-}")"
check "ledger WOOD feed == $WF_KEY"   "${GOT_WF:-}" "$WANT_WF"
check "ledger WOOD feed maxDelay"     "${GOT_WD:-}" "$WANT_WD"
USDG=$(a USDG)
USDG_SLOT=""; [ -n "$USDG" ] && is_uint "${AF_SLOT:-}" && USDG_SLOT=$(cast index address "$USDG" "$AF_SLOT")
read -r GOT_AF GOT_AD <<<"$(feed_cfg "$USDG_SLOT")"
check "ledger USDG feed == CHAINLINK_USDG_USD_FEED" "${GOT_AF:-}" "$(a CHAINLINK_USDG_USD_FEED)"
check "ledger USDG feed maxDelay == ASSET_FEED_MAX_DELAY" "${GOT_AD:-}" "$(param ASSET_FEED_MAX_DELAY)"
# The cap bounds upward manipulation, so it must sit ABOVE what the wired feed reports (a
# cap below market binds permanently and makes the feed inert), and the runbook re-seats it
# at 2x once the feed falls below cap / 2.5. Read against the feed the ledger actually reads.
CAP=$(call "$LEDGER" 'woodUsdPriceX8()(uint256)')
WANSWER=""; [ -n "${GOT_WF:-}" ] && WANSWER=$(answer_of "$GOT_WF")
if ! is_uint "$CAP" || [ "$CAP" = "0" ]; then
  bad "ledger.woodUsdPriceX8 (cap) seated" "${CAP:-unread} (0 halts every price read)"
elif ! is_uint "$WANSWER" || [ "$WANSWER" = "0" ]; then
  bad "ledger's WOOD feed answers" "'${WANSWER}' from ${GOT_WF:-<unread>}: cap band unchecked"
else
  RATIO=$(awk -v c="$CAP" -v f="$WANSWER" 'BEGIN { printf "%.2fx", c / f }')
  if [ "$CAP" -ge "$WANSWER" ]; then ok "cap >= feed (it does not bind)" "cap $CAP feed $WANSWER ($RATIO)"
  else bad "cap >= feed (it does not bind)" "cap $CAP feed $WANSWER ($RATIO): bonds are pinned at the cap"; fi
  if [ "$((CAP * 10))" -le "$((WANSWER * 25))" ]; then ok "cap <= 2.5x feed" "cap $CAP feed $WANSWER ($RATIO)"
  else bad "cap <= 2.5x feed" "cap $CAP feed $WANSWER ($RATIO): re-seat at 2x with setWoodUsdPrice"; fi
fi
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
if is_uint "$WPRICE" && [ "$WPRICE" != "0" ]; then
  ok "ledger.woodPriceX8 resolves" "$WPRICE"
else
  bad "ledger.woodPriceX8 resolves" "reverts or zero (NoWoodPrice)"
fi
check "config.maxStrategyDuration == MAX_STRATEGY_DURATION" "$(call "$CONFIG" 'maxStrategyDuration()(uint256)')" "$(param MAX_STRATEGY_DURATION)"
# Every live governor carries the factory's wiring. A vault created between run 1 and
# run 2 would be minted unwired; the closed registry sentinel prevents it, this re-reads it.
NSYN=$(call "$FACTORY" 'syndicateCount()(uint256)')
is_uint "$NSYN" || { bad "factory.syndicateCount" "unreadable (governor wiring NOT checked)"; NSYN=0; }
for ((i = 1; i <= NSYN; i++)); do
  SVAULT=$(cast call "$FACTORY" 'syndicates(uint256)(uint256,address,address,string,uint256,bool,string)' "$i" \
    --rpc-url "$RPC" 2>/dev/null | sed -n 2p | awk '{print $1}')
  SGOV=$(call1 "$FACTORY" 'governorOf(address)(address)' "$SVAULT")
  check "governor #$i.exposureLedger"   "$(call "$SGOV" 'exposureLedger()(address)')"    "$LEDGER"
  check "governor #$i.bondEscrow"       "$(call "$SGOV" 'bondEscrow()(address)')"        "$ESCROW"
  check "governor #$i.tierRegistry"     "$(call "$SGOV" 'tierRegistry()(address)')"      "$TIERS"
done

echo; echo "── Plan D: the three roles, all on THIS game ──"
check "ledger.coverageFreezer"        "$(call "$LEDGER" 'coverageFreezer()(address)')"   "$GAME"
check "tiers.authorizedDemoter"       "$(call "$TIERS" 'authorizedDemoter()(address)')"  "$GAME"
check "swood.authorizedSlasher"       "$(call "$SWOOD" 'authorizedSlasher()(address)')"  "$GAME"
check "game.stakedWood (reciprocal)"  "$(call "$GAME" 'stakedWood()(address)')"          "$SWOOD"
check "game.exposureLedger"           "$(call "$GAME" 'exposureLedger()(address)')"      "$LEDGER"
check "game.tierRegistry"             "$(call "$GAME" 'tierRegistry()(address)')"        "$TIERS"
check "game.challengeWindow == ledger" "$(call "$GAME" 'challengeWindow()(uint256)')"    "$(call "$LEDGER" 'challengeWindow()(uint256)')"
# Never set by the ceremony: the bond and the three burns are the contract's defaults.
for p in challengerBondBps forfeitBurnBps settleBurnBps inconclusiveBurnBps; do
  check "game.$p (src default)" "$(call "$GAME" "$p()(uint256)")" "$(src_default src/ChallengeGame.sol "$p")"
done
# Beta posture (SHE-352): filings stay paused until the juror reserve is 30 days old. Both
# modes: lifting it is SHE-361's call, not the handoff's. Update this check when it lands.
check "game.filingsPaused (beta posture)" "$(call "$GAME" 'filingsPaused()(bool)')"      "true"

echo; echo "── TokenCourt ──"
check "game.court (ruling authority)" "$(call "$GAME" 'court()(address)')"               "$COURT"
check "court.challengeGame"           "$(call "$COURT" 'challengeGame()(address)')"      "$GAME"
check "court.stakedWood"              "$(call "$COURT" 'stakedWood()(address)')"         "$SWOOD"
# The referral window must be POSITIVE or every disputed challenge free-wins for the
# accused. Same sum as DeployTokenCourt._wireCourt, MIN_REFERRAL_SLACK included:
# autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK <= disputeTimeout.
AS=$(call "$GAME" 'autoSlashDelay()(uint256)'); VW=$(call "$COURT" 'voteWindow()(uint256)')
FB=$(call "$COURT" 'FINALIZE_BUFFER()(uint256)'); SL=$(call "$GAME" 'MIN_REFERRAL_SLACK()(uint256)')
DT=$(call "$GAME" 'disputeTimeout()(uint256)')
if ! is_uint "$AS" || ! is_uint "$VW" || ! is_uint "$FB" || ! is_uint "$SL" || ! is_uint "$DT"; then
  bad "referral window positive" "unread: '$AS' '$VW' '$FB' '$SL' '$DT'"
elif [ $((AS + VW + FB + SL)) -le "$DT" ]; then
  ok "referral window positive" "$AS + $VW + $FB + $SL <= $DT"
else
  bad "referral window positive" "$AS + $VW + $FB + $SL > $DT"
fi
# Turnout is AGED weight while the floor's base is RAW stake, so a floor at or
# above the age floor is unclearable with all stake young.
PF=$(call "$COURT" 'participationFloorBps()(uint256)'); AF=$(call "$SWOOD" 'ageFloorBps()(uint256)')
if ! is_uint "$PF" || ! is_uint "$AF"; then
  bad "participationFloor < ageFloor" "unread: '$PF' '$AF'"
elif [ "$PF" -lt "$AF" ]; then
  ok "participationFloor < ageFloor" "$PF < $AF"
else
  bad "participationFloor < ageFloor" "$PF >= $AF (unclearable at launch)"
fi

echo; echo "── WOOD price source ──"
check "feed decimals == 8"            "$(call "$WFEED" 'decimals()(uint8)')"             "8"
# A late 24h heartbeat round must still price WOOD (audit V1-06): ETH_USD_MAX_AGE = 26h.
if [ "$POSTURE" = "mainnet" ]; then
  check "feed.ethUsdMaxAge == ETH_USD_MAX_AGE" "$(call "$WFEED" 'ethUsdMaxAge()(uint256)')" "$(param ETH_USD_MAX_AGE)"
fi

if [ "$HAS_TWAP" = 1 ]; then
  echo; echo "── WOOD V3 TWAP feed (SHE-398) ──"
  POOL=$(a WOOD_WETH_UNISWAP_V3_POOL)
  check "twapFeed.pool"                "$(call "$TWAP_FEED" 'pool()(address)')"           "$POOL"
  check "twapFeed.window == WOOD_TWAP_WINDOW" "$(call "$TWAP_FEED" 'window()(uint32)')"   "$(param WOOD_TWAP_WINDOW)"
  check "twapFeed.ethUsdMaxAge == ETH_USD_MAX_AGE" "$(call "$TWAP_FEED" 'ethUsdMaxAge()(uint256)')" "$(param ETH_USD_MAX_AGE)"
  RING=$(cast call "$POOL" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' --rpc-url "$RPC" 2>/dev/null | sed -n 5p | awk '{print $1}')
  TW=$(param WOOD_TWAP_WINDOW)
  if is_uint "$RING" && is_uint "$TW" && [ "$RING" -gt "$TW" ]; then ok "pool ring target > window" "$RING"
  else bad "pool ring target > window" "${RING:-unread} (needs window + 1)"; fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '%s%s checks passed, 0 failed, %s warnings (%s mode)%s\n' "$GRN" "$PASS" "$WARN" "$MODE" "$OFF"
else
  printf '%s%s passed, %s FAILED, %s warnings (%s mode)%s\n' "$RED" "$PASS" "$FAIL" "$WARN" "$MODE" "$OFF"; exit 1
fi
