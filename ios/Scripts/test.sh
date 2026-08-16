#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh

# The fixtures are written as New York wall-clock times — `Fixtures.referenceDate`
# is 15:40 in New York, which is before the 17:00 collection and after it in
# other zones. Left to the machine's zone the suite passed here and failed in
# UTC, so it was testing the developer's location as much as the code.
#
# New York specifically, not UTC: it is west of UTC, so a `date` parsed as UTC
# midnight and rendered locally lands on the previous day. Pinning to UTC would
# hide that, which is the bug this suite exists to catch.
export TZ=America/New_York

filtered=0
for argument in "$@"; do
  case "${argument}" in
    --filter|--filter=*) filtered=1 ;;
  esac
done
tests_run=0
build_failed=0

run_package() {
  local package="$1"
  shift
  local output test_status count build_status

  cd "${package}" || return $?
  swift build || {
    build_status=$?
    build_failed=1
    cd - >/dev/null
    return "${build_status}"
  }

  # A swift-testing runtime that SwiftPM links but cannot introspect discovers no
  # tests, runs nothing, and exits 0 — a green build that asserted nothing. The
  # count is parsed back out and required to be non-zero so that silence fails.
  output=$(swift test "${SWIFT_TEST_FLAGS[@]}" "$@" 2>&1) && test_status=0 || test_status=$?
  cd - >/dev/null
  printf '%s\n' "$output"

  count=$(printf '%s\n' "$output" | sed -n 's/.*Test run with \([0-9][0-9]*\) test.*/\1/p' | tail -1)
  if [[ -z "${count}" || ("${count}" -eq 0 && "${filtered}" -eq 0) ]]; then
    echo "harness error: no tests were discovered or run" >&2
    return 1
  fi
  tests_run=$((tests_run + count))
  return "${test_status}"
}

status=0
run_package Packages "$@" || status=1
run_package Packages/MailClockKit "$@" || status=1
if [[ "${tests_run}" -eq 0 && "${build_failed}" -eq 0 ]]; then
  echo "harness error: no tests were discovered or run" >&2
  status=1
fi
exit "${status}"
