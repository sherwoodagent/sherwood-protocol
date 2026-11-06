#!/usr/bin/env bash
# check-template-destinations.sh — mechanical backstop for the SHE-209 certification
# review invariant (docs/adapter-onboarding-checklist.md, "Certification review
# invariant"): a certified template must pay out only to `vault()` and must expose no
# payout / recipient / router address settable from `initialize` / `updateParams` data.
#
# Class certification admits EVERY clone of the template as a batch recipient, and the
# vault binding (`vault() == vault`) neutralizes a hostile clone only under that
# invariant. Nothing on-chain checks it, so this script pins the two mechanical halves
# against every file in src/strategies/:
#
#   1. Every ERC-20 movement out of a template (`transfer`, `safeTransfer`,
#      `transferFrom`, `safeTransferFrom`) names the vault or the template itself as
#      the destination — never a variable, a parameter, or a decoded field.
#   2. No identifier in a template carries a destination-shaped name
#      (`recipient` / `receiver` / `dest` / `destination` / `beneficiary` / `payout` /
#      `payee`) unless the same statement binds it to `address(this)` or the vault.
#      This is the checklist's own grep instruction, made a gate.
#
# Comments and string literals are stripped first, so prose may still use the words.
# Fails loudly (exit 1) listing every offending file:line. A legitimate new hit (e.g. a
# venue struct with a `recipient` field that the template fills with `address(this)`)
# is written so the binding is on the same statement; anything else is a design change
# and needs the checklist's reviewer sign-off, not an exemption here.
#
# Usage: ./script/check-template-destinations.sh [dir]   (default: src/strategies)
set -euo pipefail

cd "$(dirname "$0")/.."

DIR="${1:-src/strategies}"
[ -d "$DIR" ] || { echo "template-destinations: FAIL — no such directory: $DIR" >&2; exit 1; }

python3 - "$DIR" <<'PY'
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
files = sorted(root.rglob("*.sol"))
if not files:
    print(f"template-destinations: FAIL — no .sol files under {root}", file=sys.stderr)
    sys.exit(1)

# Destinations a template may pay. `_vault` is BaseStrategy's storage slot,
# `vault()` its getter; `address(this)` keeps funds inside the template.
BOUND = re.compile(r"address\(this\)|\bvault\(\)|\b_vault\b")
MOVES = re.compile(r"\.(safeTransferFrom|transferFrom|safeTransfer|transfer)\s*\(")
NAMES = re.compile(r"recipient|receiver|beneficiar|payout|payee|destination|\bdest\b", re.I)


def strip(src: str) -> str:
    """Blank out comments and string literals, preserving newlines for line numbers."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j])); i = j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(c + " " * (j - i - 2) + c if j - i >= 2 else c); i = j
        else:
            out.append(c); i += 1
    return "".join(out)


def call_args(code: str, start: int):
    """Split the balanced argument list opening at code[start] == '(' on top-level commas."""
    depth, args, cur = 0, [], []
    for k in range(start, len(code)):
        ch = code[k]
        if ch == "(":
            depth += 1
            if depth == 1:
                continue
        elif ch == ")":
            depth -= 1
            if depth == 0:
                args.append("".join(cur).strip())
                return args, k
        elif ch == "," and depth == 1:
            args.append("".join(cur).strip()); cur = []
            continue
        cur.append(ch)
    return args, len(code)


def statement_at(code: str, pos: int) -> str:
    a = code.rfind(";", 0, pos) + 1
    b = code.find(";", pos)
    return code[a:b if b >= 0 else len(code)]


failures = []
for path in files:
    code = strip(path.read_text())
    lineno = lambda pos: code.count("\n", 0, pos) + 1

    # 1. token movements: the `to` argument must be bound.
    for m in MOVES.finditer(code):
        args, _ = call_args(code, m.end() - 1)
        fn = m.group(1)
        to = args[1] if fn.endswith("From") and len(args) > 1 else (args[0] if args else "")
        if not BOUND.fullmatch(to.strip()):
            failures.append(f"{path}:{lineno(m.start())}: {fn}(...) pays `{to}`, not the vault or address(this)")

    # 2. destination-shaped identifiers must be bound on the same statement.
    for m in NAMES.finditer(code):
        stmt = statement_at(code, m.start())
        if not BOUND.search(stmt):
            failures.append(f"{path}:{lineno(m.start())}: destination-shaped identifier `{m.group(0)}` not bound to the vault or address(this)")

if failures:
    print("template-destinations: FAIL — SHE-209 certification invariant (see docs/adapter-onboarding-checklist.md):", file=sys.stderr)
    for f in failures:
        print(f"  {f}", file=sys.stderr)
    sys.exit(1)

print(f"template-destinations: OK ({len(files)} templates)")
PY
