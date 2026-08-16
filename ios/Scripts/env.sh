#!/usr/bin/env bash
# Xcode is not required to build, test, or screenshot this package, but the
# Command Line Tools ship swift-testing in a framework SwiftPM does not search
# by default, and its interop dylib in a third directory. These flags point at
# both. Remove them once a full Xcode is installed.
set -euo pipefail

CLT="/Library/Developer/CommandLineTools"
TESTING_FRAMEWORKS="${CLT}/Library/Developer/Frameworks"
TESTING_LIBS="${CLT}/Library/Developer/usr/lib"

SWIFT_TEST_FLAGS=(
  -Xswiftc -F -Xswiftc "${TESTING_FRAMEWORKS}"
  -Xlinker -F -Xlinker "${TESTING_FRAMEWORKS}"
  -Xlinker -rpath -Xlinker "${TESTING_FRAMEWORKS}"
  -Xlinker -rpath -Xlinker "${TESTING_LIBS}"
)

# Fixtures are anchored to US Eastern. Pinning the zone keeps "arrived today"
# and the five o'clock cutoff deterministic wherever this runs.
export TZ="${TZ:-America/New_York}"
