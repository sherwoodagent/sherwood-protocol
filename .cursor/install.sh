#!/usr/bin/env bash
# Cloud Agent bootstrap for the Sherwood Protocol Foundry workspace.
# Idempotent: safe to re-run and safe to run against cached/prebuilt state.
set -euo pipefail

# Pin must match .github/workflows/ci.yml FOUNDRY_VERSION — forge fmt/build rules
# drift across versions, so a mismatch fails the format/goldens gates spuriously.
FOUNDRY_VERSION="v1.7.1"
FOUNDRY_BIN="$HOME/.foundry/bin"

if [ ! -x "$FOUNDRY_BIN/foundryup" ]; then
  curl -L https://foundry.paradigm.xyz | bash
fi
export PATH="$FOUNDRY_BIN:$PATH"

foundryup --install "$FOUNDRY_VERSION"

# Persist forge on PATH for future login shells (foundryup does not touch .bashrc).
PATH_LINE='export PATH="$HOME/.foundry/bin:$PATH"'
grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null || echo "$PATH_LINE" >>"$HOME/.bashrc"

# Pre-warm out/ + cache/ so the first agent build is incremental, not a ~17-min
# cold via_ir compile of the whole tree.
forge build

forge --version
