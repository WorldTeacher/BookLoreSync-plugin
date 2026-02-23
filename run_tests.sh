#!/usr/bin/env bash
# run_tests.sh — Run all Booklore plugin unit tests.
# Exits 0 only if every test suite passes.
# Used by CI and can be run locally: bash run_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Require luajit; fall back to lua if unavailable.
if command -v luajit &>/dev/null; then
    LUA=luajit
elif command -v lua &>/dev/null; then
    LUA=lua
else
    echo "ERROR: neither luajit nor lua found in PATH" >&2
    exit 1
fi

echo "Using Lua runtime: $($LUA -v 2>&1 | head -1)"
echo ""

FAILED_SUITES=()

run_suite() {
    local file="$1"
    echo "──────────────────────────────────────────"
    echo "Running: $file"
    echo "──────────────────────────────────────────"
    if $LUA "$file"; then
        echo "[PASSED] $file"
    else
        echo "[FAILED] $file"
        FAILED_SUITES+=("$file")
    fi
    echo ""
}

run_suite "test_api_client.lua"
run_suite "test_main.lua"
run_suite "test_updater.lua"
run_suite "test_cfi.lua"

echo "══════════════════════════════════════════"
if [ ${#FAILED_SUITES[@]} -eq 0 ]; then
    echo "ALL TEST SUITES PASSED"
    exit 0
else
    echo "FAILED SUITES (${#FAILED_SUITES[@]}):"
    for s in "${FAILED_SUITES[@]}"; do
        echo "  - $s"
    done
    exit 1
fi
