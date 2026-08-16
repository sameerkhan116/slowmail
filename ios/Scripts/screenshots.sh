#!/usr/bin/env bash
# Renders every screen to PNG with no simulator. See Sources/Screenshots/main.swift
# for what the tool can and cannot verify.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh
OUT="${1:-$(pwd)/Screenshots}"
cd Packages
swift run Screenshots "${OUT}"
echo "screenshots in ${OUT}"
