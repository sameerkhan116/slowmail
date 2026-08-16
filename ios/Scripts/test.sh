#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh
cd Packages
swift build

# A swift-testing runtime that SwiftPM links but cannot introspect discovers no
# tests, runs nothing, and exits 0 — a green build that asserted nothing. The
# count is parsed back out and required to be non-zero so that silence fails.
output=$(swift test "${SWIFT_TEST_FLAGS[@]}" "$@" 2>&1) && status=0 || status=$?
printf '%s\n' "$output"

count=$(printf '%s\n' "$output" | sed -n 's/.*Test run with \([0-9][0-9]*\) test.*/\1/p' | tail -1)
if [[ -z "${count}" || "${count}" -eq 0 ]]; then
  echo "harness error: no tests were discovered or run" >&2
  exit 1
fi
exit "${status}"
