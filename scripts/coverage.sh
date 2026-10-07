#!/usr/bin/env bash
# Runs the test suite with coverage and reports line coverage for Sources/CeeloCore.
# Usage: scripts/coverage.sh [--min PERCENT]
# Model integration tests run only when the FluidAudio models are downloaded; set CEELO_SKIP_MODEL_TESTS=1
# to skip them (CI does not have the models).
set -euo pipefail
cd "$(dirname "$0")/.."

min=""
if [[ "${1:-}" == "--min" ]]; then
    min="${2:?--min needs a percentage}"
fi

swift test --enable-code-coverage

bin="$(swift build --show-bin-path)"
profdata="$bin/codecov/default.profdata"
tests="$bin/ceeloPackageTests.xctest/Contents/MacOS/ceeloPackageTests"

xcrun llvm-cov report "$tests" -instr-profile "$profdata" Sources/CeeloCore
total="$(xcrun llvm-cov export "$tests" -instr-profile "$profdata" -summary-only Sources/CeeloCore \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"])')"
printf '\nLine coverage (Sources/CeeloCore): %.2f%%\n' "$total"

if [[ -n "$min" ]] && ! awk -v total="$total" -v min="$min" 'BEGIN { exit !(total >= min) }'; then
    echo "Coverage is below the required ${min}%" >&2
    exit 1
fi
