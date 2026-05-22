#!/usr/bin/env bash
# run_tests.sh - Run framework-based Lua tests with coverage.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
cd "$REPO_ROOT"

if ! command -v lua &>/dev/null; then
    echo "ERROR: lua not found in PATH" >&2
    exit 1
fi

LUA_VERSION="$(lua -e 'print(_VERSION:match("Lua (%d+%.%d+)"))')"
LUAROCKS_BIN="$(command -v "luarocks-$LUA_VERSION" || command -v luarocks || true)"

if [ -n "${LUAROCKS_BIN:-}" ]; then
    eval "$($LUAROCKS_BIN --lua-version="$LUA_VERSION" path)"
fi

if ! command -v busted &>/dev/null; then
    echo "ERROR: busted not found in PATH (install via luarocks install busted)" >&2
    exit 1
fi

if ! command -v luacov &>/dev/null; then
    echo "ERROR: luacov not found in PATH (install via luarocks install luacov)" >&2
    exit 1
fi

if ! command -v luacov-cobertura &>/dev/null; then
    echo "ERROR: luacov-cobertura not found in PATH (install via luarocks install luacov-cobertura)" >&2
    exit 1
fi

rm -f luacov.stats.out luacov.report.out coverage.xml

echo "Running Busted test suite"
busted --coverage --pattern "_spec%.lua$" test

echo ""
echo "Running Python schema tests"
python3 spec/test_database_schema.py

echo "Generating luacov text report"
luacov

echo "Generating Cobertura XML report"
luacov-cobertura -o coverage.xml

if [ ! -f coverage.xml ]; then
    echo "ERROR: coverage.xml was not generated" >&2
    exit 1
fi

TOTAL_COVERAGE=$(awk '/^Summary/{found=1} found && /^Total/{print $NF; exit}' luacov.report.out)
if [ -n "${TOTAL_COVERAGE:-}" ]; then
    echo "TOTAL_COVERAGE=${TOTAL_COVERAGE}"
fi

echo "All tests passed and coverage artifacts generated"
