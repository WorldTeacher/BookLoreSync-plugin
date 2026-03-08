#!/usr/bin/env bash
# run_tests.sh - Run framework-based Lua tests with coverage.
# Exits 0 only if tests pass and coverage artifacts are generated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
busted --output utfTerminal --pattern "_spec%.lua$" test

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
