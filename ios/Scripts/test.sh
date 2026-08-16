#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh
cd Packages
swift build
swift test "${SWIFT_TEST_FLAGS[@]}" "$@"
