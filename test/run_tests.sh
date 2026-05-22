#!/usr/bin/env bash
# run_tests.sh - Run Busted Lua test suite for BookloreSync KOReader plugin
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

if ! command -v busted &>/dev/null; then
    echo "ERROR: busted not found in PATH (install via luarocks install busted)" >&2
    exit 1
fi

echo "Running Busted test suite"
busted --output utfTerminal --pattern "_spec%.lua$" test

echo ""
echo "All tests passed!"
